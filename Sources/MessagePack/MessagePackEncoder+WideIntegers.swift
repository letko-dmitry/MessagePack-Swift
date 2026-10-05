// MARK: - 128-bit integers

extension MessagePackEncoderImpl {
    /// Writes a 128-bit integer as the 64-bit MessagePack integer holding
    /// it, calling `begin` (which opens the container entry) only once the
    /// value is known to fit, so a throw leaves no partial entry behind.
    func encodeWideInteger(
        _ value: some BinaryInteger,
        path: @autoclosure () -> MessagePackEncodingPath,
        begin: () -> Void
    ) throws {
        if let signed = Int64(exactly: value) {
            begin()
            state.pointee.buffer.writeIntOutlined(signed)
        } else if let unsigned = UInt64(exactly: value) {
            begin()
            state.pointee.buffer.writeUIntOutlined(unsigned)
        } else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: codingPath(path()),
                    debugDescription: "Number \(value) does not fit in a 64-bit MessagePack integer"
                ))
        }
    }
}
