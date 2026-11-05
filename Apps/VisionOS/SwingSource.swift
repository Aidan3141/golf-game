import SwingKit

// anything that hands us swings. mock now, network relay later
@MainActor
protocol SwingSource: AnyObject {
    var swings: AsyncStream<SwingResult> { get }
}

@MainActor
final class MockSwingSource: SwingSource {
    let swings: AsyncStream<SwingResult>
    private let continuation: AsyncStream<SwingResult>.Continuation

    init() {
        (swings, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    func send(_ swing: SwingResult) {
        continuation.yield(swing)
    }
}
