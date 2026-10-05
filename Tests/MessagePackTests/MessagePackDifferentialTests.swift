import Foundation
import Testing

@testable import MessagePack

/// Deterministic generator (SplitMix64), so every run checks the same
/// inputs and a failure reproduces from its seed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

private enum Shape {
    /// Everything the format has.
    case any
    /// What `Codable` can express: string map keys, no extensions.
    case codable
}

private func randomValue(
    _ generator: inout SeededGenerator, shape: Shape, depth: Int = 0
) -> MessagePackValue {
    // One value in eight is an array or a map, while nesting is shallow.
    if depth < 3, Int.random(in: 0..<8, using: &generator) == 0 {
        return randomContainer(&generator, shape: shape, depth: depth)
    }

    return randomScalar(&generator, shape: shape)
}

private func randomScalar(_ generator: inout SeededGenerator, shape: Shape) -> MessagePackValue {
    // Extensions come last, as `Codable` has none.
    let caseCount = shape == .any ? 15 : 14

    switch Int.random(in: 0..<caseCount, using: &generator) {
    case 0: return .nil
    case 1: return .bool(Bool.random(using: &generator))
    case 2: return .int8(Int8.random(in: .min ... -1, using: &generator))
    case 3: return .int16(Int16.random(in: .min ... .max, using: &generator))
    case 4: return .int32(Int32.random(in: .min ... .max, using: &generator))
    case 5: return .int64(Int64.random(in: .min ... .max, using: &generator))
    case 6: return .uint8(UInt8.random(in: 0 ... .max, using: &generator))
    case 7: return .uint16(UInt16.random(in: 0 ... .max, using: &generator))
    case 8: return .uint32(UInt32.random(in: 0 ... .max, using: &generator))
    case 9: return .uint64(UInt64.random(in: 0 ... .max, using: &generator))
    case 10: return .float32(Float(Int16.random(in: .min ... .max, using: &generator)) / 64)
    case 11: return .float64(Double.random(in: -1e12...1e12, using: &generator))
    case 12: return .string(randomString(&generator))
    case 13:
        let count = Int.random(in: 0...40, using: &generator)
        return .binary(Data((0..<count).map { _ in UInt8.random(in: 0 ... .max, using: &generator) }))
    default:
        let count = [1, 2, 4, 8, 16, 3, 300][Int.random(in: 0..<7, using: &generator)]
        let type = Int8.random(in: 0 ... .max, using: &generator)
        return .ext(type: type, data: Data((0..<count).map { _ in UInt8.random(in: 0 ... .max, using: &generator) }))
    }
}

private func randomContainer(
    _ generator: inout SeededGenerator, shape: Shape, depth: Int
) -> MessagePackValue {
    if Bool.random(using: &generator) {
        let count = Int.random(in: 0...6, using: &generator)
        return .array((0..<count).map { _ in randomValue(&generator, shape: shape, depth: depth + 1) })
    }

    var map: [MessagePackValue: MessagePackValue] = [:]
    for _ in 0..<Int.random(in: 0...6, using: &generator) {
        let key: MessagePackValue =
            shape == .codable || Bool.random(using: &generator)
            ? .string(randomString(&generator))
            : .uint16(UInt16.random(in: 0 ... .max, using: &generator))
        map[key] = randomValue(&generator, shape: shape, depth: depth + 1)
    }
    return .map(map)
}

