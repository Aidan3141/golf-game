import Foundation

// coords: x = right of target, y = up, z = downrange. meters
public struct FlightPoint: Sendable, Hashable {
    public var time: Double
    public var position: SIMD3<Double>
}

public struct FlightResult: Sendable, Hashable {
    public var points: [FlightPoint]
    public var landingIndex: Int  // first point on the ground after carry
    public var carry: Double  // m, tee -> first landing
    public var total: Double  // m, tee -> where it stops
    public var offline: Double  // m, + = right of target, at rest
    public var apex: Double  // m, max height
    public var duration: Double  // secs until stopped

    public var landingPoint: SIMD3<Double> { points[landingIndex].position }
    public var restPoint: SIMD3<Double> { points[points.count - 1].position }
}

public enum Units {
    public static let yardsPerMeter = 1.0936133
    public static func yards(_ meters: Double) -> Double { meters * yardsPerMeter }
    public static func meters(yards: Double) -> Double { yards / yardsPerMeter }
}

public enum FlightSimulator {
    public static func simulate(swing: SwingResult, tuning: FlightTuning = .standard) -> FlightResult {
        simulate(LaunchConditions(swing: swing, tuning: tuning), tuning: tuning)
    }

    // steps gravity + drag + lift/curve, then bounce + roll. pure, no randomness here
    public static func simulate(_ launch: LaunchConditions, tuning t: FlightTuning = .standard) -> FlightResult {
        let rad = Double.pi / 180
        let la = launch.launchAngle * rad
        let dir = launch.startDirection * rad
        var v = SIMD3(
            launch.ballSpeed * cos(la) * sin(dir),
            launch.ballSpeed * sin(la),
            launch.ballSpeed * cos(la) * cos(dir)
        )
        var p = SIMD3<Double>(0, 0, 0)

        // backspin axis points left (-x) so lift = axis x v goes up. tilt it to curve
        let tilt = launch.spinAxisTilt * rad
        let spinAxis = SIMD3(-cos(tilt) * cos(dir), sin(tilt), cos(tilt) * sin(dir))

        let k = t.aeroK
        var time = 0.0
        var nextOutput = 0.0
        var points: [FlightPoint] = []
        var landingIndex: Int?
        var landing = SIMD3<Double>(0, 0, 0)
        var apex = 0.0
        var rolling = false

        func record() {
            points.append(FlightPoint(time: time, position: p))
        }
        record()

        while time < t.maxFlightTime {
            time += t.timeStep

            if rolling {
                // simple linear slow down on the ground
                var flat = SIMD3(v.x, 0, v.z)
                let speed = (flat * flat).sum().squareRoot()
                let newSpeed = speed - t.rollDeceleration * t.timeStep
                if newSpeed <= 0 {
                    record()
                    break
                }
                flat *= newSpeed / speed
                v = flat
                p += v * t.timeStep
            } else {
                let speed = (v * v).sum().squareRoot()
                let spin = exp(-time / t.spinDecayTime)
                let drag = -k * t.dragCoefficient * speed * v
                let lift = k * t.liftCoefficient * spin * speed * cross(spinAxis, v)
                let accel = drag + lift + SIMD3(0, -t.gravity, 0)
                // semi-implicit euler, good enough at 240hz
                v += accel * t.timeStep
                p += v * t.timeStep
                apex = max(apex, p.y)

                if p.y <= 0 && v.y < 0 {
                    p.y = 0
                    if landingIndex == nil {
                        landing = p
                        record()
                        landingIndex = points.count - 1
                        nextOutput = time + t.outputInterval
                    }
                    v.y = -v.y * t.bounceRestitution
                    v.x *= t.bounceFriction
                    v.z *= t.bounceFriction
                    if v.y < t.rollStopSpeed {
                        v.y = 0
                        rolling = true
                    }
                }
            }

            if time >= nextOutput {
                record()
                nextOutput += t.outputInterval
            }
        }

        let rest = points[points.count - 1].position
        return FlightResult(
            points: points,
            landingIndex: landingIndex ?? points.count - 1,
            carry: (landing.x * landing.x + landing.z * landing.z).squareRoot(),
            total: (rest.x * rest.x + rest.z * rest.z).squareRoot(),
            offline: rest.x,
            apex: apex,
            duration: time
        )
    }

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
