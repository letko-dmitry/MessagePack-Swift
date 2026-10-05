import Foundation

/// Decodes `Decodable` values from MessagePack binary data, analogous to
/// `JSONDecoder`.
///
/// Decoding operates directly on the raw bytes without materializing a
/// ``MessagePackValue`` tree: keyed containers scan their entries' byte
/// offsets lazily (using the shared skip logic in the parser) and match keys
/// by comparing UTF-8 bytes in place, and unkeyed containers stream through
/// their elements.
///
/// Special types:
/// - `Date` decodes from the timestamp extension type (-1), or leniently from
///   a numeric value interpreted as seconds since 1970.
/// - `Data` decodes from bin 8/16/32.
/// - ``MessagePackTimestamp`` decodes from the timestamp extension type.
/// - `Decimal` decodes through its own `Codable` conformance (the map of its
///   fields), and with ``decimalDecodingStrategy`` set to
///   ``DecimalDecodingStrategy/stringOrNumber`` also from a string of decimal
///   digits (what ``MessagePackEncoder/DecimalEncodingStrategy/string``
///   writes) or any number.
///
/// The `Decoder` and containers handed to `init(from:)` are valid only while
/// ``decode(_:from:)`` runs: like the pointer in `withUnsafeBytes`, they
/// refer to the input and to state on the call's stack, so a conformance
/// must not store them for later use.
///
/// Integers decode from any integer wire format that fits the requested
/// type; the smallest-format encoding the serializer and encoder use is
/// therefore always round-trippable.
public struct MessagePackDecoder {
    /// How `Decimal` values are read, named like the encoder's
    /// ``MessagePackEncoder/DecimalEncodingStrategy``.
    public enum DecimalDecodingStrategy: Sendable {
        /// Defers to `Decimal`'s own `Codable` conformance, which reads the
        /// map of its fields. The default, and what earlier versions did.
        case deferredToDecimal
        /// Also reads a string of decimal digits (what
        /// ``MessagePackEncoder/DecimalEncodingStrategy/string`` writes, and
        /// other languages' decimal types produce) and any number: integers
        /// convert exactly, floats through their shortest decimal text, so a
        /// float 64 of 0.35 decodes as 0.35.
        case stringOrNumber
    }

    /// Contextual information made available to the `Decodable` types via
    /// `Decoder.userInfo`.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// How `Decimal` values are read. Defaults to
    /// ``DecimalDecodingStrategy/deferredToDecimal``.
    public var decimalDecodingStrategy: DecimalDecodingStrategy = .deferredToDecimal

    public init() {}

    /// Decodes a value of the given type from MessagePack binary data.
    ///
    /// Throws `DecodingError.dataCorrupted` if `data` contains bytes beyond
    /// the first top-level value.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // The mutable decoding state lives on this frame, as the context
        // (and every container it serves) is only valid during the call.
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> T in
            var state = MessagePackDecodingContext.State(
                base: raw.baseAddress,
                count: raw.count,
                userInfo: userInfo,
                decimalDecodingStrategy: decimalDecodingStrategy
            )

            return try withUnsafeMutablePointer(to: &state) { state in
                let context = MessagePackDecodingContext(state: state)
                var parser = context.parser(at: 0)
                let value = try MessagePackDecoding.unwrap(
                    type, parser: &parser, context: context, path: .root)
                guard parser.offset == raw.count else {
                    throw MessagePackDecoding.corrupted(.trailingBytes, .root, offset: parser.offset)
                }
                return value
            }
        }
    }
}

extension MessagePackDecoder: @unchecked Sendable {}

// MARK: - Shared decoding state

/// The state shared by every decoder and container of one `decode` call: the
/// input buffer and user info, plus the bookkeeping that lets a decoded value
/// be passed over without walking its bytes again. The buffer pointer, like
/// the state itself, is only valid for the duration of the top-level `decode`
/// call.
struct MessagePackDecodingContext {
    struct State {
        let base: UnsafeRawPointer?
        let count: Int
        let userInfo: [CodingUserInfoKey: Any]
        let decimalDecodingStrategy: MessagePackDecoder.DecimalDecodingStrategy

