import Foundation

// wire format between watch / phone / vision pro. bump version on breaking changes
public enum MessagePayload: Codable, Sendable, Hashable {
    case swing(SwingResult)
    case ping
    case hello(device: String)  // first thing sent on a new connection
    case clubSample(ClubSample)  // live club, time already in the receivers clock
    case swingAt(SwingResult, impactTime: Double?)  // + when impact happened, receivers uptime clock
    case clockPing(t0: Double)  // phone -> avp, phones uptime
    case clockPong(t0: Double, t1: Double)  // avp -> phone, t1 = avps uptime when the ping landed
    case quickImpact(QuickImpact)  // watch saw impact, launch now, full swing follows
    case mode(SwingMode)  // avp -> phone -> watch, full swing or putting
}

public struct MessageEnvelope: Codable, Sendable, Hashable {
    // v2: live club carries angular velocity + synced sample time, clock ping/pong
    public static let currentVersion = 2

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
