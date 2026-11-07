import SwiftData
import SwiftUI
import SwingKit

@main
struct GolfGamePhoneApp: App {
    @State private var connectivity = PhoneConnectivity()
    @State private var store = RecordingStore()
    @State private var sender = NetworkSwingSender()
    @State private var feed = SwingFeed()
    @State private var ble = PhoneBLELink()
    private let container: ModelContainer = {
        do {
            return try ModelContainer(for: SwingRecord.self)
        } catch {
            fatalError("swiftdata store broke: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            root
                .environment(connectivity)
                .environment(store)
                .environment(sender)
                .environment(feed)
                .environment(ble)
                .onAppear {
                    store.reload()
                    sender.start()
                    // relay only works w/ the app open, so dont let the screen lock
                    UIApplication.shared.isIdleTimerDisabled = true
                    connectivity.onReceive = { [store] in store.reload() }
                    sender.onMode = { [connectivity] mode in
                        connectivity.send(mode: mode)
                    }
                    // club samples come over bluetooth (fast lane) or watchconnectivity, same deal
                    let forward: (ClubSample) -> Void = { [sender] sample in
                        // already too old to be useful, dont bother the headset
                        if let t = sample.time, ProcessInfo.processInfo.systemUptime - t > 1 { return }
                        sender.send(club: sample)
                    }
                    connectivity.onClub = forward
                    ble.onClub = forward
                    ble.onImpact = { [sender] q in sender.send(quickImpact: q) }
                    ble.start()
                    connectivity.onSwing = { [sender, feed, container] swing, impact in
                        sender.send(swing, impactPhoneTime: impact)  // headset first, everything else can wait
                        feed.add(swing, watchLatency: impact.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
                        let ctx = container.mainContext
                        ctx.insert(SwingRecord(swing))
                        try? ctx.save()
                    }
                }
        }
        .modelContainer(container)
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        // `-seedHistory` fills fake swings, `-openHistory` starts on the history screen. sim testing
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-seedHistory") {
            let _ = Self.seed(container.mainContext)
        }
        if args.contains("-openHistory") {
            NavigationStack { HistoryView() }
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }

    #if DEBUG
    @MainActor
    private static func seed(_ ctx: ModelContext) {
        guard (try? ctx.fetchCount(FetchDescriptor<SwingRecord>())) == 0 else { return }
        for i in 0..<18 {
            let s = SwingResult(
                timestamp: Date.now.addingTimeInterval(Double(i - 18) * 3600 * 5),
                handedness: .right,
                backswingDuration: .random(in: 0.7...1.1),
                downswingDuration: .random(in: 0.28...0.42),
                peakWristAngularVelocity: .random(in: 15...21),
                peakAcceleration: 11, smoothnessScore: .random(in: 0.55...0.85),
                pathBias: 0, confidence: 0.9
            )
            ctx.insert(SwingRecord(s))
        }
        try? ctx.save()
    }
    #endif
}
