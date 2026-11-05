// fixed size, overwrites oldest. not thread safe, keep it on one actor
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0  // next write slot
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    public var capacity: Int { storage.count }

    public mutating func append(_ e: Element) {
        storage[head] = e
        head = (head + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    public mutating func append(contentsOf s: some Sequence<Element>) {
        for e in s { append(e) }
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }

    // oldest -> newest
    public var elements: [Element] {
        let start = (head - count + storage.count) % storage.count
        return (0..<count).compactMap { storage[(start + $0) % storage.count] }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
