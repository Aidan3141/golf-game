import Network

// iphone -> vision pro link settings, shared by both apps
enum SwingLink {
    static let serviceType = "_golfgame._tcp"
    static let serviceName = "Golf Game"

    // peer to peer = awdl, so it works w/o a shared wifi (campus wifi blocks bonjour)
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.noDelay = true  // tiny msgs, send right away
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }
}

enum LinkState: Equatable, Sendable {
    case off
    case searching  // phone: browsing, avp: listening
    case connected(String)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    var label: String {
        switch self {
        case .off: "off"
        case .searching: "searching…"
        case .connected(let name): "✅ \(name)"
        case .failed(let msg): "❌ \(msg)"
        }
    }
}
