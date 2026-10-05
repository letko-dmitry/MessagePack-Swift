import Foundation

private let secondSingleValueMessage = """
    Attempt to encode a second value (or a value after a container) through \
    a single value encoding container
    """

// MARK: - Deferred (super) encoder

/// Encoder returned by `superEncoder()` / `superEncoder(forKey:)`. Writing
/// the map key (or counting the array element) is deferred until this
/// encoder is first encoded into, so:
/// - a super encoder that is requested but never used contributes nothing
///   (the output stays valid), and
/// - a super encoder used after further sibling writes still produces a
///   well-formed entry (the key is written at actual encode time).
final class MessagePackDeferredEncoder: Encoder {
    let impl: MessagePackEncoderImpl
    let path: MessagePackEncodingPath
    let parentPosition: Int
    /// The map key to write on activation; nil when the parent is an array.
    let key: String?
    private var inner: _MessagePackEncoder?

    init(impl: MessagePackEncoderImpl, path: MessagePackEncodingPath, parentPosition: Int, key: String?) {
        self.impl = impl
        self.path = path
        self.parentPosition = parentPosition
        self.key = key
    }

    var codingPath: [CodingKey] { impl.codingPath(path) }
    var userInfo: [CodingUserInfoKey: Any] { impl.userInfo }

    /// Writes the deferred entry (exactly once) and returns the real encoder.
    func activate() -> _MessagePackEncoder {
        if let inner { return inner }
        impl.beginEntry(in: parentPosition)
        if let key { impl.state.pointee.buffer.writeString(key) }
        let encoder = _MessagePackEncoder(impl: impl, path: path, start: impl.state.pointee.buffer.offset)
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

    @inline(never)
    private func begin() -> UnsafeMutablePointer<MessagePackEncoderState> {
        let start = owner.activate().start
        let state = owner.impl.state
        precondition(state.pointee.buffer.offset == start, secondSingleValueMessage)
        return state
    }

    mutating func encodeNil() throws { begin().pointee.buffer.writeNil() }
    mutating func encode(_ value: Bool) throws { begin().pointee.buffer.writeBool(value) }
    mutating func encode(_ value: String) throws { begin().pointee.buffer.writeString(value) }
    mutating func encode(_ value: Double) throws { begin().pointee.buffer.writeDouble(value) }
    mutating func encode(_ value: Float) throws { begin().pointee.buffer.writeFloat(value) }
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
        try owner.impl.encodeWideInteger(value, path: owner.path) { _ = begin() }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128) throws {
        try owner.impl.encodeWideInteger(value, path: owner.path) { _ = begin() }
    }

    // The ten integer overloads differ only in the width they widen from.
    // `writeInt`/`writeUInt` then pick the smallest wire format for the
    // widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger) {
        begin().pointee.buffer.writeIntOutlined(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger) {
        begin().pointee.buffer.writeUIntOutlined(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        _ = begin()
        try owner.impl.encode(value, path: owner.path)
    }
}

// MARK: - Keyed container

struct MessagePackKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let impl: MessagePackEncoderImpl
    /// Where the map's header is, which identifies the map.
    let position: Int
    let path: MessagePackEncodingPath

    var codingPath: [CodingKey] { impl.codingPath(path) }

    /// Counts the entry and writes the key. The value must follow.
    @inline(__always)
    private func beginEntry(_ key: Key) {
        impl.beginEntry(in: position)
        impl.state.pointee.buffer.writeString(key.stringValue)
    }

    /// ``beginEntry(_:)`` out of line, for the overloads of rarely encoded
    /// types: one shared copy instead of one inlined into each.
    @inline(never)
    private func beginEntryOutlined(_ key: Key) {
        beginEntry(key)
    }

    mutating func encodeNil(forKey key: Key) throws {
        beginEntryOutlined(key)
        impl.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        beginEntryOutlined(key)
        impl.state.pointee.buffer.writeFloat(value)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        beginEntry(key)
        impl.state.pointee.buffer.writeIntOutlined(Int64(value))
    }
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
        try impl.encodeWideInteger(value, path: impl.path(path, appending: key)) { beginEntryOutlined(key) }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128, forKey key: Key) throws {
        try impl.encodeWideInteger(value, path: impl.path(path, appending: key)) { beginEntryOutlined(key) }
    }

    // The integer overloads other than `Int` differ only in the width they
    // widen from. `writeInt`/`writeUInt` then pick the smallest wire format
    // for the widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger, forKey key: Key) {
        beginEntryOutlined(key)
        impl.state.pointee.buffer.writeIntOutlined(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger, forKey key: Key) {
        beginEntryOutlined(key)
        impl.state.pointee.buffer.writeUIntOutlined(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        beginEntry(key)
        try impl.encode(value, path: impl.path(path, appending: key))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        beginEntryOutlined(key)
        let nestedPath = impl.path(path, appending: key)
        return KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer<NestedKey>(
                impl: impl,
                position: impl.openContainer(isMap: true),
                path: nestedPath
            )
        )
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        beginEntryOutlined(key)
        let nestedPath = impl.path(path, appending: key)
        return MessagePackUnkeyedEncodingContainer(
            impl: impl,
            position: impl.openContainer(isMap: false),
            path: nestedPath
        )
    }

    mutating func superEncoder() -> Encoder {
        MessagePackDeferredEncoder(
            impl: impl,
            path: impl.path(path, appending: MessagePackCodingKey.super),
            parentPosition: position,
            key: MessagePackCodingKey.super.stringValue
        )
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        MessagePackDeferredEncoder(
            impl: impl,
            path: impl.path(path, appending: key),
            parentPosition: position,
            key: key.stringValue
        )
    }
}

