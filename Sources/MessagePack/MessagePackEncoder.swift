import Foundation

/// Encodes `Encodable` values into MessagePack binary data, analogous to
/// `JSONEncoder`.
///
/// Values are written in a single streaming pass into a growable buffer;
/// container headers (whose element counts are unknown up front) are reserved
/// at full width and compacted to the smallest spec format when encoding
/// finishes, so the output is byte-identical to what
/// ``MessagePackSerializer`` produces for the equivalent value tree.
///
/// Special types:
/// - `Date` is encoded as the timestamp extension type (-1). Dates whose
///   interval since 1970 is not finite or does not fit in the timestamp range
///   throw `EncodingError.invalidValue`.
/// - `Data` is encoded as bin 8/16/32.
/// - ``MessagePackTimestamp`` is encoded as the timestamp extension type.
/// - `Decimal`, which MessagePack has no type for, is encoded through its own
///   `Codable` conformance (a map of its fields), or, with
///   ``decimalEncodingStrategy`` set to
///   ``DecimalEncodingStrategy/convertToString``, as a string of its exact
///   decimal digits such as `"0.35"`.
///
/// Keyed containers are encoded as maps with string keys. Because encoding is
/// streaming, writes must be well nested: a nested container (or an encoder
/// from `superEncoder()`) must be fully encoded before its parent container
/// continues — which is how compiler-synthesized and conventional
/// hand-written `Encodable` conformances behave. Out-of-order writes are
/// detected and trap with a precondition failure instead of producing
/// corrupt output. A `superEncoder()` that is never encoded into simply
/// contributes nothing (its entry is written lazily on first use).
///
/// Like `JSONEncoder`, this type is marked `Sendable` with unchecked
/// conformance: it has value semantics, but values stored in `userInfo` must
/// themselves be `Sendable` for cross-task sharing to be safe.
public struct MessagePackEncoder {
    /// How `Decimal` values are written, named like `JSONEncoder`'s
    /// strategies.
    public enum DecimalEncodingStrategy: Sendable {
        /// Defers to `Decimal`'s own `Codable` conformance, which writes a
        /// map of its fields (`exponent`, `mantissa`, …). The default, and
        /// what earlier versions wrote.
        case deferredToDecimal
        /// Converts to a string of the exact decimal digits (`"0.35"`): a
        /// fraction of the map's size, and parsed by other languages' decimal
        /// types. Decoders read it with
        /// ``MessagePackDecoder/DecimalDecodingStrategy/convertFromString`` in
        /// their strategy; versions before this option cannot.
        case convertToString
    }

    /// Contextual information made available to the `Encodable` types via
    /// `Encoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// How `Decimal` values are written.
    public var decimalEncodingStrategy: DecimalEncodingStrategy

    public init(decimalEncodingStrategy: DecimalEncodingStrategy = .deferredToDecimal) {
        self.decimalEncodingStrategy = decimalEncodingStrategy
    }

    /// Encodes `value` into MessagePack binary data.
    ///
    /// Throws `EncodingError.invalidValue` if `value` (or a nested value)
    /// encodes nothing, since MessagePack has no representation for "no
    /// value".
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let impl = MessagePackEncoderImpl(userInfo: userInfo, decimalEncodingStrategy: decimalEncodingStrategy)
        defer { impl.tearDown() }
        try impl.encodeEncodable(value, codingPath: [])
        return impl.finalize()
    }
}

extension MessagePackEncoder: @unchecked Sendable {}

// MARK: - Mutable encoder state

/// All per-encode mutable state, kept behind an `UnsafeMutablePointer` so
/// the per-element hot path bypasses dynamic exclusivity enforcement on
/// class properties.
struct MessagePackEncoderState {
    var buffer = MessagePackScratchBuffer()

    /// Stack of header positions of containers that are still open for
    /// writing. A write to a container pops any nested containers above it
    /// (they are implicitly closed); a write to a container that is no
    /// longer on the stack is an out-of-order write and traps.
    var openContainers: [Int] = []

    /// Per-`_MessagePackEncoder` record of the container it created, so
    /// repeated `container(keyedBy:)` / `unkeyedContainer()` calls on the
    /// same encoder merge into one container instead of emitting siblings,
    /// and so encoding a second value for the same slot is detected.
    /// `0` = none; `position + 1` = keyed; `-(position + 1)` = unkeyed;
    /// `singleValueWrittenMarker` = a single value was already written.
    var encoderSlots: [Int] = []

