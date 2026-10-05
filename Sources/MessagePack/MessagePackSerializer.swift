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
        try withUnsafeTemporaryAllocation(byteCount: MessagePackScratchBuffer.initialCapacity, alignment: 8) {
            (memory) throws(MessagePackError) -> Data in
            var buffer = MessagePackScratchBuffer(memory: memory)
            do throws(MessagePackError) {
                try buffer.writeValidated(value)
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
