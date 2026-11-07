import Foundation
import Observation
import simd

// slow stuff only: are ur hands together + in front of u at address. fed every frame by HandClub
// from the shared HandTracking session, never tries to judge the swing itself
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

    static let maxGap: Float = 0.15  // m between palms, hands on a grip are ~8-12cm apart
    static let handHeight: ClosedRange<Float> = 0.55...1.15  // m off the floor at address
    static let maxSideways: Float = 0.25  // m off ur centerline

    func set(_ s: Status) {
        if s != status { status = s }
        if s != .good {
            goodSince = nil
        }
        if case .off = s { handsMid = nil }
    }

    func update(left: SIMD3<Float>?, right: SIMD3<Float>?) {
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

    // world origin = where u stood when the space opened, so x ~ ur centerline
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
