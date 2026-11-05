import Foundation

// all the knobs, tuned on the nov 5 recordings (ultra, left wrist, righty)
public struct SwingDetectorConfig: Sendable, Hashable {
    public var smoothingTau = 0.015  // s, ema on rotation magnitude
    public var stillThreshold = 0.6  // rad/s, below = wrist still
    public var addressStillTime = 0.5  // s still -> address
    public var takeawayThreshold = 0.5  // rad/s, backswing starts above this
    public var impactMinPeak = 9.0  // rad/s, real swings were 16-21
    public var impactPeakDrop = 0.6  // peak confirmed once we fall below 60% of it
    public var impactPeakTimeout = 0.08  // s, or this long after the peak
    public var minBackswingHump = 2.5  // rad/s, real were 4.7-6.9
    public var maxTopRatio = 0.35  // top speed must be < 35% of the hump (or < topAbsolute)
    public var topAbsolute = 1.5
    public var downswing = 0.12...0.8  // s, real were 0.28-0.49
    public var backswing = 0.35...2.5  // s, real were 0.92-1.11
    public var topSearch = 0.1...0.8  // s before impact
    public var humpSearch = 0.12...1.5  // s before top
    public var refractory = 1.2  // s after impact, ignore follow thru
    public var bufferSeconds = 4.0
    public var smoothnessFloor = 0.04  // roughness at/below this = 1.0
    public var smoothnessGain = 6.0  // real swings (rough .073-.103) land ~0.6-0.8
    public var minConfidenceToSend = 0.5

    public init() {}
    public static let standard = SwingDetectorConfig()
}

public enum SwingEvent: Sendable, Hashable {
    case address(at: Double)
    case takeaway(at: Double)
    case impact(SwingResult, SwingTimeline)
    case rejected(reason: String, at: Double)
}

// phase boundaries in the same clock as the input, for charts + debugging
public struct SwingTimeline: Sendable, Hashable {
    public var address: Double?
    public var takeaway: Double?  // nil if it started before the buffer
    public var top: Double
    public var impact: Double
}

// feed it motion as it arrives (any rate ~100-200hz). works on magnitudes so it doesnt care
// about which wrist or hand. finds impact live, then looks back in the buffer for top + takeaway
public struct SwingDetector: Sendable {
    public private(set) var phase = SwingPhase.idle
    public var config: SwingDetectorConfig
    public var handedness: Handedness

    struct Frame: Sendable {
        var t: Double
        var raw: Double
        var smooth: Double
        var motion: MotionFrame
    }

    // live swing angle (rad) from the address pose, nil till we see an address. for streaming the club
    public private(set) var currentAngle: Double?
    private var angles = SwingAngleTracker()

    private var frames: RingBuffer<Frame>
    private var accel: RingBuffer<AccelSample>
    private var smooth: Double?
    private var lastT: Double?
    private var stillSince: Double?
    private var addressAt: Double?
    private var peak: Frame?
    private var lastImpact = -Double.infinity

    public init(config: SwingDetectorConfig = .standard, handedness: Handedness = .right) {
        self.config = config
        self.handedness = handedness
        frames = RingBuffer(capacity: Int(config.bufferSeconds * 250))
        accel = RingBuffer(capacity: Int(config.bufferSeconds * 850))
    }

    public mutating func reset() {
        frames.removeAll()
        accel.removeAll()
        smooth = nil
        lastT = nil
        angles.clear()
        currentAngle = nil
        stillSince = nil
        addressAt = nil
        peak = nil
        phase = .idle
    }

    // optional, only used for peak g at impact
    public mutating func add(accel samples: [AccelSample]) {
        accel.append(contentsOf: samples)
    }

    public mutating func add(motion: [MotionFrame]) -> [SwingEvent] {
        var events: [SwingEvent] = []
        for m in motion {
            events += step(m)
        }
        return events
    }

    private mutating func step(_ m: MotionFrame) -> [SwingEvent] {
        let t = m.t
        let raw = m.rotationMagnitude
        let dt = lastT.map { max(t - $0, 0) } ?? 0
        lastT = t
        let alpha = dt > 0 ? 1 - exp(-dt / config.smoothingTau) : 1
        let s = (smooth ?? raw) + alpha * (raw - (smooth ?? raw))
        smooth = s
        let frame = Frame(t: t, raw: raw, smooth: s, motion: m)
        frames.append(frame)
        currentAngle = angles.angle(m)

        var events: [SwingEvent] = []
        stillSince = s < config.stillThreshold ? (stillSince ?? t) : nil

        // waiting out the follow thru
        if phase == .followThrough {
            if t - lastImpact > config.refractory && s < config.stillThreshold * 2 {
                phase = .idle
                angles.clear()
                currentAngle = nil
            } else {
                return events
            }
        }

        if let since = stillSince, t - since >= config.addressStillTime, phase != .address {
            phase = .address
            addressAt = t
            angles.setReference(m)
            currentAngle = 0
            events.append(.address(at: t))
        }

        if phase == .address && s > config.takeawayThreshold * 2 {
            phase = .backswing
            events.append(.takeaway(at: t))
        }

        // impact: wait for the peak to be clearly over
        if s >= config.impactMinPeak || peak != nil {
            if s > (peak?.smooth ?? 0) {
                peak = frame
                phase = .downswing
            } else if let p = peak, s < p.smooth * config.impactPeakDrop || t - p.t > config.impactPeakTimeout {
                peak = nil
                lastImpact = p.t
                phase = .followThrough
                events.append(analyze(impact: p))
                addressAt = nil
            }
        }
        return events
    }

