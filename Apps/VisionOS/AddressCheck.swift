import ARKit
import Foundation
import Observation
import simd

// slow stuff only: are ur hands together + in front of u at address. never tries to follow the swing
@MainActor
@Observable
final class AddressCheck {
    enum Status: Equatable {
        case off
        case unsupported
        case denied
        case noHands
        case good
        case hint(String)

        var label: String {
            switch self {
            case .off: "off"
            case .unsupported: "not supported here"
            case .denied: "hand tracking not allowed"
            case .noHands: "cant see ur hands"
            case .good: "✅ good grip spot"
            case .hint(let h): h
            }
        }
    }

    private(set) var status = Status.off
    // world space, only when both hands are tracked. not observed, read by the club snapper
    @ObservationIgnored private(set) var handsMid: SIMD3<Float>?
    @ObservationIgnored private(set) var goodSince: Double?
    @ObservationIgnored private var session: ARKitSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var left: SIMD3<Float>?
    @ObservationIgnored private var right: SIMD3<Float>?

    static let maxGap: Float = 0.12  // m between wrists, hands on the grip are ~5-8cm
    static let handHeight: ClosedRange<Float> = 0.55...1.15  // m off the floor at address
    static let maxSideways: Float = 0.25  // m off ur centerline

    func start() {
        guard task == nil else { return }
        guard HandTrackingProvider.isSupported else {
            status = .unsupported
            return
        }
        let s = ARKitSession()
        let hands = HandTrackingProvider()
        session = s
        status = .noHands
        task = Task {
            do {
                try await s.run([hands])
            } catch {
                self.status = .denied
                return
            }
            for await update in hands.anchorUpdates {
                self.handle(update.anchor)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.stop()
        session = nil
        left = nil
        right = nil
        handsMid = nil
        goodSince = nil
        status = .off
    }

    private func handle(_ anchor: HandAnchor) {
        var p: SIMD3<Float>?
        if anchor.isTracked, let wrist = anchor.handSkeleton?.joint(.wrist), wrist.isTracked {
            let m = anchor.originFromAnchorTransform * wrist.anchorFromJointTransform
            p = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        if anchor.chirality == .left { left = p } else { right = p }
        let new = Self.evaluate(left: left, right: right)
        if new != status { status = new }  // only poke observers when it actually changes
        if let l = left, let r = right {
            handsMid = (l + r) / 2
        } else {
            handsMid = nil
        }
        if new == .good {
            goodSince = goodSince ?? ProcessInfo.processInfo.systemUptime
        } else {
            goodSince = nil
        }
    }

    // world origin = where u stood when the range opened, so x ~ ur centerline
    static func evaluate(left: SIMD3<Float>?, right: SIMD3<Float>?) -> Status {
        guard let l = left, let r = right else { return .noHands }
        if simd_distance(l, r) > maxGap { return .hint("bring ur hands together") }
        let mid = (l + r) / 2
        if mid.y > handHeight.upperBound { return .hint("hands lower, let ur arms hang") }
        if mid.y < handHeight.lowerBound { return .hint("stand up a bit taller") }
        if abs(mid.x) > maxSideways { return .hint("hands more in front of u") }
        return .good
    }
}
