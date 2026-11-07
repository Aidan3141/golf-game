import ARKit
import Foundation
import Observation
import QuartzCore
import RealityKit
import SwingKit

// records everything about a shot so the mac can redraw it from the outside (stick figure,
// club, ball, watch). head + every hand joint + club + ball, every frame, world space.
// one json per shot in Documents/Showcase (Files app + share button in the window)
@MainActor
@Observable
final class ShowcaseRecorder {
    struct Frame: Codable {
        var t: Double  // headset uptime, relative to the first frame once written
        var head: [Float]?  // px py pz qx qy qz qw
        var left: [Float]?  // xyz per joint, same order as Log.joints
        var right: [Float]?
        var grip: [Float]?  // club grip + clubhead, if the hand club is showing
        var club: [Float]?
        var ball: [Float]?
        var watch: Double?  // watch club angle (rad)
        var phase: String
    }

    struct ShotInfo: Codable {
        var carryYd: Double
        var totalYd: Double
        var apexM: Double
        var offlineM: Double
        var flightSecs: Double
        var tempo: Double
        var backswing: Double
        var downswing: Double
        var wristSpeed: Double  // rad/s
        var smoothness: Double
        var pathBias: Double
        var face: Double?
        var provisional: Bool
        var refined: Bool
        var live: Bool
    }

    struct Log: Codable {
        var version = 1
        var createdAt: Date
        var handedness: String
        var clubSource: String
        var joints: [String]
        var rangeRoot: [Float]  // world from range root, 4x4 column major
        var tee: [Float]  // tee in world
        var launchT: Double  // when the ball launched, same clock as frames
        var shot: ShotInfo
        var frames: [Frame]
    }

    static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appending(path: "Showcase", directoryHint: .isDirectory)
    static let jointNames = HandSkeleton.JointName.allCases

    // arkit only runs while the range is open, so on + attached = recording
    var isOn = false {
        didSet { refresh() }
    }
    private(set) var status = "off"
    private(set) var lastFile: URL?

    @ObservationIgnored private weak var ball: Entity?
    @ObservationIgnored private weak var root: Entity?
    @ObservationIgnored private var ring: [Frame] = []
    @ObservationIgnored private var session: ARKitSession?
    @ObservationIgnored private var handSession: ARKitSession?
    @ObservationIgnored private var world: WorldTrackingProvider?
    @ObservationIgnored private var hands: HandTrackingProvider?
    @ObservationIgnored private var launch: (t: Double, root: simd_float4x4)?
    @ObservationIgnored private var running = false

    func attach(ball: Entity, root: Entity) {
        self.ball = ball
        self.root = root
        refresh()
    }

    func detach() {
        ball = nil
        root = nil
        refresh()
    }

    private func refresh() {
        let want = isOn && root != nil
        if want && !running { start() }
        if !want && running { stop() }
        if !want && isOn { status = "on, open the range" }
    }

    // MARK: tracking

    private func start() {
        running = true
        // own sessions so the club tracking stays untouched. hands in a separate one so if it
        // cant run next to the club's hand tracking we still get the head
        if WorldTrackingProvider.isSupported {
            let s = ARKitSession()
            let w = WorldTrackingProvider()
            session = s
            world = w
            Task {
                do { try await s.run([w]) } catch { self.status = "head failed: \(error.localizedDescription)" }
            }
        }
        if HandTrackingProvider.isSupported {
            let s = ARKitSession()
            let h = HandTrackingProvider()
            handSession = s
            hands = h
            Task {
                do { try await s.run([h]) } catch { self.status = "hands failed: \(error.localizedDescription)" }
            }
        }
        status = world == nil ? "on (no arkit here, club + ball only)" : "on"
    }

    private func stop() {
        running = false
        session?.stop()
        handSession?.stop()
        session = nil
        handSession = nil
        world = nil
        hands = nil
        ring.removeAll()
        launch = nil
        status = "off"
    }

    // MARK: frames

    // every frame from the hand club tick
    func tick(grip: SIMD3<Float>?, club: SIMD3<Float>?, watch: Double?, phase: String) {
        guard isOn else { return }
        var f = Frame(t: ProcessInfo.processInfo.systemUptime, phase: phase)
        let now = CACurrentMediaTime()
        if let w = world, w.state == .running, let d = w.queryDeviceAnchor(atTimestamp: now), d.isTracked {
            let m = d.originFromAnchorTransform
            let q = HandTracking.rotation(of: m)
            f.head = [m.columns.3.x, m.columns.3.y, m.columns.3.z, q.imag.x, q.imag.y, q.imag.z, q.real]
        }
        if let h = hands, h.state == .running {
            let a = h.latestAnchors
            f.left = Self.joints(a.leftHand)
            f.right = Self.joints(a.rightHand)
        }
        f.grip = grip.map { [$0.x, $0.y, $0.z] }
        f.club = club.map { [$0.x, $0.y, $0.z] }
        if let b = ball?.position(relativeTo: nil) { f.ball = [b.x, b.y, b.z] }
        f.watch = watch
        ring.append(f)
        if ring.count > 1800 { ring.removeFirst(ring.count - 1800) }  // ~20s at 90fps
    }

    private static func joints(_ a: HandAnchor?) -> [Float]? {
        guard let a, a.isTracked, let skel = a.handSkeleton else { return nil }
        let m = a.originFromAnchorTransform
        var out: [Float] = []
        out.reserveCapacity(jointNames.count * 3)
        for name in jointNames {
            let p = (m * skel.joint(name).anchorFromJointTransform).columns.3
            out += [p.x, p.y, p.z]
        }
        return out
    }

    // MARK: shots

    // ball just launched (not a mid flight refine)
    func launched() {
        guard isOn, let root else { return }
        launch = (ProcessInfo.processInfo.systemUptime, root.transformMatrix(relativeTo: nil))
    }

    // ball stopped + went back to the tee. write 4s before launch -> now
    func finished(_ shot: Shot?, handedness: Handedness, source: String) {
        guard isOn, let launch, let shot else { return }
        self.launch = nil
        let frames = ring.filter { $0.t >= launch.t - 4 }
        guard let first = frames.first else { return }
        let rel = frames.map { f -> Frame in
            var f = f
            f.t = ((f.t - first.t) * 1000).rounded() / 1000
            return f
        }
        let s = shot.swing
        let fl = shot.flight
        let info = ShotInfo(
            carryYd: Units.yards(fl.carry), totalYd: Units.yards(fl.total), apexM: fl.apex, offlineM: fl.offline,
            flightSecs: fl.duration, tempo: s.tempoRatio, backswing: s.backswingDuration, downswing: s.downswingDuration,
            wristSpeed: s.peakWristAngularVelocity, smoothness: s.smoothnessScore, pathBias: s.pathBias, face: s.faceAngle,
            provisional: shot.provisional, refined: shot.refined, live: shot.live)
        let r = launch.root
        let tee = r * SIMD4<Float>(RangeScene.teePosition, 1)
        let log = Log(
            createdAt: .now, handedness: handedness.rawValue, clubSource: source,
            joints: Self.jointNames.map(\.description),
            rangeRoot: [r.columns.0, r.columns.1, r.columns.2, r.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
            tee: [tee.x, tee.y, tee.z], launchT: launch.t - first.t, shot: info, frames: rel)
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd-HHmmss"
            let url = Self.directory.appending(path: "showcase-\(df.string(from: .now)).json")
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            try e.encode(log).write(to: url)
            status = String(format: "saved %.0f yd shot", info.carryYd)
            lastFile = url
        } catch {
            status = "save failed: \(error.localizedDescription)"
        }
    }

    static func all() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
