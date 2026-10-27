import Foundation

private let secondSingleValueMessage = """
    Attempt to encode a second value (or a value after a container) through \
    a single value encoding container
    """

let outOfOrderWriteMessage = """
    Attempt to encode into a MessagePack container after writes to its parent \
    closed it. Nested containers and superEncoder() values must be fully \
    encoded before their parent container continues.
    """

// MARK: - Deferred (super) encoder

/// Encoder returned by `superEncoder()` / `superEncoder(forKey:)`. Writing
/// the map key (or bumping the array count) is deferred until this encoder
/// is first encoded into, so:
/// - a super encoder that is requested but never used contributes nothing
///   (the output stays valid), and
/// - a super encoder used after further sibling writes still produces a
///   well-formed entry (the key is written at actual encode time).
final class MessagePackDeferredEncoder: Encoder {
    let context: MessagePackEncodingContext
    let path: MessagePackEncodingPath
    let parentPosition: Int
    /// The map key to write on activation; nil when the parent is an array.
    let key: String?
    private var inner: MessagePackDirectEncoder?

    init(context: MessagePackEncodingContext, path: MessagePackEncodingPath, parentPosition: Int, key: String?) {
        self.context = context
        self.path = path
        self.parentPosition = parentPosition
        self.key = key
    }

    var codingPath: [CodingKey] { context.codingPath(path) }

    var userInfo: [CodingUserInfoKey: Any] { context.userInfo }

    /// Writes the deferred entry (exactly once) and returns the direct encoder.
    func activate() -> MessagePackDirectEncoder {
        if let inner { return inner }
        precondition(
            context.state.pointee.beginEntry(at: parentPosition), outOfOrderWriteMessage)
        if let key { context.state.pointee.buffer.writeString(key) }
        let encoder = MessagePackDirectEncoder(context: context, path: path, start: context.state.pointee.buffer.offset)
        inner = encoder
        return encoder
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        activate().container(keyedBy: type)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        activate().unkeyedContainer()
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackDeferredSingleValueEncodingContainer(owner: self)
    }
}

/// Single-value container for ``MessagePackDeferredEncoder``: activates the
/// owner (writing the deferred entry) only when a value is actually encoded.
struct MessagePackDeferredSingleValueEncodingContainer: SingleValueEncodingContainer {
    let owner: MessagePackDeferredEncoder

    var codingPath: [CodingKey] { owner.codingPath }

    @inline(__always)
    private func beginValue() -> UnsafeMutablePointer<MessagePackEncodingState> {
        let start = owner.activate().start
        let state = owner.context.state
        precondition(state.pointee.buffer.offset == start, secondSingleValueMessage)
        return state
    }

    mutating func encodeNil() throws { beginValue().pointee.buffer.writeNil() }
    mutating func encode(_ value: Bool) throws { beginValue().pointee.buffer.writeBool(value) }
    mutating func encode(_ value: String) throws { beginValue().pointee.buffer.writeString(value) }
    mutating func encode(_ value: Double) throws { beginValue().pointee.buffer.writeDouble(value) }
    mutating func encode(_ value: Float) throws { beginValue().pointee.buffer.writeFloat(value) }
    mutating func encode(_ value: Int) throws { encodeSigned(value) }
    mutating func encode(_ value: Int8) throws { encodeSigned(value) }
    mutating func encode(_ value: Int16) throws { encodeSigned(value) }
    mutating func encode(_ value: Int32) throws { encodeSigned(value) }
    mutating func encode(_ value: Int64) throws { encodeSigned(value) }
    mutating func encode(_ value: UInt) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt8) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt16) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt32) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt64) throws { encodeUnsigned(value) }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: Int128) throws {
        try owner.context.encodeWideInteger(value, path: owner.path) { _ = beginValue() }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128) throws {
        try owner.context.encodeWideInteger(value, path: owner.path) { _ = beginValue() }
    }

    // The ten integer overloads differ only in the width they widen from.
    // `writeInt`/`writeUInt` then pick the smallest wire format for the
    // widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger) {
        beginValue().pointee.buffer.writeInt(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger) {
        beginValue().pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        _ = beginValue()
        try owner.context.encodeValue(value, path: owner.path)
    }
}

// MARK: - Keyed container

