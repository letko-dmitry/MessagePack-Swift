import Foundation
import Testing

@testable import MessagePack

private struct Box<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value
}

/// Encodes a `Decimal` through its own `Codable` conformance, the map of
/// fields that the default `.deferredToDecimal` strategy writes.
private struct DeferredDecimal: Encodable {
    let decimal: Decimal

    func encode(to encoder: Encoder) throws {
        try decimal.encode(to: encoder)
    }
}

// MARK: - Decimal

@Suite("Codable Decimal")
struct CodableDecimalTests {
    /// `Decimal` has no MessagePack type: it goes through its own `Codable`
    /// conformance, a map of its fields.
    @Test func defersToDecimal() throws {
        let decimal = try #require(Decimal(string: "-1234.5678"))

        let data = try MessagePackEncoder().encode(Box(value: decimal))
        #expect(data == (try MessagePackEncoder().encode(["value": DeferredDecimal(decimal: decimal)])))
        #expect(try MessagePackDecoder().decode(Box<Decimal>.self, from: data).value == decimal)
    }

    /// A string or a number is not that map: a type mismatch, so a decoding
    /// fallback on a mismatch works.
    @Test func otherTypesAreAMismatch() throws {
        for value: MessagePackValue in [.string("0.35"), .float64(0.35), .uint8(3)] {
            let data = try MessagePackSerializer.serialize(value: value)
            #expect {
                try MessagePackDecoder().decode(Decimal.self, from: data)
            } throws: { error in
                if case DecodingError.typeMismatch = error { true } else { false }
            }
        }
    }
}

// MARK: - 128-bit integers

@Suite("Codable 128-bit integers")
struct Codable128BitIntegerTests {
    @available(watchOS 11.0, *)
    private struct Wide: Codable, Equatable {
        var signed: Int128
        var unsigned: UInt128
        var list: [Int128]
        var optional: UInt128?
    }

    @available(watchOS 11.0, *)
    @Test func roundTripValuesThatFit() throws {
        let wide = Wide(signed: Int128(Int64.min), unsigned: UInt128(UInt64.max), list: [-1, 0, 1], optional: 7)
        #expect(try MessagePackDecoder().decode(Wide.self, from: MessagePackEncoder().encode(wide)) == wide)

        let single = Int128(Int64.max)
        #expect(try MessagePackDecoder().decode(Int128.self, from: MessagePackEncoder().encode(single)) == single)
    }

    @available(watchOS 11.0, *)
    @Test func encodesTheSmallestIntegerFormat() throws {
        #expect(try MessagePackEncoder().encode(Int128(5)) == MessagePackEncoder().encode(5))
        #expect(try MessagePackEncoder().encode(UInt128(UInt64.max)) == MessagePackEncoder().encode(UInt64.max))
    }

    @available(watchOS 11.0, *)
    @Test func valuesBeyond64BitsThrow() throws {
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(Box(value: Int128.max))
        }
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode([UInt128.max])
        }
        #expect(throws: EncodingError.self) {
            try MessagePackEncoder().encode(Int128(Int64.min) - 1)
        }
    }
}

// MARK: - Floats for integers

/// The spec's deserialization maps float 32/64 to its Float type and the int
/// formats to Integer, so a float is a type mismatch for an integer, even
/// one holding a whole number.
@Suite("Floats for integers")
struct FloatsForIntegersTests {
    @Test func floatsAreAMismatchForIntegers() throws {
        for value: MessagePackValue in [.float64(5), .float32(-3), .float64(5.5)] {
            let data = try MessagePackSerializer.serialize(value: value)
            #expect {
                try MessagePackDecoder().decode(Int.self, from: data)
            } throws: { error in
                if case DecodingError.typeMismatch = error { true } else { false }
            }
            #expect {
                try MessagePackSerializer.deserialize(Int16.self, from: data)
            } throws: { error in
                if case MessagePackError.typeMismatch(expected: "integer", format: _) = error { true } else { false }
            }
        }
    }

    @Test func booleansAreAMismatchForIntegers() throws {
        let data = try MessagePackSerializer.serialize(value: .bool(true))
        #expect(throws: DecodingError.self) {
            try MessagePackDecoder().decode(Int.self, from: data)
        }
    }
}
