import Charts
import SwiftData
import SwiftUI
import SwingKit

// every real swing, newest first, w/ a tempo trend chart
struct HistoryView: View {
    @Query(sort: \SwingRecord.date, order: .reverse) private var swings: [SwingRecord]
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            if swings.count >= 2 {
                Section("tempo over time") {
                    Chart {
                        RuleMark(y: .value("goal", 3.0))
                            .foregroundStyle(.green.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        ForEach(swings.reversed()) { s in
                            PointMark(x: .value("date", s.date), y: .value("tempo", s.tempo))
                                .foregroundStyle(Coach.tempoGood ~= s.tempo ? .green : .orange)
                        }
                    }
                    .chartYScale(domain: 1...4.5)
                    .frame(height: 200)
                }
                Section("stats") {
                    let tempos = swings.map(\.tempo)
                    let avg = tempos.reduce(0, +) / Double(tempos.count)
                    LabeledContent("Swings", value: "\(swings.count)")
                    LabeledContent("Avg tempo", value: String(format: "%.2f : 1", avg))
                    LabeledContent("In the zone", value: String(format: "%.0f%%", 100 * Double(tempos.filter { Coach.tempoGood ~= $0 }.count) / Double(tempos.count)))
                    LabeledContent("Avg smoothness", value: String(format: "%.0f%%", 100 * swings.map(\.smoothness).reduce(0, +) / Double(swings.count)))
                }
            }

            ForEach(groupedByDay, id: \.0) { day, items in
                Section(day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(items) { s in
                        HistoryRow(swing: s)
                    }
                    .onDelete { idx in
                        idx.map { items[$0] }.forEach(context.delete)
                    }
                }
            }
        }
        .overlay {
            if swings.isEmpty {
                ContentUnavailableView("No swings yet", systemImage: "figure.golf",
                                       description: Text("swings from the watch show up here"))
            }
        }
        .navigationTitle("History")
    }

    private var groupedByDay: [(Date, [SwingRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: swings) { cal.startOfDay(for: $0.date) }
        return groups.sorted { $0.key > $1.key }
    }
}

struct HistoryRow: View {
    let swing: SwingRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f : 1", swing.tempo))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Coach.tempoGood ~= swing.tempo ? .green : .orange)
                Text(swing.tipTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f yd", swing.carryYards))
                    .font(.subheadline.monospacedDigit())
                Text(swing.date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