private func randomString(_ generator: inout SeededGenerator) -> String {
    let alphabet = Array("abcXYZ019_- éß日本🎌")
    let count = [0, 1, 5, 31, 32, 40][Int.random(in: 0..<6, using: &generator)]
    return String((0..<count).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
}

// MARK: - Codable mirror

/// A value `Codable` cannot express (a non-string map key, an extension),
/// which the `.codable` shape never generates.
private struct UnsupportedShape: Error {}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

/// Encodes a value tree through the `Codable` containers, the route a
/// `Codable` model takes, and decodes one back by trying each type.
private struct CodableValue: Codable {
    var value: MessagePackValue

    init(_ value: MessagePackValue) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        switch value {
        case .nil:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let v): try encodeSingle(v, to: encoder)
        case .int8(let v): try encodeSingle(v, to: encoder)
        case .int16(let v): try encodeSingle(v, to: encoder)
        case .int32(let v): try encodeSingle(v, to: encoder)
        case .int64(let v): try encodeSingle(v, to: encoder)
        case .uint8(let v): try encodeSingle(v, to: encoder)
        case .uint16(let v): try encodeSingle(v, to: encoder)
        case .uint32(let v): try encodeSingle(v, to: encoder)
        case .uint64(let v): try encodeSingle(v, to: encoder)
        case .float32(let v): try encodeSingle(v, to: encoder)
        case .float64(let v): try encodeSingle(v, to: encoder)
        case .string(let v): try encodeSingle(v, to: encoder)
        case .binary(let v): try encodeSingle(v, to: encoder)
        case .array(let elements):
            var container = encoder.unkeyedContainer()
            for element in elements {
                try container.encode(CodableValue(element))
            }
        case .map(let entries):
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, element) in entries {
                guard case .string(let name) = key else { throw UnsupportedShape() }
                try container.encode(CodableValue(element), forKey: AnyKey(stringValue: name))
            }
        case .ext:
            throw UnsupportedShape()
        }
    }

    private func encodeSingle(_ value: some Encodable, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyKey.self) {
            var map: [MessagePackValue: MessagePackValue] = [:]
            for key in container.allKeys {
                map[.string(key.stringValue)] = try container.decode(CodableValue.self, forKey: key).value
            }
            value = .map(map)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var elements: [MessagePackValue] = []
            while !container.isAtEnd {
                elements.append(try container.decode(CodableValue.self).value)
            }
            value = .array(elements)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .nil
        } else if let v = try? container.decode(Bool.self) {
            value = .bool(v)
        } else if let v = try? container.decode(String.self) {
            value = .string(v)
        } else if let v = try? container.decode(Data.self) {
            value = .binary(v)
        } else if let v = try? container.decode(Int64.self) {
            value = .int64(v)
        } else if let v = try? container.decode(UInt64.self) {
            value = .uint64(v)
        } else {
            value = .float64(try container.decode(Double.self))
        }
    }
}

/// Numbers compared by value, as the `Codable` route cannot tell a float
/// holding a whole number from an integer.
private func normalized(_ value: MessagePackValue) -> MessagePackValue {
    switch value {
    case .array(let elements):
        return .array(elements.map(normalized))
    case .map(let entries):
        return .map(Dictionary(uniqueKeysWithValues: entries.map { (normalized($0), normalized($1)) }))
    case .float32(let v):
        return normalizedNumber(Double(v))
    case .float64(let v):
        return normalizedNumber(v)
    default:
        if let v = value.int64Value { return .int64(v) }
        if let v = value.uint64Value { return .uint64(v) }
        return value
    }
}

private func normalizedNumber(_ value: Double) -> MessagePackValue {
    if let v = Int64(exactly: value) { return .int64(v) }
    if let v = UInt64(exactly: value) { return .uint64(v) }
    return .float64(value)
}

// MARK: - Tests

@Suite("Differential routes")
struct DifferentialRouteTests {
    @Test func serializerAndMacroRoutesAgree() throws {
        var generator = SeededGenerator(state: 0x5eed_0001)

        for _ in 0..<400 {
            let value = randomValue(&generator, shape: .any)
            let bytes = try MessagePackSerializer.serialize(value: value)

            #expect(MessagePackSerializer.serialize(value) == bytes, "\(value)")

            // Parsing picks the narrowest integer case and rebuilds maps (in
            // their own order), so values compare after normalization.
            let parsed = try MessagePackSerializer.deserialize(data: bytes)
            #expect(normalized(parsed) == normalized(value), "\(value)")
            #expect(try MessagePackSerializer.deserialize(MessagePackValue.self, from: bytes) == parsed, "\(value)")
        }
    }

    @Test func codableRouteAgreesWithTheSerializer() throws {
        var generator = SeededGenerator(state: 0x5eed_0002)

        for _ in 0..<400 {
            let value = randomValue(&generator, shape: .codable)
            let bytes = try MessagePackSerializer.serialize(value: value)

            #expect(try MessagePackEncoder().encode(CodableValue(value)) == bytes, "\(value)")

            let decoded = try MessagePackDecoder().decode(CodableValue.self, from: bytes).value
            #expect(normalized(decoded) == normalized(value), "\(value)")
        }
    }
}

@Suite("Codable container headers")
struct CodableContainerHeaderTests {
    private static func map(_ count: Int) -> MessagePackValue {
        .map(Dictionary(uniqueKeysWithValues: (0..<count).map { (.string("key\($0)"), .uint32(UInt32($0))) }))
    }

    /// Headers start as fixmap/fixarray and widen in place at 16 and 65,536
    /// entries; the bytes must match the serializer's, which knows every
    /// count up front.
    @Test(arguments: [0, 15, 16, 17, 65_535, 65_536, 65_537])
    func headersWidenToTheSerializersFormats(count: Int) throws {
        let values: [MessagePackValue] = [
            .array((0..<count).map { .uint32(UInt32($0)) }),
            Self.map(count),
        ]

        for value in values {
            #expect(try MessagePackEncoder().encode(CodableValue(value)) == MessagePackSerializer.serialize(value: value))
        }
    }

