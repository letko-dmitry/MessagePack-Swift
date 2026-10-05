import Foundation

/// Encodes `Encodable` values into MessagePack binary data, analogous to
/// `JSONEncoder`.
///
/// Values are written in a single streaming pass straight into the output.
/// A container's header is written as a fixmap or fixarray when it opens and
/// keeps the running entry count itself, widening in place to the 16- or
/// 32-bit format if the container outgrows it, so the output is
/// byte-identical to what ``MessagePackSerializer`` produces for the
/// equivalent value tree.
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
/// The `Encoder` and containers handed to `encode(to:)` are valid only while
/// ``encode(_:)`` runs, as they write into memory on the call's stack; a
/// conformance must not store them for later use.
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
        try MessagePackEncoderState.with(userInfo: userInfo, decimalEncodingStrategy: decimalEncodingStrategy) { state in
            let impl = MessagePackEncoderImpl(state: state)
            do {
                try impl.encodeEncodable(value, path: .root)
            } catch {
                state.pointee.buffer.deallocate()
                throw error
            }
            return state.pointee.buffer.finish()
        }
    }
}

extension MessagePackEncoder: @unchecked Sendable {}

// MARK: - Mutable encoder state

/// All per-encode state, in the frame of ``MessagePackEncoder/encode(_:)``
/// behind an `UnsafeMutablePointer`: copying the pointer into every encoder
/// and container costs no reference counting, and the per-element hot path
/// bypasses dynamic exclusivity enforcement.
struct MessagePackEncoderState {
    let userInfo: [CodingUserInfoKey: Any]
    let decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy

    var buffer: MessagePackScratchBuffer

    /// Stack of header positions of containers that are still open for
    /// writing. A write to a container pops any nested containers above it
    /// (they are implicitly closed); a write to a container that is no
    /// longer on the stack is an out-of-order write and traps.
    var openContainers: MessagePackStack<Int>

    /// The nodes of the coding paths in use; see ``MessagePackEncodingPath``.
    var pathNodes: MessagePackStack<MessagePackEncodingPath.Node>

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
            buffer.incrementContainerCount(at: position)
            return true
        }
        return beginEntrySlow(at: position)
    }

    /// Runs `body` with the state of one `encode` call. The state lives in
    /// this frame, as the encoder (and every container it serves) is only
    /// valid during the call, and so does the memory of its buffer and
    /// stacks until they outgrow it: a typical message is encoded without
    /// allocating any of them.
    static func with<R>(
        userInfo: [CodingUserInfoKey: Any],
        decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy,
        _ body: (UnsafeMutablePointer<MessagePackEncoderState>) throws -> R
    ) rethrows -> R {
        try withUnsafeTemporaryAllocation(byteCount: MessagePackScratchBuffer.initialCapacity, alignment: 8) { output in
            try withUnsafeTemporaryAllocation(of: Int.self, capacity: 32) { openContainers in
                try withUnsafeTemporaryAllocation(of: MessagePackEncodingPath.Node.self, capacity: 16) { pathNodes in
                    var state = MessagePackEncoderState(
                        userInfo: userInfo,
                        decimalEncodingStrategy: decimalEncodingStrategy,
                        buffer: MessagePackScratchBuffer(memory: output),
                        openContainers: MessagePackStack(memory: openContainers),
                        pathNodes: MessagePackStack(memory: pathNodes)
                    )
                    defer {
                        state.openContainers.deallocate()
                        state.pathNodes.deallocate()
                    }

                    return try withUnsafeMutablePointer(to: &state, body)
                }
            }
        }
    }

    @inline(never)
    private mutating func beginEntrySlow(at position: Int) -> Bool {
        while let top = openContainers.last, top != position {
            openContainers.removeLast()
        }
        guard openContainers.last == position else { return false }
        buffer.incrementContainerCount(at: position)
        return true
    }
}

// MARK: - Coding paths

/// A coding path of the encoder: the index of its last key in
/// ``MessagePackEncoderState/pathNodes``, each node linking to its parent.
///
/// A nested value's node is pushed when the value gets an encoder of its own
/// and popped once the value is encoded, along with the nodes of its nested
/// containers (kept until then, so a closed nested container still reports
/// its own path), so a path costs a store into memory of the `encode` call,
/// where an array costs an allocation per value. A stale path (one kept past
/// its value, against the documented rules) reads keys of other values,
/// never freed memory.
struct MessagePackEncodingPath {
    struct Node {
        let parent: Int
        let key: any CodingKey
    }

