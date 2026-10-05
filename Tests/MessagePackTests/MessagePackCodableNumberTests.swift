import Foundation
import Testing

@testable import MessagePack

private struct Box<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value
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
