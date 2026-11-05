import Charts
import SwiftUI
import SwingKit

// plots for eyeballing swings + tuning the detector later
struct RecordingDetailView: View {
    let item: RecordingStore.Item
    @State private var showAxes = false

    private var rec: SwingRecording { item.recording }

    var body: some View {
        List {
            Section {
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
