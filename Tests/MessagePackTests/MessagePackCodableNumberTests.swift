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
