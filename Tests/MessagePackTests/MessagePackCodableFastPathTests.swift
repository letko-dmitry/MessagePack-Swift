import Foundation
import Testing

@testable import MessagePack

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func keys(_ path: [CodingKey]) -> [String] {
    path.map { $0.intValue.map { "#\($0)" } ?? $0.stringValue }
}

private func decodingPath(_ body: () throws -> Void) -> [String]? {
    do {
        try body()
        return nil
    } catch let DecodingError.typeMismatch(_, context),
        let DecodingError.valueNotFound(_, context),
        let DecodingError.keyNotFound(_, context),
        let DecodingError.dataCorrupted(context)
    {
        return keys(context.codingPath)
    } catch {
        return nil
    }
}

// MARK: - Coding paths

@Suite("Codable coding paths")
struct CodableCodingPathTests {
    private struct Leaf: Codable {
        var value: Int
    }

    private struct Branch: Codable {
        var leaves: [Leaf]
    }

    private struct Root: Codable {
        var branch: Branch
    }

    @Test func decodingErrorsCarryTheFullPath() throws {
        let data = try MessagePackSerializer.serialize(
            value: .map([
                .string("branch"): .map([
                    .string("leaves"): .array([
                        .map([.string("value"): .uint8(1)]),
                        .map([.string("value"): .string("x")]),
                    ])
                ])
            ]))

        let path = decodingPath { _ = try MessagePackDecoder().decode(Root.self, from: data) }
        #expect(path == ["branch", "leaves", "#1", "value"])
    }

    @Test func arraysOfOptionalStructsKeepTheirCursor() throws {
        struct Item: Codable, Equatable {
            var id: Int
            var tags: [String]
        }

        let items: [Item?] = [Item(id: 1, tags: ["a"]), nil, Item(id: 2, tags: []), nil, Item(id: 3, tags: ["b", "c"])]
        let data = try MessagePackEncoder().encode(items)
        #expect(try MessagePackDecoder().decode([Item?].self, from: data) == items)
    }

    @Test func decodersExposeTheirPath() throws {
        struct Probe: Decodable {
            var path: [String]

            init(from decoder: Decoder) throws {
                path = keys(decoder.codingPath)
            }
        }

        struct Outer: Decodable {
            var probes: [String: [Probe]]
        }

        let data = try MessagePackSerializer.serialize(
            value: .map([.string("probes"): .map([.string("a"): .array([.nil, .nil])])]))
        let outer = try MessagePackDecoder().decode(Outer.self, from: data)
        #expect(outer.probes["a"]?.map(\.path) == [["probes", "a", "#0"], ["probes", "a", "#1"]])
    }

