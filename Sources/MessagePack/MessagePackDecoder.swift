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
/// - `Date` decodes from the formats ``dateDecodingStrategy`` accepts: by
///   default the timestamp extension type (-1) and, as in earlier versions, a
///   number of seconds since 1970.
/// - `Data` decodes from bin 8/16/32.
/// - ``MessagePackTimestamp`` decodes from the timestamp extension type.
/// - `Decimal` decodes from the formats ``decimalDecodingStrategy`` accepts:
///   by default the map of fields its own `Codable` conformance writes, and
///   optionally a string of decimal digits (what
///   ``MessagePackEncoder/DecimalEncodingStrategy/convertToString`` writes),
///   an integer, or a float.
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
    /// How `Decimal` values, which MessagePack has no type for, are read,
    /// named like `JSONDecoder`'s strategies. As an option set, it accepts
    /// several formats at once, such as the map and a string.
    public struct DecimalDecodingStrategy: OptionSet, Sendable {
        public let rawValue: UInt8

        // The initializer and the options are emitted into clients, which
        // then use constants instead of calling the globals' accessors.

        @inline(always)
        @export(implementation)
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Defers to `Decimal`'s own `Codable` conformance, which reads the
        /// map of fields it writes
        /// (``MessagePackEncoder/DecimalEncodingStrategy/deferredToDecimal``).
        /// The default, and all that earlier versions read.
        @inline(always)
        @export(implementation)
        public static var deferredToDecimal: Self { Self(rawValue: 1 << 0) }
        /// Converts from a string of decimal digits: what
        /// ``MessagePackEncoder/DecimalEncodingStrategy/convertToString``
        /// writes, and other languages' decimal types produce.
        @inline(always)
        @export(implementation)
        public static var convertFromString: Self { Self(rawValue: 1 << 1) }
        /// Converts from an integer, exactly.
        @inline(always)
        @export(implementation)
        public static var convertFromInteger: Self { Self(rawValue: 1 << 2) }
        /// Converts from a float through its shortest decimal text, so a
        /// float 64 of 0.35 reads as 0.35.
        @inline(always)
        @export(implementation)
        public static var convertFromFloat: Self { Self(rawValue: 1 << 3) }
    }

    /// How `Date` values are read, named like `JSONDecoder`'s strategies. As
    /// an option set, it accepts several formats at once: by default both,
    /// as earlier versions did.
    public struct DateDecodingStrategy: OptionSet, Sendable {
        public let rawValue: UInt8

        // Emitted into clients, like the `Decimal` options.

        @inline(always)
        @export(implementation)
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Reads the spec's timestamp extension type (-1), which
        /// ``MessagePackEncoder`` writes.
        @inline(always)
        @export(implementation)
        public static var timestamp: Self { Self(rawValue: 1 << 0) }
        /// Converts from a number, integer or float, of seconds since
        /// 1970-01-01T00:00:00 UTC. A convention rather than a MessagePack
        /// type: without it, only timestamps are read, as on the
        /// `@MessagePackSerializable` route.
        @inline(always)
        @export(implementation)
        public static var convertFromSecondsSince1970: Self { Self(rawValue: 1 << 1) }
    }

    /// Contextual information made available to the `Decodable` types via
    /// `Decoder.userInfo`.
    public var userInfo = [CodingUserInfoKey: Any]()

    /// How `Decimal` values are read; a value in a format the strategy does
    /// not accept is a type mismatch.
    public var decimalDecodingStrategy: DecimalDecodingStrategy

    /// How `Date` values are read; a value in a format the strategy does not
    /// accept is a type mismatch.
    public var dateDecodingStrategy: DateDecodingStrategy

    public init(
        decimalDecodingStrategy: DecimalDecodingStrategy = .deferredToDecimal,
        dateDecodingStrategy: DateDecodingStrategy = [.timestamp, .convertFromSecondsSince1970]
    ) {
        self.decimalDecodingStrategy = decimalDecodingStrategy
        self.dateDecodingStrategy = dateDecodingStrategy
    }

    /// Decodes a value of the given type from MessagePack binary data.
    ///
    /// Throws `DecodingError.dataCorrupted` if `data` contains bytes beyond
    /// the first top-level value.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try data.withUnsafeBytes { try decode(type, from: $0) }
    }

    /// Decodes a value of the given type from MessagePack bytes in any
    /// contiguous memory, read in place rather than copied into a `Data`
    /// first: `data.bytes` of a `Data`, `array.span.bytes` of an `[UInt8]`
    /// from OS 26, or `slice.span.bytes` of an `ArraySlice<UInt8>` on any
    /// OS, such as an array's `array[...]` kept in a variable.
    ///
    /// Throws `DecodingError.dataCorrupted` if `bytes` contains bytes beyond
    /// the first top-level value.
    public func decode<T: Decodable>(_ type: T.Type, from bytes: RawSpan) throws -> T {
        try bytes.withUnsafeBytes { try decode(type, from: $0) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from raw: UnsafeRawBufferPointer) throws -> T {
        // The mutable decoding state lives on this frame, as the context
        // (and every container it serves) is only valid during the call, and
        // so does the memory of its coding-path stack until it outgrows it.
        try withUnsafeTemporaryAllocation(of: MessagePackCodingPath.Node.self, capacity: 16) { pathNodes in
            var state = MessagePackDecodingContext.State(
                base: raw.baseAddress,
                count: raw.count,
                userInfo: userInfo,
                decimalDecodingStrategy: decimalDecodingStrategy,
                dateDecodingStrategy: dateDecodingStrategy,
                pathNodes: MessagePackStack(memory: pathNodes)
            )
            defer { state.pathNodes.deallocate() }

            return try withUnsafeMutablePointer(to: &state) { state in
                let context = MessagePackDecodingContext(state: state)
                var parser = context.parser(at: 0)
                let value = try MessagePackDecoding.decodeValue(
                    type, parser: &parser, context: context, path: .root)
                guard parser.offset == raw.count else {
                    throw MessagePackDecoding.corrupted(.trailingBytes, context, .root, offset: parser.offset)
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
        let dateDecodingStrategy: MessagePackDecoder.DateDecodingStrategy

        /// Memo of the most recently completed value whose end no keyed
        /// storage tracks: an unkeyed container that decoded its last
        /// element, or a value decoded through a single-value container
        /// (`Optional` and other wrappers). It lets
        /// ``MessagePackDecoding/decodeValue(_:parser:context:path:)``
        /// advance past the value starting at `memoStart` without skipping
        /// it a second time. A stale memo is harmless: byte offsets uniquely
        /// identify values, so a matching `memoStart` always implies the
        /// same `memoEnd`.
        var memoStart = -1
        var memoEnd = -1

        /// The value ``MessagePackDecoding/decodeValue(_:parser:context:path:)``
        /// is decoding through its `Decodable` conformance, and the storage
        /// of the map that value opened, if any. Nested decodes save and
        /// restore both, so once `init(from:)` returns they describe the
        /// value itself, however many nested maps it opened, and its end is
        /// found by finishing that map's lazy scan instead of skipping the
        /// whole value.
        var decodingOffset = -1
        var decodingStorage: MessagePackKeyedStorage?

        /// The type of the value at `decodingOffset`, saved and restored with
        /// it: a dictionary whose own conformance reads keys and values in
        /// turn reads a map's entries as them; see
        /// ``MessagePackDirectDecoder/unkeyedContainer()``.
        var decodingType: Any.Type?

        /// Recycled keyed-container storages. Decoding a homogeneous array
        /// of structs otherwise allocates a fresh storage object plus its
        /// entry array per element; reuse eliminates both, and
        /// `isKnownUniquelyReferenced` keeps a storage alive as long as any
        /// container still references it.
        var storagePool: [MessagePackKeyedStorage] = []

        /// The nodes of the coding paths in use; see ``MessagePackCodingPath``.
        var pathNodes: MessagePackStack<MessagePackCodingPath.Node>

        /// The types ``MessagePackDecoding/decodeArray(_:parser:context:path:)``
        /// checked; see ``arrayConformance(of:)``.
        var arrayTypes: (ArrayType?, ArrayType?, ArrayType?, ArrayType?)
        var arrayTypeCount = 0
        typealias ArrayType = (type: ObjectIdentifier, conformance: (any MessagePackDecodableArray.Type)?)
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
    func reusableKeyedStorage() -> MessagePackKeyedStorage {
        for index in state.pointee.storagePool.indices {
            if isKnownUniquelyReferenced(&state.pointee.storagePool[index]) {
                return state.pointee.storagePool[index]
            }
        }

        let storage = MessagePackKeyedStorage.make(context: self)
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
    ///
    /// Returns `any Error`, already boxed, like every error builder here.
    /// Returned as the resilient `DecodingError`, it was boxed at each
    /// `throw` site, which called the type's metadata accessor and
    /// `swift_allocError`.
    @inline(never)
    static func corrupted(
        _ error: consuming MessagePackError, _ context: MessagePackDecodingContext,
        _ path: @autoclosure () -> MessagePackCodingPath, offset: Int
    ) -> any Error {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: context.codingPath(popping: path),
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
    /// decode path. The builders take the coding path as it is stored, or
    /// the closure that makes it, and build its array of keys themselves,
    /// so that code stays off the decode paths too.
    @inline(never)
    static func wrongType(
        _ type: Any.Type, _ parser: Parser, _ context: MessagePackDecodingContext,
        _ path: @autoclosure () -> MessagePackCodingPath
    ) -> any Error {
        guard let format = try? parser.peekFormat() else {
            return corrupted(.insufficientData, context, path(), offset: parser.offset)
        }
        if format == 0xc0 {
            return DecodingError.valueNotFound(
                type,
                DecodingError.Context(
                    codingPath: context.codingPath(popping: path),
                    debugDescription: "Cannot decode \(type) -- found nil value instead\(at(parser.offset))"
                ))
        }
        return DecodingError.typeMismatch(
            type,
            DecodingError.Context(
                codingPath: context.codingPath(popping: path),
                debugDescription:
                    "Expected \(type) but found MessagePack format byte 0x\(String(format, radix: 16))\(at(parser.offset))"
            ))
    }

    /// Translates a primitive failure into a `DecodingError` with full
    /// coding-path context. Only reached on failure, so building the path
    /// here keeps the happy path allocation-free.
    @inline(never)
    static func decodingError(
        _ failure: consuming MessagePackDecodeFailure, type: Any.Type, parser: Parser,
        context: MessagePackDecodingContext, path: @autoclosure () -> MessagePackCodingPath
    ) -> any Error {
        switch failure {
        case .wrongType:
            return wrongType(type, parser, context, path())
        case .invalid(let message):
            return DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: context.codingPath(popping: path), debugDescription: message + at(parser.offset)))
        case .corrupted(let error):
            return corrupted(error, context, path(), offset: parser.offset)
        }
    }

    @inline(__always)
    static func skip(_ parser: inout Parser, context: MessagePackDecodingContext, path: MessagePackCodingPath) throws {
        let startOffset = parser.offset
        do throws(MessagePackError) {
            try parser.skipValue()
        } catch {
            throw corrupted(error, context, path, offset: startOffset)
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
            guard let value = T(exactly: v) else { throw outOfRange(v, T.self) }
            return value
        case .unsigned(let v):
            guard let value = T(exactly: v) else { throw outOfRange(v, T.self) }
            return value
        }
    }

    /// The failure for a wire number outside the requested type's range. Out
    /// of line and non-generic, so the message is built in one place.
    @inline(never)
    static func outOfRange(_ number: Any, _ type: Any.Type) -> MessagePackDecodeFailure {
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
        let value: Double?
        do throws(MessagePackError) {
            value = try parser.readRawFloat()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { return try readIntegerAsFloat(&parser) }

        let narrowed = Float(value)
        // A finite float64 must stay finite as Float; JSONDecoder likewise
        // rejects numbers that do not fit the requested type.
        if narrowed.isInfinite && value.isFinite {
            throw outOfRange(value, Float.self)
        }
        return narrowed
    }

    /// Leniently reads any integer as the nearest `Float`. Kept apart from
    /// the float path, unlike in ``MessagePackReader/readFloat()``: measured,
    /// each shape is the faster one on its route.
    @inline(__always)
    private static func readIntegerAsFloat(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Float {
        let value: Float?
        do throws(MessagePackError) {
            value = try parser.readRawIntegerAsFloat()
        } catch {
            throw .corrupted(error)
        }
        guard let value else { throw .wrongType }
        return value
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

    /// Reads a `Date` from a format `strategy` accepts; anything else is the
    /// wrong type. Inlined into `decodeValue` like the one-format reader
    /// before it: called out of line, every `Date` paid about 25 more
    /// instructions for the call.
    @inline(__always)
    static func readDate(
        _ parser: inout Parser, strategy: MessagePackDecoder.DateDecodingStrategy
    ) throws(MessagePackDecodeFailure) -> Date {
        if let format = try? parser.peekFormat(), isExtFormat(format) {
            guard strategy.contains(.timestamp) else { throw .wrongType }
            return try readTimestamp(&parser).date
        }
        guard strategy.contains(.convertFromSecondsSince1970) else { throw .wrongType }
        return Date(timeIntervalSince1970: try readDouble(&parser))
    }

    @inline(__always)
    private static func isExtFormat(_ format: UInt8) -> Bool {
        (0xd4...0xd8).contains(format) || (0xc7...0xc9).contains(format)
    }

    @inline(__always)
    private static func isArrayFormat(_ format: UInt8) -> Bool {
        (0x90...0x9f).contains(format) || format == 0xdc || format == 0xdd
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
            throw decodingError(error, type: type, parser: parser, context: context, path: path())
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
        _ context: MessagePackDecodingContext,
        _ path: () -> MessagePackCodingPath,
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> V
    ) throws -> V {
        do throws(MessagePackDecodeFailure) {
            return try read(&parser)
        } catch {
            parser.offset = startOffset
            throw decodingError(error, type: type, parser: parser, context: context, path: path())
        }
    }

    /// Decodes a value of arbitrary `Decodable` type at the parser's current
    /// position, advancing the parser past it. Types MessagePack represents
    /// natively decode directly, bypassing the `Decodable` container
    /// machinery.
    static func decodeValue<T: Decodable>(
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        path: @autoclosure () -> MessagePackCodingPath
    ) throws -> T {
        // On failure the parser is rewound to the value start, so callers
        // that catch and retry (or an unkeyed container's cursor) never
        // desync from the element boundary.
        let startOffset = parser.offset
        if T.self == Int.self { return try readScalarOrRewind(Int.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == String.self { return try readScalarOrRewind(String.self, &parser, startOffset, context, path, readString) as! T }
        if T.self == Bool.self { return try readScalarOrRewind(Bool.self, &parser, startOffset, context, path, readBool) as! T }
        if T.self == Double.self { return try readScalarOrRewind(Double.self, &parser, startOffset, context, path, readDouble) as! T }
        if T.self == Float.self { return try readScalarOrRewind(Float.self, &parser, startOffset, context, path, readFloat) as! T }
        if T.self == Int64.self { return try readScalarOrRewind(Int64.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == UInt64.self { return try readScalarOrRewind(UInt64.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == Int32.self { return try readScalarOrRewind(Int32.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == UInt32.self { return try readScalarOrRewind(UInt32.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == Int16.self { return try readScalarOrRewind(Int16.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == UInt16.self { return try readScalarOrRewind(UInt16.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == Int8.self { return try readScalarOrRewind(Int8.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == UInt8.self { return try readScalarOrRewind(UInt8.self, &parser, startOffset, context, path, readInteger) as! T }
        if T.self == UInt.self { return try readScalarOrRewind(UInt.self, &parser, startOffset, context, path, readInteger) as! T }
        let foundation = MessagePackFoundationTypes.shared
        if ObjectIdentifier(T.self) == foundation.date {
            let strategy = context.state.pointee.dateDecodingStrategy
            return try readScalarOrRewind(Date.self, &parser, startOffset, context, path) {
                (parser: inout Parser) throws(MessagePackDecodeFailure) -> Date in
                try readDate(&parser, strategy: strategy)
            } as! T
        }
        if ObjectIdentifier(T.self) == foundation.data {
            return try readScalarOrRewind(Data.self, &parser, startOffset, context, path, readBinary) as! T
        }
        if T.self == MessagePackTimestamp.self {
            return try readScalarOrRewind(MessagePackTimestamp.self, &parser, startOffset, context, path, readTimestamp) as! T
        }
        if let collectionType = MessagePackCollectionType(ObjectIdentifier(T.self)) {
            return try decodeCollection(collectionType, type, parser: &parser, context: context, path: path)
        }
        // The default strategy, `.deferredToDecimal` alone, is what
        // `Decimal`'s own conformance reads below.
        if ObjectIdentifier(T.self) == foundation.decimal, context.state.pointee.decimalDecodingStrategy != .deferredToDecimal {
            return try decodeDecimal(parser: &parser, context: context, path: path) as! T
        }
        if let format = try? parser.peekFormat(), isArrayFormat(format) {
            return try decodeArray(type, parser: &parser, context: context, path: path)
        }

        return try decodeWithContainers(type, parser: &parser, context: context, path: path)
    }

    /// Decodes a value through its `Decodable` conformance and the container
    /// machinery, advancing the parser past it.
    ///
    /// Pops the value's coding-path node, which `path` pushes, and those of
    /// the containers its `init(from:)` requested, once the value is decoded.
    static func decodeWithContainers<T: Decodable>(
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        path: () -> MessagePackCodingPath
    ) throws -> T {
        let state = context.state
        let pathNodeCount = state.pointee.pathNodes.count
        defer { state.pointee.pathNodes.removeAll(from: pathNodeCount) }

        let path = path()
        let startOffset = parser.offset
        let decoder = MessagePackDirectDecoder(context: context, offset: startOffset, path: path)

        let outerOffset = state.pointee.decodingOffset
        let outerType = state.pointee.decodingType
        let outerStorage = state.pointee.decodingStorage
        state.pointee.decodingOffset = startOffset
        state.pointee.decodingType = type
        state.pointee.decodingStorage = nil
        defer {
            state.pointee.decodingOffset = outerOffset
            state.pointee.decodingType = outerType
            state.pointee.decodingStorage = outerStorage
        }

        let value = try type.init(from: decoder)

        if let storage = state.pointee.decodingStorage {
            do throws(MessagePackError) {
                parser.offset = try storage.mapEnd()
            } catch {
                throw corrupted(error, context, path, offset: startOffset)
            }
        } else if state.pointee.memoStart == startOffset {
            parser.offset = state.pointee.memoEnd
        } else {
            try skip(&parser, context: context, path: path)
        }

        return value
    }

    /// Whether `type` is a `Dictionary`, whose own conformance asks for an
    /// unkeyed container only for a key type it decodes from keys and values
    /// in turn. Out of line: only a request for an unkeyed container that
    /// the input cannot serve checks.
    @inline(never)
    static func isDictionary(_ type: Any.Type) -> Bool {
        messagePackIsOneReferenceWide(type) && type is any MessagePackDecodableDictionary.Type
    }

    /// Guards against unbounded recursion through recursive `Decodable`
    /// types fed deeply nested hostile input. Every nesting level appends to
    /// the coding path, so its depth tracks the container depth (mirroring
    /// the serializer's `maxDepth` protection).
    static func checkDepth(_ context: MessagePackDecodingContext, _ path: MessagePackCodingPath, offset: Int) throws {
        guard context.depth(path) < maxDepth else {
            throw corrupted(.depthLimitExceeded, context, path, offset: offset)
        }
    }
}

// MARK: - Decoder

/// The `Decoder` handed to `Decodable.init(from:)`. Direct, unlike
/// ``MessagePackNilDecoder``: it reads a value present in the input, in place.
/// Also serves as its own single-value container.
struct MessagePackDirectDecoder: Decoder, SingleValueDecodingContainer {
    let context: MessagePackDecodingContext
    /// The byte offset of the value this decoder decodes.
    let offset: Int
    let path: MessagePackCodingPath

    var codingPath: [CodingKey] { context.codingPath(path) }

    var userInfo: [CodingUserInfoKey: Any] { context.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try MessagePackDecoding.checkDepth(context, path, offset: offset)
        var parser = context.parser(at: offset)
        guard let entryCount = try readMapHeader(&parser) else {
            throw MessagePackDecoding.wrongType([String: Any].self, parser, context, path)
        }
        let storage = context.reusableKeyedStorage()
        storage.reset(offset: offset, path: path, firstKeyOffset: parser.offset, entryCount: entryCount)
        if context.state.pointee.decodingOffset == offset {
            context.state.pointee.decodingStorage = storage
        }

        return KeyedDecodingContainer(MessagePackKeyedDecodingContainer<Key>(storage: storage))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        try MessagePackDecoding.checkDepth(context, path, offset: offset)
        var parser = context.parser(at: offset)
        let elementCount: Int?
        do throws(MessagePackError) {
            elementCount = try parser.readRawArrayHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, context, path, offset: offset)
        }
        guard let elementCount else {
            // A dictionary that its own conformance decodes from keys and
            // values in turn, asking for them on a map, as `.convertToMap`
            // and the macro route write it: the map's entries are those.
            if context.state.pointee.decodingOffset == offset,
                let type = context.state.pointee.decodingType,
                MessagePackDecoding.isDictionary(type)
            {
                return try mapEntriesAsPairs()
            }
            throw MessagePackDecoding.wrongType([Any].self, parser, context, path)
        }
        guard elementCount <= parser.count - parser.offset else {
            throw MessagePackDecoding.corrupted(.insufficientData, context, path, offset: offset)
        }
        return MessagePackUnkeyedDecodingContainer(
            context: context, path: path, elementCount: elementCount,
            startOffset: offset, parser: parser)
    }

    private func mapEntriesAsPairs() throws -> UnkeyedDecodingContainer {
        var parser = context.parser(at: offset)
        guard let entryCount = try readMapHeader(&parser) else {
            throw MessagePackDecoding.wrongType([Any].self, parser, context, path)
        }
        return MessagePackUnkeyedDecodingContainer(
            context: context, path: path, elementCount: entryCount &* 2,
            startOffset: offset, parser: parser)
    }

    /// The entry count of the map at the parser, or nil if the value there
    /// is not a map.
    @inline(__always)
    private func readMapHeader(_ parser: inout MessagePackDecoding.Parser) throws -> Int? {
        let entryCount: Int?
        do throws(MessagePackError) {
            entryCount = try parser.readRawMapHeader()
        } catch {
            throw MessagePackDecoding.corrupted(error, context, path, offset: offset)
        }
        guard let entryCount else { return nil }
        // Each entry needs at least two bytes; reject hostile counts before
        // reserving storage.
        guard entryCount <= (parser.count - parser.offset) / 2 else {
            throw MessagePackDecoding.corrupted(.insufficientData, context, path, offset: offset)
        }
        return entryCount
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
        let value = try MessagePackDecoding.decodeValue(
            type, parser: &parser, context: context, path: path)

        // This decoder's own value ends where the one it wraps does. The
        // `decodeValue` that created this decoder (for `Optional` and other
        // single-value wrappers) would otherwise skip the value again.
        context.state.pointee.memoStart = offset
        context.state.pointee.memoEnd = parser.offset

        return value
    }
}