    /// Slot marker meaning "a single value was already encoded for this
    /// encoder" (distinct from any container position encoding).
    static let singleValueWrittenMarker = Int.min

    @inline(__always)
    mutating func makeEncoderSlot() -> Int {
        encoderSlots.append(0)
        return encoderSlots.count - 1
    }

    /// Records that the encoder's single value was written; traps if a
    /// value or container was already encoded for it, mirroring
    /// `JSONEncoder`'s precondition for the same misuse.
    @inline(__always)
    mutating func markSingleValueWritten(id: Int) {
        precondition(
            encoderSlots[id] == 0,
            "Attempt to encode a second value (or a value after a container) through a single value encoding container"
        )
        encoderSlots[id] = Self.singleValueWrittenMarker
    }

    /// Registers one new entry in the container at `position`, closing any
    /// nested containers opened after it. Returns false if that container
    /// itself has already been closed (out-of-order write).
    @inline(__always)
    mutating func beginEntry(at position: Int) -> Bool {
        if openContainers.last == position {
            buffer.bumpContainerCount(at: position)
            return true
        }
        return beginEntrySlow(at: position)
    }

    @inline(never)
    private mutating func beginEntrySlow(at position: Int) -> Bool {
        while let top = openContainers.last, top != position {
            openContainers.removeLast()
        }
        guard openContainers.last == position else { return false }
        buffer.bumpContainerCount(at: position)
        return true
    }
}

// MARK: - Shared encoder state

final class MessagePackEncoderImpl {
    /// A container header reserved in the scratch buffer, patched at the end.
    /// The running element count lives in the reserved bytes themselves.
    struct ContainerHeader {
        let position: Int
        let isMap: Bool
    }

    /// The mutable encoding state. Owned by this instance; released by
    /// `tearDown()`.
    let state: UnsafeMutablePointer<MessagePackEncoderState>
    var headers: [ContainerHeader] = []
    let userInfo: [CodingUserInfoKey: Any]
    let decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy

    init(userInfo: [CodingUserInfoKey: Any], decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy) {
        self.state = .allocate(capacity: 1)
        self.state.initialize(to: MessagePackEncoderState())
        self.userInfo = userInfo
        self.decimalEncodingStrategy = decimalEncodingStrategy
    }

