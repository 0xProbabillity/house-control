#if ROOM_SCAN
import SwiftUI
import HouseCore

/// The floor plan the scan made, drawn from above, with its rooms to name and its pinned
/// devices; saved as the home (or as another floor of it), ready to fine-tune in the editor.
struct ScanReviewView: View {
    @Environment(AppModel.self) private var model
    let controller: ScanController
    @State private var plan: [String: Any]
    @State private var name: String
    @State private var roomNames: [String: String] = [:]
    @State private var asFloor = false
    @State private var floorName = "Upstairs"
    @State private var confirmReplace = false
    @State private var confirmDiscard = false
    @State private var editAfter = false

    init(controller: ScanController) {
        self.controller = controller
        _plan = State(initialValue: controller.plan ?? [:])
        _name = State(initialValue: controller.homeName)
    }

    private var rooms: [(id: String, name: String)] {
        (plan["rooms"] as? [[String: Any]] ?? []).compactMap { r in
            (r["id"] as? String).map { ($0, r["name"] as? String ?? $0) }
        }
    }

    private var editor: PlanEditor { PlanEditor(plan: named) }

    /// The plan with the names typed here.
    private var named: [String: Any] {
        var out = plan
        out["name"] = name.trimmingCharacters(in: .whitespaces).isEmpty ? controller.homeName : name.trimmingCharacters(in: .whitespaces)
        out["rooms"] = (plan["rooms"] as? [[String: Any]] ?? []).map { room in
            var room = room
            if let id = room["id"] as? String, let typed = roomNames[id]?.trimmingCharacters(in: .whitespaces), !typed.isEmpty {
                room["name"] = typed
            }
            return room
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        ScanPlanPreview(plan: named)
                            .frame(height: 330)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
                        Text(summary).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                    VStack(spacing: 10) {
                        SectionTitle("Name")
                        Card(padding: 16) {
                            InputField(title: "What do you call it?", text: $name, prompt: controller.homeName, focused: false) {
                                TextField("", text: $name).textInputAutocapitalization(.words).submitLabel(.done)
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        SectionTitle("Rooms")
                        Card {
                            ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
                                if index > 0 { RowDivider() }
                                HStack(spacing: 14) {
                                    IconBadge(symbol: Self.symbol(for: room.name), tint: Theme.accent)
                                    TextField(room.name, text: Binding(get: { roomNames[room.id] ?? room.name },
                                                                       set: { roomNames[room.id] = $0 }))
                                        .font(.system(size: 16.5, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                        .textInputAutocapitalization(.words)
                                        .submitLabel(.done)
                                    Image(systemName: "pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 58)
                            }
                        }
                    }
                    if !editor.items.isEmpty { devicesSection }
                    if model.hasCustomPlan { destinationSection }
                    VStack(spacing: 10) {
                        Button { save(edit: false) } label: { Label(asFloor ? "Add the floor" : "Save the home", systemImage: "checkmark") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button { save(edit: true) } label: { Label("Save and fine-tune in the editor", systemImage: "pencil.and.ruler.fill") }
                            .buttonStyle(SecondaryButtonStyle())
                        Footnote(text: "A scan is a starting point. In the editor, drag walls, furniture and lamps where they really are, and link the lamps you left for later.")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("Your scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { confirmDiscard = true }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("Your scan").font(.headline)
                        BetaBadge()
                    }
                }
            }
            .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.showScan = false }
            }
            .confirmationDialog("Replace \(model.customPlanName ?? "your home")?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { commit() }
            } message: {
                Text(model.macName == nil
                     ? "The scan becomes this iPhone's home in place of the one there now. That one is kept: Settings → Home → Earlier homes brings it back."
                     : "The scan becomes this iPhone's home, and \(model.macName ?? "your computer")'s too. The one there now is kept: Settings → Home → Earlier homes brings it back.")
            }
        }
        .presentationBackground(Theme.background)
    }

    private var summary: String {
        let furniture = (plan["furniture"] as? [Any])?.count ?? 0
        let devices = editor.items.count
        var parts = ["\(rooms.count) room\(rooms.count == 1 ? "" : "s")"]
        if furniture > 0 { parts.append("\(furniture) piece\(furniture == 1 ? "" : "s") of furniture") }
        if devices > 0 { parts.append("\(devices) device\(devices == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var devicesSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Devices")
            Card {
                ForEach(Array(editor.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    HStack(spacing: 14) {
                        IconBadge(symbol: item.kind == .ac ? "air.conditioner.horizontal.fill" : "lightbulb.fill",
                                  tint: item.kind == .ac ? Theme.accent : Theme.warm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Text([roomNames[item.room] ?? item.roomName,
                                  item.link.map { ConnectionLook.title($0.service) } ?? "Simulated, link it later"]
                                .joined(separator: " · "))
                                .font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button {
                            var edit = PlanEditor(plan: plan)
                            edit.remove(item.id)
                            withAnimation { plan = edit.plan }
                            Haptics.shared.play("light")
                        } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 21)).foregroundStyle(Theme.red.opacity(0.85))
                        }
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 62)
                }
            }
        }
    }

    private var destinationSection: some View {
        VStack(spacing: 10) {
            SectionTitle("Save as")
            Card {
                choice(false, title: "A new home", detail: "In place of \(model.customPlanName ?? "your home")", symbol: "house.fill")
                RowDivider()
                choice(true, title: "Another floor", detail: "Added on top of \(model.customPlanName ?? "your home")", symbol: "square.stack.3d.up.fill")
                if asFloor {
                    RowDivider()
                    HStack(spacing: 14) {
                        Text("Floor name").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        TextField("Upstairs", text: $floorName).font(.system(size: 16, weight: .semibold))
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.words)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: asFloor)
        }
    }

    private func choice(_ floor: Bool, title: String, detail: String, symbol: String) -> some View {
        Button { asFloor = floor } label: {
            HStack(spacing: 14) {
                IconBadge(symbol: symbol, tint: floor ? Theme.green : Theme.warm)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: asFloor == floor ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(asFloor == floor ? Theme.accent : Theme.faint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 66)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityAddTraits(asFloor == floor ? .isSelected : [])
    }

    private func save(edit: Bool) {
        editAfter = edit
        if model.hasCustomPlan, !asFloor { confirmReplace = true } else { commit() }
    }

    private func commit() {
        let floor = floorName.trimmingCharacters(in: .whitespaces)
        model.saveScan(named, asFloor: model.hasCustomPlan && asFloor ? (floor.isEmpty ? "Upstairs" : floor) : nil, edit: editAfter)
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("bath") { return "shower.fill" }
        if n.contains("kitchen") { return "frying.pan.fill" }
        if n.contains("bed") { return "bed.double.fill" }
        if n.contains("living") { return "sofa.fill" }
        if n.contains("dining") { return "fork.knife" }
        if n.contains("hall") { return "door.left.hand.open" }
        return "square.dashed"
    }
}

/// The plan from above: floors, walls with their doors and windows, furniture outlines, lamps
/// and air conditioners.
struct ScanPlanPreview: View {
    let plan: [String: Any]

    private struct Room { let rect: CGRect; let name: String; let floor: String }

    var body: some View {
        Canvas { context, size in
            let rooms = (plan["rooms"] as? [[String: Any]] ?? []).compactMap { r -> Room? in
                guard let rect = Self.numbers(r["rect"]), rect.count == 4 else { return nil }
                return Room(rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
                            name: r["name"] as? String ?? "", floor: r["floor"] as? String ?? "oak")
            }
            guard let bounds = rooms.map(\.rect).reduce(nil, { $0?.union($1) ?? $1 }), bounds.width > 0, bounds.height > 0 else { return }
            let pad: CGFloat = 24
            let scale = min((size.width - pad * 2) / bounds.width, (size.height - pad * 2) / bounds.height)
            let origin = CGPoint(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                 y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            func point(_ x: Double, _ z: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + z * scale) }
            func rect(_ r: CGRect) -> CGRect {
                CGRect(origin: point(r.minX, r.minY), size: CGSize(width: r.width * scale, height: r.height * scale))
            }

            for room in rooms {
                context.fill(Path(rect(room.rect)), with: .color(Self.floorColor(room.floor)))
            }
            // Furniture outlines.
            for item in plan["furniture"] as? [[String: Any]] ?? [] {
                guard let pos = Self.numbers(item["pos"]), pos.count == 2 else { continue }
                let (w, d) = Self.footprint(item)
                let rot = (item["rot"] as? NSNumber)?.doubleValue ?? 0
                var path = Path(roundedRect: CGRect(x: -w * scale / 2, y: -d * scale / 2, width: w * scale, height: d * scale),
                                cornerRadius: min(4, d * scale / 4))
                let center = point(pos[0], pos[1])
                path = path.applying(CGAffineTransform(rotationAngle: -rot * .pi / 180))
                    .applying(CGAffineTransform(translationX: center.x, y: center.y))
                context.fill(path, with: .color(.white.opacity(0.1)))
                context.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 1)
            }
            // Walls.
            for room in rooms {
                context.stroke(Path(rect(room.rect)), with: .color(Color(red: 0.91, green: 0.89, blue: 0.86)), lineWidth: 2.5)
            }
            // Doors, windows, openings over the walls.
            for opening in plan["openings"] as? [[String: Any]] ?? [] {
                guard let from = Self.numbers(opening["from"]), let to = Self.numbers(opening["to"]), from.count == 2, to.count == 2 else { continue }
                var line = Path()
                line.move(to: point(from[0], from[1]))
                line.addLine(to: point(to[0], to[1]))
                // The gap in the wall shows the floor underneath, layered as the card and the floor are.
                let mid = CGPoint(x: (from[0] + to[0]) / 2, y: (from[1] + to[1]) / 2)
                let under = rooms.first { $0.rect.insetBy(dx: -0.01, dy: -0.01).contains(mid) }
                context.stroke(line, with: .color(Theme.background), lineWidth: 5)
                context.stroke(line, with: .color(Theme.surface), lineWidth: 5)
                if let under { context.stroke(line, with: .color(Self.floorColor(under.floor)), lineWidth: 5) }
                switch opening["type"] as? String {
                case "window": context.stroke(line, with: .color(Color(red: 0.61, green: 0.75, blue: 1)), lineWidth: 2.5)
                case "door": context.stroke(line, with: .color(Theme.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                default: break
                }
            }
            // Room names.
            for room in rooms {
                let c = point(room.rect.midX, room.rect.midY)
                context.draw(Text(room.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.text.opacity(0.75)),
                             at: c)
            }
            // Lamps and ACs.
            for light in plan["lights"] as? [[String: Any]] ?? [] {
                guard let pos = Self.numbers(light["pos"]), pos.count == 2 else { continue }
                let c = point(pos[0], pos[1])
                context.fill(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)),
                             with: .radialGradient(Gradient(colors: [Theme.warm.opacity(0.55), Theme.warm.opacity(0)]),
                                                   center: c, startRadius: 0, endRadius: 14))
                context.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(Theme.warm))
            }
            for ac in plan["acs"] as? [[String: Any]] ?? [] {
                guard let pos = Self.numbers(ac["pos"]), pos.count == 2 else { continue }
                let c = point(pos[0], pos[1])
                let along = ["north", "south"].contains(ac["wall"] as? String ?? "")
                let box = along ? CGRect(x: c.x - 10, y: c.y - 3.5, width: 20, height: 7) : CGRect(x: c.x - 3.5, y: c.y - 10, width: 7, height: 20)
                context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.accent))
            }
        }
        .accessibilityLabel("Floor plan of the scan")
    }

    static func numbers(_ value: Any?) -> [Double]? {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
    }

    static func floorColor(_ kind: String) -> Color {
        switch kind {
        case "tile": Color(red: 0.55, green: 0.62, blue: 0.7).opacity(0.32)
        case "stone": Color(red: 0.6, green: 0.58, blue: 0.55).opacity(0.3)
        case "walnut": Color(red: 0.45, green: 0.31, blue: 0.22).opacity(0.42)
        default: Color(red: 0.66, green: 0.5, blue: 0.34).opacity(0.34)
        }
    }

    /// Width and depth on the floor, as `web/src/three/furniture.js` builds each piece.
    static func footprint(_ item: [String: Any]) -> (Double, Double) {
        let w = (item["width"] as? NSNumber)?.doubleValue
        switch item["type"] as? String ?? "" {
        case "sofa": return (w ?? 2.2, 0.95)
        case "armchair": return (0.92, 0.88)
        case "coffeeTable": return (w ?? 1.1, 0.58)
        case "tv": return (w ?? 1.7, 0.4)
        case "sideboard": return (w ?? 1.6, 0.42)
        case "diningSet": return (w ?? 1.8, 1.9)
        case "kitchen": return (w ?? 3, 0.62)
        case "fridge": return (0.7, 0.68)
        case "bed": return ((w ?? 1.6) + 0.1, 2.14)
        case "nightstand": return (0.46, 0.4)
        case "dresser": return (w ?? 1.3, 0.45)
        case "vanity": return (w ?? 1, 0.5)
        case "bathtub": return (1.7, 0.78)
        case "toilet": return (0.4, 0.66)
        case "desk": return (w ?? 1.4, 0.65)
        case "wardrobe": return (w ?? 1.6, 0.6)
        case "bookshelf": return (w ?? 1, 0.32)
        case "stairs": return (w ?? 1, (item["depth"] as? NSNumber)?.doubleValue ?? 2.8)
        default: return (0.5, 0.5)
        }
    }
}
#endif
