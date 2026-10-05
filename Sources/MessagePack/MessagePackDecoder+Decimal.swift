import Foundation

// MARK: - Decimal

extension MessagePackDecoding {
    /// Decodes a `Decimal` with ``MessagePackDecoder/DecimalDecodingStrategy/stringOrNumber``:
    /// from the map of fields that `Decimal`'s own `Codable` conformance
    /// writes (through that conformance), from a string of decimal digits
    /// (the encoder's `.string` strategy, and what other languages' decimal
    /// types produce), or from any number: integers convert exactly and
    /// floats through their shortest decimal text, so a float 64 of 0.35
    /// decodes as 0.35 rather than 0.34999999999999997952.
    static func decodeDecimal(
        parser: inout Parser,
        context: MessagePackDecodingContext,
        path: () -> MessagePackCodingPath
    ) throws -> Decimal {
        if let format = try? parser.peekFormat(), isMapFormat(format) {
            return try decodeWithContainers(Decimal.self, parser: &parser, context: context, path: path())
        }

        return try readScalarOrRewind(Decimal.self, &parser, parser.offset, path, readDecimal)
    }

    private static func readDecimal(_ parser: inout Parser) throws(MessagePackDecodeFailure) -> Decimal {
        let string: String?
        do throws(MessagePackError) {
            string = try parser.readRawString()
        } catch {
            throw .corrupted(error)
        }

        if let string {
            guard let decimal = decimal(from: string) else {
                throw .invalid("String \"\(string)\" is not a decimal number")
            }
            return decimal
        }

        let integer: MessagePackRawInteger?
        do throws(MessagePackError) {
            integer = try parser.readRawInteger()
        } catch {
            throw .corrupted(error)
        }

        switch integer {
        case .signed(let value):
            return Decimal(value)
        case .unsigned(let value):
            return Decimal(value)
        case nil:
            break
        }

        // A float converts through its shortest text in the width it was
        // written in: widened to a Double first, a float 32 of 0.35 would
        // come out as 0.3499999940395355.
        let isFloat32 = (try? parser.peekFormat()) == 0xca
        let value = try readDouble(&parser)
        let text = isFloat32 ? "\(Float(value))" : "\(value)"
        guard value.isFinite, let decimal = Decimal(string: text) else {
            throw .invalid("Number \(value) does not fit in Decimal")
        }

        return decimal
    }

    /// Parses the whole string as a decimal number in the POSIX format that
    /// `Decimal.description` produces. `Decimal(string:)` alone would accept
    /// a numeric prefix and ignore the rest ("1.5abc", "1,5").
    private static func decimal(from string: String) -> Decimal? {
        if string == "NaN" {
            return .nan
        }

        let scanner = Scanner(string: string)
        scanner.charactersToBeSkipped = nil

        guard let decimal = scanner.scanDecimal(), scanner.isAtEnd else {
            return nil
        }

        return decimal
    }

    @inline(__always)
    private static func isMapFormat(_ format: UInt8) -> Bool {
        (0x80...0x8f).contains(format) || format == 0xde || format == 0xdf
    }
}
