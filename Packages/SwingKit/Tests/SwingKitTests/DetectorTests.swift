import Foundation
import Testing
@testable import SwingKit

// real swings from the watch, nov 5. tempo values worked out by hand from the plots
enum Fixtures {
    static let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static var all: [SwingRecording] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            try? SwingRecording.decode(Data(contentsOf: $0))
        }
    }
}

private func run(_ rec: SwingRecording, every: Int = 1, batch: Int = 200) -> [SwingEvent] {
    var d = SwingDetector()
    d.add(accel: rec.accel)
    let motion = rec.motion.enumerated().filter { $0.offset % every == 0 }.map(\.element)
    var events: [SwingEvent] = []
    // feed in ~1s chunks like batched updates do
    var i = 0
    while i < motion.count {
        events += d.add(motion: Array(motion[i..<min(i + batch, motion.count)]))
        i += batch
    }
    return events
}

private func impacts(_ e: [SwingEvent]) -> [(SwingResult, SwingTimeline)] {
    e.compactMap { if case .impact(let r, let t) = $0 { (r, t) } else { nil } }
}

@Suite struct DetectorTests {
    @Test func fixturesLoaded() {
        #expect(Fixtures.all.count == 10)
    }

    @Test(arguments: [1, 2])  // 200hz + downsampled to 100hz (live stream rate)
    func everyRealSwingDetectedOnce(every: Int) {
        for rec in Fixtures.all {
            let hits = impacts(run(rec, every: every))
            #expect(hits.count == 1, "\(rec.fileName): \(hits.count) impacts")
            guard let (r, t) = hits.first else { continue }
            #expect(r.peakWristAngularVelocity > 14, "\(rec.fileName)")
            #expect(r.downswingDuration > 0.25 && r.downswingDuration < 0.55, "\(rec.fileName) down \(r.downswingDuration)")
            #expect(r.confidence >= 0.5, "\(rec.fileName) conf \(r.confidence)")
            if t.takeaway != nil {
                #expect(r.tempoRatio > 2 && r.tempoRatio < 3.5, "\(rec.fileName) tempo \(r.tempoRatio)")
            }
        }
    }

    @Test func tempoMatchesHandMeasured() throws {
        // swing-20261105-143939: back ~0.95, down ~0.41 -> ~2.3
        let rec = try #require(Fixtures.all.first { $0.id.uuidString.hasPrefix("4932") })
        let (r, _) = try #require(impacts(run(rec)).first)
        #expect(abs(r.tempoRatio - 2.33) < 0.25, "tempo \(r.tempoRatio)")
        #expect(r.peakAcceleration > 9)
    }

    @Test func addressSeenWhenStillFirst() throws {
        let rec = try #require(Fixtures.all.first { $0.id.uuidString.hasPrefix("4932") })
        let e = run(rec)
        #expect(e.contains { if case .address = $0 { true } else { false } })
    }

    @Test func smoothnessInRange() {
        for rec in Fixtures.all {
            for (r, _) in impacts(run(rec)) {
                #expect(r.smoothnessScore > 0.5 && r.smoothnessScore < 0.9, "\(rec.fileName) \(r.smoothnessScore)")
            }
        }
    }

    // MARK: fake stuff that shouldnt count

    private func synth(_ f: (Double) -> Double, secs: Double = 4, hz: Double = 100) -> [MotionFrame] {
        stride(from: 0.0, to: secs, by: 1 / hz).map { t in
            MotionFrame(t: t, rotX: f(t), rotY: 0, rotZ: 0, userX: 0, userY: 0, userZ: 0,
                        gravX: 0, gravY: -1, gravZ: 0, qw: 1, qx: 0, qy: 0, qz: 0)
        }
    }

    @Test func stillWristJustAddress() {
        var d = SwingDetector()
        let e = d.add(motion: synth { _ in 0.1 })
        #expect(impacts(e).isEmpty)
        #expect(e.contains { if case .address = $0 { true } else { false } })
    }

    @Test func waggleIgnored() {
        var d = SwingDetector()
        let e = d.add(motion: synth { t in 3 * sin(2 * .pi * 2 * t) })
        #expect(impacts(e).isEmpty)
    }

    @Test func randomBigFlickRejected() {
        // spike w/ no backswing before it, like bumping ur arm
        var d = SwingDetector()
        let e = d.add(motion: synth { t in t > 2 && t < 2.08 ? 15 : 0.2 })
        #expect(impacts(e).isEmpty)
        #expect(e.contains { if case .rejected = $0 { true } else { false } })
    }

    @Test func noDoubleCountOnFollowThrough() throws {
        let rec = try #require(Fixtures.all.first)
        var d = SwingDetector()
        let e = d.add(motion: rec.motion)
        #expect(impacts(e).count == 1)
    }
}