    /// Releases the encoding state. Must be called exactly once, after
    /// encoding finishes (successfully or not).
    func tearDown() {
        state.pointee.buffer.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Reserves a header slot for a new container and returns its buffer
    /// position, which identifies the container for count bookkeeping.
    func beginContainer(isMap: Bool) -> Int {
        let position = state.pointee.buffer.reserveContainerHeader()
        state.pointee.openContainers.append(position)
        headers.append(ContainerHeader(position: position, isMap: isMap))
        return position
    }

    /// Encodes a value of arbitrary `Encodable` type. Types MessagePack
    /// represents natively are written directly, bypassing the `Encodable`
    /// container machinery (and its per-value encoder and coding-path
    /// allocations); the path closure only runs when a value actually needs
    /// it (nested encoders and errors).
    func encodeEncodable<T: Encodable>(
        _ value: T, codingPath: @autoclosure () -> [CodingKey]
    ) throws {
        switch withUnsafePointer(to: value, { encodeNative(T.self, UnsafeRawPointer($0)) }) {
        case .encoded:
            return
        case .notNative:
            try encodeWithContainers(value, codingPath: codingPath())
        case .unrepresentableDate:
            throw Self.unrepresentableDate(value, codingPath: codingPath())
        }
    }

    /// What ``encodeNative(_:_:)`` did with a value.
    enum NativeEncoding {
        case encoded
        /// The type is not natively represented, or is a `Decimal` deferring
        /// to its own conformance.
        case notNative
        /// A `Date` outside the timestamp range.
        case unrepresentableDate
    }

    /// Writes the value at `value` if its type is natively represented.
    ///
    /// Out of line and not generic: one copy of the type checks, and no
    /// resilient `Date` or `Decimal` in the generic `encodeEncodable`, which
    /// would otherwise size its frame (and probe the stack) on every call.
    /// Types are matched by metadata identity and read through the raw
    /// pointer: an `as!` per type reserves a stack temporary per cast site
    /// (measured at ~7% of encoding time in `chkstk` probes), and a
    /// conditional cast to a protocol costs `swift_conformsToProtocol`, more
    /// than this whole chain of comparisons.
    @inline(never)
    func encodeNative(_ type: Any.Type, _ value: UnsafeRawPointer) -> NativeEncoding {
        let foundation = MessagePackFoundationTypes.shared
        let type = ObjectIdentifier(type)

        // The types seen most in generic contexts first: every struct passes
        // all of these checks before its own conformance runs.
        if type == ObjectIdentifier(String.self) {
            state.pointee.buffer.writeString(value.assumingMemoryBound(to: String.self).pointee)
        } else if type == foundation.data {
            state.pointee.buffer.writeBinary(value.assumingMemoryBound(to: Data.self).pointee)
        } else if type == ObjectIdentifier(Int.self) {
            state.pointee.buffer.writeInt(Int64(value.load(as: Int.self)))
        } else if type == foundation.date {
            guard encodeDate(value) else {
                return .unrepresentableDate
            }
        } else if type == ObjectIdentifier(Double.self) {
            state.pointee.buffer.writeDouble(value.load(as: Double.self))
        } else if type == ObjectIdentifier(Bool.self) {
            state.pointee.buffer.writeBool(value.load(as: Bool.self))
        } else if type == ObjectIdentifier(Float.self) {
            state.pointee.buffer.writeFloat(value.load(as: Float.self))
        } else if type == ObjectIdentifier(Int64.self) {
            state.pointee.buffer.writeInt(value.load(as: Int64.self))
        } else if type == ObjectIdentifier(UInt64.self) {
            state.pointee.buffer.writeUInt(value.load(as: UInt64.self))
        } else if type == ObjectIdentifier(Int32.self) {
            state.pointee.buffer.writeInt(Int64(value.load(as: Int32.self)))
        } else if type == ObjectIdentifier(UInt32.self) {
            state.pointee.buffer.writeUInt(UInt64(value.load(as: UInt32.self)))
        } else if type == ObjectIdentifier(Int16.self) {
            state.pointee.buffer.writeInt(Int64(value.load(as: Int16.self)))
        } else if type == ObjectIdentifier(UInt16.self) {
            state.pointee.buffer.writeUInt(UInt64(value.load(as: UInt16.self)))
        } else if type == ObjectIdentifier(Int8.self) {
            state.pointee.buffer.writeInt(Int64(value.load(as: Int8.self)))
        } else if type == ObjectIdentifier(UInt8.self) {
            state.pointee.buffer.writeUInt(UInt64(value.load(as: UInt8.self)))
        } else if type == ObjectIdentifier(UInt.self) {
            state.pointee.buffer.writeUInt(UInt64(value.load(as: UInt.self)))
        } else if type == ObjectIdentifier(MessagePackTimestamp.self) {
            state.pointee.buffer.writeTimestamp(value.load(as: MessagePackTimestamp.self))
        } else if let collectionType = MessagePackCollectionType(type) {
            encodeCollection(collectionType, value)
        } else if type == foundation.decimal, decimalEncodingStrategy == .convertToString {
            encodeDecimal(value)
        } else {
            return .notNative
        }

        return .encoded
    }

    // `Date` and `Decimal` are written out of line, keeping these resilient
    // types out of the frame of `encodeNative`, which every struct passes
    // through: in it, they made each call probe the stack (`chkstk`).

    /// Writes the `Date` at `value`, or returns false if the timestamp range
    /// cannot hold it.
    @inline(never)
    private func encodeDate(_ value: UnsafeRawPointer) -> Bool {
        guard let timestamp = MessagePackTimestamp(exactly: value.load(as: Date.self)) else {
            return false
        }
        state.pointee.buffer.writeTimestamp(timestamp)
        return true
    }

    /// Writes the `Decimal` at `value` as a string of its exact digits.
    @inline(never)
    private func encodeDecimal(_ value: UnsafeRawPointer) {
        state.pointee.buffer.writeString(value.assumingMemoryBound(to: Decimal.self).pointee.description)
    }

    /// Encodes a value through its `Encodable` conformance.
    func encodeWithContainers<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws {
        let before = state.pointee.buffer.offset
        try value.encode(to: _MessagePackEncoder(impl: self, codingPath: codingPath))
        // MessagePack has no representation for "no value at all";
        // JSONEncoder throws in the same situation.
        guard state.pointee.buffer.offset != before else {
            throw Self.nothingEncoded(value, type: T.self, codingPath: codingPath)
        }
    }

    // The errors are built out of line, keeping their messages and the
    // resilient `Date` off the encode paths.

    @inline(never)
    static func unrepresentableDate(_ value: Any, codingPath: [CodingKey]) -> any Error {
        let interval = (value as? Date)?.timeIntervalSince1970 ?? .nan
        return EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: codingPath,
                debugDescription:
                    "Date (timeIntervalSince1970: \(interval)) cannot be represented as a MessagePack timestamp"
            ))
    }

    @inline(never)
    static func nothingEncoded(_ value: Any, type: Any.Type, codingPath: [CodingKey]) -> any Error {
        EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Value of type \(type) did not encode any values"
            ))
    }

    /// Produces the final `Data`, compacting each reserved 5-byte container
    /// header to the smallest format for its final count.
    func finalize() -> Data {
        var finalSize = state.pointee.buffer.offset
        for header in headers {
            let count = state.pointee.buffer.containerCount(at: header.position)
            finalSize -= 5 - MessagePackScratchBuffer.containerHeaderSize(count: count)
        }
        let out = UnsafeMutableRawPointer.allocate(byteCount: max(finalSize, 1), alignment: 8)
        var writer = MessagePackSerializer.Writer(base: out)
        var source = 0
        for header in headers {
            let chunk = header.position - source
            if chunk > 0 {
                writer.writeBytes(state.pointee.buffer.base + source, count: chunk)
            }
            source = header.position + 5
            let count = state.pointee.buffer.containerCount(at: header.position)
            if header.isMap {
                writer.writeMapHeader(count: count)
            } else {
                writer.writeArrayHeader(count: count)
            }
        }
        let tail = state.pointee.buffer.offset - source
        if tail > 0 {
            writer.writeBytes(state.pointee.buffer.base + source, count: tail)
        }
        assert(writer.offset == finalSize)
        return Data(
            bytesNoCopy: out,
            count: finalSize,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
    }
}

