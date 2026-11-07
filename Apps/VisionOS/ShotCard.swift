import SwiftUI
import SwingKit

// floats in the range after each shot
struct ShotCard: View {
    let shot: Shot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f", Units.yards(shot.flight.carry)))
                    .font(.system(size: 92, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("yd carry")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f total", Units.yards(shot.flight.total)))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                stat("Tempo", String(format: "%.1f : 1", shot.swing.tempoRatio), color: tempoColor)
                stat("Smooth", String(format: "%.0f%%", shot.swing.smoothnessScore * 100),
                     color: shot.swing.smoothnessScore >= Coach.smoothGood ? .green : .orange)
                stat("Curve", curveText, color: .primary)
            }

            TempoBar(ratio: shot.swing.tempoRatio)

            VStack(alignment: .leading, spacing: 4) {
                Text(shot.tip.title)
                    .font(.title3.weight(.bold))
                Text(shot.tip.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(width: 640)
        .glassBackgroundEffect()
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }
    }

    private var tempoColor: Color {
        Coach.tempoGood ~= shot.swing.tempoRatio ? .green : .orange
    }

    private var curveText: String {
        let yd = Units.yards(shot.flight.offline)
        if abs(yd) < 3 { return "straight" }
        return String(format: "%.0f %@", abs(yd), yd > 0 ? "R" : "L")
    }
}

// where ur tempo lands vs the 3:1 sweet spot
struct TempoBar: View {
    let ratio: Double
    static let range = 1.5...4.5

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (r: Double) in CGFloat((r - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.green.opacity(0.5))
                    .frame(width: x(Coach.tempoGood.upperBound) - x(Coach.tempoGood.lowerBound))
                    .offset(x: x(Coach.tempoGood.lowerBound))
                Circle().fill(.white)
                    .frame(width: 18, height: 18)
                    .offset(x: min(max(x(ratio), 0), w) - 9)
            }
        }
        .frame(height: 18)
        .overlay(alignment: .bottom) {
            HStack {
                Text("rushed"); Spacer(); Text("3 : 1"); Spacer(); Text("slow")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .offset(y: 18)
        }
        .padding(.bottom, 14)
    }
}
