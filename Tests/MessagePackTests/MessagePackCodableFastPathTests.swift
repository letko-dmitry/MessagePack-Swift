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

private func decodingDescription(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let DecodingError.typeMismatch(_, context),
        let DecodingError.valueNotFound(_, context),
        let DecodingError.keyNotFound(_, context),
        let DecodingError.dataCorrupted(context)
    {
        return context.debugDescription
    } catch {
        return nil
    }
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

    @Test func errorsReportTheByteOffset() throws {
        // fixmap(1) { "value": "x" }: the mismatched value starts at byte 7.
        let data = Data([0x81, 0xa5] + Array("value".utf8) + [0xa1, 0x78])

        do {
            _ = try MessagePackDecoder().decode(Leaf.self, from: data)
            Issue.record("Expected a type mismatch")
        } catch let DecodingError.typeMismatch(_, context) {
            #expect(context.debugDescription.hasSuffix("at byte offset 7"))
        }
    }

    @Test func errorsPointAtTheValueStart() throws {
        struct Keyed: Decodable {
            var value: Int8
        }

        struct Wrapped: Decodable {
            var value: Int8

            init(from decoder: Decoder) throws {
                value = try decoder.singleValueContainer().decode(Int8.self)
            }
        }

        // uint 16 300 does not fit in Int8. In fixmap(1) { "value": 300 } it
        // starts at byte 7; on its own, at byte 0.
        let keyed = Data([0x81, 0xa5] + Array("value".utf8) + [0xcd, 0x01, 0x2c])
        let single = Data([0xcd, 0x01, 0x2c])

        let keyedDescription = decodingDescription { _ = try MessagePackDecoder().decode(Keyed.self, from: keyed) }
        #expect(keyedDescription?.hasSuffix("at byte offset 7") == true)

        let wrappedDescription = decodingDescription { _ = try MessagePackDecoder().decode(Wrapped.self, from: single) }
        #expect(wrappedDescription?.hasSuffix("at byte offset 0") == true)
    }

    @Test func corruptDataErrorsPointAtTheValueOfTheirPath() throws {
        struct Ints: Decodable {
            var a: [Int]
        }

        struct Counts: Decodable {
            var a: [String: Int]
        }

        /// Arrays nested in arrays, as deep as the input goes.
        struct Deep: Decodable {
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                if !container.isAtEnd {
                    _ = try container.decode(Deep.self)
                }
            }
        }

        struct NestedMap: Decodable {
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                _ = try container.nestedContainer(keyedBy: AnyKey.self)
            }
        }

        func decoding<T: Decodable>(_ type: T.Type) -> (Data) throws -> Void {
            { _ = try MessagePackDecoder().decode(type, from: $0) }
        }

        let value = Array("value".utf8)
        let leaves = Array("leaves".utf8)
        let list = Array("list".utf8)
        // Each case fails at a different place in the decoder, at the value
        // the error's coding path names.
        let cases: [(name: String, bytes: [UInt8], decode: (Data) throws -> Void, offset: Int, path: [String])] = [
            ("trailing bytes", [0x01, 0x02], decoding(Int.self), 1, []),
            ("truncated map header", [0x91, 0xde, 0x00], decoding([Leaf].self), 1, ["#0"]),
            ("map count past the end", [0x91, 0xde, 0xff, 0xff], decoding([Leaf].self), 1, ["#0"]),
            ("truncated array header", [0x81, 0xa6] + leaves + [0xdd, 0x00], decoding(Branch.self), 8, ["leaves"]),
            (
                "array count past the end", [0x81, 0xa6] + leaves + [0xdc, 0xff, 0xff], decoding(Branch.self), 8,
                ["leaves"]
            ),
            (
                "depth limit", [UInt8](repeating: 0x91, count: 129) + [0x90], decoding(Deep.self), 128,
                Array(repeating: "#0", count: 128)
            ),
            ("skipping a nested map", [0x91, 0x81, 0xa1, 0x6b, 0xa5, 0x61], decoding(NestedMap.self), 1, ["#0"]),
            ("key lookup", [0x91, 0x82, 0xa1, 0x61, 0x01, 0xa5, 0x76], decoding([Leaf].self), 1, ["#0"]),
            (
                "end of a map after its last read", [0x91, 0x82, 0xa5] + value + [0x01, 0xa4] + list + [0x92, 0x01],
                decoding([Leaf].self), 1, ["#0"]
            ),
            ("truncated [Int] header", [0x81, 0xa1, 0x61, 0xdc, 0x00], decoding(Ints.self), 3, ["a"]),
            ("[Int] count past the end", [0x81, 0xa1, 0x61, 0xdc, 0xff, 0xff], decoding(Ints.self), 3, ["a"]),
            ("truncated [String: Int] header", [0x81, 0xa1, 0x61, 0xde, 0x00], decoding(Counts.self), 3, ["a"]),
            ("[String: Int] count past the end", [0x81, 0xa1, 0x61, 0xde, 0xff, 0xff], decoding(Counts.self), 3, ["a"]),
            ("truncated [String: Int] key", [0x81, 0xa1, 0x61, 0x81, 0xa5, 0x62], decoding(Counts.self), 3, ["a"]),
            ("truncated [String] element", [0x92, 0xa1, 0x61, 0xa3, 0x62], decoding([String].self), 3, ["#1"]),
        ]

        for test in cases {
            let data = Data(test.bytes)
            let description = decodingDescription { try test.decode(data) }
            #expect(
                description?.hasSuffix("at byte offset \(test.offset)") == true,
                "\(test.name): \(description ?? "no error")")
            #expect(decodingPath { try test.decode(data) } == test.path, "\(test.name)")
        }
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

    @Test func duplicateWireKeysFirstWins() throws {
        // fixmap(2) { "a": 1, "a": 2 }, as `Dictionary.init(from:)` reads it.
        let data = Data([0x82, 0xa1, 0x61, 0x01, 0xa1, 0x61, 0x02])
        #expect(try MessagePackDecoder().decode([String: Int].self, from: data) == ["a": 1])
        // The same through the container route, which `[String: Int8]` takes.
        #expect(try MessagePackDecoder().decode([String: Int8].self, from: data) == ["a": 1])
    }

    @Test func duplicateKeysInStructsReadTheFirst() throws {
        // The spec leaves duplicate keys to the implementation. The value
        // tree and the macro route keep the last entry; `Codable` (structs and
        // dictionaries alike) looks keys up and reads the first, since finding
        // a later duplicate would cost every lookup a scan of the rest of the
        // map.
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

    @Test func nonMapValueThrows() throws {
        let data = try MessagePackSerializer.serialize(value: .array([.uint8(1)]))
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode([String: Int].self, from: data)
        }
    }
}