// MARK: - Unkeyed container

struct MessagePackUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let impl: MessagePackEncoderImpl
    /// Where the array's header is, which identifies the array.
    let position: Int
    let path: MessagePackEncodingPath

    var codingPath: [CodingKey] { impl.codingPath(path) }

    var count: Int { impl.state.pointee.buffer.containerCount(at: position) }

    /// Counts the element, so the count includes it afterwards: its index,
    /// `count &- 1`, cannot overflow.
    @inline(__always)
    private func beginElement() {
        impl.beginEntry(in: position)
    }

    mutating func encodeNil() throws {
        beginElement()
        impl.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool) throws {
        beginElement()
        impl.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String) throws {
        beginElement()
        impl.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double) throws {
        beginElement()
        impl.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        beginElement()
        impl.state.pointee.buffer.writeFloat(value)
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
        try impl.encodeWideInteger(value, path: impl.path(path, appendingIndex: count)) { beginElement() }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128) throws {
        try impl.encodeWideInteger(value, path: impl.path(path, appendingIndex: count)) { beginElement() }
    }

    // The ten integer overloads differ only in the width they widen from.
    // `writeInt`/`writeUInt` then pick the smallest wire format for the
    // widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger) {
        beginElement()
        impl.state.pointee.buffer.writeIntOutlined(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger) {
        beginElement()
        impl.state.pointee.buffer.writeUIntOutlined(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        beginElement()
        try impl.encode(value, path: impl.path(path, appendingIndex: count &- 1))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        beginElement()
        let nestedPath = impl.path(path, appendingIndex: count &- 1)
        return KeyedEncodingContainer(
            MessagePackKeyedEncodingContainer<NestedKey>(
                impl: impl,
                position: impl.openContainer(isMap: true),
                path: nestedPath
            )
        )
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        beginElement()
        let nestedPath = impl.path(path, appendingIndex: count &- 1)
        return MessagePackUnkeyedEncodingContainer(
            impl: impl,
            position: impl.openContainer(isMap: false),
            path: nestedPath
        )
    }

    mutating func superEncoder() -> Encoder {
        MessagePackDeferredEncoder(
            impl: impl,
            path: impl.path(path, appendingIndex: count),
            parentPosition: position,
            key: nil
        )
    }
}

// MARK: - Single value container

struct MessagePackSingleValueEncodingContainer: SingleValueEncodingContainer {
    let impl: MessagePackEncoderImpl
    let path: MessagePackEncodingPath
    /// Where the encoder's value starts; see ``_MessagePackEncoder/start``.
    let start: Int

    var codingPath: [CodingKey] { impl.codingPath(path) }

    /// Traps if something was already encoded for the value, like
    /// `JSONEncoder`: a second value would corrupt the output.
    @inline(__always)
    private func beginValue() {
        precondition(impl.state.pointee.buffer.offset == start, secondSingleValueMessage)
    }

    mutating func encodeNil() throws {
        beginValue()
        impl.state.pointee.buffer.writeNil()
    }

    mutating func encode(_ value: Bool) throws {
        beginValue()
        impl.state.pointee.buffer.writeBool(value)
    }

    mutating func encode(_ value: String) throws {
        beginValue()
        impl.state.pointee.buffer.writeString(value)
    }

    mutating func encode(_ value: Double) throws {
        beginValue()
        impl.state.pointee.buffer.writeDouble(value)
    }

    mutating func encode(_ value: Float) throws {
        beginValue()
        impl.state.pointee.buffer.writeFloat(value)
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
        try impl.encodeWideInteger(value, path: path) { beginValue() }
    }

    @available(watchOS 11.0, *)
    mutating func encode(_ value: UInt128) throws {
        try impl.encodeWideInteger(value, path: path) { beginValue() }
    }

    // The ten integer overloads differ only in the width they widen from.
    // `writeInt`/`writeUInt` then pick the smallest wire format for the
    // widened value, so widening here costs nothing on the wire.
    @inline(__always)
    private func encodeSigned(_ value: some SignedInteger & FixedWidthInteger) {
        beginValue()
        impl.state.pointee.buffer.writeIntOutlined(Int64(value))
    }

    @inline(__always)
    private func encodeUnsigned(_ value: some UnsignedInteger & FixedWidthInteger) {
        beginValue()
        impl.state.pointee.buffer.writeUIntOutlined(UInt64(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        beginValue()
        try impl.encode(value, path: path)
    }
}