    // look back from impact
    private func analyze(impact: Frame) -> SwingEvent {
        let all = frames.elements
        let before = all.filter { $0.t <= impact.t }
        guard let first = before.first else { return .rejected(reason: "no data", at: impact.t) }

        let topWindow = before.filter {
            (impact.t - config.topSearch.upperBound)...(impact.t - config.topSearch.lowerBound) ~= $0.t
        }
        guard let top = topWindow.min(by: { $0.smooth < $1.smooth }) else {
            return .rejected(reason: "too short", at: impact.t)
        }

        let humpWindow = before.filter {
            (top.t - config.humpSearch.upperBound)...(top.t - config.humpSearch.lowerBound) ~= $0.t
        }
        guard let hump = humpWindow.max(by: { $0.smooth < $1.smooth }), hump.smooth >= config.minBackswingHump else {
            return .rejected(reason: "no backswing", at: impact.t)
        }

        guard top.smooth < max(config.topAbsolute, config.maxTopRatio * hump.smooth) else {
            return .rejected(reason: "no clear top", at: impact.t)
        }

        // walk back from the hump till the wrist was basically still
        let beforeHump = before.filter { $0.t <= hump.t }
        let takeaway = beforeHump.last(where: { $0.smooth < config.takeawayThreshold })
        let clipped = takeaway == nil
        let takeawayT = takeaway?.t ?? first.t

        let back = top.t - takeawayT
        let down = impact.t - top.t
        let face = angles.faceAngle(impact.motion)

        guard config.downswing ~= down else {
            return .rejected(reason: down < config.downswing.lowerBound ? "downswing too fast" : "downswing too slow", at: impact.t)
        }
        guard clipped || config.backswing ~= back else {
            return .rejected(reason: back < config.backswing.lowerBound ? "backswing too short" : "backswing too slow", at: impact.t)
        }

        let backswingFrames = before.filter { $0.t >= takeawayT && $0.t <= top.t }
        let smoothness = Self.smoothness(backswingFrames, hump: hump.smooth, floor: config.smoothnessFloor, gain: config.smoothnessGain)

        let peakG = accel.elements
            .filter { abs($0.t - impact.t) <= 0.06 }
            .map(\.magnitude)
            .max() ?? 0

        var conf = min(1, impact.smooth / 14)
        if top.smooth > config.maxTopRatio * hump.smooth { conf *= 0.8 }
        if addressAt == nil { conf *= 0.9 }
        if clipped { conf *= 0.7 }

        let result = SwingResult(
            timestamp: .now,
            handedness: handedness,
            backswingDuration: back,
            downswingDuration: down,
            peakWristAngularVelocity: before.map(\.raw).suffix(20).max() ?? impact.raw,
            peakAcceleration: peakG,
            smoothnessScore: smoothness,
            pathBias: 0,  // avp turns faceAngle into curve
            confidence: conf,
            faceAngle: face
        )
        let timeline = SwingTimeline(address: addressAt, takeaway: clipped ? nil : takeawayT, top: top.t, impact: impact.t)
        return .impact(result, timeline)
    }

    // jitter in the backswing: raw vs a slow (80ms) moving avg, relative to how fast u swung
    static func smoothness(_ frames: [Frame], hump: Double, floor: Double, gain: Double) -> Double {
        guard frames.count > 10, hump > 0 else { return 0.5 }
        let window = 0.08
        var sq = 0.0
        var j = 0
        var sum = 0.0
        var lo = 0
        for (i, f) in frames.enumerated() {
            sum += f.raw
            while frames[lo].t < f.t - window {
                sum -= frames[lo].raw
                lo += 1
            }
            let avg = sum / Double(i - lo + 1)
            sq += (f.raw - avg) * (f.raw - avg)
            j += 1
        }
        let roughness = (sq / Double(j)).squareRoot() / hump
        return min(max(1 - max(roughness - floor, 0) * gain, 0), 1)
    }
}
