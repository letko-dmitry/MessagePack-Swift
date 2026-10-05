import Foundation

/// Serializes and deserializes ``MessagePackValue`` trees to and from the
/// MessagePack binary format (https://github.com/msgpack/msgpack/blob/master/spec.md).
public struct MessagePackSerializer {
    /// Maximum nesting depth accepted when deserializing. Serialization is
    /// iterative and has no depth limit.
    static let maxDepth = 512

    /// Serializes a value into MessagePack binary data.
    ///
    /// Integers are encoded with the smallest format that can represent the
    /// value, as recommended by the specification. Non-negative integers use
    /// the unsigned formats (positive fixint / uint 8-64); negative integers
    /// use the signed formats (negative fixint / int 8-64).
    public static func serialize(value: MessagePackValue) throws(MessagePackError) -> Data {
        try withUnsafeTemporaryAllocation(byteCount: MessagePackOutputBuffer.initialCapacity, alignment: 8) {
            (memory) throws(MessagePackError) -> Data in
            var buffer = MessagePackOutputBuffer(memory: memory)
            do throws(MessagePackError) {
                try buffer.writeValue(value)
            } catch {
                buffer.deallocate()
                throw error
            }
            return buffer.finish()
        }
    }

    /// Deserializes MessagePack binary data into a value.
    ///
    /// Throws ``MessagePackError/trailingBytes`` if `data` contains bytes
    /// beyond the first top-level value.
    public static func deserialize(data: Data) throws(MessagePackError) -> MessagePackValue {
        let result: Result<MessagePackValue, MessagePackError> = data.withUnsafeBytes { buffer in
            var parser = Parser(buffer: buffer)
            do throws(MessagePackError) {
                let value = try parser.parseValue()
                guard parser.offset == buffer.count else {
                    throw MessagePackError.trailingBytes
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}

// MARK: - Value-tree writing

/// A container being written by ``MessagePackOutputBuffer/writeValue(_:)``.
/// Arrays iterate `items` by `index`; maps iterate the dictionary by native
/// index (no flattening allocation), with `pending` holding the value to
/// write after its key.
private struct MessagePackValueFrame {
    let items: [MessagePackValue]
    var index = 0
    let map: [MessagePackValue: MessagePackValue]
    var mapIndex: [MessagePackValue: MessagePackValue].Index
    var pending: MessagePackValue?
    let isMap: Bool

    init(items: [MessagePackValue]) {
        self.items = items
        self.map = [:]
        self.mapIndex = self.map.startIndex
        self.pending = nil
        self.isMap = false
    }

    init(map: [MessagePackValue: MessagePackValue]) {
        self.items = []
        self.map = map
        self.mapIndex = map.startIndex
        self.pending = nil
        self.isMap = true
    }
}

extension MessagePackOutputBuffer {
    /// Writes a whole value tree, throwing ``MessagePackError/valueTooLarge``
    /// for strings, binary, ext payloads, or containers beyond the
    /// MessagePack limits.
    ///
    /// Iterative, with the containers being written on an explicit stack, so
    /// hostile or extremely deep trees cannot overflow the call stack.
    mutating func writeValue(_ root: MessagePackValue) throws(MessagePackError) {
        var stack: [MessagePackValueFrame] = []
        try writeScalarOrHeader(root, stack: &stack)
        while !stack.isEmpty {
            let top = stack.count - 1
            if stack[top].isMap {
                if let pending = stack[top].pending {
                    stack[top].pending = nil
                    try writeScalarOrHeader(pending, stack: &stack)
                    continue
                }
                let index = stack[top].mapIndex
                guard index != stack[top].map.endIndex else {
                    stack.removeLast()
                    continue
                }
                stack[top].mapIndex = stack[top].map.index(after: index)
                let entry = stack[top].map[index]
                stack[top].pending = entry.value
                try writeScalarOrHeader(entry.key, stack: &stack)
            } else {
                // Write consecutive elements in a tight loop, breaking only
                // when an element pushes a nested container frame.
                let items = stack[top].items
                let count = items.count
                var index = stack[top].index
                while index < count {
                    // Passed straight from the subscript, the element is
                    // borrowed rather than copied (and released) each time.
                    try writeScalarOrHeader(items[index], stack: &stack)
                    index += 1
                    if stack.count != top + 1 { break }
                }
                if index == count && stack.count == top + 1 {
                    stack.removeLast()
                } else {
                    stack[top].index = index
                }
            }
        }
    }

    /// Writes a scalar, or writes a container header and pushes a frame for
    /// its children. Small enough to be inlined at each call in the walk:
    /// the rarer values go through ``writeContainerOrBytes(_:stack:)``.
    @inline(__always)
    private mutating func writeScalarOrHeader(
        _ value: MessagePackValue, stack: inout [MessagePackValueFrame]
    ) throws(MessagePackError) {
        switch value {
        case .nil:
            writeNil()
        case .bool(let v):
            writeBool(v)
        case .int8(let v):
            writeInt(Int64(v))
        case .int16(let v):
            writeInt(Int64(v))
        case .int32(let v):
            writeInt(Int64(v))
        case .int64(let v):
            writeInt(v)
        case .uint8(let v):
            writeUInt(UInt64(v))
        case .uint16(let v):
            writeUInt(UInt64(v))
        case .uint32(let v):
            writeUInt(UInt64(v))
        case .uint64(let v):
            writeUInt(v)
        case .float32(let v):
            writeFloat(v)
        case .float64(let v):
            writeDouble(v)
        default:
            try writeContainerOrBytes(value, stack: &stack)
        }
    }

    /// Writes a string, binary, or ext value, or writes a container header
    /// and pushes a frame for its children.
    @inline(never)
    private mutating func writeContainerOrBytes(
        _ value: MessagePackValue, stack: inout [MessagePackValueFrame]
    ) throws(MessagePackError) {
        switch value {
        case .string(let s):
            guard s.utf8.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeString(s)
        case .binary(let d):
            guard d.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeBinary(d)
        case .array(let elements):
            guard elements.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeArrayHeader(count: elements.count)
            if !elements.isEmpty { stack.append(MessagePackValueFrame(items: elements)) }
        case .map(let entries):
            guard entries.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeMapHeader(count: entries.count)
            if !entries.isEmpty { stack.append(MessagePackValueFrame(map: entries)) }
        case .ext(let type, let d):
            guard d.count <= MessagePackLimits.maxLength else { throw .valueTooLarge }
            writeExt(type: type, data: d)
        default:
            preconditionFailure("scalars are written by writeScalarOrHeader")
        }
    }
}
