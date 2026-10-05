import Foundation

// MARK: - Keyed container

/// Entry offsets for one wire map, scanned once at container creation.
/// A class so the rolling search index survives the container being copied
/// into `KeyedDecodingContainer`'s box. Instances are recycled through
/// ``MessagePackDecodingContext/borrowKeyedStorage()``, so `scan` must leave
/// no state behind from a previous use.
final class MessagePackKeyedStorage {
    struct Entry {
        let keyOffset: Int
        /// The byte count of a string key, whose bytes end where the value
        /// starts, or -1 for any other key.
        let keyLength: Int
        let valueOffset: Int
    }

    var entries: [Entry] = []
    /// Where the next key lookup starts. Keys are usually requested in wire
    /// order, so remembering the last match makes typical lookups O(1).
    var searchIndex = 0

    func scan(
        entryCount: Int, parser: inout MessagePackSerializer.Parser
    ) throws(MessagePackError) {
        // Build into a local array (with the stored one detached so the
        // local is uniquely referenced), keeping the append loop free of
        // class-property exclusivity and uniqueness checks.
        var scanned = entries
        entries = []
        searchIndex = 0
        scanned.removeAll(keepingCapacity: true)
        scanned.reserveCapacity(Swift.min(entryCount, messagePackMaxPreallocation))
        for _ in 0..<entryCount {
            let keyOffset = parser.offset
            let keyLength: Int
            if let keyBytes = try parser.readRawStringBytes() {
                keyLength = keyBytes.count
            } else {
                try parser.skipValue()
                keyLength = -1
            }
            let valueOffset = parser.offset
            try parser.skipValue()
            scanned.append(Entry(keyOffset: keyOffset, keyLength: keyLength, valueOffset: valueOffset))
        }
        entries = scanned
    }
}

