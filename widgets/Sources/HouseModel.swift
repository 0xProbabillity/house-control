import SwiftUI
import WidgetKit
import AppIntents
import HouseCore

/// Plan coordinates (metres) to a point in the widget: the plan turned by the azimuth
/// and seen from above at the elevation, scaled to fit, the way the panel's camera
/// looks at the home.
struct IsoProjection {
    static let backWall = 1.0
    static let frontWall = 0.16
    static let innerWall = 0.46
    /// Furniture is drawn lower than it is, like the walls, so it never hides the floor.
    static let furniture = 0.5

    private let cosA: Double, sinA: Double, sinE: Double, cosE: Double
    private(set) var scale: CGFloat = 1
    private(set) var origin = CGPoint.zero

    init(home: HomeSnapshot, size: CGSize, padding: CGFloat, azimuth: Double = 36, elevation: Double = 52) {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        cosA = cos(a); sinA = sin(a); sinE = sin(e); cosE = cos(e)
        var points: [CGPoint] = []
        for r in home.rooms {
            for (x, z) in [(r.x, r.z), (r.x + r.w, r.z), (r.x + r.w, r.z + r.d), (r.x, r.z + r.d)] {
                points.append(raw(x, z, 0))
                points.append(raw(x, z, Self.backWall))
            }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX, maxY > minY else { return }
        let w = max(1, size.width - padding * 2), h = max(1, size.height - padding * 2)
        scale = min(w / (maxX - minX), h / (maxY - minY))
        origin = CGPoint(x: (size.width - (maxX - minX) * scale) / 2 - minX * scale,
                         y: (size.height - (maxY - minY) * scale) / 2 - minY * scale)
    }

    private func raw(_ x: Double, _ z: Double, _ h: Double) -> CGPoint {
        let rx = x * cosA - z * sinA
        let rz = x * sinA + z * cosA
        return CGPoint(x: rx, y: rz * sinE - h * cosE)
    }

    func point(_ x: Double, _ z: Double, _ h: Double = 0) -> CGPoint {
        let p = raw(x, z, h)
        return CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    /// How near a plan point is to the viewer: larger is nearer.
    func depth(_ x: Double, _ z: Double) -> Double { x * sinA + z * cosA }

    /// True when a wall whose outside points along (nx, nz) shows its outside to the viewer.
    func facesViewer(_ nx: Double, _ nz: Double) -> Bool { nx * sinA + nz * cosA > 0.01 }

    /// Light falling on a wall with this normal, 0…1 (the key light comes from the upper left).
    func shade(_ nx: Double, _ nz: Double) -> Double { 0.5 + 0.5 * (nx * cosA - nz * sinA) }

    var squash: Double { sinE }
}

/// A closed polygon through the given points.
struct Polygon: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for point in points.dropFirst() { p.addLine(to: point) }
        p.closeSubpath()
        return p
    }
}

private struct Wall: Identifiable {
    var id: String
    var from: (Double, Double)
    var to: (Double, Double)
    var normal: (Double, Double)
    var height: Double
    var depth: Double
    var outside: Bool
}

/// The home as a small 3D model: floors, walls, every lamp glowing in its colour on the
/// floor of its room, the ACs on their walls. With `interactive`, each lamp is a button.
struct HouseModel: View {
    let home: HomeSnapshot
    var padding: CGFloat = 8
    var interactive = false
    /// Larger dots and glows for a small widget, where the model is tiny.
    var boost: Double = 1
    private let look = WidgetLook()

