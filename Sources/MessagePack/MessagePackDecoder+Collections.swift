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
        codingPath: () -> [CodingKey]
    ) throws -> T {
        // Only the `[Int]` loop inlines the integer read. The other integer
        // loops call the shared out-of-line read: `[Int64]` and `[UInt64]`
        // would inline code identical to `[Int]` and `[UInt]`, which the
        // optimizer then merges into one function.
        switch collectionType {
        case .intArray:
            return try primitiveArray(&parser, codingPath, readIntegerInlined) as [Int] as! T
        case .stringArray:
            return try primitiveArray(&parser, codingPath, readString) as [String] as! T
        case .doubleArray:
            return try primitiveArray(&parser, codingPath, readDouble) as [Double] as! T
        case .boolArray:
            return try primitiveArray(&parser, codingPath, readBool) as [Bool] as! T
        case .floatArray:
            return try primitiveArray(&parser, codingPath, readFloat) as [Float] as! T
        case .int64Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [Int64] as! T
        case .uInt64Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [UInt64] as! T
        case .int32Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [Int32] as! T
        case .uInt32Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [UInt32] as! T
        case .int16Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [Int16] as! T
        case .uInt16Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [UInt16] as! T
        case .int8Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [Int8] as! T
        case .uInt8Array:
            return try primitiveArray(&parser, codingPath, readInteger) as [UInt8] as! T
        case .uIntArray:
            return try primitiveArray(&parser, codingPath, readInteger) as [UInt] as! T
        }
    }

    /// Decodes an array of a natively represented element type with a tight
    /// loop over the raw bytes, bypassing the unkeyed-container machinery.
    /// Error behavior matches the machinery: element failures are reported at
    /// the element's index in the coding path.
    static func primitiveArray<E>(
        _ parser: inout Parser,
        _ codingPath: () -> [CodingKey],
        _ read: (inout Parser) throws(MessagePackDecodeFailure) -> E
    ) throws -> [E] {
        let startOffset = parser.offset
        let headerCount: Int?
        do throws(MessagePackError) {
            headerCount = try parser.readRawArrayHeader()
        } catch {
            throw corrupted(error, codingPath(), offset: startOffset)
        }
        guard let elementCount = headerCount else {
            parser.offset = startOffset
            throw wrongType([E].self, parser, codingPath())
        }
        // Each element takes at least one byte; reject hostile counts before
        // reserving storage.
        guard elementCount <= parser.count - parser.offset else {
            throw corrupted(.insufficientData, codingPath(), offset: startOffset)
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
                    path: codingPath() + [MessagePackCodingKey(index: index)])
            }
        }
        return result
    }
}
