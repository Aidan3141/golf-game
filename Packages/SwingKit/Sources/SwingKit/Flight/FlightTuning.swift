// every knob for ball flight in one place. tweak here, not in the sim code
public struct FlightTuning: Sendable, Hashable {
    // physics
    public var gravity = 9.81  // m/s^2
    public var dragCoefficient = 0.25
    public var liftCoefficient = 0.25  // from backspin, keeps irons up
    public var spinDecayTime = 6.0  // secs, lift fades as spin dies
    public var airDensity = 1.225  // kg/m^3
    public var ballMass = 0.04593  // kg
    public var ballRadius = 0.02135  // m

    // swing -> launch
    public var speedPerWristRadPerSec = 2.35  // ball m/s per rad/s of wrist speed
    public var minBallSpeed = 12.0  // m/s
    public var maxBallSpeed = 75.0  // m/s
    public var launchAngleDegrees = 18.0  // ~7 iron
    public var smoothnessSpeedPenalty = 0.15  // 0 smooth = -15% speed
    public var maxRandomLaunchAngleDegrees = 4.0  // at smoothness 0
    public var maxRandomStartDegrees = 5.0  // at smoothness 0
    public var startLineDegreesPerPathBias = 3.0  // in-to-out starts a bit right (rh)
    public var curveDegreesPerPathBias = 45.0  // spin axis tilt, exaggerated on purpose
    public var tempoCurveGain = 1.5  // how much bad tempo boosts curve
    public var targetTempo = 3.0
    public var maxSpinAxisTiltDegrees = 60.0

    // ground
    public var bounceRestitution = 0.3  // vertical speed kept on bounce
    public var bounceFriction = 0.6  // horizontal speed kept on bounce
    public var rollStopSpeed = 1.2  // below this vertical speed we just roll
    public var rollDeceleration = 3.0  // m/s^2 on fairway

    // sim
    public var timeStep = 1.0 / 240.0
    public var outputInterval = 1.0 / 60.0  // one point per frame-ish
    public var maxFlightTime = 20.0

    public init() {}

    public static let standard = FlightTuning()

    // drag/lift accel = k * |v| * stuff, k = 0.5 * rho * area / mass
    var aeroK: Double {
        0.5 * airDensity * (Double.pi * ballRadius * ballRadius) / ballMass
    }
}
