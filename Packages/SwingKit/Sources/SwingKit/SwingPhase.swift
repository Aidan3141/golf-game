// detector states, see M4 for the actual state machine
public enum SwingPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case address
    case backswing
    case top
    case downswing
    case impact
    case followThrough
}