    /// Nested containers widen while their parents stay open, and the parents
    /// widen after them, moving the nested bytes.
    @Test func nestedHeadersWiden() throws {
        let value = MessagePackValue.array(
            (0..<17).map { index in
                .map([
                    .string("values"): .array((0..<(index * 4)).map { .uint32(UInt32($0)) }),
                    .string("map"): Self.map(index),
                ])
            })

        #expect(try MessagePackEncoder().encode(CodableValue(value)) == MessagePackSerializer.serialize(value: value))
    }

    /// Nesting deeper than the encoder's stacks start out with moves them to
    /// the heap mid-encode.
    @Test func deepNestingOutgrowsTheEncoderStacks() throws {
        var value = MessagePackValue.array([.uint8(1)])
        for depth in 0..<100 {
            value = depth % 2 == 0 ? .map([.string("level\(depth)"): value]) : .array([.nil, value])
        }

        #expect(try MessagePackEncoder().encode(CodableValue(value)) == MessagePackSerializer.serialize(value: value))
    }

    @Test func unkeyedCountFollowsWidenedHeaders() throws {
        struct Counting: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                for index in 0..<70_000 {
                    guard container.count == index else {
                        throw EncodingError.invalidValue(index, .init(codingPath: [], debugDescription: "count \(container.count)"))
                    }
                    try container.encode(index)
                }
            }
        }

        let data = try MessagePackEncoder().encode(Counting())
        #expect(try MessagePackDecoder().decode([Int].self, from: data) == Array(0..<70_000))
    }

    /// A super encoder keeps its parent's header position, which widening
    /// does not move.
    @Test func superEncoderActivatedAfterItsParentWidened() throws {
        struct LateSuper: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: AnyKey.self)
                let superEncoder = container.superEncoder()
                for index in 0..<20 {
                    try container.encode(index, forKey: AnyKey(stringValue: "key\(index)"))
                }
                var single = superEncoder.singleValueContainer()
                try single.encode("late")
            }
        }

        let data = try MessagePackEncoder().encode(LateSuper())
        var expected = Dictionary(uniqueKeysWithValues: (0..<20).map { (MessagePackValue.string("key\($0)"), MessagePackValue.uint8(UInt8($0))) })
        expected[.string("super")] = .string("late")
        #expect(try MessagePackSerializer.deserialize(data: data) == .map(expected))
    }
}

@Suite("Hostile input")
struct HostileInputTests {
    private struct Probe: Codable {
        var id: Int?
        var name: String?
        var values: [Double]?
        var nested: [String: Int]?
        var children: [Probe]?
        var decimal: Decimal?
    }

    /// Mutated and truncated encodings must throw or decode, never crash or
    /// hang, on every route.
    @Test func mutatedInputNeverCrashes() throws {
        var generator = SeededGenerator(state: 0x5eed_0003)

        let seeds: [Data] = try (0..<40).map { _ in
            try MessagePackSerializer.serialize(value: randomValue(&generator, shape: .any))
        } + [
            try MessagePackEncoder().encode(
                Probe(
                    id: 1, name: "x", values: [1.5, 2], nested: ["a": 1],
                    children: [Probe(id: 2, name: nil, values: nil, nested: nil, children: [], decimal: 0.5)],
                    decimal: nil))
        ]

        for _ in 0..<20_000 {
            var bytes = [UInt8](seeds[Int.random(in: 0..<seeds.count, using: &generator)])
            guard !bytes.isEmpty else { continue }

            for _ in 0...Int.random(in: 0...3, using: &generator) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                switch Int.random(in: 0..<4, using: &generator) {
                case 0: bytes[index] = UInt8.random(in: 0 ... .max, using: &generator)
                case 1: bytes.removeSubrange(index...)
                case 2: bytes.insert(UInt8.random(in: 0 ... .max, using: &generator), at: index)
                default: bytes[index] ^= 0x80
                }
                if bytes.isEmpty { bytes = [0xc0] }
            }

            let data = Data(bytes)
            _ = try? MessagePackSerializer.deserialize(data: data)
            _ = try? MessagePackSerializer.deserialize(MessagePackValue.self, from: data)
            _ = try? MessagePackDecoder().decode(CodableValue.self, from: data)
            _ = try? MessagePackDecoder().decode(Probe.self, from: data)
        }
    }
}