    static let root = Self(node: -1)

    let node: Int
}

// MARK: - Shared encoder state

/// The encoding machinery shared by every encoder and container of one
/// `encode` call: a single pointer to the state, so copying it into each of
/// them costs no reference counting, and creating it no allocation.
struct MessagePackEncoderImpl {
    /// The mutable encoding state, in the frame of
    /// ``MessagePackEncoder/encode(_:)``.
    let state: UnsafeMutablePointer<MessagePackEncoderState>

    var userInfo: [CodingUserInfoKey: Any] { state.pointee.userInfo }
    var decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy { state.pointee.decimalEncodingStrategy }

    func path(_ parent: MessagePackEncodingPath, appending key: some CodingKey) -> MessagePackEncodingPath {
        state.pointee.pathNodes.append(MessagePackEncodingPath.Node(parent: parent.node, key: key))
        return MessagePackEncodingPath(node: state.pointee.pathNodes.count &- 1)
    }

    func path(_ parent: MessagePackEncodingPath, appendingIndex index: Int) -> MessagePackEncodingPath {
        path(parent, appending: MessagePackCodingKey(index: index))
    }

    /// The keys of `path`, built only for errors and `codingPath` reads.
    func codingPath(_ path: MessagePackEncodingPath) -> [CodingKey] {
        var keys: [CodingKey] = []
        var node = path.node
        while node >= 0 {
            let entry = state.pointee.pathNodes[node]
            keys.append(entry.key)
            node = entry.parent
        }
        return keys.reversed()
    }

    /// Opens a container: writes its header as a fixmap or fixarray, which
    /// counts (and widens) in place, and returns the header's position,
    /// which identifies the container for that bookkeeping.
    func beginContainer(isMap: Bool) -> Int {
        let position = state.pointee.buffer.offset
        state.pointee.buffer.writeByte(isMap ? 0x80 : 0x90)
        state.pointee.openContainers.append(position)
        return position
    }

    /// Encodes a value of arbitrary `Encodable` type. Types MessagePack
    /// represents natively are written directly, bypassing the `Encodable`
    /// container machinery (and its per-value encoder and coding-path
    /// allocations); the path closure only runs when a value actually needs
    /// it (nested encoders and errors).
    func encodeEncodable<T: Encodable>(
        _ value: T, path: @autoclosure () -> MessagePackEncodingPath
    ) throws {
        switch withUnsafePointer(to: value, { encodeNative(T.self, UnsafeRawPointer($0)) }) {
        case .encoded:
            return
        case .notNative:
            // Drops the value's path node, and those of its nested
            // containers, once the value is encoded.
            let pathNodeCount = state.pointee.pathNodes.count
            defer { state.pointee.pathNodes.removeAll(from: pathNodeCount) }

            try encodeWithContainers(value, path: path())
        case .unrepresentableDate:
            throw Self.unrepresentableDate(value, codingPath: codingPath(path()))
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
    func encodeWithContainers<T: Encodable>(_ value: T, path: MessagePackEncodingPath) throws {
        let before = state.pointee.buffer.offset
        try value.encode(to: _MessagePackEncoder(impl: self, path: path))
        // MessagePack has no representation for "no value at all";
        // JSONEncoder throws in the same situation.
        guard state.pointee.buffer.offset != before else {
            throw Self.nothingEncoded(value, type: T.self, codingPath: codingPath(path))
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

}

// MARK: - Encoder

/// The `Encoder` handed to `Encodable.encode(to:)`. A three-word struct
/// (shared state + coding path + slot id) so passing it as an existential
/// does not allocate.
struct _MessagePackEncoder: Encoder {
    let impl: MessagePackEncoderImpl
    let path: MessagePackEncodingPath
    /// Index into `MessagePackEncoderState.encoderSlots`, used to merge
    /// repeated container requests for the same value.
    let id: Int

    init(impl: MessagePackEncoderImpl, path: MessagePackEncodingPath) {
        self.impl = impl
        self.path = path
        self.id = impl.state.pointee.makeEncoderSlot()
    }

    var codingPath: [CodingKey] { impl.codingPath(path) }

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
                path: path
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        MessagePackUnkeyedEncodingContainer(
            impl: impl,
            headerPosition: containerPosition(isMap: false),
            path: path
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackSingleValueEncodingContainer(impl: impl, path: path, encoderID: id)
    }
}

