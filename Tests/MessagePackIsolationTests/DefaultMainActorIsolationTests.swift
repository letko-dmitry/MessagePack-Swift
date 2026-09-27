import Foundation
import MessagePack
import Testing

// This module is compiled with `-default-isolation MainActor`, so `Envelope` and every
// conformance declared in this file are main-actor isolated. The macro's expansion must
// nevertheless remain callable off the main actor, otherwise a plugin host or any other
// nonisolated code path could not serialize messages defined in such a module.
// (`Equatable` is deliberately not adopted: that conformance would be isolated too, which is
// exactly what the macro's `nonisolated extension` avoids for `MessagePackSerializable`.)

@MessagePackSerializable
struct Envelope {
    var op: String
    var payload: Data
    var count: Int?
}

@Suite struct DefaultMainActorIsolationTests {
    @Test nonisolated func roundTripsFromANonisolatedContext() throws {
        let envelope = Envelope(op: "editor.replace", payload: Data([1, 2, 3]), count: 3)
        let bytes = MessagePackSerializer.serialize(envelope)
        let decoded = try MessagePackSerializer.deserialize(Envelope.self, from: bytes)
        #expect(decoded.op == "editor.replace")
        #expect(decoded.payload == Data([1, 2, 3]))
        #expect(decoded.count == 3)
    }

    @Test func roundTripsOnTheMainActor() throws {
        let envelope = Envelope(op: "notice", payload: Data(), count: nil)
        let bytes = MessagePackSerializer.serialize(envelope)
        let decoded = try MessagePackSerializer.deserialize(Envelope.self, from: bytes)
        #expect(decoded.op == "notice")
        #expect(decoded.payload.isEmpty)
        #expect(decoded.count == nil)
    }
}
