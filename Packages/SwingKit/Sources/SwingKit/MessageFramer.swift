import Foundation

// tcp is a byte stream so each envelope goes as [4 byte big endian length][json]
public enum MessageFramer {
    public static let maxFrame = 1 << 20  // 1mb, anything bigger is junk

    public static func frame(_ envelope: MessageEnvelope) throws -> Data {
        let body = try envelope.encoded()
        var len = UInt32(body.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(body)
        return out
    }
}

// feed it bytes as they come in, get whole envelopes out
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    public private(set) var droppedFrames = 0

    public init() {}

    public mutating func append(_ data: Data) -> [MessageEnvelope] {
        buffer.append(data)
        var out: [MessageEnvelope] = []
        while buffer.count >= 4 {
            let len = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard len <= MessageFramer.maxFrame else {
                // garbage, start over
                buffer.removeAll()
                droppedFrames += 1
                break
            }
            guard buffer.count >= 4 + len else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + len)
            buffer.removeFirst(4 + len)
            if let env = try? MessageEnvelope.decode(body) {
                out.append(env)
            } else {
                droppedFrames += 1
            }
        }
        // keep indices starting at 0
        buffer = Data(buffer)
        return out
    }
}
