import CoreGraphics
import Foundation

// raw bgra frames -> ffmpeg stdin -> h264 mp4
final class FFmpegPipe {
    private let proc = Process()
    private let pipe = Pipe()
    private let width: Int
    private let height: Int

    init(out: String, width: Int, height: Int, fps: Double) throws {
        self.width = width
        self.height = height
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-",
            "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", out,
        ]
        proc.standardInput = pipe
        try proc.run()
    }

    func write(_ ctx: CGContext) throws {
        guard let data = ctx.data else { return }
        let bytes = Data(bytesNoCopy: data, count: ctx.bytesPerRow * height, deallocator: .none)
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
    }

    func finish() throws {
        try pipe.fileHandleForWriting.close()
        proc.waitUntilExit()
    }
}
