import Foundation
import simd

// same json the avp ShowcaseRecorder writes
struct Recording: Codable {
    struct Frame: Codable {
        var t: Double
        var head: [Float]?
        var left: [Float]?
        var right: [Float]?
        var grip: [Float]?
        var club: [Float]?
        var ball: [Float]?
        var watch: Double?
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
        var wristSpeed: Double
        var smoothness: Double
        var pathBias: Double
        var face: Double?
        var provisional: Bool
        var refined: Bool
        var live: Bool
    }

    var handedness: String
    var clubSource: String
    var joints: [String]
    var rangeRoot: [Float]
    var tee: [Float]
    var launchT: Double
    var shot: ShotInfo
    var frames: [Frame]

    static func load(_ path: String) throws -> Recording {
        try JSONDecoder().decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    var rootMatrix: simd_float4x4 {
        let r = rangeRoot
        return simd_float4x4(columns: (
            [r[0], r[1], r[2], r[3]], [r[4], r[5], r[6], r[7]],
            [r[8], r[9], r[10], r[11]], [r[12], r[13], r[14], r[15]]
        ))
    }

    var isRighty: Bool { handedness == "right" }
}

// one moment of the recording, everything interpolated
struct Pose {
    var head: (p: SIMD3<Float>, q: simd_quatf)?
    var left: [String: SIMD3<Float>]?
    var right: [String: SIMD3<Float>]?
    var grip: SIMD3<Float>?
    var club: SIMD3<Float>?
    var ball: SIMD3<Float>?
    var phase: String
}

extension Recording {
    func index(at t: Double) -> Int {
        var lo = 0
        var hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func pose(at t: Double) -> Pose {
        let i = index(at: t)
        let j = min(i + 1, frames.count - 1)
        let a = frames[i]
        let b = frames[j]
        let x = Float(b.t > a.t ? min(max((t - a.t) / (b.t - a.t), 0), 1) : 0)
        func v3(_ p: [Float]?, _ q: [Float]?) -> SIMD3<Float>? {
            guard let p else { return q.map { SIMD3($0[0], $0[1], $0[2]) } }
            let pa = SIMD3(p[0], p[1], p[2])
            guard let q else { return pa }
            return simd_mix(pa, SIMD3(q[0], q[1], q[2]), SIMD3(repeating: x))
        }
        func hand(_ p: [Float]?, _ q: [Float]?) -> [String: SIMD3<Float>]? {
            guard let p else { return nil }
            var out: [String: SIMD3<Float>] = [:]
            for (k, name) in joints.enumerated() {
                let pa = SIMD3(p[k * 3], p[k * 3 + 1], p[k * 3 + 2])
                if let q {
                    out[name] = simd_mix(pa, SIMD3(q[k * 3], q[k * 3 + 1], q[k * 3 + 2]), SIMD3(repeating: x))
                } else {
                    out[name] = pa
                }
            }
            return out
        }
        var head: (SIMD3<Float>, simd_quatf)?
        if let h = a.head {
            let qa = simd_quatf(ix: h[3], iy: h[4], iz: h[5], r: h[6])
            var p = SIMD3(h[0], h[1], h[2])
            var q = qa
            if let h2 = b.head {
                p = simd_mix(p, SIMD3(h2[0], h2[1], h2[2]), SIMD3(repeating: x))
                q = simd_slerp(qa, simd_quatf(ix: h2[3], iy: h2[4], iz: h2[5], r: h2[6]), x)
            }
            head = (p, q)
        }
        return Pose(head: head, left: hand(a.left, b.left), right: hand(a.right, b.right),
                    grip: v3(a.grip, b.grip), club: v3(a.club, b.club), ball: v3(a.ball, b.ball),
                    phase: a.phase)
    }
}