        /// Memo of the most recently completed value whose end no keyed
        /// storage tracks: an unkeyed container that decoded its last
        /// element, or a value decoded through a single-value container
        /// (`Optional` and other wrappers). It lets
        /// ``MessagePackDecoding/unwrap(_:parser:context:path:)`` advance past
        /// the value starting at `memoStart` without skipping it a second
        /// time. A stale memo is harmless: byte offsets uniquely identify
        /// values, so a matching `memoStart` always implies the same
        /// `memoEnd`.
        var memoStart = -1
        var memoEnd = -1

        /// The value ``MessagePackDecoding/unwrap(_:parser:context:path:)``
        /// is decoding through its `Decodable` conformance, and the storage
        /// of the map that value opened, if any. Nested decodes save and
        /// restore both, so once `init(from:)` returns they describe the
        /// value itself, however many nested maps it opened, and its end is
        /// found by finishing that map's lazy scan instead of skipping the
        /// whole value.
        var decodingOffset = -1
        var decodingStorage: MessagePackKeyedStorage?

        /// Recycled keyed-container storages. Decoding a homogeneous array
        /// of structs otherwise allocates a fresh storage object plus its
        /// entry array per element; reuse eliminates both, and
        /// `isKnownUniquelyReferenced` keeps a storage alive as long as any
        /// container still references it.
        var storagePool: [MessagePackKeyedStorage] = []
    }

    /// The decoding state, in the frame of
    /// ``MessagePackDecoder/decode(_:from:)``: a single pointer, so copying
    /// the context into every decoder and container costs no reference
    /// counting, and its mutable parts bypass the dynamic exclusivity
    /// enforcement class properties get.
    let state: UnsafeMutablePointer<State>

    var userInfo: [CodingUserInfoKey: Any] { state.pointee.userInfo }

    /// Returns a keyed storage no live container references, or a fresh one.
    /// The pool is bounded: with more than `poolLimit` containers alive at
    /// once (keyed nesting that deep is rare), extra storages are simply not
    /// pooled.
    func borrowKeyedStorage() -> MessagePackKeyedStorage {
        for index in state.pointee.storagePool.indices {
            if isKnownUniquelyReferenced(&state.pointee.storagePool[index]) {
                return state.pointee.storagePool[index]
            }
        }

        let storage = MessagePackKeyedStorage.make()
        let poolLimit = 8
        if state.pointee.storagePool.count < poolLimit {
            state.pointee.storagePool.append(storage)
        }

        return storage
    }

    @inline(__always)
    func parser(at offset: Int) -> MessagePackSerializer.Parser {
        MessagePackSerializer.Parser(base: state.pointee.base, count: state.pointee.count, offset: offset)
    }
}

// MARK: - Primitive failures

/// Failure modes of the raw decode primitives. Carries no coding-path
/// context, so the primitives allocate nothing on the happy path; containers
/// translate a failure into a full `DecodingError` in their `catch`.
enum MessagePackDecodeFailure: Error {
    /// The wire value's format does not match the requested type. The parser
    /// has been rewound to the value's start.
    case wrongType
    /// The wire value matched but its content is unusable (out-of-range
    /// number, malformed timestamp). The payload is the debug description.
    case invalid(String)
    /// The underlying bytes are malformed.
    case corrupted(MessagePackError)
}

// MARK: - Decoding primitives

/// Namespace for the typed decode primitives shared by all containers.
enum MessagePackDecoding {
    typealias Parser = MessagePackSerializer.Parser

    /// Maximum container nesting depth while decoding. Deliberately lower
    /// than the serializer's iterative `maxDepth`: Codable decoding recurses
    /// through user types' `init(from:)`, and concurrency-pool threads have
    /// small (512 KB) stacks, so hostile deeply-nested input must be
    /// rejected well before the stack runs out.
    static let maxDepth = 128