    var body: some View {
        GeometryReader { geo in
            let iso = IsoProjection(home: home, size: geo.size, padding: padding)
            let full = look.fullColor
            ZStack(alignment: .topLeading) {
                floors(iso, full: full)
                if full { rugs(iso); glows(iso) }
                walls(iso, full: full)
                acs(iso, full: full)
                lamps(iso, full: full)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: interactive ? .contain : .ignore)
        .accessibilityLabel("\(home.name): \(home.lightsLine)")
    }

    private func roomCorners(_ r: HomeSnapshot.Room, _ iso: IsoProjection, inset: Double = 0) -> [CGPoint] {
        [iso.point(r.x + inset, r.z + inset), iso.point(r.x + r.w - inset, r.z + inset),
         iso.point(r.x + r.w - inset, r.z + r.d - inset), iso.point(r.x + inset, r.z + r.d - inset)]
    }

    private static func floorColor(_ kind: String?) -> Color {
        switch kind {
        case "walnut": return Color(hex: "#2b2019")
        case "tile": return Color(hex: "#262c36")
        case "stone": return Color(hex: "#2e3036")
        default: return Color(hex: "#3a2b20")
        }
    }

    @ViewBuilder private func floors(_ iso: IsoProjection, full: Bool) -> some View {
        // A soft shadow under the whole home lifts it off the background.
        if full {
            ForEach(home.rooms) { r in
                Polygon(points: roomCorners(r, iso, inset: -0.15)).fill(Color.black.opacity(0.35))
                    .blur(radius: 6).offset(y: 5)
            }
        }
        ForEach(home.rooms) { r in
            let shape = Polygon(points: roomCorners(r, iso))
            if full {
                let lit = home.lights(in: r.id).filter(\.on)
                shape.fill(Self.floorColor(r.floor).opacity(lit.isEmpty ? 0.8 : 1))
                    .overlay(shape.stroke(Color.white.opacity(0.06), lineWidth: 0.5))
            } else {
                shape.fill(Color.white.opacity(0.08)).overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 0.8))
            }
        }
    }

    private func rugs(_ iso: IsoProjection) -> some View {
        ForEach(Array((home.furniture ?? []).enumerated().filter { $0.element.type == "rug" }), id: \.offset) { _, f in
            Polygon(points: Self.footprint(f).map { iso.point($0.0, $0.1) })
                .fill(Color(hex: f.color ?? "#3b4a66").opacity(roomLit(at: f.x, f.z) == nil ? 0.45 : 0.75))
        }
    }

    private func glows(_ iso: IsoProjection) -> some View {
        ForEach(home.rooms) { r in
            ZStack(alignment: .topLeading) {
                ForEach(home.lights(in: r.id).filter(\.on)) { l in
                    let c = iso.point(l.x, l.z)
                    let radius = (1.25 + 1.35 * l.level) * iso.scale * (0.85 + 0.15 * boost)
                    Ellipse()
                        .fill(RadialGradient(colors: [l.glow.opacity(0.95 * l.level + 0.05), l.glow.opacity(0.4 * l.level), .clear],
                                             center: .center, startRadius: 0, endRadius: radius))
                        .frame(width: radius * 2, height: radius * 2 * iso.squash)
                        .position(c)
                }
            }
            .clipShape(Polygon(points: roomCorners(r, iso)))
            .blendMode(.screen)
        }
    }

    private func wallList(_ iso: IsoProjection) -> [Wall] {
        var walls: [String: Wall] = [:]
        func inside(_ x: Double, _ z: Double, except id: String) -> Bool {
            home.rooms.contains { $0.id != id && x > $0.x && x < $0.x + $0.w && z > $0.z && z < $0.z + $0.d }
        }
        for r in home.rooms {
            let edges: [((Double, Double), (Double, Double), (Double, Double))] = [
                ((r.x, r.z), (r.x + r.w, r.z), (0, -1)),
                ((r.x + r.w, r.z), (r.x + r.w, r.z + r.d), (1, 0)),
                ((r.x + r.w, r.z + r.d), (r.x, r.z + r.d), (0, 1)),
                ((r.x, r.z + r.d), (r.x, r.z), (-1, 0)),
            ]
            for (a, b, n) in edges {
                let mid = ((a.0 + b.0) / 2, (a.1 + b.1) / 2)
                let outside = !inside(mid.0 + n.0 * 0.08, mid.1 + n.1 * 0.08, except: r.id)
                let height = outside ? (iso.facesViewer(n.0, n.1) ? IsoProjection.frontWall : IsoProjection.backWall)
                                     : IsoProjection.innerWall
                // An inner wall belongs to two rooms: draw it once.
                let key = [a, b].map { "\(($0.0 * 20).rounded()),\(($0.1 * 20).rounded())" }.sorted().joined(separator: "|")
                if !outside, walls[key] != nil { continue }
                walls[key] = Wall(id: key, from: a, to: b, normal: n, height: height,
                                  depth: iso.depth(mid.0, mid.1) + (outside && !iso.facesViewer(n.0, n.1) ? -0.5 : 0),
                                  outside: outside)
            }
        }
        return walls.values.sorted { $0.depth < $1.depth }
    }

    private enum Solid: Identifiable {
        case wall(Wall)
        case piece(HomeSnapshot.Furniture, index: Int, depth: Double)

        var id: String {
            switch self {
            case .wall(let w): return "w" + w.id
            case .piece(_, let index, _): return "f\(index)"
            }
        }

        var depth: Double {
            switch self {
            case .wall(let w): return w.depth
            case .piece(_, _, let depth): return depth
            }
        }
    }

    /// Walls and furniture, farthest first, so nearer ones are drawn over them.
    private func solids(_ iso: IsoProjection) -> [Solid] {
        var list = wallList(iso).map(Solid.wall)
        for (i, f) in (home.furniture ?? []).enumerated() where f.type != "rug" {
            list.append(.piece(f, index: i, depth: iso.depth(f.x, f.z)))
        }
        return list.sorted { $0.depth < $1.depth }
    }

    @ViewBuilder private func walls(_ iso: IsoProjection, full: Bool) -> some View {
        ForEach(solids(iso)) { solid in
            switch solid {
            case .wall(let w): wall(w, iso, full: full)
            case .piece(let f, _, _): if full { piece(f, iso) }
            }
        }
    }

    @ViewBuilder private func wall(_ w: Wall, _ iso: IsoProjection, full: Bool) -> some View {
        let base = [iso.point(w.from.0, w.from.1), iso.point(w.to.0, w.to.1)]
        let top = [iso.point(w.to.0, w.to.1, w.height), iso.point(w.from.0, w.from.1, w.height)]
        if full {
            let light = iso.shade(w.normal.0, w.normal.1)
            let front = w.outside && iso.facesViewer(w.normal.0, w.normal.1)
            Polygon(points: base + top)
                .fill(LinearGradient(colors: [Color(white: (front ? 0.40 : 0.66) + 0.2 * light),
                                              Color(white: (front ? 0.30 : 0.46) + 0.16 * light)],
                                     startPoint: .top, endPoint: .bottom))
            Path { p in p.move(to: top[0]); p.addLine(to: top[1]) }
                .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: max(1, iso.scale * 0.08), lineCap: .round))
        } else {
            Path { p in p.move(to: top[0]); p.addLine(to: top[1]) }
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    private static func furnitureLook(_ type: String) -> (height: Double, color: String) {
        switch type {
        case "sofa", "armchair": return (0.8, "#8b93a7")
        case "coffeeTable", "diningSet", "desk": return (0.74, "#6b4f3a")
        case "tv": return (0.55, "#1b1e26")
        case "sideboard", "dresser", "nightstand": return (0.72, "#5a4434")
        case "island", "kitchen", "vanity": return (0.9, "#e2ded6")
        case "fridge": return (1.7, "#cfd3d8")
        case "bed": return (0.55, "#dfe3ea")
        case "plant": return (1.0, "#3f7a4a")
        case "bathtub", "toilet": return (0.5, "#eef1f4")
        case "wardrobe", "bookshelf": return (1.7, "#5a4434")
        default: return (0.6, "#7a7f8c")
        }
    }

    /// The four corners of a piece's footprint on the plan, turned the way three.js turns it.
    private static func footprint(_ f: HomeSnapshot.Furniture, grow: Double = 0) -> [(Double, Double)] {
        let a = f.rot * .pi / 180, c = cos(a), s = sin(a)
        let hw = f.w / 2 + grow, hd = f.d / 2 + grow
        return [(-hw, -hd), (hw, -hd), (hw, hd), (-hw, hd)].map { (lx, lz) in
            (f.x + lx * c + lz * s, f.z - lx * s + lz * c)
        }
    }

    private func roomLit(at x: Double, _ z: Double) -> HomeSnapshot.Light? {
        guard let room = home.rooms.first(where: { x >= $0.x && x <= $0.x + $0.w && z >= $0.z && z <= $0.z + $0.d }) else { return nil }
        return home.lights(in: room.id).first(where: \.on)
    }

    @ViewBuilder private func piece(_ f: HomeSnapshot.Furniture, _ iso: IsoProjection) -> some View {
        let look = Self.furnitureLook(f.type)
        let h = look.height * IsoProjection.furniture
        let color = Color(hex: f.color ?? look.color)
        let corners = Self.footprint(f, grow: -0.04)
        let lit = roomLit(at: f.x, f.z)
        let dim = lit == nil ? 0.5 : 0.18
        ForEach(0..<4, id: \.self) { i in
            let a = corners[i], b = corners[(i + 1) % 4]
            // The outward normal of this side; only sides that face the viewer are seen.
            let n = (b.1 - a.1, -(b.0 - a.0))
            if iso.facesViewer(n.0, n.1) {
                Polygon(points: [iso.point(a.0, a.1), iso.point(b.0, b.1), iso.point(b.0, b.1, h), iso.point(a.0, a.1, h)])
                    .fill(color).overlay(Polygon(points: [iso.point(a.0, a.1), iso.point(b.0, b.1), iso.point(b.0, b.1, h),
                                                          iso.point(a.0, a.1, h)]).fill(Color.black.opacity(min(0.85, dim + 0.3))))
            }
        }
        let top = Polygon(points: corners.map { iso.point($0.0, $0.1, h) })
        top.fill(color)
            .overlay(top.fill(Color.black.opacity(dim)))
            .overlay(top.fill(lit.map { $0.glow.opacity(0.22) } ?? .clear))
    }

    private func acs(_ iso: IsoProjection, full: Bool) -> some View {
        ForEach(home.acs) { ac in
            let p = iso.point(ac.x, ac.z, IsoProjection.backWall * 0.8)
            let size = max(5, iso.scale * 0.55) * (0.9 + 0.1 * boost)
            ZStack {
                if ac.on && full {
                    Circle().fill(RadialGradient(colors: [ac.tint.opacity(0.75), .clear], center: .center,
                                                 startRadius: 0, endRadius: size * 1.6))
                        .frame(width: size * 3.2, height: size * 3.2)
                        .blendMode(.screen)
                }
                Image(systemName: ac.on ? ac.modeSymbol : "air.conditioner.horizontal")
                    .font(.system(size: size * 0.95, weight: .bold))
                    .foregroundStyle(ac.on ? (full ? Color.white : Color.white) : Color.white.opacity(0.45))
                    .frame(width: size * 1.7, height: size * 1.7)
                    .background(Circle().fill(ac.on ? ac.tint.opacity(full ? 0.9 : 0.4) : Color.black.opacity(0.35)))
                    .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.6))
                    .widgetAccentable(ac.on)
            }
            .position(p)
        }
    }

    private func lamps(_ iso: IsoProjection, full: Bool) -> some View {
        ForEach(home.lights) { l in
            let p = iso.point(l.x, l.z, 0.12)
            let dot = max(3.5, iso.scale * 0.2) * (0.8 + 0.2 * boost)
            let mark = ZStack {
                if l.on && full {
                    Circle().fill(RadialGradient(colors: [Color.white, l.glow.opacity(0.9), l.glow.opacity(0)],
                                                 center: .center, startRadius: 0, endRadius: dot * 2.4))
                        .frame(width: dot * 4.8, height: dot * 4.8)
                }
                Circle()
                    .fill(l.on ? (full ? Color.white : Color.white) : Color.white.opacity(full ? 0.22 : 0.3))
                    .frame(width: dot, height: dot)
                    .overlay(Circle().stroke(Color.black.opacity(l.on ? 0 : 0.35), lineWidth: 0.5))
                    .widgetAccentable(l.on)
            }
            if interactive {
                Button(intent: ToggleLightIntent(lightID: l.id)) {
                    mark.frame(width: max(30, dot * 5), height: max(30, dot * 5)).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(l.name), \(l.on ? "on" : "off")")
                .position(p)
            } else {
                mark.position(p)
            }
        }
    }
}
