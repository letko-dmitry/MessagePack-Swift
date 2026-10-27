import Foundation

/// A generic coding key used for array indices, `Int` dictionary keys, and
/// the `super` key.
///
/// Integer keys defer building their `stringValue` until it is actually read
/// (error reporting), keeping hot encode/decode paths allocation-free. The
/// enum payload keeps the type within three words, so storing it in a
/// `CodingKey` existential never heap-allocates.
struct MessagePackCodingKey: CodingKey {
    private enum Value {
        case string(String)
        case index(Int)
        case dictionaryKey(Int)
    }

    private let value: Value

    var stringValue: String {
        switch value {
        case .string(let s): return s
        case .index(let i): return "Index \(i)"
        case .dictionaryKey(let i): return String(i)
        }
    }

    var intValue: Int? {
        switch value {
        case .string: return nil
        case .index(let i), .dictionaryKey(let i): return i
        }
    }

    init?(stringValue: String) {
        value = .string(stringValue)
    }

    init?(intValue: Int) {
        value = .index(intValue)
    }

    init(index: Int) {
        value = .index(index)
    }

    /// The key of an `Int`-keyed dictionary entry, named by its digits like
    /// the keys of `Dictionary`'s own `Codable` conformance.
    init(dictionaryKey: Int) {
        value = .dictionaryKey(dictionaryKey)
    }

    static let `super` = MessagePackCodingKey(stringValue: "super")!
}