    @Test func encodersExposeTheirPath() throws {
        final class Recorder: @unchecked Sendable {
            var paths: [[String]] = []
        }

        struct Probe: Encodable {
            let recorder: Recorder

            func encode(to encoder: Encoder) throws {
                recorder.paths.append(keys(encoder.codingPath))
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }

        struct Outer: Encodable {
            let probes: [String: [Probe]]
        }

        let recorder = Recorder()
        _ = try MessagePackEncoder().encode(Outer(probes: ["a": [Probe(recorder: recorder), Probe(recorder: recorder)]]))
        #expect(recorder.paths == [["probes", "a", "#0"], ["probes", "a", "#1"]])
    }

    /// Paths of finished values are dropped and their room reused, which
    /// must not leak into the paths of later siblings and nested containers.
    @Test func encoderPathsSurviveSiblingsAndNestedContainers() throws {
        final class Recorder: @unchecked Sendable {
            var paths: [[String]] = []
        }

        struct Probe: Encodable {
            let recorder: Recorder

            func encode(to encoder: Encoder) throws {
                recorder.paths.append(keys(encoder.codingPath))
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }

        struct Outer: Encodable {
            enum Keys: String, CodingKey {
                case a, b, c
            }

            let recorder: Recorder

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(Probe(recorder: recorder), forKey: .a)
                var nested = container.nestedUnkeyedContainer(forKey: .b)
                try nested.encode(Probe(recorder: recorder))
                try nested.encode(Probe(recorder: recorder))
                try container.encode(Probe(recorder: recorder), forKey: .c)
                try Probe(recorder: recorder).encode(to: container.superEncoder())
                recorder.paths.append(keys(nested.codingPath))
            }
        }

        let recorder = Recorder()
        _ = try MessagePackEncoder().encode([Outer(recorder: recorder)])
        #expect(recorder.paths == [["#0", "a"], ["#0", "b", "#0"], ["#0", "b", "#1"], ["#0", "c"], ["#0", "super"], ["#0", "b"]])
    }

    /// A closing nested container drops its path node, but not one a super
    /// encoder requested while it was open still needs.
    @Test func superEncoderPathOutlivesANestedContainerClosedBeforeIt() throws {
        final class Recorder: @unchecked Sendable {
            var paths: [[String]] = []
        }

        struct Probe: Encodable {
            let recorder: Recorder

            func encode(to encoder: Encoder) throws {
                recorder.paths.append(keys(encoder.codingPath))
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }

        struct Outer: Encodable {
            enum Keys: String, CodingKey {
                case rows, x
            }

            let recorder: Recorder

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                for _ in 0..<3 {
                    var rows = container.nestedUnkeyedContainer(forKey: .rows)
                    try rows.encode(Probe(recorder: recorder))
                }
                var row = container.nestedUnkeyedContainer(forKey: .rows)
                let superEncoder = container.superEncoder()
                try row.encode(1)
                try container.encode(2, forKey: .x)  // closes `row`
                try Probe(recorder: recorder).encode(to: superEncoder)
            }
        }

        let recorder = Recorder()
        _ = try MessagePackEncoder().encode(Outer(recorder: recorder))
        #expect(recorder.paths == [["rows", "#0"], ["rows", "#0"], ["rows", "#0"], ["super"]])
    }

    @Test func encodingErrorsCarryTheFullPath() throws {
        struct Holder: Encodable {
            var dates: [Date]
        }

        do {
            _ = try MessagePackEncoder().encode(["holder": Holder(dates: [.now, Date(timeIntervalSince1970: .infinity)])])
            Issue.record("Expected an encoding error")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(keys(context.codingPath) == ["holder", "dates", "#1"])
        }
    }
}

// MARK: - decodeIfPresent

@Suite("Codable decodeIfPresent")
struct CodableDecodeIfPresentTests {
    private struct Sparse: Decodable {
        struct Inner: Decodable, Equatable {
            var value: Int
        }

        var number: Int?
        var inner: Inner?
    }

    @Test func presentNilAndAbsentValues() throws {
        let present = try MessagePackSerializer.serialize(
            value: .map([.string("number"): .uint8(5), .string("inner"): .map([.string("value"): .uint8(7)])]))
        let decoded = try MessagePackDecoder().decode(Sparse.self, from: present)
        #expect(decoded.number == 5)
        #expect(decoded.inner == Sparse.Inner(value: 7))

        let explicitNil = try MessagePackSerializer.serialize(
            value: .map([.string("number"): .nil, .string("inner"): .nil]))
        let decodedNil = try MessagePackDecoder().decode(Sparse.self, from: explicitNil)
        #expect(decodedNil.number == nil)
        #expect(decodedNil.inner == nil)

        let absent = try MessagePackSerializer.serialize(value: .map([:]))
        let decodedAbsent = try MessagePackDecoder().decode(Sparse.self, from: absent)
        #expect(decodedAbsent.number == nil)
        #expect(decodedAbsent.inner == nil)
    }

    @Test func mismatchedPresentValueThrows() throws {
        let data = try MessagePackSerializer.serialize(value: .map([.string("number"): .string("five")]))
        let path = decodingPath { _ = try MessagePackDecoder().decode(Sparse.self, from: data) }
        #expect(path == ["number"])
    }

    @Test func repeatedAndOutOfOrderLookupsResolve() throws {
        struct Probe: Decodable {
            enum Keys: String, CodingKey { case a, b, c }
            var values: [Int]

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                var values: [Int] = []
                for key in [Keys.c, .c, .a, .b, .a, .c] where container.contains(key) {
                    values.append(try container.decode(Int.self, forKey: key))
                }
                self.values = values
            }
        }

        let data = try MessagePackSerializer.serialize(
            value: .map([.string("a"): .uint8(1), .string("b"): .uint8(2), .string("c"): .uint8(3)]))
        #expect(try MessagePackDecoder().decode(Probe.self, from: data).values == [3, 3, 1, 2, 1, 3])
    }
}

// MARK: - String-keyed dictionaries

