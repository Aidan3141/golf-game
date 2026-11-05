import Charts
import SwiftUI
import SwingKit

// plots for eyeballing swings + tuning the detector later
struct RecordingDetailView: View {
    let item: RecordingStore.Item
    @State private var showAxes = false

    private var rec: SwingRecording { item.recording }

    // rerun the detector on the saved data so we can see where it put the phases
    private var detected: (SwingResult, SwingTimeline)? {
        var d = SwingDetector(handedness: rec.handedness)
        d.add(accel: rec.accel)
        for e in d.add(motion: rec.motion) {
            if case .impact(let r, let t) = e { return (r, t) }
        }
        return nil
    }

    @ChartContentBuilder
    private func phaseLines(_ t: SwingTimeline?) -> some ChartContent {
        if let t {
            if let a = t.takeaway {
                RuleMark(x: .value("takeaway", a))
                    .foregroundStyle(.green)
                    .annotation(position: .top, alignment: .leading) { Text("take").font(.caption2) }
            }
            RuleMark(x: .value("top", t.top))
                .foregroundStyle(.yellow)
                .annotation(position: .top, alignment: .leading) { Text("top").font(.caption2) }
            RuleMark(x: .value("impact", t.impact))
                .foregroundStyle(.red)
                .annotation(position: .top, alignment: .leading) { Text("impact").font(.caption2) }
        }
    }

    var body: some View {
        let det = detected
        List {
            Section("detector") {
                if let (r, _) = det {
                    LabeledContent("Tempo", value: String(format: "%.2f : 1", r.tempoRatio))
                    LabeledContent("Back / down", value: String(format: "%.2fs / %.2fs", r.backswingDuration, r.downswingDuration))
                    LabeledContent("Smoothness", value: String(format: "%.0f%%", r.smoothnessScore * 100))
                    LabeledContent("Confidence", value: String(format: "%.0f%%", r.confidence * 100))
                } else {
                    Text("no swing found").foregroundStyle(.secondary)
                }
                if let note = rec.note {
                    LabeledContent("Note", value: note)
                }
                Toggle("Show x/y/z", isOn: $showAxes)
            }

            Section("acceleration (g)") {
                Chart {
                    if showAxes {
                        ForEach(axisPoints(rec.accel.map { ($0.t, $0.x, $0.y, $0.z) }), id: \.self) { p in
                            LineMark(x: .value("t", p.t), y: .value("g", p.v))
                                .foregroundStyle(by: .value("axis", p.axis))
                        }
                    } else {
                        ForEach(rec.accel, id: \.t) { a in
                            LineMark(x: .value("t", a.t), y: .value("g", a.magnitude))
                        }
                    }
                    phaseLines(det?.1)
                }
                .chartXAxisLabel("secs")
                .frame(height: 220)
            }

            Section("rotation (rad/s)") {
                Chart {
                    if showAxes {
                        ForEach(axisPoints(rec.motion.map { ($0.t, $0.rotX, $0.rotY, $0.rotZ) }), id: \.self) { p in
                            LineMark(x: .value("t", p.t), y: .value("rad/s", p.v))
                                .foregroundStyle(by: .value("axis", p.axis))
                        }
                    } else {
                        ForEach(rec.motion, id: \.t) { m in
                            LineMark(x: .value("t", m.t), y: .value("rad/s", m.rotationMagnitude))
                        }
                        .foregroundStyle(.orange)
                    }
                    phaseLines(det?.1)
                }
                .chartXAxisLabel("secs")
                .frame(height: 220)
            }

            Section("info") {
                LabeledContent("Peak accel", value: String(format: "%.1f g", rec.accel.map(\.magnitude).max() ?? 0))
                LabeledContent("Peak rotation", value: String(format: "%.1f rad/s", rec.motion.map(\.rotationMagnitude).max() ?? 0))
                LabeledContent("Samples", value: "\(rec.accel.count) accel · \(rec.motion.count) motion")
                LabeledContent("Rates", value: String(format: "%.0f / %.0f Hz", rec.measuredAccelHz, rec.measuredMotionHz))
                LabeledContent("Source", value: rec.source)
                LabeledContent("Wrist", value: rec.wrist)
                LabeledContent("Hand", value: rec.handedness.rawValue)
            }
        }
        .navigationTitle(Text(rec.startedAt, format: .dateTime.hour().minute().second()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: item.url)
        }
    }

    private struct AxisPoint: Hashable {
        let t: Double
        let v: Double
        let axis: String
    }

    private func axisPoints(_ rows: [(Double, Double, Double, Double)]) -> [AxisPoint] {
        rows.flatMap { r in
            [AxisPoint(t: r.0, v: r.1, axis: "x"), AxisPoint(t: r.0, v: r.2, axis: "y"), AxisPoint(t: r.0, v: r.3, axis: "z")]
        }
    }
}
