/// A stack in memory that its owner provides, typically from its own call
/// frame through `withUnsafeTemporaryAllocation`, moving to the heap only
/// when it outgrows that memory.
///
/// The encoder keeps its open containers and coding-path nodes in two of
/// them: a message nests a few levels deep, and arrays for those cost two
/// allocations (and their growth) on every `encode` call.
///
/// The owner calls ``deallocate()`` once it is done with the stack.
struct MessagePackStack<Element> {
    private var base: UnsafeMutablePointer<Element>
    private var capacity: Int
    private(set) var count = 0
    /// Whether `base` was allocated when growing rather than provided.
    private var isOnHeap = false

    init(memory: UnsafeMutableBufferPointer<Element>) {
        // Growing doubles the capacity, so zero would never grow.
        precondition(memory.count > 0, "a stack needs room for an element")
        self.base = memory.baseAddress.unsafelyUnwrapped
        self.capacity = memory.count
    }

    var last: Element? {
        count > 0 ? base[count &- 1] : nil
    }

    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "index out of range")
        return base[index]
    }

    mutating func append(_ element: Element) {
        if count == capacity {
            grow()
        }
        (base + count).initialize(to: element)
        count &+= 1
    }

    /// Removes the elements from `index` on.
    mutating func removeAll(from index: Int) {
        (base + index).deinitialize(count: count &- index)
        count = index
    }

    mutating func removeLast() {
        removeAll(from: count &- 1)
    }

    /// Releases the elements, and the memory if it came from the heap.
    mutating func deallocate() {
        removeAll(from: 0)
        if isOnHeap {
            base.deallocate()
        }
    }

    @inline(never)
    private mutating func grow() {
        let newBase = UnsafeMutablePointer<Element>.allocate(capacity: capacity * 2)
        newBase.moveInitialize(from: base, count: count)
        if isOnHeap {
            base.deallocate()
        }
        base = newBase
        capacity *= 2
        isOnHeap = true
    }
}

extension MessagePackStack {
    func lastIndex(where predicate: (Element) -> Bool) -> Int? {
        var index = count
        while index > 0 {
            index &-= 1
            if predicate(base[index]) {
                return index
            }
        }
        return nil
    }
}
