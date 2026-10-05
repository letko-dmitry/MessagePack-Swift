import Foundation

/// Limits imposed by the MessagePack wire format itself.
@usableFromInline
enum MessagePackLimits {
    /// The longest str/bin/ext payload, array, or map the format can express
    /// (2^32-1), since every 32-bit header stores its length in a `UInt32`,
    /// capped to the addressable collection size on 32-bit platforms.
    ///
    /// A computed property rather than a `static let`: it folds to an
    /// immediate at every use site, with no lazy global initialization.
    @inlinable
    static var maxLength: Int { Int(clamping: UInt32.max) }
}

/// The growable byte buffer all routes write MessagePack into: the
/// ``MessagePackWriter`` of ``MessagePackSerializable`` conformances, the
/// value-tree serializer, and ``MessagePackEncoder``. Integers, strings, and
/// headers take the smallest format that holds them, so every route writes
/// the same bytes for equivalent values.
///
/// A buffer starts in memory its caller provides, from its own call frame
/// (`withUnsafeTemporaryAllocation`), and moves to the heap if it outgrows
/// it: then ``finish()`` hands the bytes to a `Data` without copying them,
/// while a small result is copied into a `Data` of its exact size, which
/// holds up to 14 bytes inline.
///
/// Heap memory comes from `UnsafeMutableRawPointer.allocate`, which measured
/// faster than `malloc`/`realloc` for large buffers (a 1 MB binary
/// serialized in 15 µs instead of 17–18) and no slower for small ones.
@usableFromInline
struct MessagePackOutputBuffer {
    /// The size of the memory each route starts its buffer in.
    @inlinable
    static var initialCapacity: Int { 1024 }

    @usableFromInline
    var base: UnsafeMutableRawPointer
    @usableFromInline
    var capacity: Int
    @usableFromInline
    var offset = 0
    /// Whether `base` came from the heap, by growing, rather than from the
    /// caller.
    @usableFromInline
    var isOnHeap = false

    @usableFromInline
    init(memory: UnsafeMutableRawBufferPointer) {
        // grow() doubles the capacity, so zero would never grow.
        precondition(memory.count > 0, "a buffer needs room for a byte")
        self.base = memory.baseAddress.unsafelyUnwrapped
        self.capacity = memory.count
    }

    /// Releases the memory of a buffer whose bytes are not wanted.
    @usableFromInline
    func deallocate() {
        if isOnHeap {
            base.deallocate()
        }
    }

