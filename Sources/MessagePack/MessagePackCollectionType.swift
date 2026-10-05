/// A collection type with an encode and decode fast path: an array of a
/// natively represented value type.
enum MessagePackCollectionType {
    case intArray, stringArray, doubleArray, boolArray, floatArray, int64Array,
        uInt64Array, int32Array, uInt32Array, int16Array, uInt16Array, int8Array,
        uInt8Array, uIntArray

    /// The fast-path collection type `type` is, if any.
    ///
    /// Non-generic and out of line: comparing `T.self` with 14 generic types
    /// inline in the coders' generic dispatch made every other value pay for
    /// their metadata accessors and stack temporaries.
    @inline(never)
    init?(_ type: ObjectIdentifier) {
        let identifiers = Identifiers.shared

        switch type {
        case identifiers.intArray: self = .intArray
        case identifiers.stringArray: self = .stringArray
        case identifiers.doubleArray: self = .doubleArray
        case identifiers.boolArray: self = .boolArray
        case identifiers.floatArray: self = .floatArray
        case identifiers.int64Array: self = .int64Array
        case identifiers.uInt64Array: self = .uInt64Array
        case identifiers.int32Array: self = .int32Array
        case identifiers.uInt32Array: self = .uInt32Array
        case identifiers.int16Array: self = .int16Array
        case identifiers.uInt16Array: self = .uInt16Array
        case identifiers.int8Array: self = .int8Array
        case identifiers.uInt8Array: self = .uInt8Array
        case identifiers.uIntArray: self = .uIntArray
        default: return nil
        }
    }

    /// Cached, as the metadata of a generic type (`[Int].self`) is otherwise
    /// looked up through an accessor on every use. Loading all of them from
    /// one static value costs a single lazy-initialization check.
    private struct Identifiers {
        static let shared = Self()

        let intArray = ObjectIdentifier([Int].self)
        let stringArray = ObjectIdentifier([String].self)
        let doubleArray = ObjectIdentifier([Double].self)
        let boolArray = ObjectIdentifier([Bool].self)
        let floatArray = ObjectIdentifier([Float].self)
        let int64Array = ObjectIdentifier([Int64].self)
        let uInt64Array = ObjectIdentifier([UInt64].self)
        let int32Array = ObjectIdentifier([Int32].self)
        let uInt32Array = ObjectIdentifier([UInt32].self)
        let int16Array = ObjectIdentifier([Int16].self)
        let uInt16Array = ObjectIdentifier([UInt16].self)
        let int8Array = ObjectIdentifier([Int8].self)
        let uInt8Array = ObjectIdentifier([UInt8].self)
        let uIntArray = ObjectIdentifier([UInt].self)
    }
}