struct MessagePackKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let context: MessagePackDecodingContext
    let storage: MessagePackKeyedStorage
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(storage.entries.count)
        for entry in storage.entries {
            var parser = context.parser(at: entry.keyOffset)
            if let string = ((try? parser.readRawString()) ?? nil) {
                if let key = Key(stringValue: string) { keys.append(key) }
            } else {
                var intParser = context.parser(at: entry.keyOffset)
                guard let raw = ((try? intParser.readRawInteger()) ?? nil) else { continue }
                let intValue: Int?
                switch raw {
                case .signed(let v): intValue = Int(exactly: v)
                case .unsigned(let v): intValue = Int(exactly: v)
                }
                if let intValue, let key = Key(intValue: intValue) { keys.append(key) }
            }
        }
        return keys
    }

    /// Finds the value offset for a key by comparing raw key bytes in place;
    /// no `String` is materialized for wire keys.
    private func valueOffset(for key: some CodingKey) -> Int? {
        let entries = storage.entries
        let entryCount = entries.count
        guard entryCount > 0 else { return nil }
        var keyString = key.stringValue
        return keyString.withUTF8 { (keyBytes: UnsafeBufferPointer<UInt8>) -> Int? in
            var index = storage.searchIndex
            for _ in 0..<entryCount {
                if index >= entryCount { index = 0 }
                let entry = entries[index]
                index += 1
                if matches(keyBytes: keyBytes, key: key, entry: entry) {
                    // Remember the match itself (not the next entry), so a
                    // key asked for again (`contains` before `decode`) is
                    // found at once while sequential access stays O(1).
                    storage.searchIndex = index - 1
                    return entry.valueOffset
                }
            }
            return nil
        }
    }

    private func matches(
        keyBytes: UnsafeBufferPointer<UInt8>, key: some CodingKey, entry: MessagePackKeyedStorage.Entry
    ) -> Bool {
        guard entry.keyLength >= 0 else {
            // Asked for only here: string keys are the common case, and the
            // `intValue` of a key type is a call through its conformance.
            return matchesIntegerKey(key.intValue, at: entry.keyOffset)
        }
        guard entry.keyLength == keyBytes.count else {
            return false
        }
        guard entry.keyLength > 0, let keyBase = keyBytes.baseAddress, let base = context.base else {
            // Empty keys match; any other key has bytes on both sides.
            return entry.keyLength == 0
        }

        // The scan recorded where the key's bytes are, so this is a length
        // check and a `memcmp`, without parsing the key's header again.
        return memcmp(base + (entry.valueOffset &- entry.keyLength), keyBase, keyBytes.count) == 0
    }

    /// Matches a non-string wire key against the coding key's `intValue`.
    private func matchesIntegerKey(_ intValue: Int?, at keyOffset: Int) -> Bool {
        guard let intValue else { return false }
        var parser = context.parser(at: keyOffset)
        guard let raw = ((try? parser.readRawInteger()) ?? nil) else { return false }
        switch raw {
        case .signed(let v): return Int64(intValue) == v
        case .unsigned(let v): return intValue >= 0 && UInt64(intValue) == v
        }
    }

    private func requireOffset(_ key: Key) throws -> Int {
        guard let offset = valueOffset(for: key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \"\(key.stringValue)\""
                ))
        }
        return offset
    }

    func contains(_ key: Key) -> Bool {
        valueOffset(for: key) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        let parser = context.parser(at: try requireOffset(key))
        return ((try? parser.peekFormat()) ?? 0xc1) == 0xc0
    }

    /// The value offset for a key whose value is present and not nil. One
    /// lookup serves all of `decodeIfPresent`, where the default
    /// implementation looks the key up three times (`contains`,
    /// `decodeNil`, `decode`); `PropertyListDecoder` avoids that the same
    /// way.
    private func presentValueOffset(_ key: Key) -> Int? {
        guard let valueOffset = valueOffset(for: key) else { return nil }
        var parser = context.parser(at: valueOffset)
        return parser.readRawNil() ? nil : valueOffset
    }

    // The scalar wrappers stay inline so that each `decode(_:forKey:)`
    // overload calls a `decodeScalar` specialized for its value type: the
    // container is generic over `Key`, and as its own methods the helpers
    // were left unspecialized, passing the type and the read closure at run
    // time. The read itself is shared by all key types.

    @inline(__always)
    private func decodeScalar<T>(
        _ type: T.Type, forKey key: Key,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T {
        try MessagePackDecoding.decodeScalar(
            type, context: context, offset: try requireOffset(key), codingPath: codingPath + [key], read)
    }

    @inline(__always)
    private func decodeScalarIfPresent<T>(
        _ type: T.Type, forKey key: Key,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T? {
        guard let valueOffset = presentValueOffset(key) else { return nil }
        return try MessagePackDecoding.decodeScalar(
            type, context: context, offset: valueOffset, codingPath: codingPath + [key], read)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readBool)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readString)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readDouble)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readFloat)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    @available(watchOS 11.0, *)
    func decode(_ type: Int128.Type, forKey key: Key) throws -> Int128 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    @available(watchOS 11.0, *)
    func decode(_ type: UInt128.Type, forKey key: Key) throws -> UInt128 {
        try decodeScalar(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try decode(type, at: try requireOffset(key), forKey: key)
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readBool)
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readString)
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readDouble)
    }

    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readFloat)
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }
    @available(watchOS 11.0, *)
    func decodeIfPresent(_ type: Int128.Type, forKey key: Key) throws -> Int128? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }
    @available(watchOS 11.0, *)
    func decodeIfPresent(_ type: UInt128.Type, forKey key: Key) throws -> UInt128? {
        try decodeScalarIfPresent(type, forKey: key, MessagePackDecoding.readInteger)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let valueOffset = presentValueOffset(key) else { return nil }
        return try decode(type, at: valueOffset, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, at valueOffset: Int, forKey key: Key) throws -> T {
        var parser = context.parser(at: valueOffset)
        return try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, codingPath: codingPath + [key])
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let impl = MessagePackDecoderImpl(
            context: context, offset: try requireOffset(key), codingPath: codingPath + [key])
        return try impl.container(keyedBy: NestedKey.self)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let impl = MessagePackDecoderImpl(
            context: context, offset: try requireOffset(key), codingPath: codingPath + [key])
        return try impl.unkeyedContainer()
    }

    /// Mirroring `JSONDecoder`, a missing entry yields a decoder positioned
    /// on a nil value rather than throwing `keyNotFound`.
    private func superDecoder(for key: some CodingKey) -> Decoder {
        guard let offset = valueOffset(for: key) else {
            return MessagePackNilDecoder(
                codingPath: codingPath + [key], userInfo: context.userInfo)
        }
        return MessagePackDecoderImpl(
            context: context, offset: offset, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> Decoder {
        superDecoder(for: MessagePackCodingKey.super)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        superDecoder(for: key)
    }
}

// MARK: - Nil decoder

/// Decoder representing an absent value, returned by `superDecoder()` when
/// the wire map has no matching entry (`JSONDecoder` behaves the same way,
/// treating the missing entry as null).
struct MessagePackNilDecoder: Decoder, SingleValueDecodingContainer {
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    private func valueNotFound(_ type: Any.Type) -> DecodingError {
        .valueNotFound(
            type,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Cannot decode \(type) -- found nil value instead"
            ))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw valueNotFound(KeyedDecodingContainer<Key>.self)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw valueNotFound(UnkeyedDecodingContainer.self)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }

    func decodeNil() -> Bool { true }

    func decode(_ type: Bool.Type) throws -> Bool { throw valueNotFound(type) }
    func decode(_ type: String.Type) throws -> String { throw valueNotFound(type) }
    func decode(_ type: Double.Type) throws -> Double { throw valueNotFound(type) }
    func decode(_ type: Float.Type) throws -> Float { throw valueNotFound(type) }
    func decode(_ type: Int.Type) throws -> Int { throw valueNotFound(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { throw valueNotFound(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { throw valueNotFound(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { throw valueNotFound(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { throw valueNotFound(type) }
    func decode(_ type: UInt.Type) throws -> UInt { throw valueNotFound(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { throw valueNotFound(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { throw valueNotFound(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { throw valueNotFound(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { throw valueNotFound(type) }

    @available(watchOS 11.0, *)
    func decode(_ type: Int128.Type) throws -> Int128 { throw valueNotFound(type) }

    @available(watchOS 11.0, *)
    func decode(_ type: UInt128.Type) throws -> UInt128 { throw valueNotFound(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // Lets Optional<T> decode as nil via its own conformance; anything
        // else fails with valueNotFound from the container requests above.
        try T(from: self)
    }
}

// MARK: - Unkeyed container

struct MessagePackUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let context: MessagePackDecodingContext
    let codingPath: [CodingKey]
    let elementCount: Int
    /// Where this array value starts, for the end-of-container memo.
    let startOffset: Int
    /// Cursor positioned at the next element to decode.
    var parser: MessagePackSerializer.Parser
    var currentIndex = 0

    var count: Int? { elementCount }
    var isAtEnd: Bool { currentIndex >= elementCount }

    /// Advances the element index; on decoding the final element, records
    /// where this array ends so `unwrap` can reuse it instead of re-skipping.
    @inline(__always)
    private mutating func advanceIndex() {
        currentIndex += 1
        if currentIndex == elementCount {
            context.memoStart = startOffset
            context.memoEnd = parser.offset
        }
    }

    private func checkEnd(_ type: Any.Type) throws {
        if currentIndex >= elementCount {
            throw DecodingError.valueNotFound(
                type,
                DecodingError.Context(
                    codingPath: codingPath + [MessagePackCodingKey(index: currentIndex)],
                    debugDescription: "Unkeyed container is at end"
                ))
        }
    }

    mutating func decodeNil() throws -> Bool {
        try checkEnd(Any?.self)
        if ((try? parser.peekFormat()) ?? 0xc1) == 0xc0 {
            parser.offset += 1
            advanceIndex()
            return true
        }
        return false
    }

    private mutating func decodeScalar<T>(
        _ type: T.Type,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T {
        try checkEnd(type)
        // On failure, rewind to the element start so the cursor stays in
        // sync with `currentIndex` — callers may catch the error and retry
        // with a different type (`try? decode(A.self)` fallback patterns).
        let elementStart = parser.offset
        do throws(MessagePackDecodeFailure) {
            let value = try read(&parser)
            advanceIndex()
            return value
        } catch {
            parser.offset = elementStart
            throw MessagePackDecoding.decodingError(
                error, type: type, parser: parser,
                path: codingPath + [MessagePackCodingKey(index: currentIndex)])
        }
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        try decodeScalar(type, MessagePackDecoding.readBool)
    }

    mutating func decode(_ type: String.Type) throws -> String {
        try decodeScalar(type, MessagePackDecoding.readString)
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        try decodeScalar(type, MessagePackDecoding.readDouble)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        try decodeScalar(type, MessagePackDecoding.readFloat)
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    @available(watchOS 11.0, *)
    mutating func decode(_ type: Int128.Type) throws -> Int128 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    @available(watchOS 11.0, *)
    mutating func decode(_ type: UInt128.Type) throws -> UInt128 {
        try decodeScalar(type, MessagePackDecoding.readInteger)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try checkEnd(type)
        // Local copies so the lazy coding-path closure does not capture
        // `self` while `parser` is passed inout.
        let parentPath = codingPath
        let index = currentIndex
        let value = try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context,
            codingPath: parentPath + [MessagePackCodingKey(index: index)])
        advanceIndex()
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try checkEnd(KeyedDecodingContainer<NestedKey>.self)
        let path = codingPath + [MessagePackCodingKey(index: currentIndex)]
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, codingPath: path)
        let container = try impl.container(keyedBy: NestedKey.self)
        try MessagePackDecoding.skip(&parser, path: path)
        advanceIndex()
        return container
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try checkEnd(UnkeyedDecodingContainer.self)
        let path = codingPath + [MessagePackCodingKey(index: currentIndex)]
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, codingPath: path)
        let container = try impl.unkeyedContainer()
        try MessagePackDecoding.skip(&parser, path: path)
        advanceIndex()
        return container
    }

    mutating func superDecoder() throws -> Decoder {
        try checkEnd(Decoder.self)
        let path = codingPath + [MessagePackCodingKey(index: currentIndex)]
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, codingPath: path)
        try MessagePackDecoding.skip(&parser, path: path)
        advanceIndex()
        return impl
    }
}
