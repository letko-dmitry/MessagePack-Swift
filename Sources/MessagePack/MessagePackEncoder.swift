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
///   ``decimalEncodingStrategy`` set to ``DecimalEncodingStrategy/string``,
///   as a string of its exact decimal digits such as `"0.35"`.
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
/// ``encode(_:)`` runs, as they write into state on the call's stack; a
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
        /// A string of the exact decimal digits (`"0.35"`): a fraction of
        /// the map's size, and parsed by other languages' decimal types.
        /// Decoders need ``MessagePackDecoder/DecimalDecodingStrategy/stringOrNumber``
        /// to read it; versions before this option cannot.
        case string
    }

    /// Contextual information made available to the `Encodable` types via
    /// `Encoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// How `Decimal` values are written. Defaults to
    /// ``DecimalEncodingStrategy/deferredToDecimal``.
    public var decimalEncodingStrategy: DecimalEncodingStrategy = .deferredToDecimal

    public init() {}

    /// Encodes `value` into MessagePack binary data.
    ///
    /// Throws `EncodingError.invalidValue` if `value` (or a nested value)
    /// encodes nothing, since MessagePack has no representation for "no
    /// value".
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        try MessagePackEncoderState.with(userInfo: userInfo, decimalEncodingStrategy: decimalEncodingStrategy) { state in
            do {
                try MessagePackEncoderImpl(state: state).encode(value, path: .root)
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

/// All per-encode mutable state, kept behind an `UnsafeMutablePointer` so
/// the per-element hot path bypasses dynamic exclusivity enforcement on
/// class properties.
struct MessagePackEncoderState {
    let userInfo: [CodingUserInfoKey: Any]
    let decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy

    var buffer: MessagePackOutputBuffer

    /// The header positions of the containers still open for writing,
    /// innermost (and highest) last. A write to a container closes the
    /// containers opened after it; a write to a container no longer here is
    /// an out-of-order write and traps.
    var openContainers: MessagePackStack<Int>

    /// The nodes of the coding paths in use; see ``MessagePackEncodingPath``.
    var pathNodes: MessagePackStack<MessagePackEncodingPath.Node>

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
        try withUnsafeTemporaryAllocation(byteCount: MessagePackOutputBuffer.initialCapacity, alignment: 8) { output in
            try withUnsafeTemporaryAllocation(of: Int.self, capacity: 32) { openContainers in
                try withUnsafeTemporaryAllocation(of: MessagePackEncodingPath.Node.self, capacity: 16) { pathNodes in
                    var state = MessagePackEncoderState(
                        userInfo: userInfo,
                        decimalEncodingStrategy: decimalEncodingStrategy,
                        buffer: MessagePackOutputBuffer(memory: output),
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
}

// MARK: - Coding paths

/// A coding path of the encoder: the index of its last key in
/// ``MessagePackEncoderState/pathNodes``, each node linking to its parent.
///
/// A nested value's node is pushed when the value gets an encoder of its own
/// and popped once the value is encoded, along with the nodes of its nested
/// containers (kept until then, so a closed nested container still reports
/// its own path), so a path costs a store into memory of the `encode` call,
/// where a linked list costs an allocation per value. A stale path
/// (one kept past its value, against the documented rules) reads keys of
/// other values, never freed memory.
struct MessagePackEncodingPath {
    struct Node {
        let parent: Int
        let key: any CodingKey
    }

    static let root = Self(node: -1)

    let node: Int
}

// MARK: - Shared encoder state

private let outOfOrderWriteMessage = """
    Attempt to encode into a MessagePack container after writes to its parent \
    closed it. Nested containers and superEncoder() values must be fully \
    encoded before their parent container continues.
    """

/// The encoding machinery shared by every encoder and container of one
/// `encode` call: a single pointer to the state, so copying it into each of
/// them costs no reference counting, and creating it no allocation.
struct MessagePackEncoderImpl {
    /// The mutable encoding state, in the frame of
    /// ``MessagePackEncoder/encode(_:)``.
    let state: UnsafeMutablePointer<MessagePackEncoderState>

    var userInfo: [CodingUserInfoKey: Any] { state.pointee.userInfo }
    var decimalEncodingStrategy: MessagePackEncoder.DecimalEncodingStrategy { state.pointee.decimalEncodingStrategy }

    // MARK: Coding paths

    func path(_ parent: MessagePackEncodingPath, appending key: some CodingKey) -> MessagePackEncodingPath {
        state.pointee.pathNodes.append(MessagePackEncodingPath.Node(parent: parent.node, key: key))
        return MessagePackEncodingPath(node: state.pointee.pathNodes.count &- 1)
    }

    func path(_ parent: MessagePackEncodingPath, appendingIndex index: Int) -> MessagePackEncodingPath {
        path(parent, appending: MessagePackCodingKey(intValue: index))
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

    // MARK: Containers

    /// Opens a container at the current position, writing its header as an
    /// empty fixmap or fixarray, and returns the header's position, which
    /// identifies the container from then on.
    func openContainer(isMap: Bool) -> Int {
        let position = state.pointee.buffer.offset
        state.pointee.buffer.writeByte(isMap ? 0x80 : 0x90)
        state.pointee.openContainers.append(position)
        return position
    }

    /// Counts one more entry in the container at `position`, whose key (or
    /// element) the caller writes next, closing the containers opened after
    /// it.
    @inline(__always)
    func beginEntry(in position: Int) {
        if state.pointee.openContainers.last != position {
            closeContainers(above: position)
        }
        state.pointee.buffer.incrementContainerCount(at: position)
    }

    /// Closes the containers opened after the one at `position`, trapping if
    /// that one has itself been closed: its entry would land after bytes of
    /// its parent.
    @inline(never)
    private func closeContainers(above position: Int) {
        closeContainers(from: position + 1)
        precondition(state.pointee.openContainers.last == position, outOfOrderWriteMessage)
    }

    /// Closes the containers whose headers are at `position` or after it.
    @inline(__always)
    func closeContainers(from position: Int) {
        while let top = state.pointee.openContainers.last, top >= position {
            state.pointee.openContainers.removeLast()
        }
    }

    /// Checks a repeated container request for the value starting at
    /// `position`, whose container is reused (`JSONEncoder` merges repeated
    /// requests too). Traps unless that container is still open and of the
    /// requested kind: anything else at `position` is a value already
    /// encoded through a single value container, whose containers closed
    /// when it was done.
    @inline(never)
    func checkReusedContainer(at position: Int, isMap: Bool) {
        precondition(
            state.pointee.openContainers.lastIndex(where: { $0 == position }) != nil,
            "Attempt to request an encoding container for a value that was already encoded through a single value container"
        )
        let existingIsMap = state.pointee.buffer.isMapHeader(at: position)
        precondition(
            existingIsMap == isMap,
            "Attempt to request a \(isMap ? "keyed" : "unkeyed") encoding container for a value that already requested a \(existingIsMap ? "keyed" : "unkeyed") one"
        )
    }

    // MARK: Values

    /// Encodes a value of any `Encodable` type. Types MessagePack represents
    /// natively are written directly, bypassing the `Encodable` container
    /// machinery (and its per-value encoder and coding-path node);
    /// the path closure only runs when a value actually needs it (nested
    /// encoders and errors).
    ///
    /// Thin, as the compiler copies a function taking a closure into each
    /// call site: the type checks run out of line in
    /// ``encodeNative(_:_:)``.
    func encode<T: Encodable>(_ value: T, path: @autoclosure () -> MessagePackEncodingPath) throws {
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
    /// resilient `Date` or `Decimal` in the generic `encode`, which would
    /// otherwise size its frame (and probe the stack) on every call. Types
    /// are matched by metadata identity and read through the raw pointer: an
    /// `as!` per type reserves a stack temporary per cast site, and a
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
            state.pointee.buffer.writeIntOutlined(Int64(value.load(as: Int.self)))
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
            state.pointee.buffer.writeIntOutlined(value.load(as: Int64.self))
        } else if type == ObjectIdentifier(UInt64.self) {
            state.pointee.buffer.writeUIntOutlined(value.load(as: UInt64.self))
        } else if type == ObjectIdentifier(Int32.self) {
            state.pointee.buffer.writeIntOutlined(Int64(value.load(as: Int32.self)))
        } else if type == ObjectIdentifier(UInt32.self) {
            state.pointee.buffer.writeUIntOutlined(UInt64(value.load(as: UInt32.self)))
        } else if type == ObjectIdentifier(Int16.self) {
            state.pointee.buffer.writeIntOutlined(Int64(value.load(as: Int16.self)))
        } else if type == ObjectIdentifier(UInt16.self) {
            state.pointee.buffer.writeUIntOutlined(UInt64(value.load(as: UInt16.self)))
        } else if type == ObjectIdentifier(Int8.self) {
            state.pointee.buffer.writeIntOutlined(Int64(value.load(as: Int8.self)))
        } else if type == ObjectIdentifier(UInt8.self) {
            state.pointee.buffer.writeUIntOutlined(UInt64(value.load(as: UInt8.self)))
        } else if type == ObjectIdentifier(UInt.self) {
            state.pointee.buffer.writeUIntOutlined(UInt64(value.load(as: UInt.self)))
        } else if type == ObjectIdentifier(MessagePackTimestamp.self) {
            state.pointee.buffer.writeTimestamp(value.load(as: MessagePackTimestamp.self))
        } else if let collectionType = MessagePackCollectionType(type) {
            encodeCollection(collectionType, value)
        } else if type == foundation.decimal, decimalEncodingStrategy == .string {
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

    /// Encodes a value through its `Encodable` conformance, with an encoder
    /// for the value starting at the current position.
    func encodeWithContainers<T: Encodable>(_ value: T, path: MessagePackEncodingPath) throws {
        let start = state.pointee.buffer.offset
        try value.encode(to: _MessagePackEncoder(impl: self, path: path, start: start))

        // MessagePack has no representation for "no value at all";
        // JSONEncoder throws in the same situation.
        guard state.pointee.buffer.offset != start else {
            throw Self.nothingEncoded(value, codingPath: codingPath(path))
        }

        // The value is complete, so are its containers: closing them here
        // lets the parent's next entry find its container on top, and turns
        // any later write into them into an out-of-order write.
        closeContainers(from: start)
    }

    // MARK: Errors

    // Built out of line and returned boxed: a resilient `EncodingError` (or
    // `Date`) in a function sizes its frame dynamically on every call, even
    // when the throwing branch is not taken.

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
    static func nothingEncoded(_ value: Any, codingPath: [CodingKey]) -> any Error {
        EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Value of type \(type(of: value)) did not encode any values"
            ))
    }
}

// MARK: - Encoder

/// The `Encoder` handed to `Encodable.encode(to:)`. A three-word struct
/// (shared state, coding path, start), so passing it as an existential does
/// not allocate.
struct _MessagePackEncoder: Encoder {
    let impl: MessagePackEncoderImpl
    let path: MessagePackEncodingPath
    /// Where the value of this encoder starts in the output. A value is one
    /// single value or one container whose header is written at `start`, so
    /// what the output holds there tells what has been encoded for it: no
    /// per-encoder record is needed.
    let start: Int

    var codingPath: [CodingKey] { impl.codingPath(path) }
    var userInfo: [CodingUserInfoKey: Any] { impl.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer(impl: impl, position: containerPosition(isMap: true), path: path)
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        MessagePackUnkeyedEncodingContainer(impl: impl, position: containerPosition(isMap: false), path: path)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackSingleValueEncodingContainer(impl: impl, path: path, start: start)
    }

    /// The header position of this value's container: opened at `start` on
    /// the first request, and the same one on later requests.
    private func containerPosition(isMap: Bool) -> Int {
        if impl.state.pointee.buffer.offset == start {
            return impl.openContainer(isMap: isMap)
        }
        impl.checkReusedContainer(at: start, isMap: isMap)
        return start
    }
}
