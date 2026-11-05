import simd

// turns watch attitude into a swing angle + face angle, relative to the address pose.
// all in the watch body frame so we dont care which way u face
public struct SwingAngleTracker: Sendable {
    // avg takeaway axis from the nov 5 swings (left wrist), used till we see the real one
    public static let defaultSwingAxis = simd_normalize(SIMD3<Double>(0.62, 0.76, 0.15))
    static let axisLockAngle = 0.4  // rad of motion before we trust the swing axis

    public private(set) var hasReference = false
    private var ref = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var axis: SIMD3<Double>?

    public init() {}

    public mutating func setReference(_ f: MotionFrame) {
        ref = Self.quat(f)
        axis = nil
        hasReference = true
    }

    public mutating func clear() {
        hasReference = false
        axis = nil
    }

    public var swingAxis: SIMD3<Double> { axis ?? Self.defaultSwingAxis }

    // signed radians along the swing axis. + = backswing, ~0 at impact, - = follow thru
    public mutating func angle(_ f: MotionFrame) -> Double? {
        guard hasReference else { return nil }
        let v = Self.rotationVector(from: ref, to: Self.quat(f))
        if axis == nil, simd_length(v) > Self.axisLockAngle {
            axis = simd_normalize(v)
        }
        return simd_dot(v, swingAxis)
    }

    // forearm roll at impact vs address, degrees. its the twist that isnt part of the swing,
    // roughly the watch x axis (along the forearm) w/ the swing axis taken out.
    // which sign = open is calibrated on the avp side
    public func faceAngle(_ f: MotionFrame) -> Double? {
        guard hasReference else { return nil }
        let v = Self.rotationVector(from: ref, to: Self.quat(f))
        let a = swingAxis
        let x = SIMD3<Double>(1, 0, 0)
        let roll = simd_normalize(x - simd_dot(x, a) * a)
        return simd_dot(v, roll) * 180 / .pi
    }

    static func quat(_ f: MotionFrame) -> simd_quatd {
        simd_normalize(simd_quatd(ix: f.qx, iy: f.qy, iz: f.qz, r: f.qw))
    }

    // body frame rotation from a to b as axis * angle (shortest way)
    static func rotationVector(from a: simd_quatd, to b: simd_quatd) -> SIMD3<Double> {
        var d = a.inverse * b
        if d.real < 0 { d = simd_quatd(vector: -d.vector) }
        let s = simd_length(d.imag)
        guard s > 1e-9 else { return .zero }
        let angle = 2 * atan2(s, d.real)
        return d.imag / s * angle
    }
}
