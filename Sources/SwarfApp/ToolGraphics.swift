import SwiftUI
import CAMCore

/// A dimension of a bit, labelled with the same letter on the diagram and beside its field.
enum ToolDim: String, CaseIterable, Identifiable {
    case diameter, fluteLength, stickout, shank, cornerRadius, angle, tipDiameter
    var id: String { rawValue }
    var letter: String {
        switch self {
        case .diameter: return "A"
        case .fluteLength: return "B"
        case .stickout: return "C"
        case .shank: return "D"
        case .cornerRadius: return "E"
        case .angle: return "F"
        case .tipDiameter: return "G"
        }
    }
    var color: Color {
        switch self {
        case .diameter: return .blue
        case .fluteLength: return .orange
        case .stickout: return .purple
        case .shank: return .teal
        case .cornerRadius: return .pink
        case .angle: return .green
        case .tipDiameter: return .red
        }
    }
    static func applicable(to k: ToolKind) -> [ToolDim] {
        switch k {
        case .flat, .roughing, .ball: return [.diameter, .fluteLength, .stickout, .shank]
        case .bullNose: return [.diameter, .fluteLength, .stickout, .shank, .cornerRadius]
        case .vBit: return [.diameter, .fluteLength, .stickout, .shank, .angle, .tipDiameter]
        case .drill: return [.diameter, .fluteLength, .stickout, .shank, .angle]
        }
    }
}

/// Letter badge matching a dimension on the diagram.
struct DimBadge: View {
    let dim: ToolDim
    var body: some View {
        Text(dim.letter)
            .font(.caption2.bold()).foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(dim.color, in: Circle())
            .accessibilityLabel("Dimension \(dim.letter)")
    }
}