    /// The bytes as a `Data`. The buffer must not be used afterwards.
    @usableFromInline
    func finish() -> Data {
        guard isOnHeap else {
            return Data(bytes: base, count: offset)
        }
        return Data(bytesNoCopy: base, count: offset, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }

    // MARK: Bytes

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

    /// Writes `bytes`, which may be empty (with no base address).
    @inlinable
    @inline(__always)
    mutating func writeBytes(_ bytes: UnsafeRawBufferPointer) {
        if let baseAddress = bytes.baseAddress {
            writeBytes(baseAddress, count: bytes.count)
        }
    }

    // MARK: Scalars

    @inlinable
    @inline(__always)
    mutating func writeNil() {
        writeByte(0xc0)
    }

    @inlinable
    @inline(__always)
    mutating func writeBool(_ value: Bool) {
        writeByte(value ? 0xc3 : 0xc2)
    }

    /// Writes a signed integer using the smallest format that represents it.
    /// Non-negative values use the unsigned family, as the spec recommends.
    @inlinable
    @inline(__always)
    mutating func writeInt(_ value: Int64) {
        if value >= 0 {
            writeUInt(UInt64(bitPattern: value))
        } else if value >= -32 {
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value >= Int64(Int8.min) {
            writeByte(0xd0)
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value >= Int64(Int16.min) {
            writeByte(0xd1)
            writeBigEndian(Int16(truncatingIfNeeded: value))
        } else if value >= Int64(Int32.min) {
            writeByte(0xd2)
            writeBigEndian(Int32(truncatingIfNeeded: value))
        } else {
            writeByte(0xd3)
            writeBigEndian(value)
        }
    }

    /// Writes an unsigned integer using the smallest format that represents it.
    @inlinable
    @inline(__always)
    mutating func writeUInt(_ value: UInt64) {
        if value <= 0x7f {
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value <= 0xff {
            writeByte(0xcc)
            writeByte(UInt8(truncatingIfNeeded: value))
        } else if value <= 0xffff {
            writeByte(0xcd)
            writeBigEndian(UInt16(truncatingIfNeeded: value))
        } else if value <= 0xffff_ffff {
            writeByte(0xce)
            writeBigEndian(UInt32(truncatingIfNeeded: value))
        } else {
            writeByte(0xcf)
            writeBigEndian(value)
        }
    }

    /// Out-of-line integer writes for the many per-type entry points (the
    /// encoder's container overloads): one shared copy of the smallest-format
    /// selection instead of one inlined into every caller. The value-tree walk
    /// and the collection loops keep the inlined writers, as a call per
    /// integer there measured slower.
    @inline(never)
    mutating func writeIntOutlined(_ value: Int64) {
        writeInt(value)
    }

    @inline(never)
    mutating func writeUIntOutlined(_ value: UInt64) {
        writeUInt(value)
    }

    @inlinable
    @inline(__always)
    mutating func writeFloat(_ value: Float) {
        writeByte(0xca)
        writeBigEndian(value.bitPattern)
    }

    @inlinable
    @inline(__always)
    mutating func writeDouble(_ value: Double) {
        writeByte(0xcb)
        writeBigEndian(value.bitPattern)
    }

    // MARK: Strings, binary, and extensions

    @inlinable
    @inline(__always)
    mutating func writeStringHeader(byteCount length: Int) {
        if length < 32 {
            writeByte(0xa0 | UInt8(truncatingIfNeeded: length))
        } else if length <= 0xff {
            writeByte(0xd9)
            writeByte(UInt8(truncatingIfNeeded: length))
        } else if length <= 0xffff {
            writeByte(0xda)
            writeBigEndian(UInt16(truncatingIfNeeded: length))
        } else {
            precondition(
                length <= MessagePackLimits.maxLength,
                "MessagePack strings are limited to 2^32-1 bytes")
            writeByte(0xdb)
            writeBigEndian(UInt32(truncatingIfNeeded: length))
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeString(_ string: String) {
        // Borrows the UTF-8 of a native string in place: `withUTF8` is
        // mutating, and copying the string to call it retains and releases
        // its storage for every string written.
        let written: Void? = string.utf8.withContiguousStorageIfAvailable { utf8 in
            writeStringHeader(byteCount: utf8.count)
            writeBytes(UnsafeRawBufferPointer(utf8))
        }
        if written == nil {
            writeNonContiguousString(string)
        }
    }

    /// Writes a string with no contiguous UTF-8, such as one bridged from
    /// `NSString`, by making a native copy.
    @usableFromInline
    @inline(never)
    mutating func writeNonContiguousString(_ string: String) {
        var string = string
        string.withUTF8 { utf8 in
            writeStringHeader(byteCount: utf8.count)
            writeBytes(UnsafeRawBufferPointer(utf8))
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeBinary(_ data: Data) {
        let length = data.count
        if length <= 0xff {
            writeByte(0xc4)
            writeByte(UInt8(truncatingIfNeeded: length))
        } else if length <= 0xffff {
            writeByte(0xc5)
            writeBigEndian(UInt16(truncatingIfNeeded: length))
        } else {
            precondition(
                length <= MessagePackLimits.maxLength,
                "MessagePack binary is limited to 2^32-1 bytes")
            writeByte(0xc6)
            writeBigEndian(UInt32(truncatingIfNeeded: length))
        }
        data.withUnsafeBytes { writeBytes($0) }
    }

    @inlinable
    @inline(__always)
    mutating func writeExt(type: Int8, data: Data) {
        let length = data.count
        switch length {
        case 1: writeByte(0xd4)
        case 2: writeByte(0xd5)
        case 4: writeByte(0xd6)
        case 8: writeByte(0xd7)
        case 16: writeByte(0xd8)
        default:
            if length <= 0xff {
                writeByte(0xc7)
                writeByte(UInt8(truncatingIfNeeded: length))
            } else if length <= 0xffff {
                writeByte(0xc8)
                writeBigEndian(UInt16(truncatingIfNeeded: length))
            } else {
                precondition(
                    length <= MessagePackLimits.maxLength,
                    "MessagePack ext payloads are limited to 2^32-1 bytes")
                writeByte(0xc9)
                writeBigEndian(UInt32(truncatingIfNeeded: length))
            }
        }
        writeByte(UInt8(bitPattern: type))
        data.withUnsafeBytes { writeBytes($0) }
    }

    /// Writes a timestamp as the spec's ext type -1 in its smallest layout,
    /// straight from its fields rather than through a `Data` payload.
    @inlinable
    mutating func writeTimestamp(_ timestamp: MessagePackTimestamp) {
        switch timestamp.layout {
        case .bits32(let payload):
            writeByte(0xd6)  // fixext 4
            writeByte(0xff)
            writeBigEndian(payload)
        case .bits64(let payload):
            writeByte(0xd7)  // fixext 8
            writeByte(0xff)
            writeBigEndian(payload)
        case .bits96(let nanoseconds, let seconds):
            writeByte(0xc7)  // ext 8
            writeByte(12)
            writeByte(0xff)
            writeBigEndian(nanoseconds)
            writeBigEndian(seconds)
        }
    }

    // MARK: Containers

    @inlinable
    @inline(__always)
    mutating func writeArrayHeader(count: Int) {
        if count < 16 {
            writeByte(0x90 | UInt8(truncatingIfNeeded: count))
        } else if count <= 0xffff {
            writeByte(0xdc)
            writeBigEndian(UInt16(truncatingIfNeeded: count))
        } else {
            precondition(
                count <= MessagePackLimits.maxLength,
                "MessagePack arrays are limited to 2^32-1 elements")
            writeByte(0xdd)
            writeBigEndian(UInt32(truncatingIfNeeded: count))
        }
    }

    @inlinable
    @inline(__always)
    mutating func writeMapHeader(count: Int) {
        if count < 16 {
            writeByte(0x80 | UInt8(truncatingIfNeeded: count))
        } else if count <= 0xffff {
            writeByte(0xde)
            writeBigEndian(UInt16(truncatingIfNeeded: count))
        } else {
            precondition(
                count <= MessagePackLimits.maxLength,
                "MessagePack maps are limited to 2^32-1 entries")
            writeByte(0xdf)
            writeBigEndian(UInt32(truncatingIfNeeded: count))
        }
    }
}

// MARK: - Container headers

/// The headers of containers whose counts are not known up front, which
/// ``MessagePackEncoder`` counts in place.
extension MessagePackOutputBuffer {
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

    /// Whether the container header at `position` is a map's.
    func isMapHeader(at position: Int) -> Bool {
        let header = base.load(fromByteOffset: position, as: UInt8.self)
        return header & 0xf0 == 0x80 || header == 0xde || header == 0xdf
    }
}
