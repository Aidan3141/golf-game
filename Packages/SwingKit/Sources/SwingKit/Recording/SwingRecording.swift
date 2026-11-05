import Foundation

// raw accel, g. t = secs since recording start
public struct AccelSample: Codable, Sendable, Hashable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(t: Double, x: Double, y: Double, z: Double) {
        self.t = t
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

// fused device motion. rot in rad/s, accel in g, attitude quaternion
public struct MotionFrame: Codable, Sendable, Hashable {
    public var t: Double
    public var rotX: Double, rotY: Double, rotZ: Double
    public var userX: Double, userY: Double, userZ: Double
    public var gravX: Double, gravY: Double, gravZ: Double
    public var qw: Double, qx: Double, qy: Double, qz: Double

    public init(
        t: Double,
        rotX: Double, rotY: Double, rotZ: Double,
        userX: Double, userY: Double, userZ: Double,
        gravX: Double, gravY: Double, gravZ: Double,
        qw: Double, qx: Double, qy: Double, qz: Double
    ) {
        self.t = t
        self.rotX = rotX; self.rotY = rotY; self.rotZ = rotZ
        self.userX = userX; self.userY = userY; self.userZ = userZ
        self.gravX = gravX; self.gravY = gravY; self.gravZ = gravZ
        self.qw = qw; self.qx = qx; self.qy = qy; self.qz = qz
    }

    public var rotationMagnitude: Double { (rotX * rotX + rotY * rotY + rotZ * rotZ).squareRoot() }
    public var userAccelMagnitude: Double { (userX * userX + userY * userY + userZ * userZ).squareRoot() }
}

// one capture from the watch, sent to the phone as a json file
public struct SwingRecording: Codable, Sendable, Hashable, Identifiable {
    public static let currentVersion = 1

    public var version = SwingRecording.currentVersion
    public var id: UUID
    public var startedAt: Date
    public var duration: Double
    public var handedness: Handedness
    public var wrist: String  // "left" / "right", where the watch is
    public var source: String  // "batched" or "motionManager"
    public var accelHz: Double  // reported rate
    public var motionHz: Double
    public var accel: [AccelSample]
    public var motion: [MotionFrame]
    public var note: String?

    public init(
        id: UUID = UUID(), startedAt: Date, duration: Double, handedness: Handedness, wrist: String,
        source: String, accelHz: Double, motionHz: Double,
        accel: [AccelSample], motion: [MotionFrame], note: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.handedness = handedness
        self.wrist = wrist
        self.source = source
        self.accelHz = accelHz
        self.motionHz = motionHz
        self.accel = accel
        self.motion = motion
        self.note = note
    }

    // measured rates from the actual samples, reported ones can lie
    public var measuredAccelHz: Double { Self.rate(accel.map(\.t)) }
    public var measuredMotionHz: Double { Self.rate(motion.map(\.t)) }

    private static func rate(_ ts: [Double]) -> Double {
        guard let first = ts.first, let last = ts.last, last > first else { return 0 }
        return Double(ts.count - 1) / (last - first)
    }

    public var fileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "swing-\(f.string(from: startedAt))-\(id.uuidString.prefix(4)).json"
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> SwingRecording {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SwingRecording.self, from: data)
    }

    // csv for plotting in whatever. two sections, accel then motion
    public func accelCSV() -> String {
        var s = "t,ax,ay,az\n"
        for a in accel {
            s += "\(a.t),\(a.x),\(a.y),\(a.z)\n"
        }
        return s
    }

    public func motionCSV() -> String {
        var s = "t,rx,ry,rz,ux,uy,uz,gx,gy,gz,qw,qx,qy,qz\n"
        for m in motion {
            s += "\(m.t),\(m.rotX),\(m.rotY),\(m.rotZ),\(m.userX),\(m.userY),\(m.userZ),\(m.gravX),\(m.gravY),\(m.gravZ),\(m.qw),\(m.qx),\(m.qy),\(m.qz)\n"
        }
        return s
    }
}
