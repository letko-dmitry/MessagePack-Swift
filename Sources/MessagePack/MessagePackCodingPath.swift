/// A decoder's coding path stored as a linked list, like `_CodingPathNode` in
/// swift-foundation's `JSONDecoder`: a nested value extends its container's
/// path in constant time with a single allocation, instead of copying (and
/// retaining) every key of the parent path into a new array. The array of
/// keys is built only for errors and for `codingPath` reads.
///
/// A single word, so decoders holding it stay within the inline storage of
/// an existential.
indirect enum MessagePackCodingPath {
    case root
    case node(parent: MessagePackCodingPath, key: CodingKey, depth: Int)

    /// The number of keys, which is the container nesting depth.
    var depth: Int {
        switch self {
        case .root: return 0
        case .node(_, _, let depth): return depth
        }
    }

    var keys: [CodingKey] {
        var keys: [CodingKey] = []
        keys.reserveCapacity(depth)
        var path = self
        while case .node(let parent, let key, _) = path {
            keys.append(key)
            path = parent
        }
        keys.reverse()
        return keys
    }

    func appending(_ key: consuming CodingKey) -> MessagePackCodingPath {
        // Depth is bounded by the decoders' nesting limit and by the stack.
        .node(parent: self, key: key, depth: depth &+ 1)
    }

    func appending(index: Int) -> MessagePackCodingPath {
        appending(MessagePackCodingKey(index: index))
    }
}
