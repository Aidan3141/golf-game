import Foundation

// wire format between watch / phone / vision pro. bump version on breaking changes
public enum MessagePayload: Codable, Sendable, Hashable {
    case swing(SwingResult)
    case ping
    case hello(device: String)  // first thing sent on a new connection
    case club(angle: Double, phase: SwingPhase)  // live swing angle (rad from address), ~25hz
}

public struct MessageEnvelope: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public let version: Int
    public let sentAt: Date
    public let payload: MessagePayload

    public init(payload: MessagePayload, sentAt: Date = .now, version: Int = MessageEnvelope.currentVersion) {
        self.version = version
        self.sentAt = sentAt
        self.payload = payload
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MessageEnvelope {
        try decoder.decode(MessageEnvelope.self, from: data)
    }

    // iso8601 so it reads ok when debugging
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
