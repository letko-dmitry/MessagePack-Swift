import Foundation

// MARK: - Keyed container

/// Entry offsets for one wire map, scanned lazily: the scan stops at each
/// array or map value until a lookup needs to go past it, and a nested
/// value's end is recorded when the value is decoded. Keys are usually
/// requested in wire order, so the scan resumes where that value was decoded
/// to, and every byte of a nested value is walked once, by its own decoder,
/// instead of once more by every enclosing map's scan.
///
/// A class so it can be recycled across the containers of one `decode`
/// call through ``MessagePackDecodingContext/borrowKeyedStorage()`` (so
/// `reset` must leave no state behind from a previous use) and referred to
/// from the context while its value is being decoded.
final class MessagePackKeyedStorage: ManagedBuffer<MessagePackKeyedStorage.State, Void> {
    struct Entry {
        let keyOffset: Int
        /// The byte count of a string key, whose bytes end where the value
        /// starts, or -1 for any other key.
        let keyLength: Int
        let valueOffset: Int
    }

    struct State {
        /// The entries scanned so far, in wire order. Each value ends where
        /// the next entry's key starts, so only the last one's end is kept.
        var entries: [Entry] = []
        /// Where the last scanned entry's value ends, or -1 until that value
        /// is decoded or skipped.
        var lastValueEnd = -1
        var entryCount = 0
        /// The entry of the last key match, where the next lookup starts.
        var searchIndex = 0
        var firstKeyOffset = 0
    }

    /// The state lives in the buffer's header, allocated with the object
    /// (as swift-collections does), and is reached through a pointer so the
    /// lookup and scan paths bypass dynamic exclusivity enforcement on
    /// class properties.
    private var state: UnsafeMutablePointer<State> {
        withUnsafeMutablePointerToHeader { $0 }
    }

    static func make() -> MessagePackKeyedStorage {
        unsafeDowncast(create(minimumCapacity: 0) { _ in State() }, to: MessagePackKeyedStorage.self)
    }

    var entryCount: Int { state.pointee.entryCount }
    var scannedCount: Int { state.pointee.entries.count }

    var searchIndex: Int {
        get { state.pointee.searchIndex }
        set { state.pointee.searchIndex = newValue }
    }

    func entry(at index: Int) -> Entry {
        state.pointee.entries[index]
    }

    func reset(firstKeyOffset: Int, entryCount: Int) {
        state.pointee.firstKeyOffset = firstKeyOffset
        state.pointee.entryCount = entryCount
        state.pointee.searchIndex = 0
        state.pointee.lastValueEnd = -1

        state.pointee.entries.removeAll(keepingCapacity: true)
        state.pointee.entries.reserveCapacity(Swift.min(entryCount, messagePackMaxPreallocation))
    }

    /// Scans ahead: entries with scalar, string, or binary values are
    /// scanned in one go, as skipping those costs next to nothing, and the
    /// scan stops after the first entry whose value is an array or map,
    /// whose end is only known cheaply once it has been decoded.
    func scanAhead(_ context: MessagePackDecodingContext) throws(MessagePackError) {
        let entryCount = entryCount
        var scannedCount = scannedCount
        var keyOffset = try scannedEnd(context)

        while scannedCount < entryCount {
            var parser = context.parser(at: keyOffset)
            let keyLength: Int
            if let keyBytes = try parser.readRawStringBytes() {
                keyLength = keyBytes.count
            } else {
                try parser.skipValue()
                keyLength = -1
            }
            let valueOffset = parser.offset
            let isContainer = Self.isContainer(try parser.peekFormat())
            if !isContainer {
                try parser.skipValue()
            }

            state.pointee.entries.append(Entry(keyOffset: keyOffset, keyLength: keyLength, valueOffset: valueOffset))
            if isContainer {
                state.pointee.lastValueEnd = -1
                return
            }

            state.pointee.lastValueEnd = parser.offset
            scannedCount &+= 1
            keyOffset = parser.offset
        }
    }

    @inline(__always)
    private static func isContainer(_ format: UInt8) -> Bool {
        (0x80...0x9f).contains(format) || (0xdc...0xdf).contains(format)
    }

    /// Records where a decoded value ends. Only the last scanned entry's end
    /// is not already known, as the next entry's key.
    func recordValueEnd(_ end: Int, at index: Int) {
        if index == scannedCount &- 1 {
            state.pointee.lastValueEnd = end
        }
    }

