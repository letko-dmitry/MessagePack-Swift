import Foundation
import Testing

@testable import MessagePack

private let mapEncoder = MessagePackEncoder(dictionaryEncodingStrategy: .convertToMap)

private enum Suit: String, Codable, MessagePackSerializable {
    case hearts, spades
}

private enum Rank: Int, Codable, MessagePackSerializable {
    case one = 1, two
}

/// Read through their coding keys by `Dictionary`'s own conformance, unlike
/// the enums above.
private enum Slot: Int, Codable, CodingKeyRepresentable, MessagePackSerializable {
    case first = 1, second
}

private enum Tag: String, Codable, CodingKeyRepresentable, MessagePackSerializable {
    case a, b
}

@MessagePackSerializable
private struct Point: Codable, Hashable {
    var x: Int
    var y: Int
}

@MessagePackSerializable
private struct Holder: Codable, Equatable {
    var bytes: [Int8: String]
    var nested: [Int: [Double: Bool]]
    var points: [Suit: Point]
}

private let holder = Holder(bytes: [1: "x", -2: "y"], nested: [2: [0.5: true]], points: [.hearts: Point(x: 3, y: 4)])

@Suite("Codable dictionary strategy")
struct CodableDictionaryStrategyTests {
    @Test func defaultKeepsTheFormsOfEarlierVersions() throws {
        #expect([UInt8](try MessagePackEncoder().encode([1: "a"])) == [0x81, 0xa1, 0x31, 0xa1, 0x61])
        #expect([UInt8](try MessagePackEncoder().encode([Int8(1): 2])) == [0x92, 0x01, 0x02])
        #expect([UInt8](try MessagePackEncoder().encode(["k": 2])) == [0x81, 0xa1, 0x6b, 0x02])
    }

    @Test func convertToMapWritesWhatTheMacroWrites() throws {
        #expect([UInt8](try mapEncoder.encode([1: "a"])) == [0x81, 0x01, 0xa1, 0x61])
        #expect([UInt8](try mapEncoder.encode([Int8(1): 2])) == [0x81, 0x01, 0x02])

        try expectMacroBytes([1: "a", -7: "b", 300: "c"])
        try expectMacroBytes([Int8(-1): 2, 5: 6])
        try expectMacroBytes([UInt64.max: "max", 0: "zero"])
        try expectMacroBytes([1.5: true, -0.0: false])
        try expectMacroBytes([true: 1, false: 0])
        try expectMacroBytes(["k": 2, "l": 3])
        try expectMacroBytes([Suit.hearts: 1, .spades: 2])
        try expectMacroBytes([Rank.one: "1", .two: "2"])
        try expectMacroBytes([Slot.first: "1", .second: "2"])
        try expectMacroBytes([Tag.a: 1, .b: 2])
        try expectMacroBytes([Point(x: 1, y: 2): "p"])
        try expectMacroBytes([1: [Int8(2): "nested"]])
        try expectMacroBytes([Int: Int]())
        // Past 15 entries the header widens in place to a map 16.
        try expectMacroBytes(Dictionary(uniqueKeysWithValues: (0..<20).map { (Int8($0), $0) }))
        try expectMacroBytes(holder)
    }

    @Test func decoderReadsEveryForm() throws {
        try expectRoundTrips([1: "a", -7: "b"])
        try expectRoundTrips([Int8(-1): 2, 5: 6])
        try expectRoundTrips([1.5: true, 2: false])
        try expectRoundTrips([true: 1])
        try expectRoundTrips([Suit.hearts: 1, .spades: 2])
        try expectRoundTrips([Slot.first: "1", .second: "2"])
        try expectRoundTrips([Tag.a: 1])
        try expectRoundTrips([Point(x: 1, y: 2): "p"])
        try expectRoundTrips([1: [Int8(2): "nested"]])
        try expectRoundTrips([Int8: Int]())
        try expectRoundTrips(holder)
    }

    /// Only a dictionary's own decoding reads a map as its pairs.
    @Test func otherTypesStillRejectMaps() throws {
        let map = try mapEncoder.encode([Int8(1): 2])
        #expect {
            try MessagePackDecoder().decode([Rank].self, from: map)
        } throws: { error in
            if case DecodingError.typeMismatch = error { true } else { false }
        }

        // Keys of another type stay a mismatch.
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode([Int8: Int].self, from: MessagePackEncoder().encode(["a": 1]))
        }
    }

    @Test func duplicateKeysKeepTheLastValue() throws {
        // {1: "a", 1: "b"}
        let data = Data([0x82, 0x01, 0xa1, 0x61, 0x01, 0xa1, 0x62])
        #expect(try MessagePackDecoder().decode([Int8: String].self, from: data) == [1: "b"])
    }

    @Test func hostileMapCountThrows() throws {
        // A map 32 claiming 2^32-1 entries.
        let data = Data([0xdf, 0xff, 0xff, 0xff, 0xff, 0x01, 0x02])
        #expect {
            try MessagePackDecoder().decode([Int8: Int].self, from: data)
        } throws: { error in
            if case DecodingError.dataCorrupted = error { true } else { false }
        }
    }

    /// Like `Dictionary`'s own conformance, the coding path names `String`
    /// and `Int` keys, and other entries by their position.
    @Test func encodingErrorsNameTheKey() throws {
        let unrepresentable = Date(timeIntervalSince1970: .infinity)
        let cases: [(MessagePackEncoder, any Encodable, String, Int?)] = [
            (MessagePackEncoder(), [5: unrepresentable], "5", 5),
            (mapEncoder, [5: unrepresentable], "5", 5),
            (MessagePackEncoder(), ["k": unrepresentable], "k", nil),
            (mapEncoder, ["k": unrepresentable], "k", nil),
            (mapEncoder, [Int8(3): unrepresentable], "Index 0", 0),
        ]
        for (encoder, value, stringValue, intValue) in cases {
            #expect {
                try encoder.encode(value)
            } throws: { error in
                guard case EncodingError.invalidValue(_, let context) = error, let key = context.codingPath.last else {
                    return false
                }
                return key.stringValue == stringValue && key.intValue == intValue
            }
        }
    }

    private func expectMacroBytes<T: Encodable & MessagePackSerializable>(
        _ value: T, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        // The same instance, so both routes iterate a dictionary in the same
        // order.
        #expect(try mapEncoder.encode(value) == MessagePackSerializer.serialize(value), sourceLocation: sourceLocation)
    }

    private func expectRoundTrips<T: Codable & MessagePackSerializable & Equatable>(
        _ value: T, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for data in [MessagePackSerializer.serialize(value), try mapEncoder.encode(value), try MessagePackEncoder().encode(value)] {
            #expect(try MessagePackDecoder().decode(T.self, from: data) == value, sourceLocation: sourceLocation)
        }
        #expect(
            try MessagePackSerializer.deserialize(T.self, from: mapEncoder.encode(value)) == value,
            sourceLocation: sourceLocation)
    }
}
