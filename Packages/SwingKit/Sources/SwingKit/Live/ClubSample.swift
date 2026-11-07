import Foundation

// one live club reading from the watch: angle along the swing axis (rad from address),
// how fast its turning (rad/s) + when it was measured. time is in the RECEIVERS clock
// (systemUptime) once the clocks are synced, nil before that
public struct ClubSample: Codable, Sendable, Hashable {
    public var angle: Double
    public var omega: Double
    public var phase: SwingPhase
    public var time: Double?

    public init(angle: Double, omega: Double, phase: SwingPhase, time: Double?) {
        self.angle = angle
        self.omega = omega
        self.phase = phase
        self.time = time
    }

    // same reading, time moved into another clock
    public func shifted(by offset: Double?) -> ClubSample {
        var s = self
        if let t = time, let offset { s.time = t + offset } else { s.time = nil }
        return s
    }

    // dead reckoning: where the angle should be at `t`. capped so a stale reading or a
    // reversal (top of backswing) cant fling the club around
    public func predictedAngle(at t: Double, maxHorizon: Double = 0.25, maxDelta: Double = 1.6) -> Double {
        guard let time else { return angle }
        let dt = min(max(t - time, 0), maxHorizon)
        let d = min(max(omega * dt, -maxDelta), maxDelta)
        return angle + d
    }
}

// angular velocity from a stream of angles. finite difference over ~30ms so one noisy
// sample doesnt spike it
public struct AngleRateTracker: Sendable {
    public var window: Double
    private var history: [(t: Double, a: Double)] = []

    public init(window: Double = 0.03) {
        self.window = window
    }

    public mutating func reset() { history.removeAll() }

    @discardableResult
    public mutating func add(t: Double, angle: Double) -> Double {
        history.append((t, angle))
        history.removeAll { $0.t < t - 0.2 }
        // newest sample thats at least `window` old, else the oldest we have
        guard let ref = history.last(where: { $0.t <= t - window }) ?? history.first, t > ref.t else { return 0 }
        return (angle - ref.a) / (t - ref.t)
    }
}
