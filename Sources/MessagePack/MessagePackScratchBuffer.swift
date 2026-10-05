import Foundation

/// A growable raw byte buffer conforming to ``MessagePackFormatSink``, which
/// every route writes into; ``finish()`` turns it into the result.
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

    /// Adds an entry to the count in the container header at `position`.
    ///
    /// A header starts as a fixmap or fixarray and is widened in place to the
    /// 16- and then the 32-bit format when its count outgrows it, moving the
    /// entries already written: at most twice per container, and only ever
    /// for the innermost open container, so no open container moves.
    @inline(__always)
    mutating func incrementContainerCount(at position: Int) {
        let header = base.load(fromByteOffset: position, as: UInt8.self)
        // A fixmap (0x80...0x8f) or fixarray (0x90...0x9f) below 15 entries.
        if header & 0x0f != 0x0f && header <= 0x9f {
            base.storeBytes(of: header &+ 1, toByteOffset: position, as: UInt8.self)
        } else {
            incrementWideContainerCount(at: position)
        }
    }

    @inline(never)
    private mutating func incrementWideContainerCount(at position: Int) {
        let header = base.load(fromByteOffset: position, as: UInt8.self)

        switch header {
        case 0x8f, 0x9f:
            // The 16th entry: map 16 / array 16.
            insertBytes(2, at: position + 1)
            base.storeBytes(of: header == 0x8f ? 0xde : 0xdc, toByteOffset: position, as: UInt8.self)
            base.storeBytes(of: UInt16(16).bigEndian, toByteOffset: position + 1, as: UInt16.self)
        case 0xde, 0xdc:
            let count = UInt16(bigEndian: base.loadUnaligned(fromByteOffset: position + 1, as: UInt16.self))
            if count < 0xffff {
                base.storeBytes(of: (count + 1).bigEndian, toByteOffset: position + 1, as: UInt16.self)
            } else {
                // The 65,536th entry: map 32 / array 32.
                insertBytes(2, at: position + 3)
                base.storeBytes(of: header == 0xde ? 0xdf : 0xdd, toByteOffset: position, as: UInt8.self)
                base.storeBytes(of: UInt32(0x1_0000).bigEndian, toByteOffset: position + 1, as: UInt32.self)
            }
        default:
            let count = UInt32(bigEndian: base.loadUnaligned(fromByteOffset: position + 1, as: UInt32.self))
            precondition(
                UInt64(count) < UInt64(MessagePackLimits.maxLength),
                "MessagePack containers are limited to 2^32-1 entries")
            base.storeBytes(of: (count + 1).bigEndian, toByteOffset: position + 1, as: UInt32.self)
        }
    }

    /// Moves the bytes from `position` on by `count`, opening a gap there.
    private mutating func insertBytes(_ count: Int, at position: Int) {
        ensure(count)
        (base + position + count).copyMemory(from: base + position, byteCount: offset - position)
        offset += count
    }

    /// The entry count in the container header at `position`.
    func containerCount(at position: Int) -> Int {
        let header = base.load(fromByteOffset: position, as: UInt8.self)

        switch header {
        case 0x80...0x9f:
            return Int(header & 0x0f)
        case 0xdc, 0xde:
            return Int(UInt16(bigEndian: base.loadUnaligned(fromByteOffset: position + 1, as: UInt16.self)))
        default:
            return Int(UInt32(bigEndian: base.loadUnaligned(fromByteOffset: position + 1, as: UInt32.self)))
        }
    }
}
