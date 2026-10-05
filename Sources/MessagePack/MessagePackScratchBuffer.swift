import Foundation

/// A growable raw byte buffer conforming to ``MessagePackFormatSink``.
/// Used as scratch space during encoding; the final `Data` is produced by
/// ``MessagePackEncoderImpl/finalize()``.
@usableFromInline
struct MessagePackScratchBuffer: MessagePackFormatSink {
    @usableFromInline
    var base: UnsafeMutableRawPointer
    @usableFromInline
    var capacity: Int
    @usableFromInline
    var offset = 0
    /// Whether `base` came from the heap rather than from the caller.
    @usableFromInline
    var isOnHeap = true

    /// The size of the memory a buffer starts in.
    @inlinable
    static var initialCapacity: Int { 1024 }

    @usableFromInline
    init(initialCapacity: Int = Self.initialCapacity) {
        // grow() doubles the capacity, so zero would never grow.
        precondition(initialCapacity > 0, "initialCapacity must be positive")
        self.base = .allocate(byteCount: initialCapacity, alignment: 8)
        self.capacity = initialCapacity
    }

    /// A buffer that starts in memory its caller provides, from its own call
    /// frame (`withUnsafeTemporaryAllocation`), and moves to the heap if it
    /// outgrows it.
    @usableFromInline
    init(memory: UnsafeMutableRawBufferPointer) {
        // grow() doubles the capacity, so zero would never grow.
        precondition(memory.count > 0, "a buffer needs room for a byte")
        self.base = memory.baseAddress.unsafelyUnwrapped
        self.capacity = memory.count
        self.isOnHeap = false
    }

    @usableFromInline
    func deallocate() {
        if isOnHeap {
            base.deallocate()
        }
    }

    /// The bytes as a `Data`. A buffer on the heap is handed over without
    /// copying; a result still in the caller's memory is copied into a `Data`
    /// of its exact size, which holds up to 14 bytes inline. The buffer must
    /// not be used afterwards.
    @usableFromInline
    func finish() -> Data {
        guard isOnHeap else {
            return Data(bytes: base, count: offset)
        }
        return Data(bytesNoCopy: base, count: offset, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }

    @inlinable
    @inline(__always)
    mutating func ensure(_ additional: Int) {
        if capacity &- offset < additional {
            grow(additional)
        }
    }

    @usableFromInline
    @inline(never)
    mutating func grow(_ additional: Int) {
        var newCapacity = capacity * 2
        while newCapacity - offset < additional {
            newCapacity *= 2
        }
        let newBase = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 8)
        newBase.copyMemory(from: base, byteCount: offset)
        deallocate()
        base = newBase
        capacity = newCapacity
        isOnHeap = true
    }

    @inlinable
    @inline(__always)
    mutating func writeByte(_ byte: UInt8) {
        ensure(1)
        base.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
        offset &+= 1
    }

    @inlinable
    @inline(__always)
    mutating func writeBigEndian<T: FixedWidthInteger>(_ value: T) {
        ensure(MemoryLayout<T>.size)
        base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: T.self)
        offset &+= MemoryLayout<T>.size
    }

    @inlinable
    @inline(__always)
    mutating func writeBytes(_ pointer: UnsafeRawPointer, count: Int) {
        ensure(count)
        let destination = base + offset
        // Keys and most strings are a few bytes long, for which two
        // overlapping loads and stores beat a call to `memmove`.
        if count >= 8 && count <= 16 {
            let head = pointer.loadUnaligned(as: UInt64.self)
            let tail = pointer.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self)
            destination.storeBytes(of: head, as: UInt64.self)
            destination.storeBytes(of: tail, toByteOffset: count &- 8, as: UInt64.self)
        } else if count >= 4 && count < 8 {
            let head = pointer.loadUnaligned(as: UInt32.self)
            let tail = pointer.loadUnaligned(fromByteOffset: count &- 4, as: UInt32.self)
            destination.storeBytes(of: head, as: UInt32.self)
            destination.storeBytes(of: tail, toByteOffset: count &- 4, as: UInt32.self)
        } else {
            destination.copyMemory(from: pointer, byteCount: count)
        }
        offset &+= count
    }

    /// Reserves space for a container header whose count is not yet known.
    /// The element count is accumulated directly in bytes 1...4 of the
    /// reserved space (dead until `finalize()` rewrites it), which avoids
    /// per-element bookkeeping in a separate array.
    @inline(__always)
    mutating func reserveContainerHeader() -> Int {
        ensure(5)
        let position = offset
        base.storeBytes(of: UInt32(0), toByteOffset: position + 1, as: UInt32.self)
        offset += 5
        return position
    }

    /// Increments the element count stored in a reserved container header.
    @inline(__always)
    func bumpContainerCount(at position: Int) {
        let pointer = base + position + 1
        pointer.storeBytes(of: pointer.loadUnaligned(as: UInt32.self) &+ 1, as: UInt32.self)
    }

    /// Reads the element count stored in a reserved container header.
    @inline(__always)
    func containerCount(at position: Int) -> Int {
        Int((base + position + 1).loadUnaligned(as: UInt32.self))
    }
}
