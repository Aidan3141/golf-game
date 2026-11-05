import Foundation
import Observation
import SwingKit

// last few live swings for the phone screen. real history w/ swiftdata comes in M6
@MainActor
@Observable
final class SwingFeed {
    struct Entry: Identifiable {
        let swing: SwingResult
        let watchLatency: Double
        var id: UUID { swing.id }
    }

    private(set) var entries: [Entry] = []

    func add(_ swing: SwingResult, watchLatency: Double) {
        entries.insert(Entry(swing: swing, watchLatency: watchLatency), at: 0)
        entries = Array(entries.prefix(20))
    }
}