    /// `offset` is where the bytes the error is about start: the value its
    /// coding path names, or the trailing bytes after the top-level value.
    @inline(never)
    static func corrupted(_ error: MessagePackError, _ path: MessagePackCodingPath, offset: Int) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: path.keys,
                debugDescription: "Invalid MessagePack data: \(error)\(at(offset))",
                underlyingError: error
            ))
    }

    /// The byte position in error messages, like `JSONDecoder`'s line and
    /// column, so a failure can be found in the input.
    private static func at(_ offset: Int) -> String {
        " at byte offset \(offset)"
    }

    /// A type-mismatch (or, for a nil wire value, value-not-found) error
    /// describing the format byte actually present. Out of line, like every
    /// error builder here: inlined, their messages were copied into each
    /// decode path. The builders take the coding path as it is stored and
    /// build its array of keys themselves, so that code stays off the
    /// decode paths too.
    @inline(never)
    static func wrongType(_ type: Any.Type, _ parser: Parser, _ path: MessagePackCodingPath) -> DecodingError {
        guard let format = try? parser.peekFormat() else {
            return corrupted(.insufficientData, path, offset: parser.offset)
        }
        if format == 0xc0 {
            return .valueNotFound(
                type,
                DecodingError.Context(
                    codingPath: path.keys,
                    debugDescription: "Cannot decode \(type) -- found nil value instead\(at(parser.offset))"
                ))
        }
        return .typeMismatch(
            type,
            DecodingError.Context(
                codingPath: path.keys,
                debugDescription:
                    "Expected \(type) but found MessagePack format byte 0x\(String(format, radix: 16))\(at(parser.offset))"
            ))
    }

    /// Translates a primitive failure into a `DecodingError` with full
    /// coding-path context. Only reached on failure, so building the path
    /// here keeps the happy path allocation-free.
    @inline(never)
    static func decodingError(
        _ failure: MessagePackDecodeFailure, type: Any.Type, parser: Parser, path: MessagePackCodingPath
    ) -> DecodingError {
        switch failure {
        case .wrongType:
            return wrongType(type, parser, path)
        case .invalid(let message):
            return .dataCorrupted(
                DecodingError.Context(codingPath: path.keys, debugDescription: message + at(parser.offset)))
        case .corrupted(let error):
            return corrupted(error, path, offset: parser.offset)
        }
    }

    @inline(__always)
    static func skip(_ parser: inout Parser, path: MessagePackCodingPath) throws {
        let startOffset = parser.offset
        do throws(MessagePackError) {
            try parser.skipValue()
        } catch {
            throw corrupted(error, path, offset: startOffset)
        }
    }

    /// Out of line: one specialization per integer type, shared by every
    /// container overload (inlined into each of them, it was about 45 KB of
    /// code). The `[Int]` and `[String: Int]` fast paths loop over
    /// ``readIntegerInlined(_:)`` instead.
    @inline(never)
    static func readInteger<T: FixedWidthInteger>(
        _ parser: inout Parser
    ) throws(MessagePackDecodeFailure) -> T {
        try readIntegerInlined(&parser)
    }

    @inline(__always)
    static func readIntegerInlined<T: FixedWidthInteger>(
        _ parser: inout Parser
    ) throws(MessagePackDecodeFailure) -> T {
        let integer: MessagePackRawInteger?
        do throws(MessagePackError) {
            integer = try parser.readRawInteger()
        } catch {
            throw .corrupted(error)
        }

        guard let raw = integer else { throw .wrongType }

        switch raw {
        case .signed(let v):
            guard let value = T(exactly: v) else { throw doesNotFit(v, T.self) }
            return value
        case .unsigned(let v):
            guard let value = T(exactly: v) else { throw doesNotFit(v, T.self) }
            return value
        }
    }

    /// The failure for a wire number outside the requested type's range. Out
    /// of line and non-generic, so the message is built in one place.
    @inline(never)
    static func doesNotFit(_ number: Any, _ type: Any.Type) -> MessagePackDecodeFailure {
        .invalid("Number \(number) does not fit in \(type)")
    }

    @inline(__always)
    static func readBool(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Bool {
        let value: Bool?
        do throws(MessagePackError) {
            value = try parser.readRawBool()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    @inline(__always)
    static func readString(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> String {
        let value: String?
        do throws(MessagePackError) {
            value = try parser.readRawString()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    @inline(__always)
    static func readDouble(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Double {
        let value: Double?
        do throws(MessagePackError) {
            value = try parser.readRawDouble()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    @inline(__always)
    static func readFloat(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Float {
        let value = try readDouble(&parser)
        let narrowed = Float(value)
        // A finite float64 must stay finite as Float; JSONDecoder likewise
        // rejects numbers that do not fit the requested type.
        if narrowed.isInfinite && value.isFinite {
            throw doesNotFit(value, Float.self)
        }
        return narrowed
    }

    @inline(__always)
    static func readBinary(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Data {
        let value: Data?
        do throws(MessagePackError) {
            value = try parser.readRawBinary()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
    }

    static func readTimestamp(
        _ parser: inout Parser
    ) throws(MessagePackDecodeFailure) -> MessagePackTimestamp {
        // The payload is read in place: a timestamp needs no `Data` of its own.
        let ext: (type: Int8, bytes: UnsafeRawBufferPointer)?
        do throws(MessagePackError) {
            ext = try parser.readRawExtBytes()
        } catch {
            throw .corrupted(error)
        }
        guard let ext else { throw .wrongType }
        guard ext.type == MessagePackTimestamp.extType, let timestamp = MessagePackTimestamp(payload: ext.bytes) else {
            throw .invalid(
                "Extension (type \(ext.type), \(ext.bytes.count) bytes) is not a valid MessagePack timestamp"
            )
        }
        return timestamp
    }

    static func readDate(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Date {
        if let format = try? parser.peekFormat(), isExtFormat(format) {
            return try readTimestamp(&parser).date
        }
        // Leniently accept a numeric value as seconds since 1970.
        return Date(timeIntervalSince1970: try readDouble(&parser))
    }

    @inline(__always)
    private static func isExtFormat(_ format: UInt8) -> Bool {
        (0xd4...0xd8).contains(format) || (0xc7...0xc9).contains(format)
    }

    /// Reads one scalar at `offset`, attaching the coding path on failure.
    /// The path closure only runs when an error actually propagates.
    static func decodeScalar<V>(
        _ type: V.Type,
        context: MessagePackDecodingContext,
        offset: Int,
        path: @autoclosure () -> MessagePackCodingPath,
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> V
    ) throws -> V {
        var parser = context.parser(at: offset)

        do throws(MessagePackDecodeFailure) {
            return try read(&parser)
        } catch {
            // Errors point at the value's start, as on the other routes.
            parser.offset = offset
            throw decodingError(error, type: type, parser: parser, path: path())
        }
    }

    /// Reads one scalar with `read`, rewinding the parser and attaching the
    /// coding path on failure. The path closure only runs when an error
    /// actually propagates, keeping the happy path allocation-free.
    @inline(__always)
    static func readScalarOrRewind<V>(
        _ type: V.Type,
        _ parser: inout Parser,
        _ startOffset: Int,
        _ path: () -> MessagePackCodingPath,
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> V
    ) throws -> V {
        do throws(MessagePackDecodeFailure) {
            return try read(&parser)
        } catch {
            parser.offset = startOffset
            throw decodingError(error, type: type, parser: parser, path: path())
        }
    }

    /// Decodes a value of arbitrary `Decodable` type at the parser's current
    /// position, advancing the parser past it. Types MessagePack represents
    /// natively decode directly, bypassing the `Decodable` container
    /// machinery (and its per-value decoder, existential, and coding-path
    /// allocations).
    static func unwrap<T: Decodable>(
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        path: @autoclosure () -> MessagePackCodingPath
    ) throws -> T {
        // On failure the parser is rewound to the value start, so callers
        // that catch and retry (or an unkeyed container's cursor) never
        // desync from the element boundary.
        let startOffset = parser.offset
        if T.self == Int.self { return try readScalarOrRewind(Int.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == String.self { return try readScalarOrRewind(String.self, &parser, startOffset, path, readString) as! T }
        if T.self == Bool.self { return try readScalarOrRewind(Bool.self, &parser, startOffset, path, readBool) as! T }
        if T.self == Double.self { return try readScalarOrRewind(Double.self, &parser, startOffset, path, readDouble) as! T }
        if T.self == Float.self { return try readScalarOrRewind(Float.self, &parser, startOffset, path, readFloat) as! T }
        if T.self == Int64.self { return try readScalarOrRewind(Int64.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == UInt64.self { return try readScalarOrRewind(UInt64.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == Int32.self { return try readScalarOrRewind(Int32.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == UInt32.self { return try readScalarOrRewind(UInt32.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == Int16.self { return try readScalarOrRewind(Int16.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == UInt16.self { return try readScalarOrRewind(UInt16.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == Int8.self { return try readScalarOrRewind(Int8.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == UInt8.self { return try readScalarOrRewind(UInt8.self, &parser, startOffset, path, readInteger) as! T }
        if T.self == UInt.self { return try readScalarOrRewind(UInt.self, &parser, startOffset, path, readInteger) as! T }
        let foundation = MessagePackFoundationTypes.shared
        if ObjectIdentifier(T.self) == foundation.date {
            return try readScalarOrRewind(Date.self, &parser, startOffset, path, readDate) as! T
        }
        if ObjectIdentifier(T.self) == foundation.data {
            return try readScalarOrRewind(Data.self, &parser, startOffset, path, readBinary) as! T
        }
        if T.self == MessagePackTimestamp.self {
            return try readScalarOrRewind(MessagePackTimestamp.self, &parser, startOffset, path, readTimestamp) as! T
        }
        if let collectionType = MessagePackCollectionType(ObjectIdentifier(T.self)) {
            return try decodeCollection(collectionType, type, parser: &parser, context: context, path: path)
        }
        if ObjectIdentifier(T.self) == foundation.decimal, context.state.pointee.decimalDecodingStrategy == .stringOrNumber {
            return try decodeDecimal(parser: &parser, context: context, path: path) as! T
        }

        return try decodeWithContainers(type, parser: &parser, context: context, path: path())
    }

    /// Decodes a value through its `Decodable` conformance and the container
    /// machinery, advancing the parser past it.
    static func decodeWithContainers<T: Decodable>(
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        path: MessagePackCodingPath
    ) throws -> T {
        let startOffset = parser.offset
        let impl = MessagePackDecoderImpl(context: context, offset: startOffset, path: path)

        let state = context.state
        let outerOffset = state.pointee.decodingOffset
        let outerStorage = state.pointee.decodingStorage
        state.pointee.decodingOffset = startOffset
        state.pointee.decodingStorage = nil
        defer {
            state.pointee.decodingOffset = outerOffset
            state.pointee.decodingStorage = outerStorage
        }

        let value = try type.init(from: impl)

        if let storage = state.pointee.decodingStorage {
            do throws(MessagePackError) {
                parser.offset = try storage.end(context)
            } catch {
                throw corrupted(error, path, offset: startOffset)
            }
        } else if state.pointee.memoStart == startOffset {
            parser.offset = state.pointee.memoEnd
        } else {
            try skip(&parser, path: path)
        }

        return value
    }
}

// MARK: - Decoder

/// The `Decoder` handed to `Decodable.init(from:)`. A three-word struct so
/// passing it as an existential does not allocate. Also serves as its own
/// single-value container.
struct MessagePackDecoderImpl: Decoder, SingleValueDecodingContainer {
    let context: MessagePackDecodingContext
    /// The byte offset of the value this decoder decodes.
    let offset: Int
    let path: MessagePackCodingPath

    var codingPath: [CodingKey] { path.keys }

    var userInfo: [CodingUserInfoKey: Any] { context.userInfo }

    /// Guards against unbounded recursion through recursive `Decodable`
    /// types fed deeply nested hostile input. Every nesting level appends to
    /// the coding path, so its depth tracks the container depth (mirroring
    /// the serializer's `maxDepth` protection).
    private func checkDepth() throws {
        guard path.depth < MessagePackDecoding.maxDepth else {
            throw MessagePackDecoding.corrupted(.depthLimitExceeded, path, offset: offset)
        }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try checkDepth()
        var parser = context.parser(at: offset)
        let entryCount: Int?
        do throws(MessagePackError) {
            entryCount = try parser.readRawMapHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, path, offset: offset)
        }
        guard let entryCount else {
            throw MessagePackDecoding.wrongType([String: Any].self, parser, path)
        }
        // Each entry needs at least two bytes; reject hostile counts before
        // reserving storage.
        guard entryCount <= (parser.count - parser.offset) / 2 else {
            throw MessagePackDecoding.corrupted(.insufficientData, path, offset: offset)
        }
        let storage = context.borrowKeyedStorage()
        storage.reset(firstKeyOffset: parser.offset, entryCount: entryCount)
        if context.state.pointee.decodingOffset == offset {
            context.state.pointee.decodingStorage = storage
        }

        return KeyedDecodingContainer(
            MessagePackKeyedDecodingContainer<Key>(
                context: context, storage: storage, offset: offset, path: path))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        try checkDepth()
        var parser = context.parser(at: offset)
        let elementCount: Int?
        do throws(MessagePackError) {
            elementCount = try parser.readRawArrayHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, path, offset: offset)
        }
        guard let elementCount else {
            throw MessagePackDecoding.wrongType([Any].self, parser, path)
        }
        guard elementCount <= parser.count - parser.offset else {
            throw MessagePackDecoding.corrupted(.insufficientData, path, offset: offset)
        }
        return MessagePackUnkeyedDecodingContainer(
            context: context, path: path, elementCount: elementCount,
            startOffset: offset, parser: parser)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }

    // MARK: SingleValueDecodingContainer

    func decodeNil() -> Bool {
        let parser = context.parser(at: offset)
        return ((try? parser.peekFormat()) ?? 0xc1) == 0xc0
    }

    private func decodeScalar<T>(
        _ type: T.Type,
        _ read: (inout MessagePackDecoding.Parser) throws(MessagePackDecodeFailure) -> T
    ) throws -> T {
        try MessagePackDecoding.decodeScalar(type, context: context, offset: offset, path: path, read)
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try decodeScalar(type, MessagePackDecoding.readBool)
    }

    func decode(_ type: String.Type) throws -> String {
        try decodeScalar(type, MessagePackDecoding.readString)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decodeScalar(type, MessagePackDecoding.readDouble)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try decodeScalar(type, MessagePackDecoding.readFloat)
    }

    func decode(_ type: Int.Type) throws -> Int { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt.Type) throws -> UInt { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeScalar(type, MessagePackDecoding.readInteger) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeScalar(type, MessagePackDecoding.readInteger) }

    @available(watchOS 11.0, *)
    func decode(_ type: Int128.Type) throws -> Int128 { try decodeScalar(type, MessagePackDecoding.readInteger) }

    @available(watchOS 11.0, *)
    func decode(_ type: UInt128.Type) throws -> UInt128 { try decodeScalar(type, MessagePackDecoding.readInteger) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        var parser = context.parser(at: offset)
        let value = try MessagePackDecoding.unwrap(
            type, parser: &parser, context: context, path: path)

        // This decoder's own value ends where the one it wraps does. The
        // `unwrap` that created this decoder (for `Optional` and other
        // single-value wrappers) would otherwise skip the value again.
        context.state.pointee.memoStart = offset
        context.state.pointee.memoEnd = parser.offset

        return value
    }
}

