// MARK: - Collection fast paths

extension MessagePackEncoderImpl {
    /// Writes the value at `raw`, of a fast-path collection type.
    func encodeCollection(_ collectionType: MessagePackCollectionType, _ raw: UnsafeRawPointer) {
        switch collectionType {
        case .intArray:
            encodeSignedIntegers(raw.assumingMemoryBound(to: [Int].self).pointee)
        case .stringArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [String].self).pointee) { $0.writeString($1) }
        case .doubleArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Double].self).pointee) { $0.writeDouble($1) }
        case .boolArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Bool].self).pointee) { $0.writeBool($1) }
        case .floatArray:
            encodePrimitiveArray(raw.assumingMemoryBound(to: [Float].self).pointee) { $0.writeFloat($1) }
        case .int64Array:
            encodeSignedIntegers(raw.assumingMemoryBound(to: [Int64].self).pointee)
        case .uInt64Array:
            encodeUnsignedIntegers(raw.assumingMemoryBound(to: [UInt64].self).pointee)
        case .int32Array:
            encodeSignedIntegers(raw.assumingMemoryBound(to: [Int32].self).pointee)
        case .uInt32Array:
            encodeUnsignedIntegers(raw.assumingMemoryBound(to: [UInt32].self).pointee)
        case .int16Array:
            encodeSignedIntegers(raw.assumingMemoryBound(to: [Int16].self).pointee)
        case .uInt16Array:
            encodeUnsignedIntegers(raw.assumingMemoryBound(to: [UInt16].self).pointee)
        case .int8Array:
            encodeSignedIntegers(raw.assumingMemoryBound(to: [Int8].self).pointee)
        case .uInt8Array:
            encodeUnsignedIntegers(raw.assumingMemoryBound(to: [UInt8].self).pointee)
        case .uIntArray:
            encodeUnsignedIntegers(raw.assumingMemoryBound(to: [UInt].self).pointee)
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
    ///
    /// Out of line, so each specialization is a small function in which the
    /// element writes are inlined: in the switch above, they were left as
    /// a call per element.
    @inline(never)
    private func encodePrimitiveArray<E>(
        _ array: [E], _ write: (inout MessagePackScratchBuffer, E) -> Void
    ) {
        state.pointee.buffer.writeArrayHeader(count: array.count)
        // By index, so each element is borrowed in place rather than copied
        // (retaining a string's storage) for the write.
        for index in array.indices {
            write(&state.pointee.buffer, array[index])
        }
    }

    /// Writes an array of integers with a tight loop, like
    /// ``encodePrimitiveArray(_:_:)``. Generic over the element type rather
    /// than taking a write closure: the loops for `[Int]` and `[Int64]` (and
    /// for `[UInt]` and `[UInt64]`) compile to the same code, which the
    /// optimizer merges into one function, and given a closure that merged
    /// loop called the write through a pointer for every element.
    @inline(never)
    private func encodeSignedIntegers<I: SignedInteger & FixedWidthInteger>(_ array: [I]) {
        state.pointee.buffer.writeArrayHeader(count: array.count)
        for index in array.indices {
            state.pointee.buffer.writeInt(Int64(array[index]))
        }
    }

    /// Writes an array of unsigned integers; see
    /// ``encodeSignedIntegers(_:)``.
    @inline(never)
    private func encodeUnsignedIntegers<U: UnsignedInteger & FixedWidthInteger>(_ array: [U]) {
        state.pointee.buffer.writeArrayHeader(count: array.count)
        for index in array.indices {
            state.pointee.buffer.writeUInt(UInt64(array[index]))
        }
    }

    /// Writes a string-keyed dictionary of a natively represented value
    /// type with a tight loop, like ``encodePrimitiveArray(_:_:)``. Entries
    /// come in the dictionary's iteration order, as from
    /// `Dictionary.encode(to:)`, so the output is byte-identical to the
    /// keyed-container route. Out of line for the same reason as the arrays.
    @inline(never)
    private func encodePrimitiveDictionary<V>(
        _ dictionary: [String: V], _ write: (inout MessagePackScratchBuffer, V) -> Void
    ) {
        state.pointee.buffer.writeMapHeader(count: dictionary.count)
        for (key, value) in dictionary {
            state.pointee.buffer.writeString(key)
            write(&state.pointee.buffer, value)
        }
    }
}
