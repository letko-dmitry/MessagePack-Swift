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

    /// Borrows `key` (the default) rather than consuming it: the keyed
    /// containers pass their generic `Key`, which they borrow themselves.
    /// Handing over an owned `Key` copied it into a stack temporary sized at
    /// run time, in the prologue of every `decode(_:forKey:)`.
    func appending(_ key: CodingKey) -> MessagePackCodingPath {
        // Depth is bounded by the decoders' nesting limit and by the stack.
        .node(parent: self, key: key, depth: depth &+ 1)
    }

    func appending(index: Int) -> MessagePackCodingPath {
        // Built here so the new key moves into the node rather than being
        // copied from a borrow.
        .node(parent: self, key: MessagePackCodingKey(index: index), depth: depth &+ 1)
    }
}
