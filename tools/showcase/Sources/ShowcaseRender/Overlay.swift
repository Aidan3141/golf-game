import AppKit
import CoreGraphics

// 2d data layer over the render: caption, swing data strip (tempo + phases + wrist speed from
// the watch), live ball numbers, final shot card. top-left coords in here
final class Overlay {
    struct State {
        var caption = ""
        var segment = ""
        var segX = 0.0
        var dataT = 0.0
        var phase = ""
        var wristSpeed = 0.0  // rad/s
        var impact: Double?  // 0..1 right after impact
        var ballT = 0.0
        var ballYards: Double?
        var ballHeightFt: Double?
    }

    let W: CGFloat
    let H: CGFloat
    let rec: Recording
    let accent = NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1)
    let cyan = NSColor(srgbRed: 0.45, green: 0.9, blue: 1, alpha: 1)

    init(width: Int, height: Int, rec: Recording) {
        W = CGFloat(width)
        H = CGFloat(height)
        self.rec = rec
    }

    // galvji for words, din for numbers. not the system font
    static func words(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Galvji-Bold" : "Galvji", size: size) ?? .systemFont(ofSize: size)
    }

    static func num(_ size: CGFloat) -> NSFont {
        NSFont(name: "DINAlternate-Bold", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .bold)
    }

    // text w/ its top-left at x,y (top-left coords). returns size
    @discardableResult
    func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, kern: CGFloat = 0, align: NSTextAlignment = .left) -> CGSize {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let sz = a.size()
        var px = x
        if align == .right { px = x - sz.width }
        if align == .center { px = x - sz.width / 2 }
        a.draw(at: NSPoint(x: px, y: H - y - sz.height))
        return sz
    }

    func rrect(_ r: CGRect, radius: CGFloat, fill: NSColor) {
        let f = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
        fill.setFill()
        NSBezierPath(roundedRect: f, xRadius: radius, yRadius: radius).fill()
    }

    func draw(in ctx: CGContext, _ s: State) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        defer { NSGraphicsContext.restoreGraphicsState() }

        caption(s)
        switch s.segment {
        case "swing", "impact":
            strip(s)
        case "pov":
            strip(s)
            if s.ballYards != nil { liveBall(s) }
        case "flight":
            liveBall(s)
        case "side":
            shotCard(s)
        default:
            break
        }
    }

    // title + end cards
    func card(in ctx: CGContext, kind: String, x: Double, secs: Double) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        defer { NSGraphicsContext.restoreGraphicsState() }
        let fadeIn = min(x * secs / 0.6, 1)
        let fadeOut = min((1 - x) * secs / 0.6, 1)
        let vis = CGFloat(kind == "title" ? fadeOut : fadeIn)
        let shade = NSGradient(colors: [NSColor(white: 0, alpha: 0.5), NSColor(white: 0, alpha: 0.1)])!
        shade.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
        let textA = CGFloat(min(x * secs / 0.5, 1)) * vis
        text("golf sim testing", Overlay.words(124, bold: true), NSColor(white: 1, alpha: textA), x: W / 2, y: H * 0.24, kern: -2, align: .center)
        if kind != "title" {
            text("github.com/Aidan3141/golf-game", Overlay.words(38), accent.withAlphaComponent(textA), x: W / 2, y: H * 0.24 + 170, align: .center)
        }
        let black = 1 - CGFloat(kind == "title" ? min(x * secs / 0.4, 1) : 1) * vis
        if black > 0 {
            NSColor(white: 0, alpha: black).setFill()
            NSRect(x: 0, y: 0, width: W, height: H).fill()
        }
    }

    // MARK: pieces

    func caption(_ s: State) {
        let f = Overlay.words(26, bold: true)
        let sz = NSAttributedString(string: s.caption, attributes: [.font: f]).size()
        rrect(CGRect(x: 56, y: 52, width: sz.width + 48, height: 50), radius: 12, fill: NSColor(white: 0, alpha: 0.45))
        rrect(CGRect(x: 56, y: 52, width: 6, height: 50), radius: 3, fill: s.segment == "impact" ? accent : cyan)
        text(s.caption, f, NSColor(white: 1, alpha: 0.95), x: 82, y: 52 + (50 - sz.height) / 2)
    }

    // bottom strip: tempo | swing phases to scale w/ a playhead | wrist speed off the watch
    func strip(_ s: State) {
        let back = rec.shot.backswing
        let down = rec.shot.downswing
        let lead = 0.5
        let thru = 0.6
        let total = lead + back + down + thru
        let top = H - 190
        rrect(CGRect(x: 56, y: top, width: W - 112, height: 140), radius: 18, fill: NSColor(white: 0, alpha: 0.5))
        let dim = NSColor(white: 1, alpha: 0.6)

        // tempo
        text("tempo", Overlay.words(20), dim, x: 96, y: top + 24)
        text(String(format: "%.1f:1", rec.shot.tempo), Overlay.num(60), .white, x: 96, y: top + 50)

        // timeline
        let x0: CGFloat = 340
        let w: CGFloat = W - 340 - 520
        let y = top + 74
        let barH: CGFloat = 10
        text(s.phase, Overlay.words(22, bold: true), .white, x: x0, y: top + 24)
        let parts: [(String, Double, NSColor)] = [
            ("", lead, NSColor(white: 1, alpha: 0.22)),
            (String(format: "back %.2fs", back), back, cyan.withAlphaComponent(0.9)),
            (String(format: "down %.2fs", down), down, accent),
            ("", thru, NSColor(white: 1, alpha: 0.3)),
        ]
        var x = x0
        for (label, d, c) in parts {
            let pw = w * CGFloat(d / total)
            rrect(CGRect(x: x + 2, y: y, width: pw - 4, height: barH), radius: barH / 2, fill: c)
            if !label.isEmpty { text(label, Overlay.words(18), dim, x: x + 4, y: y + barH + 10) }
            x += pw
        }
        let start = rec.launchT - down - back - lead
        let px = x0 + w * CGFloat(min(max((s.dataT - start) / total, 0), 1))
        rrect(CGRect(x: px - 2.5, y: y - 12, width: 5, height: barH + 24), radius: 2.5, fill: .white)
        let ix = x0 + w * CGFloat((lead + back + down) / total)
        text("impact", Overlay.words(17, bold: true), accent, x: ix, y: y - 34, align: .center)

        // wrist speed, off the watch
        let rx = W - 96
        let dps = (s.impact != nil ? rec.shot.wristSpeed : s.wristSpeed) * 180 / .pi
        text("wrist speed", Overlay.words(20), dim, x: rx, y: top + 24, align: .right)
        let n = text(String(format: "%.0f", dps), Overlay.num(60), s.impact != nil ? accent : .white, x: rx - 58, y: top + 50, align: .right)
        _ = n
        text("°/s", Overlay.words(24), dim, x: rx, y: top + 78, align: .right)
        text("from the apple watch on my left wrist", Overlay.words(17), NSColor(white: 1, alpha: 0.5), x: rx, y: top + 116, align: .right)
    }

    func liveBall(_ s: State) {
        let x: CGFloat = W - 88
        rrect(CGRect(x: W - 380, y: 120, width: 320, height: 210), radius: 18, fill: NSColor(white: 0, alpha: 0.45))
        let dim = NSColor(white: 1, alpha: 0.6)
        text("distance", Overlay.words(20), dim, x: x, y: 142, align: .right)
        text(String(format: "%.0f yd", s.ballYards ?? 0), Overlay.num(58), .white, x: x, y: 166, align: .right)
        text("height", Overlay.words(20), dim, x: x, y: 240, align: .right)
        text(String(format: "%.0f ft", s.ballHeightFt ?? 0), Overlay.num(44), accent, x: x, y: 264, align: .right)
    }

    func shotCard(_ s: State) {
        let a = CGFloat(min(s.segX * 4, 1))
        let w: CGFloat = 580
        let x = W - w - 70
        let y: CGFloat = H - 420 - 70
        rrect(CGRect(x: x, y: y, width: w, height: 420), radius: 24, fill: NSColor(white: 0.03, alpha: 0.62 * a))
        let white = NSColor(white: 1, alpha: a)
        let dim = NSColor(white: 1, alpha: 0.6 * a)
        text("carry", Overlay.words(24, bold: true), accent.withAlphaComponent(a), x: x + 44, y: y + 34)
        let big = text(String(format: "%.0f", rec.shot.carryYd), Overlay.num(140), white, x: x + 40, y: y + 58)
        text("yd", Overlay.words(40, bold: true), dim, x: x + 52 + big.width, y: y + 58 + big.height - 72)
        let curve: String = {
            let off = rec.shot.offlineM * 1.0936
            if abs(off) < 3 { return "straight" }
            return String(format: "%.0f yd %@", abs(off), off > 0 ? "right" : "left")
        }()
        let stats: [(String, String)] = [
            ("total", String(format: "%.0f yd", rec.shot.totalYd)),
            ("apex", String(format: "%.0f ft", rec.shot.apexM * 3.28084)),
            ("curve", curve),
            ("tempo", String(format: "%.1f:1", rec.shot.tempo)),
            ("wrist speed", String(format: "%.0f°/s", rec.shot.wristSpeed * 180 / .pi)),
            ("smooth", String(format: "%.0f%%", rec.shot.smoothness * 100)),
        ]
        for (i, (k, v)) in stats.enumerated() {
            let col = CGFloat(i % 3)
            let row = CGFloat(i / 3)
            let sx = x + 44 + col * 176
            let sy = y + 236 + row * 88
            text(k, Overlay.words(19), dim, x: sx, y: sy)
            text(v, Overlay.num(36), white, x: sx, y: sy + 24)
        }
    }
}