/// Side view of a bit: shank at the top, flutes below, the tip at the bottom. Flute lines show the flute style;
/// a roughing bit gets chip-breaker notches. With `dimensions`, labelled dimension lines are drawn too.
struct BitView: View {
    let kind: ToolKind
    var flute: FluteStyle = .unspecified
    var dimensions = false
    var highlight: ToolDim? = nil
    /// Real proportions for the shank (shank Ø / cutter Ø), when known.
    var shankRatio: Double? = nil

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .accessibilityLabel("\(kind.displayName) bit")
    }

    struct Geometry {
        var cx: CGFloat, cw: CGFloat, sw: CGFloat
        var top: CGFloat, collet: CGFloat, fluteTop: CGFloat, bodyBottom: CGFloat, tip: CGFloat
    }

    func geometry(_ size: CGSize) -> Geometry {
        let w = size.width, h = size.height
        let margin: CGFloat = dimensions ? 0.24 : 0.08
        let cw = min(w * (dimensions ? 0.30 : 0.36), h * 0.30)
        let ratio = CGFloat(min(1.7, max(0.5, shankRatio ?? (kind == .vBit || kind == .drill ? 1 : 0.9))))
        let sw = cw * ratio
        let top = h * margin * 0.6
        let tip = h * (1 - margin * (dimensions ? 1.1 : 1))
        let collet = top + (tip - top) * 0.12
        let fluteTop = top + (tip - top) * 0.42
        let pointLen: CGFloat
        switch kind {
        case .vBit: pointLen = cw / 2 / tan(.pi / 6)  // 60° included
        case .drill: pointLen = cw / 2 / tan(59 * .pi / 180)
        case .ball: pointLen = cw / 2
        default: pointLen = 0
        }
        return Geometry(cx: w / 2, cw: cw, sw: sw, top: top, collet: collet, fluteTop: fluteTop,
                        bodyBottom: tip - pointLen, tip: tip)
    }

    /// Outline of the cutting part (flutes and tip).
    func cutterPath(_ g: Geometry) -> Path {
        let l = g.cx - g.cw / 2, r = g.cx + g.cw / 2
        var p = Path()
        switch kind {
        case .flat, .roughing:
            p.addRect(CGRect(x: l, y: g.fluteTop, width: g.cw, height: g.tip - g.fluteTop))
        case .ball:
            p.move(to: CGPoint(x: l, y: g.fluteTop))
            p.addLine(to: CGPoint(x: r, y: g.fluteTop))
            p.addLine(to: CGPoint(x: r, y: g.bodyBottom))
            p.addArc(center: CGPoint(x: g.cx, y: g.bodyBottom), radius: g.cw / 2, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
        case .bullNose:
            let cr = g.cw * 0.2
            p.move(to: CGPoint(x: l, y: g.fluteTop))
            p.addLine(to: CGPoint(x: r, y: g.fluteTop))
            p.addLine(to: CGPoint(x: r, y: g.tip - cr))
            p.addArc(center: CGPoint(x: r - cr, y: g.tip - cr), radius: cr, startAngle: .zero, endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: l + cr, y: g.tip))
            p.addArc(center: CGPoint(x: l + cr, y: g.tip - cr), radius: cr, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
        case .vBit, .drill:
            let flat = kind == .vBit ? g.cw * 0.08 : 0
            p.move(to: CGPoint(x: l, y: g.fluteTop))
            p.addLine(to: CGPoint(x: r, y: g.fluteTop))
            p.addLine(to: CGPoint(x: r, y: g.bodyBottom))
            p.addLine(to: CGPoint(x: g.cx + flat, y: g.tip))
            p.addLine(to: CGPoint(x: g.cx - flat, y: g.tip))
            p.addLine(to: CGPoint(x: l, y: g.bodyBottom))
            p.closeSubpath()
        }
        return p
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let g = geometry(size)
        let steel = Color(white: 0.72), dark = Color(white: 0.35)
        // Collet nut (stick-out is measured from its face), then the shank.
        let nutW = max(g.sw, g.cw) * 1.9
        let nut = Path(roundedRect: CGRect(x: g.cx - nutW / 2, y: g.top, width: nutW, height: g.collet - g.top), cornerRadius: 3)
        ctx.fill(nut, with: .color(Color(white: 0.5).opacity(0.55)))
        let shank = Path(CGRect(x: g.cx - g.sw / 2, y: g.collet, width: g.sw, height: g.fluteTop - g.collet + 1))
        ctx.fill(shank, with: .linearGradient(Gradient(colors: [Color(white: 0.55), Color(white: 0.85), Color(white: 0.6)]),
                                              startPoint: CGPoint(x: g.cx - g.sw / 2, y: 0), endPoint: CGPoint(x: g.cx + g.sw / 2, y: 0)))
        // Cutter body.
        let body = cutterPath(g)
        ctx.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.5), steel, Color(white: 0.55)]),
                                             startPoint: CGPoint(x: g.cx - g.cw / 2, y: 0), endPoint: CGPoint(x: g.cx + g.cw / 2, y: 0)))
        // Flutes.
        var inner = ctx
        inner.clip(to: body)
        let style = kind == .drill || kind == .vBit ? (flute == .unspecified ? .upcut : flute) : flute
        let spacing = max(5, g.cw * 0.28)
        let bottom = kind == .vBit || kind == .drill ? g.bodyBottom : g.tip
        let slope = g.cw * 0.55
        func helices(from y0: CGFloat, to y1: CGFloat, up: Bool?) {
            var y = y0 - slope
            while y < y1 + slope {
                var l = Path()
                if let up {
                    l.move(to: CGPoint(x: g.cx - g.cw / 2, y: up ? y + slope : y))
                    l.addLine(to: CGPoint(x: g.cx + g.cw / 2, y: up ? y : y + slope))
                } else {
                    l = Path()
                }
                inner.stroke(l, with: .color(dark.opacity(0.85)), lineWidth: max(1, g.cw * 0.05))
                y += spacing
            }
        }
        var flutesCtx = inner
        flutesCtx.clip(to: Path(CGRect(x: 0, y: g.fluteTop, width: size.width, height: max(0, (kind == .ball ? g.tip : bottom) - g.fluteTop))))
        inner = flutesCtx
        switch style {
        case .straight:
            for i in 1...3 {
                let x = g.cx - g.cw / 2 + g.cw * CGFloat(i) / 4
                var l = Path(); l.move(to: CGPoint(x: x, y: g.fluteTop)); l.addLine(to: CGPoint(x: x, y: g.tip))
                inner.stroke(l, with: .color(dark.opacity(0.85)), lineWidth: max(1, g.cw * 0.05))
            }
        case .downcut:
            helices(from: g.fluteTop, to: g.tip, up: false)
        case .compression:
            let split = g.fluteTop + (g.tip - g.fluteTop) * 0.35
            var lower = flutesCtx
            lower.clip(to: Path(CGRect(x: 0, y: split, width: size.width, height: size.height)))
            var upper = flutesCtx
            upper.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: split)))
            inner = upper; helices(from: g.fluteTop, to: split, up: false)
            inner = lower; helices(from: split, to: g.tip, up: true)
        default:
            helices(from: g.fluteTop, to: g.tip, up: true)
        }
        if kind == .roughing {
            // Chip-breaker notches along both edges and across the flutes.
            var notches = Path()
            var y = g.fluteTop + 3
            while y < g.tip - 2 {
                for side: CGFloat in [-1, 1] {
                    let x = g.cx + side * g.cw / 2
                    notches.move(to: CGPoint(x: x, y: y))
                    notches.addLine(to: CGPoint(x: x - side * g.cw * 0.09, y: y + 2.5))
                    notches.addLine(to: CGPoint(x: x, y: y + 5))
                }
                y += 6
            }
            ctx.fill(notches, with: .color(Color(nsColor: .windowBackgroundColor)))
            var ticks = Path()
            y = g.fluteTop + 4
            while y < g.tip - 2 {
                ticks.move(to: CGPoint(x: g.cx - g.cw * 0.3, y: y)); ticks.addLine(to: CGPoint(x: g.cx + g.cw * 0.3, y: y))
                y += 6
            }
            var tc = ctx
            tc.clip(to: body)
            tc.stroke(ticks, with: .color(dark.opacity(0.35)), lineWidth: 1)
        }
        ctx.stroke(body, with: .color(dark), lineWidth: 1)
        ctx.stroke(shank, with: .color(dark.opacity(0.7)), lineWidth: 0.8)
        if dimensions { drawDimensions(&ctx, g, size) }
    }

    func drawDimensions(_ ctx: inout GraphicsContext, _ g: Geometry, _ size: CGSize) {
        let dims = ToolDim.applicable(to: kind)
        func style(_ d: ToolDim) -> (Color, CGFloat) {
            let on = highlight == nil || highlight == d
            return (d.color.opacity(on ? 1 : 0.35), highlight == d ? 2.2 : 1.2)
        }
        func arrowLine(_ a: CGPoint, _ b: CGPoint, _ d: ToolDim, label: CGPoint) {
            let (c, w) = style(d)
            var p = Path(); p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(c), lineWidth: w)
            let dx = b.x - a.x, dy = b.y - a.y, len = max(1, (dx * dx + dy * dy).squareRoot())
            let ux = dx / len, uy = dy / len, s: CGFloat = 5
            for (pt, dir) in [(a, CGFloat(1)), (b, CGFloat(-1))] {
                var head = Path()
                head.move(to: pt)
                head.addLine(to: CGPoint(x: pt.x + dir * (ux * s) - uy * s * 0.6, y: pt.y + dir * (uy * s) + ux * s * 0.6))
                head.addLine(to: CGPoint(x: pt.x + dir * (ux * s) + uy * s * 0.6, y: pt.y + dir * (uy * s) - ux * s * 0.6))
                head.closeSubpath()
                ctx.fill(head, with: .color(c))
            }
            badge(d, at: label)
        }
        func badge(_ d: ToolDim, at p: CGPoint) {
            let (c, _) = style(d)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(c))
            ctx.draw(Text(d.letter).font(.caption2.bold()).foregroundStyle(.white), at: p)
        }
        func extension_(_ a: CGPoint, _ b: CGPoint, _ d: ToolDim) {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(style(d).0.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
        }
        let l = g.cx - g.cw / 2, r = g.cx + g.cw / 2
        let wide = max(g.cw, g.sw) / 2
        if dims.contains(.diameter) {
            // Across the cutter, at the widest point of the body.
            let y = kind == .vBit || kind == .drill ? (g.fluteTop + g.bodyBottom) / 2 : g.fluteTop + (g.tip - g.fluteTop) * 0.55
            arrowLine(CGPoint(x: l, y: y), CGPoint(x: r, y: y), .diameter, label: CGPoint(x: g.cx, y: y - 11))
        }
        if dims.contains(.fluteLength) {
            let x = g.cx + wide + 16
            extension_(CGPoint(x: r, y: g.fluteTop), CGPoint(x: x + 4, y: g.fluteTop), .fluteLength)
            extension_(CGPoint(x: r, y: g.tip), CGPoint(x: x + 4, y: g.tip), .fluteLength)
            arrowLine(CGPoint(x: x, y: g.fluteTop), CGPoint(x: x, y: g.tip), .fluteLength, label: CGPoint(x: x + 13, y: (g.fluteTop + g.tip) / 2))
        }
        if dims.contains(.stickout) {
            let x = g.cx - wide - 16
            extension_(CGPoint(x: g.cx - g.cw / 2, y: g.tip), CGPoint(x: x - 4, y: g.tip), .stickout)
            arrowLine(CGPoint(x: x, y: g.collet), CGPoint(x: x, y: g.tip), .stickout, label: CGPoint(x: x - 13, y: (g.collet + g.tip) / 2))
        }
        if dims.contains(.shank) {
            let y = (g.collet + g.fluteTop) / 2
            arrowLine(CGPoint(x: g.cx - g.sw / 2, y: y), CGPoint(x: g.cx + g.sw / 2, y: y), .shank, label: CGPoint(x: g.cx, y: y - 11))
        }
        if dims.contains(.cornerRadius) {
            let cr = g.cw * 0.2
            let c = CGPoint(x: r - cr, y: g.tip - cr)
            let edge = CGPoint(x: c.x + cr * 0.707, y: c.y + cr * 0.707)
            let (col, w) = style(.cornerRadius)
            var p = Path(); p.move(to: c); p.addLine(to: edge)
            ctx.stroke(p, with: .color(col), lineWidth: w)
            var lead = Path(); lead.move(to: edge); lead.addLine(to: CGPoint(x: edge.x + 12, y: edge.y + 10))
            ctx.stroke(lead, with: .color(col), lineWidth: 0.8)
            badge(.cornerRadius, at: CGPoint(x: edge.x + 19, y: edge.y + 15))
        }
        if dims.contains(.angle) {
            let half: Double = kind == .vBit ? 30 : 59
            let rad = (g.tip - g.bodyBottom) * 0.75
            let (col, w) = style(.angle)
            var arc = Path()
            arc.addArc(center: CGPoint(x: g.cx, y: g.tip), radius: rad, startAngle: .degrees(-90 - half), endAngle: .degrees(-90 + half), clockwise: false)
            ctx.stroke(arc, with: .color(col), lineWidth: w)
            badge(.angle, at: CGPoint(x: g.cx, y: g.tip - rad - 10))
        }
        if dims.contains(.tipDiameter) {
            let flat = g.cw * 0.08
            let y = g.tip + 9
            extension_(CGPoint(x: g.cx - flat, y: g.tip), CGPoint(x: g.cx - flat, y: y + 3), .tipDiameter)
            extension_(CGPoint(x: g.cx + flat, y: g.tip), CGPoint(x: g.cx + flat, y: y + 3), .tipDiameter)
            let (col, w) = style(.tipDiameter)
            var p = Path(); p.move(to: CGPoint(x: g.cx - flat - 10, y: y)); p.addLine(to: CGPoint(x: g.cx + flat + 10, y: y))
            ctx.stroke(p, with: .color(col), lineWidth: w)
            badge(.tipDiameter, at: CGPoint(x: g.cx + flat + 20, y: y))
        }
    }
}

/// Add Tool: a square tile for each bit type; click to choose, double-click (or Add) to add.
struct NewToolSheet: View {
    var onAdd: (ToolKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ToolKind? = UserDefaults.standard.string(forKey: "SwarfNewToolKind").flatMap(ToolKind.init(rawValue:))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Tool").font(.title2.bold())
            Text("Choose the kind of bit. You can set its sizes and feeds next.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(168), spacing: 12), count: 3), spacing: 12) {
                ForEach(ToolKind.allCases) { k in tile(k) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { if let k = chosen { add(k) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    func add(_ k: ToolKind) {
        dismiss()
        onAdd(k)
    }

    func tile(_ k: ToolKind) -> some View {
        let on = chosen == k
        return VStack(spacing: 6) {
            BitView(kind: k, flute: k == .roughing ? .upcut : .unspecified)
                .frame(width: 84, height: 96)
            Text(k.displayName).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            Text(k.blurb).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 168, height: 196)
        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: on ? 2.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) { add(k) }
        .onTapGesture { chosen = k }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
