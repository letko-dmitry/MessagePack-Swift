import Foundation
import Testing

@testable import MessagePack

@MessagePackSerializable
private struct SpanPoint: Equatable {
    var x: Int
    var label: String
}

private struct CodablePoint: Codable, Equatable {
    var x: Int
    var label: String
}

private let point = SpanPoint(x: 7, label: "seven")
private let codablePoint = CodablePoint(x: 7, label: "seven")
private let pointValue = MessagePackValue.map([.string("x"): .uint8(7), .string("label"): .string("seven")])

/// The serialized point after two other bytes, so a slice of it does not
/// start at index 0.
private let framed = [0xff, 0xfe] + [UInt8](MessagePackSerializer.serialize(point))

/// What each route decodes from the span of `bytes`. Out of `#expect`, which
/// would carry a span out of the scope it borrows from.
private func decodeEveryRoute(_ bytes: ArraySlice<UInt8>) -> (
    macro: Result<SpanPoint, MessagePackError>,
    codable: Result<CodablePoint, any Error>,
    value: Result<MessagePackValue, MessagePackError>
) {
    (
        Result { () throws(MessagePackError) in
            try MessagePackSerializer.deserialize(SpanPoint.self, from: bytes.span.bytes)
        },
        Result { try MessagePackDecoder().decode(CodablePoint.self, from: bytes.span.bytes) },
        Result { () throws(MessagePackError) in try MessagePackSerializer.deserialize(data: bytes.span.bytes) }
    )
}

@Suite("Decoding from spans")
struct MessagePackSpanInputTests {
    @Test func everyRouteReadsASliceInPlace() throws {
        let decoded = decodeEveryRoute(framed[2...])
        #expect(try decoded.macro.get() == point)
        #expect(try decoded.codable.get() == codablePoint)
        #expect(try decoded.value.get() == pointValue)
    }

    @Test func everyRouteReadsAnArray() throws {
        let bytes = [UInt8](framed[2...])
        let decoded = decodeEveryRoute(bytes[...])
        #expect(try decoded.macro.get() == point)
        #expect(try decoded.codable.get() == codablePoint)
        #expect(try decoded.value.get() == pointValue)

        if #available(anyAppleOS 26, *) {
            let fromArray = try MessagePackSerializer.deserialize(SpanPoint.self, from: bytes.span.bytes)
            #expect(fromArray == point)
        }
    }

    @Test func emptyInputThrows() {
        let decoded = decodeEveryRoute([])
        #expect(throws: MessagePackError.insufficientData) { try decoded.macro.get() }
        #expect(throws: DecodingError.self) { try decoded.codable.get() }
        #expect(throws: MessagePackError.insufficientData) { try decoded.value.get() }
    }

    @Test func trailingBytesThrow() {
        let decoded = decodeEveryRoute(framed[2...] + [0xc0])
        #expect(throws: MessagePackError.trailingBytes) { try decoded.macro.get() }
        #expect(throws: DecodingError.self) { try decoded.codable.get() }
        #expect(throws: MessagePackError.trailingBytes) { try decoded.value.get() }
    }
}
