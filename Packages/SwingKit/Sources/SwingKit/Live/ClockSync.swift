import Foundation

// ntp style clock offset between this device + another one.
// send t0 (my clock) -> they stamp t1 (their clock) -> i get it back at t3 (my clock).
// offset = t1 - (t0 + t3) / 2  (their clock - my clock), exact if both legs take the same time.
// keeps the sample w/ the smallest round trip, thats the one w/ the least room for error
public struct ClockOffsetEstimator: Sendable {
    public struct Sample: Sendable, Hashable {
        public var offset: Double
        public var rtt: Double
    }

    public var window: Int
    public private(set) var samples: [Sample] = []

    public init(window: Int = 20) {
        self.window = max(window, 1)
    }

    public mutating func add(sent t0: Double, remote t1: Double, received t3: Double) {
        let rtt = t3 - t0
        // clock went backwards or it sat in a queue forever, ignore
        guard rtt >= 0, rtt < 2 else { return }
        samples.append(Sample(offset: t1 - (t0 + t3) / 2, rtt: rtt))
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    public mutating func reset() { samples.removeAll() }

    private var best: Sample? { samples.min { $0.rtt < $1.rtt } }

    // their clock - my clock, nil till we have a sample
    public var offset: Double? { best?.offset }
    public var bestRTT: Double? { best?.rtt }

    // worst case error of the offset (half the best round trip)
    public var uncertainty: Double? { best.map { $0.rtt / 2 } }

    public func toRemote(_ localTime: Double) -> Double? {
        offset.map { localTime + $0 }
    }
}