    /// Where the scanned entries end, which is where the next entry's key
    /// starts (or the map ends), skipping over the last scanned value the
    /// first time it is asked for undecoded.
    private func scannedEnd(_ context: MessagePackDecodingContext) throws(MessagePackError) -> Int {
        guard let last = state.pointee.entries.last else {
            return state.pointee.firstKeyOffset
        }

        if state.pointee.lastValueEnd < 0 {
            var parser = context.parser(at: last.valueOffset)
            try parser.skipValue()
            state.pointee.lastValueEnd = parser.offset
        }

        return state.pointee.lastValueEnd
    }

    /// Scans the entries no lookup reached and returns where the map ends.
    func end(_ context: MessagePackDecodingContext) throws(MessagePackError) -> Int {
        while scannedCount < entryCount {
            try scanAhead(context)
        }

        return try scannedEnd(context)
    }
}

/// The outcome of a key lookup. Declared outside the generic container so
/// it is not generic over `Key`: nested there, its metadata was instantiated
/// at run time on every lookup.
private enum MessagePackKeyLookup {
    case found(Int)
    case missing
    case failed(MessagePackError)
}

final class MessagePackKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let context: MessagePackDecodingContext
    let storage: MessagePackKeyedStorage
    /// The byte offset of the map, where errors about the map point.
    let offset: Int
    let path: MessagePackCodingPath

    var codingPath: [CodingKey] { path.keys }

    init(
        context: MessagePackDecodingContext, storage: MessagePackKeyedStorage, offset: Int, path: MessagePackCodingPath
    ) {
        self.context = context
        self.storage = storage
        self.offset = offset
        self.path = path
    }

    var allKeys: [Key] {
        // A map that fails to scan lists the keys before the failure; the
        // failure itself surfaces when the value's end is needed.
        _ = try? storage.end(context)

        var keys: [Key] = []
        keys.reserveCapacity(storage.scannedCount)
        for index in 0..<storage.scannedCount {
            let entry = storage.entry(at: index)
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

    /// Finds the entry for a key by comparing raw key bytes in place (no
    /// `String` is materialized for wire keys), scanning entries as needed.
    private func entryIndex(for key: some CodingKey) throws -> Int? {
        guard storage.entryCount > 0 else { return nil }

        var keyString = key.stringValue
        let lookup = keyString.withUTF8 { keyBytes in
            lookUp(keyBytes: keyBytes, key: key)
        }

        switch lookup {
        case .found(let index):
            storage.searchIndex = index
            return index
        case .missing:
            return nil
        case .failed(let error):
            throw MessagePackDecoding.corrupted(error, path, offset: offset)
        }
    }

    /// Searches from the last match (inclusive) forwards, wrapping around,
    /// as earlier versions did: keys requested in wire order are found one
    /// entry after the previous match, a key asked for again (`contains`
    /// before `decode`) at it, and of duplicate keys the same entry is found
    /// as before. Entries are scanned as the search reaches them.
    private func lookUp(keyBytes: UnsafeBufferPointer<UInt8>, key: some CodingKey) -> MessagePackKeyLookup {
        let entryCount = storage.entryCount
        let start = storage.searchIndex

        do throws(MessagePackError) {
            var index = start
            repeat {
                if index == storage.scannedCount {
                    try storage.scanAhead(context)
                }
                if matches(keyBytes: keyBytes, key: key, at: index) {
                    return .found(index)
                }
                index &+= 1
                if index == entryCount {
                    index = 0
                }
            } while index != start

            return .missing
        } catch {
            return .failed(error)
        }
    }

    private func matches(keyBytes: UnsafeBufferPointer<UInt8>, key: some CodingKey, at index: Int) -> Bool {
        let entry = storage.entry(at: index)
        guard entry.keyLength >= 0 else {
            // Asked for only here: string keys are the common case, and the
            // `intValue` of a key type is a call through its conformance.
            return matchesIntegerKey(key.intValue, at: entry.keyOffset)
        }
        guard entry.keyLength == keyBytes.count else {
            return false
        }
        guard entry.keyLength > 0, let keyBase = keyBytes.baseAddress, let base = context.state.pointee.base else {
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

    private func requireEntry(_ key: Key) throws -> Int {
        guard let index = try entryIndex(for: key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \"\(key.stringValue)\""
                ))
        }
        return index
    }

    private func valueOffset(_ key: Key) throws -> Int {
        // The lookup may scan (and append to) the entries, so it has to run
        // before they are read.
        let index = try requireEntry(key)
        return storage.entry(at: index).valueOffset
    }

    func contains(_ key: Key) -> Bool {
        (try? entryIndex(for: key)) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        let parser = context.parser(at: try valueOffset(key))
        return ((try? parser.peekFormat()) ?? 0xc1) == 0xc0
    }

    /// The entry for a key whose value is present and not nil. One lookup
    /// serves all of `decodeIfPresent`, where the default implementation
    /// looks the key up three times (`contains`, `decodeNil`, `decode`);
    /// `PropertyListDecoder` avoids that the same way.
    private func presentEntry(_ key: Key) throws -> Int? {
        guard let index = try entryIndex(for: key) else {
            return nil
        }
        var parser = context.parser(at: storage.entry(at: index).valueOffset)
        return parser.readRawNil() ? nil : index
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
            type, context: context, offset: try valueOffset(key), path: path.appending(key), read)
    }

    @inline(__always)
    private func decodeScalarIfPresent<T>(
        _ type: T.Type, forKey key: Key,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T? {
        guard let index = try presentEntry(key) else { return nil }

        return try MessagePackDecoding.decodeScalar(
            type, context: context, offset: storage.entry(at: index).valueOffset, path: path.appending(key), read)
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
        try decode(type, entry: try requireEntry(key), forKey: key)
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
        guard let index = try presentEntry(key) else { return nil }
        return try decode(type, entry: index, forKey: key)
    }

    /// Decodes the value of an entry and records where it ends, which is
    /// where the next entry's key starts.
    private func decode<T: Decodable>(_ type: T.Type, entry index: Int, forKey key: Key) throws -> T {
        var parser = context.parser(at: storage.entry(at: index).valueOffset)
        let value = try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, path: path.appending(key))
        storage.recordValueEnd(parser.offset, at: index)

        return value
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let impl = MessagePackDecoderImpl(
            context: context, offset: try valueOffset(key), path: path.appending(key))
        return try impl.container(keyedBy: NestedKey.self)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let impl = MessagePackDecoderImpl(
            context: context, offset: try valueOffset(key), path: path.appending(key))
        return try impl.unkeyedContainer()
    }

    /// Mirroring `JSONDecoder`, a missing entry yields a decoder positioned
    /// on a nil value rather than throwing `keyNotFound`.
    private func superDecoder(for key: some CodingKey) throws -> Decoder {
        guard let index = try entryIndex(for: key) else {
            return MessagePackNilDecoder(
                codingPath: path.appending(key).keys, userInfo: context.userInfo)
        }
        return MessagePackDecoderImpl(
            context: context, offset: storage.entry(at: index).valueOffset, path: path.appending(key))
    }

    func superDecoder() throws -> Decoder {
        try superDecoder(for: MessagePackCodingKey.super)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        try superDecoder(for: key)
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
    let path: MessagePackCodingPath
    let elementCount: Int
    /// Where this array value starts, for the end-of-container memo.
    let startOffset: Int
    /// Cursor positioned at the next element to decode.
    var parser: MessagePackSerializer.Parser
    var currentIndex = 0

    var codingPath: [CodingKey] { path.keys }
    var count: Int? { elementCount }
    var isAtEnd: Bool { currentIndex >= elementCount }

    /// Advances the element index; on decoding the final element, records
    /// where this array ends so `unwrap` can reuse it instead of re-skipping.
    @inline(__always)
    private mutating func advanceIndex() {
        currentIndex += 1
        if currentIndex == elementCount {
            context.state.pointee.memoStart = startOffset
            context.state.pointee.memoEnd = parser.offset
        }
    }

    private func checkEnd(_ type: Any.Type) throws {
        if currentIndex >= elementCount {
            throw DecodingError.valueNotFound(
                type,
                DecodingError.Context(
                    codingPath: path.appending(index: currentIndex).keys,
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
                path: path.appending(index: currentIndex))
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
        let parentPath = path
        let index = currentIndex
        let value = try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, path: parentPath.appending(index: index))
        advanceIndex()
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try checkEnd(KeyedDecodingContainer<NestedKey>.self)
        let elementPath = path.appending(index: currentIndex)
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, path: elementPath)
        let container = try impl.container(keyedBy: NestedKey.self)
        try MessagePackDecoding.skip(&parser, path: elementPath)
        advanceIndex()
        return container
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try checkEnd(UnkeyedDecodingContainer.self)
        let elementPath = path.appending(index: currentIndex)
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, path: elementPath)
        let container = try impl.unkeyedContainer()
        try MessagePackDecoding.skip(&parser, path: elementPath)
        advanceIndex()
        return container
    }

    mutating func superDecoder() throws -> Decoder {
        try checkEnd(Decoder.self)
        let elementPath = path.appending(index: currentIndex)
        let impl = MessagePackDecoderImpl(context: context, offset: parser.offset, path: elementPath)
        try MessagePackDecoding.skip(&parser, path: elementPath)
        advanceIndex()
        return impl
    }
}
