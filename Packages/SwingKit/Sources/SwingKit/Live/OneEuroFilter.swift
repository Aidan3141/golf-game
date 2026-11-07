import Foundation

// 1€ filter (casiez et al 2012). heavy smoothing when slow (kills jitter at address),
// almost none when fast (no lag mid swing). minCutoff = smoothing when still (hz, lower =
// smoother), beta = how fast it opens up w/ speed
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var x: Double?
    private var dx = 0.0
    private var lastT: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.01, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func reset() {
        x = nil
        dx = 0
        lastT = nil
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func filter(_ value: Double, t: Double) -> Double {
        guard let prev = x, let lt = lastT, t > lt else {
            x = value
            lastT = t
            return value
        }
        let dt = t - lt
        let rawD = (value - prev) / dt
        dx += Self.alpha(cutoff: dCutoff, dt: dt) * (rawD - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let out = prev + Self.alpha(cutoff: cutoff, dt: dt) * (value - prev)
        x = out
        lastT = t
        return out
    }
}

// 3 axis version for positions
public struct OneEuroFilter3: Sendable {
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter
    private var fz: OneEuroFilter

    public init(minCutoff: Double = 1.0, beta: Double = 0.01) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        fy = fx
        fz = fx
    }

    public mutating func set(minCutoff: Double, beta: Double) {
        fx.minCutoff = minCutoff; fy.minCutoff = minCutoff; fz.minCutoff = minCutoff
        fx.beta = beta; fy.beta = beta; fz.beta = beta
    }

    public mutating func reset() {
        fx.reset(); fy.reset(); fz.reset()
    }

    public mutating func filter(_ v: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        SIMD3(fx.filter(v.x, t: t), fy.filter(v.y, t: t), fz.filter(v.z, t: t))
    }
}
