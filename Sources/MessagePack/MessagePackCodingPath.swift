/// A coding path of the decoder: the index of its last key in
/// ``MessagePackDecodingContext/State/pathNodes``, each node linking to its
/// parent, like the encoder's ``MessagePackEncodingPath``.
///
/// A nested value's node is pushed when the value gets a decoder of its own
/// and popped once the value is decoded, along with the nodes of the
/// containers and decoders its `init(from:)` requested, which stay valid
/// until it returns. So a path costs a store into memory of the `decode`
/// call, where a linked list costs an allocation per value. A path built only
/// for an error is popped as soon as its keys are read.
///
/// A single word, so decoders holding it stay within the inline storage of
/// an existential and copy without reference counting.
struct MessagePackCodingPath {
    struct Node {
        let parent: Int
        let key: any CodingKey
        /// The number of keys up to and including this one, which is the
        /// container nesting depth.
        let depth: Int
    }

    static let root = Self(node: -1)

    let node: Int
}

extension MessagePackDecodingContext {
    /// Pushes a node for `key` under `parent` and returns its path.
    ///
    /// Borrows `key` (the default) rather than consuming it: the keyed
    /// containers pass their generic `Key`, which they borrow themselves.
    /// Handing over an owned `Key` copied it into a stack temporary sized at
    /// run time, in the prologue of every `decode(_:forKey:)`.
    func path(_ parent: MessagePackCodingPath, appending key: some CodingKey) -> MessagePackCodingPath {
        // Depth is bounded by the decoders' nesting limit and by the stack.
        let depth = depth(parent) &+ 1
        state.pointee.pathNodes.append(MessagePackCodingPath.Node(parent: parent.node, key: key, depth: depth))
        return MessagePackCodingPath(node: state.pointee.pathNodes.count &- 1)
    }

    func path(_ parent: MessagePackCodingPath, appendingIndex index: Int) -> MessagePackCodingPath {
        path(parent, appending: MessagePackCodingKey(index: index))
    }

    /// The number of keys of `path`, which is the container nesting depth.
    func depth(_ path: MessagePackCodingPath) -> Int {
        path.node < 0 ? 0 : state.pointee.pathNodes[path.node].depth
    }

    /// The keys of `path`, built only for errors and `codingPath` reads.
    func codingPath(_ path: MessagePackCodingPath) -> [CodingKey] {
        var keys: [CodingKey] = []
        keys.reserveCapacity(depth(path))
        var node = path.node
        while node >= 0 {
            let entry = state.pointee.pathNodes[node]
            keys.append(entry.key)
            node = entry.parent
        }
        keys.reverse()
        return keys
    }

    /// The keys of the path `path` makes, popping the nodes it pushes: the
    /// errors that a failed decode builds (and `try?` drops, in a loop
    /// perhaps) leave nothing behind on the stack.
    func codingPath(_ path: () -> MessagePackCodingPath) -> [CodingKey] {
        let nodeCount = state.pointee.pathNodes.count
        defer { state.pointee.pathNodes.removeAll(from: nodeCount) }

        return codingPath(path())
    }
}
