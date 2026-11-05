import Foundation
import Observation
import SwingKit

// recordings are just json files in Documents/Recordings
@MainActor
@Observable
final class RecordingStore {
    struct Item: Identifiable, Hashable {
        let url: URL
        let recording: SwingRecording
        var id: UUID { recording.id }
    }

    nonisolated static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appending(path: "Recordings", directoryHint: .isDirectory)

    private(set) var items: [Item] = []

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        items = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let rec = try? SwingRecording.decode(data) else { return nil }
                return Item(url: url, recording: rec)
            }
            .sorted { $0.recording.startedAt > $1.recording.startedAt }
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }
}
