// one raw sensor sample from the watch. units: accel in g, gyro in rad/s
public struct MotionSample: Codable, Sendable, Hashable {
    public var t: Double  // secs since capture start
    public var ax: Double
    public var ay: Double
    public var az: Double
    public var gx: Double
    public var gy: Double
    public var gz: Double

    public init(t: Double, ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
        self.t = t
        self.ax = ax
        self.ay = ay
        self.az = az
        self.gx = gx
        self.gy = gy
        self.gz = gz
    }

    public var accelMagnitude: Double { (ax * ax + ay * ay + az * az).squareRoot() }
    public var gyroMagnitude: Double { (gx * gx + gy * gy + gz * gz).squareRoot() }
}
