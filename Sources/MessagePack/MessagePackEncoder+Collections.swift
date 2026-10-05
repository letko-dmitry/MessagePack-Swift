// MARK: - Collection fast paths

extension MessagePackEncoderImpl {
    /// Writes the value at `raw`, of a fast-path collection type.
    func encodeCollection(_ collectionType: MessagePackCollectionType, _ raw: UnsafeRawPointer) {
        switch collectionType {
        case .intArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Int].self).pointee) { $0.writeInt(Int64($1)) }
        case .stringArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [String].self).pointee) { $0.writeString($1) }
        case .doubleArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Double].self).pointee) { $0.writeDouble($1) }
        case .boolArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Bool].self).pointee) { $0.writeBool($1) }
        case .floatArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Float].self).pointee) { $0.writeFloat($1) }
        case .int64Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Int64].self).pointee) { $0.writeInt($1) }
        case .uInt64Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt64].self).pointee) { $0.writeUInt($1) }
        case .int32Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Int32].self).pointee) { $0.writeInt(Int64($1)) }
        case .uInt32Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt32].self).pointee) { $0.writeUInt(UInt64($1)) }
        case .int16Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Int16].self).pointee) { $0.writeInt(Int64($1)) }
        case .uInt16Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt16].self).pointee) { $0.writeUInt(UInt64($1)) }
        case .int8Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Int8].self).pointee) { $0.writeInt(Int64($1)) }
        case .uInt8Array:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt8].self).pointee) { $0.writeUInt(UInt64($1)) }
        case .uIntArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [UInt].self).pointee) { $0.writeUInt(UInt64($1)) }
        case .intDictionary:
            encodePrimitiveDictionary(raw.assumingMemoryBound(to: [String: Int].self).pointee) { $0.writeInt(Int64($1)) }
        case .stringDictionary:
            encodePrimitiveDictionary(raw.assumingMemoryBound(to: [String: String].self).pointee) { $0.writeString($1) }
        case .doubleDictionary:
            encodePrimitiveDictionary(raw.assumingMemoryBound(to: [String: Double].self).pointee) { $0.writeDouble($1) }
        case .boolDictionary:
            encodePrimitiveDictionary(raw.assumingMemoryBound(to: [String: Bool].self).pointee) { $0.writeBool($1) }
        }
    }

    /// Writes an array of a natively represented element type with a tight
    /// loop, bypassing the unkeyed-container machinery. The count is known up
    /// front, so the header is written at its final width directly, rather
    /// than counted (and widened) entry by entry.
    @inline(__always)
    private func encodePrimitiveArray<E>(
        _ array: [E], _ write: (inout MessagePackOutputBuffer, E) -> Void
    ) {
        state.pointee.buffer.writeArrayHeader(count: array.count)
        // By index, so each element is borrowed in place rather than copied
        // (retaining a string's storage) for the write.
        for index in array.indices {
            write(&state.pointee.buffer, array[index])
        }
    }

    /// Writes a string-keyed dictionary of a natively represented value
    /// type with a tight loop, like ``encodePrimitiveArray(_:_:)``. Entries
    /// come in the dictionary's iteration order, as from
    /// `Dictionary.encode(to:)`, so the output is byte-identical to the
    /// keyed-container route.
    @inline(__always)
    private func encodePrimitiveDictionary<V>(
        _ dictionary: [String: V], _ write: (inout MessagePackOutputBuffer, V) -> Void
    ) {
        state.pointee.buffer.writeMapHeader(count: dictionary.count)
        for (key, value) in dictionary {
            state.pointee.buffer.writeString(key)
            write(&state.pointee.buffer, value)
        }
    }
}
