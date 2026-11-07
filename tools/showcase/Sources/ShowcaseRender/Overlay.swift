import AppKit
import CoreGraphics

// 2d data layer over the render: caption, swing phase timeline, the watch, live ball numbers,
// final shot card. top-left coords in here, flipped for appkit at draw time
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

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        return NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
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

    func rrect(_ r: CGRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lw: CGFloat = 2) {
        let f = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
        let p = NSBezierPath(roundedRect: f, xRadius: radius, yRadius: radius)
        fill.setFill()
        p.fill()
        if let stroke {
            stroke.setStroke()
            p.lineWidth = lw
            p.stroke()
        }
    }

    func draw(in ctx: CGContext, _ s: State) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        defer { NSGraphicsContext.restoreGraphicsState() }

        caption(s)
        switch s.segment {
        case "swing", "impact":
            timeline(s)
            watch(s)
        case "pov":
            watch(s)
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
        // fade in from / out to black
        let fadeIn = min(x * secs / 0.6, 1)
        let fadeOut = min((1 - x) * secs / 0.6, 1)
        let vis = CGFloat(kind == "title" ? fadeOut : fadeIn)
        let shade = NSGradient(colors: [NSColor(white: 0, alpha: 0.55), NSColor(white: 0, alpha: 0.15)])!
        shade.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
        let textA = CGFloat(min(x * secs / 0.5, 1)) * vis
        let white = NSColor(white: 1, alpha: textA)
        let dim = NSColor(white: 1, alpha: 0.7 * textA)
        if kind == "title" {
            text("golf sim testing", Overlay.rounded(120, .heavy), white, x: W / 2, y: H * 0.2, align: .center)
            text("vision pro  ·  apple watch  ·  iphone", Overlay.rounded(34, .semibold), dim, x: W / 2, y: H * 0.2 + 150, kern: 1.5, align: .center)
            text("real swing → real ball flight", Overlay.rounded(28, .medium), accent.withAlphaComponent(textA), x: W / 2, y: H * 0.2 + 206, kern: 1.2, align: .center)
        } else {
            text("golf sim testing", Overlay.rounded(96, .heavy), white, x: W / 2, y: H * 0.2, align: .center)
            text("github.com/Aidan3141/golf-game", Overlay.mono(40, .semibold), accent.withAlphaComponent(textA), x: W / 2, y: H * 0.2 + 130, align: .center)
            text("visionOS · watchOS · iOS · swift", Overlay.rounded(28, .medium), dim, x: W / 2, y: H * 0.2 + 196, kern: 1.2, align: .center)
        }
        // black fade
        let black = 1 - CGFloat(kind == "title" ? min(x * secs / 0.4, 1) : 1) * vis
        if black > 0 {
            NSColor(white: 0, alpha: black).setFill()
            NSRect(x: 0, y: 0, width: W, height: H).fill()
        }
    }

    // MARK: pieces

    func caption(_ s: State) {
        let f = Overlay.rounded(22, .semibold)
        let t = s.caption.uppercased()
        let sz = NSAttributedString(string: t, attributes: [.font: f, .kern: 2.5]).size()
        rrect(CGRect(x: 56, y: 52, width: sz.width + 64, height: 46), radius: 23, fill: NSColor(white: 0, alpha: 0.42))
        let dot = CGRect(x: 76, y: 52 + 23 - 6, width: 12, height: 12)
        rrect(dot, radius: 6, fill: s.segment == "impact" ? accent : cyan)
        text(t, f, NSColor(white: 1, alpha: 0.92), x: 100, y: 52 + (46 - sz.height) / 2, kern: 2.5)
        // tiny project tag top right
        text("golf sim testing", Overlay.rounded(22, .medium), NSColor(white: 1, alpha: 0.55), x: W - 60, y: 62, align: .right)
    }

    // swing phases to scale w/ a playhead. tempo is the number golfers care about
    func timeline(_ s: State) {
        let back = rec.shot.backswing
        let down = rec.shot.downswing
        let lead = 0.5
        let thru = 0.6
        let total = lead + back + down + thru
        let x0: CGFloat = 360
        let w: CGFloat = W - 720
        let y: CGFloat = H - 118
        let barH: CGFloat = 14
        rrect(CGRect(x: x0 - 30, y: y - 62, width: w + 60, height: 136), radius: 26, fill: NSColor(white: 0, alpha: 0.42))
        let parts: [(String, Double, NSColor)] = [
            ("ADDRESS", lead, NSColor(white: 1, alpha: 0.25)),
            (String(format: "BACK  %.2fs", back), back, cyan.withAlphaComponent(0.85)),
            (String(format: "DOWN  %.2fs", down), down, accent),
            ("THRU", thru, NSColor(white: 1, alpha: 0.35)),
        ]
        var x = x0
        for (label, d, c) in parts {
            let pw = w * CGFloat(d / total)
            rrect(CGRect(x: x + 2, y: y, width: pw - 4, height: barH), radius: barH / 2, fill: c)
            text(label, Overlay.rounded(19, .bold), NSColor(white: 1, alpha: 0.85), x: x + 4, y: y + barH + 12, kern: 1.2)
            x += pw
        }
        // playhead
        let start = rec.launchT - down - back - lead
        let px = x0 + w * CGFloat(min(max((s.dataT - start) / total, 0), 1))
        rrect(CGRect(x: px - 3, y: y - 14, width: 6, height: barH + 28), radius: 3, fill: .white)
        // impact tick
        let ix = x0 + w * CGFloat((lead + back + down) / total)
        text("IMPACT", Overlay.rounded(16, .heavy), accent, x: ix, y: y - 40, kern: 1.5, align: .center)
        // tempo big on the left
        text("TEMPO", Overlay.rounded(16, .bold), NSColor(white: 1, alpha: 0.6), x: x0 - 30 - 40, y: y - 48, kern: 1.5, align: .right)
        text(String(format: "%.1f:1", rec.shot.tempo), Overlay.mono(44, .heavy), .white, x: x0 - 30 - 40, y: y - 26, align: .right)
        text(s.phase, Overlay.rounded(26, .heavy), .white, x: x0, y: y - 48, kern: 2)
    }

    // the watch, drawn. screen shows what its sensing
    func watch(_ s: State) {
        let cx: CGFloat = W - 200
        let cy: CGFloat = H - 420
        let bw: CGFloat = 176
        let bh: CGFloat = 208
        rrect(CGRect(x: cx - 190, y: cy - bh / 2 - 100, width: 380, height: bh + 240), radius: 30, fill: NSColor(white: 0, alpha: 0.35))
        // band
        rrect(CGRect(x: cx - 62, y: cy - bh / 2 - 70, width: 124, height: bh + 140), radius: 30, fill: NSColor(white: 0.12, alpha: 0.85))
        // case
        let glow = s.impact.map { 1 - $0 } ?? 0
        rrect(CGRect(x: cx - bw / 2 - 6, y: cy - bh / 2 - 6, width: bw + 12, height: bh + 12), radius: 52,
              fill: NSColor(white: 0.55, alpha: 1), stroke: glow > 0 ? accent.withAlphaComponent(glow) : nil, lw: 10 * glow)
        rrect(CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh), radius: 46, fill: .black)
        // crown
        rrect(CGRect(x: cx + bw / 2 + 4, y: cy - 34, width: 12, height: 40), radius: 5, fill: NSColor(white: 0.5, alpha: 1))
        // screen
        let top = cy - bh / 2 + 26
        text(s.impact != nil ? "IMPACT" : s.phase, Overlay.rounded(18, .heavy), s.impact != nil ? accent : cyan, x: cx, y: top, kern: 1.2, align: .center)
        let dps = s.impact != nil ? rec.shot.wristSpeed * 180 / .pi : s.wristSpeed * 180 / .pi
        text(String(format: "%.0f", dps), Overlay.mono(54, .heavy), .white, x: cx, y: top + 30, align: .center)
        text("°/s wrist", Overlay.rounded(17, .semibold), NSColor(white: 1, alpha: 0.6), x: cx, y: top + 96, align: .center)
        // little speed bar
        let frac = CGFloat(min(dps / max(rec.shot.wristSpeed * 180 / .pi, 1), 1))
        rrect(CGRect(x: cx - 60, y: top + 130, width: 120, height: 8), radius: 4, fill: NSColor(white: 1, alpha: 0.15))
        rrect(CGRect(x: cx - 60, y: top + 130, width: max(8, 120 * frac), height: 8), radius: 4, fill: s.impact != nil ? accent : cyan)
        // label
        text("APPLE WATCH ON LEAD WRIST", Overlay.rounded(16, .bold), NSColor(white: 1, alpha: 0.95), x: cx, y: cy + bh / 2 + 84, kern: 1.4, align: .center)
        text("100 Hz motion → iPhone → Vision Pro", Overlay.rounded(16, .medium), NSColor(white: 1, alpha: 0.6), x: cx, y: cy + bh / 2 + 108, align: .center)
    }

    func liveBall(_ s: State) {
        let x: CGFloat = W - 60
        rrect(CGRect(x: W - 380, y: 120, width: 320, height: 210), radius: 26, fill: NSColor(white: 0, alpha: 0.42))
        text("DISTANCE", Overlay.rounded(17, .bold), NSColor(white: 1, alpha: 0.6), x: x - 28, y: 140, kern: 1.5, align: .right)
        text(String(format: "%.0f yd", s.ballYards ?? 0), Overlay.mono(52, .heavy), .white, x: x - 28, y: 162, align: .right)
        text("HEIGHT", Overlay.rounded(17, .bold), NSColor(white: 1, alpha: 0.6), x: x - 28, y: 236, kern: 1.5, align: .right)
        text(String(format: "%.0f ft", s.ballHeightFt ?? 0), Overlay.mono(40, .heavy), accent, x: x - 28, y: 258, align: .right)
    }

    func shotCard(_ s: State) {
        let a = CGFloat(min(s.segX * 4, 1))
        let w: CGFloat = 560
        let x = W - w - 70
        let y: CGFloat = H - 420 - 70
        rrect(CGRect(x: x, y: y, width: w, height: 420), radius: 34, fill: NSColor(white: 0.03, alpha: 0.62 * a))
        let white = NSColor(white: 1, alpha: a)
        let dim = NSColor(white: 1, alpha: 0.6 * a)
        text("CARRY", Overlay.rounded(20, .bold), accent.withAlphaComponent(a), x: x + 44, y: y + 36, kern: 2)
        let big = text(String(format: "%.0f", rec.shot.carryYd), Overlay.rounded(128, .heavy), white, x: x + 38, y: y + 52)
        text("yd", Overlay.rounded(40, .bold), dim, x: x + 46 + big.width, y: y + 52 + big.height - 70)
        let curve: String = {
            let off = rec.shot.offlineM * 1.0936
            if abs(off) < 3 { return "straight" }
            return String(format: "%.0f %@", abs(off), off > 0 ? "R" : "L")
        }()
        let stats: [(String, String)] = [
            ("TOTAL", String(format: "%.0f yd", rec.shot.totalYd)),
            ("APEX", String(format: "%.0f ft", rec.shot.apexM * 3.28084)),
            ("CURVE", curve),
            ("TEMPO", String(format: "%.1f:1", rec.shot.tempo)),
            ("WRIST", String(format: "%.0f°/s", rec.shot.wristSpeed * 180 / .pi)),
            ("SMOOTH", String(format: "%.0f%%", rec.shot.smoothness * 100)),
        ]
        for (i, (k, v)) in stats.enumerated() {
            let col = CGFloat(i % 3)
            let row = CGFloat(i / 3)
            let sx = x + 44 + col * 168
            let sy = y + 230 + row * 90
            text(k, Overlay.rounded(16, .bold), dim, x: sx, y: sy, kern: 1.5)
            text(v, Overlay.mono(32, .heavy), white, x: sx, y: sy + 22)
        }
    }
}