// MARK: - Encoder

/// The `Encoder` handed to `Encodable.encode(to:)`. A three-word struct
/// (shared state + coding path + slot id) so passing it as an existential
/// does not allocate.
struct _MessagePackEncoder: Encoder {
    let impl: MessagePackEncoderImpl
    let codingPath: [CodingKey]
    /// Index into `MessagePackEncoderState.encoderSlots`, used to merge
    /// repeated container requests for the same value.
    let id: Int

    init(impl: MessagePackEncoderImpl, codingPath: [CodingKey]) {
        self.impl = impl
        self.codingPath = codingPath
        self.id = impl.state.pointee.makeEncoderSlot()
    }

    var userInfo: [CodingUserInfoKey: Any] { impl.userInfo }

    /// Returns the header position for this value's container, creating it
    /// on first request and reusing it on repeated requests (matching
    /// `JSONEncoder`, which merges repeated same-kind container requests).
    private func containerPosition(isMap: Bool) -> Int {
        let slot = impl.state.pointee.encoderSlots[id]
        if slot == 0 {
            let position = impl.beginContainer(isMap: isMap)
            impl.state.pointee.encoderSlots[id] = isMap ? position + 1 : -(position + 1)
            return position
        }
        precondition(
            slot != MessagePackEncoderState.singleValueWrittenMarker,
            "Attempt to request an encoding container after a single value was already encoded for the same value"
        )
        let existingIsMap = slot > 0
        precondition(
            existingIsMap == isMap,
            "Attempt to request a \(isMap ? "keyed" : "unkeyed") encoding container for a value that already requested a \(existingIsMap ? "keyed" : "unkeyed") one"
        )
        return existingIsMap ? slot - 1 : -slot - 1
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer(
                impl: impl,
                headerPosition: containerPosition(isMap: true),
                codingPath: codingPath
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        MessagePackUnkeyedEncodingContainer(
            impl: impl,
            headerPosition: containerPosition(isMap: false),
            codingPath: codingPath
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackSingleValueEncodingContainer(impl: impl, codingPath: codingPath, encoderID: id)
    }
}