@Suite("Codable string-keyed dictionaries")
struct CodableStringKeyedDictionaryTests {
    @Test func roundTrips() throws {
        let ints = ["a": 1, "b": -2, "c": .max]
        #expect(try MessagePackDecoder().decode([String: Int].self, from: MessagePackEncoder().encode(ints)) == ints)

        let strings = ["a": "x", "": "empty key"]
        #expect(try MessagePackDecoder().decode([String: String].self, from: MessagePackEncoder().encode(strings)) == strings)

        let doubles = ["pi": 3.14, "inf": .infinity]
        #expect(try MessagePackDecoder().decode([String: Double].self, from: MessagePackEncoder().encode(doubles)) == doubles)

        let flags = ["on": true, "off": false]
        #expect(try MessagePackDecoder().decode([String: Bool].self, from: MessagePackEncoder().encode(flags)) == flags)
    }

    @Test func outputMatchesTheKeyedContainerRoute() throws {
        struct ViaContainer: Encodable {
            let dictionary: [String: Int]

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: AnyKey.self)
                for (key, value) in dictionary {
                    try container.encode(value, forKey: AnyKey(stringValue: key))
                }
            }
        }

        let dictionary = Dictionary(uniqueKeysWithValues: (0..<40).map { ("key\($0)", $0 * 1_000) })
        #expect(try MessagePackEncoder().encode(dictionary) == MessagePackEncoder().encode(ViaContainer(dictionary: dictionary)))
    }

    /// Maps the fast path leaves to the container route, which `[String: Int8]`
    /// always takes, decode as through it.
    @Test func duplicateWireKeysDecodeAsThroughTheContainers() throws {
        // fixmap(2) { "a": 1, "a": 2 }: the second lookup of "a" starts at
        // the first match.
        let adjacent = Data([0x82, 0xa1, 0x61, 0x01, 0xa1, 0x61, 0x02])
        #expect(try MessagePackDecoder().decode([String: Int].self, from: adjacent) == ["a": 1])
        #expect(try MessagePackDecoder().decode([String: Int8].self, from: adjacent) == ["a": 1])

        // fixmap(3) { "a": 1, "b": 2, "a": 3 }: it starts after "b".
        let apart = Data([0x83, 0xa1, 0x61, 0x01, 0xa1, 0x62, 0x02, 0xa1, 0x61, 0x03])
        #expect(try MessagePackDecoder().decode([String: Int].self, from: apart) == ["a": 3, "b": 2])
        #expect(try MessagePackDecoder().decode([String: Int8].self, from: apart) == ["a": 3, "b": 2])
    }

    @Test func keysThatAreNotUTF8AreSkipped() throws {
        // fixmap(2) { "\xff": 1, "b": 2 }
        let data = Data([0x82, 0xa1, 0xff, 0x01, 0xa1, 0x62, 0x02])
        #expect(try MessagePackDecoder().decode([String: Int].self, from: data) == ["b": 2])
        #expect(try MessagePackDecoder().decode([String: Int8].self, from: data) == ["b": 2])
    }

    @Test func duplicateKeysInStructsReadTheFirst() throws {
        // The spec leaves duplicate keys to the implementation. The value
        // tree and the macro route keep the last entry; `Codable` looks each
        // key up starting from the previous match, so a lone field reads the
        // first entry.
        struct Box: Decodable {
            var value: Int
        }

        let data = Data([0x82, 0xa5] + Array("value".utf8) + [0x01, 0xa5] + Array("value".utf8) + [0x02])
        #expect(try MessagePackDecoder().decode(Box.self, from: data).value == 1)
    }

    @Test func integerWireKeysBecomeStrings() throws {
        let data = try MessagePackSerializer.serialize(value: .map([.string("a"): .uint8(1), .uint8(2): .uint8(3)]))
        #expect(try MessagePackDecoder().decode([String: Int].self, from: data) == ["a": 1, "2": 3])
    }

    @Test func mismatchedValueReportsItsKey() throws {
        let data = try MessagePackSerializer.serialize(
            value: .map([.string("outer"): .map([.string("a"): .uint8(1), .string("b"): .string("x")])]))
        let path = decodingPath { _ = try MessagePackDecoder().decode([String: [String: Int]].self, from: data) }
        #expect(path == ["outer", "b"])
    }

    @Test func nonMapValueIsAMismatchForAnyDictionary() throws {
        let data = try MessagePackSerializer.serialize(value: .array([.uint8(1)]))
        #expect {
            try MessagePackDecoder().decode([String: Int].self, from: data)
        } throws: { error in
            guard case DecodingError.typeMismatch(let type, _) = error else { return false }
            return type == [String: Any].self
        }
    }
}
