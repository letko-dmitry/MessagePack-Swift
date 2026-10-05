// MARK: - Collection fast paths

extension MessagePackDecoding {
    /// Decodes a value of a fast-path collection type. Out of line, so the
    /// casts to `T` keep their stack temporaries out of `unwrap`, which every
    /// decoded value passes through.
    @inline(never)
    static func decodeCollection<T: Decodable>(
        _ collectionType: MessagePackCollectionType,
        _ type: T.Type,
        parser: inout Parser,
        context: MessagePackDecodingContext,
        path: () -> MessagePackCodingPath
    ) throws -> T {
        // Only the `[Int]` loop inlines the integer read. The other integer
        // loops call the shared out-of-line read, which measured faster for
        // the narrower types; `[Int64]` and `[UInt64]` would inline code
        // identical to `[Int]` and `[UInt]`, which the optimizer then merges
        // into one function, and that measured 7% slower for `[Int]`.
        switch collectionType {
        case .intArray:
            return try primitiveArray(&parser, path, readIntegerInlined) as [Int] as! T
        case .stringArray:
            return try primitiveArray(&parser, path, readString) as [String] as! T
        case .doubleArray:
            return try primitiveArray(&parser, path, readDouble) as [Double] as! T
        case .boolArray:
            return try primitiveArray(&parser, path, readBool) as [Bool] as! T
        case .floatArray:
            return try primitiveArray(&parser, path, readFloat) as [Float] as! T
        case .int64Array:
            return try primitiveArray(&parser, path, readInteger) as [Int64] as! T
        case .uInt64Array:
            return try primitiveArray(&parser, path, readInteger) as [UInt64] as! T
        case .int32Array:
            return try primitiveArray(&parser, path, readInteger) as [Int32] as! T
        case .uInt32Array:
            return try primitiveArray(&parser, path, readInteger) as [UInt32] as! T
        case .int16Array:
            return try primitiveArray(&parser, path, readInteger) as [Int16] as! T
        case .uInt16Array:
            return try primitiveArray(&parser, path, readInteger) as [UInt16] as! T
        case .int8Array:
            return try primitiveArray(&parser, path, readInteger) as [Int8] as! T
        case .uInt8Array:
            return try primitiveArray(&parser, path, readInteger) as [UInt8] as! T
        case .uIntArray:
            return try primitiveArray(&parser, path, readInteger) as [UInt] as! T
        case .intDictionary:
            if let dictionary = try primitiveDictionary(&parser, path, readIntegerInlined) as [String: Int]? {
                return dictionary as! T
            }
        case .stringDictionary:
            if let dictionary = try primitiveDictionary(&parser, path, readString) as [String: String]? {
                return dictionary as! T
            }
        case .doubleDictionary:
            if let dictionary = try primitiveDictionary(&parser, path, readDouble) as [String: Double]? {
                return dictionary as! T
            }
        case .boolDictionary:
            if let dictionary = try primitiveDictionary(&parser, path, readBool) as [String: Bool]? {
                return dictionary as! T
            }
        }

        // A map with a non-string key.
        return try decodeWithContainers(type, parser: &parser, context: context, path: path())
    }

    /// Decodes an array of a natively represented element type with a tight
    /// loop over the raw bytes, bypassing the unkeyed-container machinery.
    /// Error behavior matches the machinery: element failures are reported at
    /// the element's index in the coding path.
    static func primitiveArray<E>(
        _ parser: inout Parser,
        _ path: () -> MessagePackCodingPath,
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> E
    ) throws -> [E] {
        let startOffset = parser.offset
        let headerCount: Int?
        do throws(MessagePackError) {
            headerCount = try parser.readRawArrayHeader()
        } catch {
            throw corrupted(error, path(), offset: startOffset)
        }
        guard let elementCount = headerCount else {
            throw wrongType([E].self, parser, path())
        }
        // Each element takes at least one byte; reject hostile counts before
        // reserving storage.
        guard elementCount <= parser.count - parser.offset else {
            throw corrupted(.insufficientData, path(), offset: startOffset)
        }
        var result: [E] = []
        result.reserveCapacity(Swift.min(elementCount, messagePackMaxPreallocation))
        for index in 0..<elementCount {
            let elementStart = parser.offset
            do throws(MessagePackDecodeFailure) {
                result.append(try read(&parser))
            } catch {
                parser.offset = elementStart
                throw decodingError(
                    error, type: E.self, parser: parser,
                    path: path().appending(index: index))
            }
        }
        return result
    }

    /// Decodes a string-keyed dictionary of a natively represented value
    /// type with a tight loop over the raw bytes, like ``primitiveArray``.
    /// Duplicate keys keep the first value, like `Dictionary.init(from:)`.
    ///
    /// Returns nil with the parser rewound when a key is not a string:
    /// `Dictionary.init(from:)` turns integer keys into their decimal
    /// strings, so such maps take the container machinery instead.
    static func primitiveDictionary<V>(
        _ parser: inout Parser,
        _ path: () -> MessagePackCodingPath,
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> V
    ) throws -> [String: V]? {
        let startOffset = parser.offset
        let headerCount: Int?
        do throws(MessagePackError) {
            headerCount = try parser.readRawMapHeader()
        } catch {
            throw corrupted(error, path(), offset: startOffset)
        }
        guard let entryCount = headerCount else {
            throw wrongType([String: V].self, parser, path())
        }
        // Each entry takes at least two bytes; reject hostile counts before
        // reserving storage.
        guard entryCount <= (parser.count &- parser.offset) / 2 else {
            throw corrupted(.insufficientData, path(), offset: startOffset)
        }

        var result = [String: V](minimumCapacity: Swift.min(entryCount, messagePackMaxPreallocation))

        for _ in 0..<entryCount {
            let key: String?
            do throws(MessagePackError) {
                key = try parser.readRawString()
            } catch {
                throw corrupted(error, path(), offset: startOffset)
            }
            guard let key else {
                parser.offset = startOffset
                return nil
            }
            let valueStart = parser.offset
            do throws(MessagePackDecodeFailure) {
                // The first of duplicate keys wins, as through
                // `Dictionary.init(from:)`, which looks each key up.
                if let first = result.updateValue(try read(&parser), forKey: key) {
                    result[key] = first
                }
            } catch {
                parser.offset = valueStart
                throw decodingError(
                    error, type: V.self, parser: parser,
                    path: path().appending(MessagePackCodingKey(stringValue: key)))
            }
        }
        return result
    }
}