struct MessagePackKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let context: MessagePackEncodingContext
    let headerPosition: Int
    let path: MessagePackEncodingPath

    var codingPath: [CodingKey] { context.codingPath(path) }

    /// Bumps the entry count and writes the key. The value must follow.
    @inline(__always)
    private func beginEntry(_ key: Key) {
        precondition(context.state.pointee.beginEntry(at: headerPosition), outOfOrderWriteMessage)
        context.state.pointee.buffer.writeString(key.stringValue)
    }

    mutating func encodeNil(forKey key: Key) throws {
        beginEntry(key)
        context.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        beginEntry(key)
        context.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        beginEntry(key)
        context.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        beginEntry(key)
        context.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        beginEntry(key)
        context.state.pointee.buffer.writeFloat(value)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws { encodeSigned(value, forKey: key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { encodeSigned(value, forKey: key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { encodeSigned(value, forKey: key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { encodeSigned(value, forKey: key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { encodeSigned(value, forKey: key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { encodeUnsigned(value, forKey: key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { encodeUnsigned(value, forKey: key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { encodeUnsigned(value, forKey: key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { encodeUnsigned(value, forKey: key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { encodeUnsigned(value, forKey: key) }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: Int128, forKey key: Key) throws {
        try context.encodeWideInteger(value, path: context.path(path, appending: key)) { beginEntry(key) }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128, forKey key: Key) throws {
        try context.encodeWideInteger(value, path: context.path(path, appending: key)) { beginEntry(key) }
    }

    // The ten integer overloads differ only in the width they widen from.
    // `writeInt`/`writeUInt` then pick the smallest wire format for the
    // widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger, forKey key: Key) {
        beginEntry(key)
        context.state.pointee.buffer.writeInt(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger, forKey key: Key) {
        beginEntry(key)
        context.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        beginEntry(key)
        try context.encodeValue(value, path: context.path(path, appending: key))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        beginEntry(key)
        return KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer<NestedKey>(
                context: context,
                headerPosition: context.beginContainer(isMap: true),
                path: context.path(path, appending: key)
            )
        )
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        beginEntry(key)
        return MessagePackUnkeyedEncodingContainer(
            context: context,
            headerPosition: context.beginContainer(isMap: false),
            path: context.path(path, appending: key)
        )
    }

    mutating func superEncoder() -> Encoder {
        MessagePackDeferredEncoder(
            context: context,
            path: context.path(path, appending: MessagePackCodingKey.super),
            parentPosition: headerPosition,
            key: MessagePackCodingKey.super.stringValue
        )
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        MessagePackDeferredEncoder(
            context: context,
            path: context.path(path, appending: key),
            parentPosition: headerPosition,
            key: key.stringValue
        )
    }
}

// MARK: - Unkeyed container

struct MessagePackUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let context: MessagePackEncodingContext
    let headerPosition: Int
    let path: MessagePackEncodingPath

    var codingPath: [CodingKey] { context.codingPath(path) }

    var count: Int { context.state.pointee.buffer.containerCount(at: headerPosition) }

    @inline(__always)
    private func beginElement() {
        precondition(context.state.pointee.beginEntry(at: headerPosition), outOfOrderWriteMessage)
    }

    mutating func encodeNil() throws {
        beginElement()
        context.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool) throws {
        beginElement()
        context.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String) throws {
        beginElement()
        context.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double) throws {
        beginElement()
        context.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        beginElement()
        context.state.pointee.buffer.writeFloat(value)
    }

    mutating func encode(_ value: Int) throws { encodeSigned(value) }
    mutating func encode(_ value: Int8) throws { encodeSigned(value) }
    mutating func encode(_ value: Int16) throws { encodeSigned(value) }
    mutating func encode(_ value: Int32) throws { encodeSigned(value) }
    mutating func encode(_ value: Int64) throws { encodeSigned(value) }
    mutating func encode(_ value: UInt) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt8) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt16) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt32) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt64) throws { encodeUnsigned(value) }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: Int128) throws {
        try context.encodeWideInteger(value, path: context.path(path, appendingIndex: count)) {
            beginElement()
        }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128) throws {
        try context.encodeWideInteger(value, path: context.path(path, appendingIndex: count)) {
            beginElement()
        }
    }

    // The ten integer overloads differ only in the width they widen from.
    // `writeInt`/`writeUInt` then pick the smallest wire format for the
    // widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger) {
        beginElement()
        context.state.pointee.buffer.writeInt(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger) {
        beginElement()
        context.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        beginElement()
        try context.encodeValue(
            value, path: context.path(path, appendingIndex: count - 1))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        beginElement()
        return KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer<NestedKey>(
                context: context,
                headerPosition: context.beginContainer(isMap: true),
                path: context.path(path, appendingIndex: count - 1)
            )
        )
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        beginElement()
        return MessagePackUnkeyedEncodingContainer(
            context: context,
            headerPosition: context.beginContainer(isMap: false),
            path: context.path(path, appendingIndex: count - 1)
        )
    }

    mutating func superEncoder() -> Encoder {
        MessagePackDeferredEncoder(
            context: context,
            path: context.path(path, appendingIndex: count),
            parentPosition: headerPosition,
            key: nil
        )
    }
}

// MARK: - Single value container

struct MessagePackSingleValueEncodingContainer: SingleValueEncodingContainer {
    let context: MessagePackEncodingContext
    let path: MessagePackEncodingPath
    /// Where the encoder's value starts; see ``MessagePackDirectEncoder/start``.
    let start: Int

    var codingPath: [CodingKey] { context.codingPath(path) }

    /// Traps if something was already encoded for the value, like
    /// `JSONEncoder`: a second value would corrupt the output.
    @inline(__always)
    private func beginValue() {
        precondition(context.state.pointee.buffer.offset == start, secondSingleValueMessage)
    }

    mutating func encodeNil() throws {
        beginValue()
        context.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool) throws {
        beginValue()
        context.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String) throws {
        beginValue()
        context.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double) throws {
        beginValue()
        context.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        beginValue()
        context.state.pointee.buffer.writeFloat(value)
    }

    mutating func encode(_ value: Int) throws { encodeSigned(value) }
    mutating func encode(_ value: Int8) throws { encodeSigned(value) }
    mutating func encode(_ value: Int16) throws { encodeSigned(value) }
    mutating func encode(_ value: Int32) throws { encodeSigned(value) }
    mutating func encode(_ value: Int64) throws { encodeSigned(value) }
    mutating func encode(_ value: UInt) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt8) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt16) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt32) throws { encodeUnsigned(value) }
    mutating func encode(_ value: UInt64) throws { encodeUnsigned(value) }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: Int128) throws {
        try context.encodeWideInteger(value, path: path) { beginValue() }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128) throws {
        try context.encodeWideInteger(value, path: path) { beginValue() }
    }

    // The ten integer overloads differ only in the width they widen from.
    // `writeInt`/`writeUInt` then pick the smallest wire format for the
    // widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger) {
        beginValue()
        context.state.pointee.buffer.writeInt(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger) {
        beginValue()
        context.state.pointee.buffer.writeUInt(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        beginValue()
        try context.encodeValue(value, path: path)
    }
}
