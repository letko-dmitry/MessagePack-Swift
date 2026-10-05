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
        // loops call the shared out-of-line read: `[Int64]` and `[UInt64]`
        // would inline code identical to `[Int]` and `[UInt]`, which the
        // optimizer then merges into one function.
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
            if let dictionary = primitiveDictionary(&parser, readIntegerInlined) as [String: Int]? {
                return dictionary as! T
            }
        case .stringDictionary:
            if let dictionary = primitiveDictionary(&parser, readString) as [String: String]? {
                return dictionary as! T
            }
        case .doubleDictionary:
            if let dictionary = primitiveDictionary(&parser, readDouble) as [String: Double]? {
                return dictionary as! T
            }
        case .boolDictionary:
            if let dictionary = primitiveDictionary(&parser, readBool) as [String: Bool]? {
                return dictionary as! T
            }
        }

        // Anything but a map of unique string keys and values of the type.
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
            parser.offset = startOffset
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
    ///
    /// Returns nil with the parser rewound for anything but a map of unique
    /// string keys and values of type `V`, which the container machinery
    /// then decodes as before this fast path: `Dictionary.init(from:)` turns
    /// integer keys into their decimal strings, skips keys that are not
    /// valid UTF-8, keeps whichever of duplicate keys its lookups reach last,
    /// and reports errors with its types and paths.
    static func primitiveDictionary<V>(
        _ parser: inout Parser,
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> V
    ) -> [String: V]? {
        let startOffset = parser.offset
        // Each entry takes at least two bytes, so a larger count is hostile:
        // leave it to the machinery before reserving storage.
        guard let entryCount = try? parser.readRawMapHeader(),
              entryCount <= (parser.count &- parser.offset) / 2 else {
            parser.offset = startOffset
            return nil
        }

        var result = [String: V](minimumCapacity: Swift.min(entryCount, messagePackMaxPreallocation))

        for _ in 0..<entryCount {
            guard let key = try? parser.readRawString(),
                  let value = try? read(&parser),
                  result.updateValue(value, forKey: key) == nil else {
                parser.offset = startOffset
                return nil
            }
        }
        return result
    }
}
