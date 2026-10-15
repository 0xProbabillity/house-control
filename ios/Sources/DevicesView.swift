import SwiftUI
import HouseCore

/// A device of a connected platform, as `DeviceHub.allDevices` lists it.
struct RealDevice: Identifiable, Hashable {
    let raw: [String: Any]
    var service: String { raw["service"] as? String ?? "" }
    var deviceId: String { raw["id"] as? String ?? "" }
    var id: String { "\(service)|\(deviceId)" }
    var ref: PlanEditor.DeviceRef { .init(service: service, id: deviceId) }
    var name: String { raw["name"] as? String ?? deviceId }
    var kind: String { raw["kind"] as? String ?? "light" }
    var online: Bool { raw["online"] as? Bool ?? true }
    var room: String? { (raw["room"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var detail: String { [room, raw["detail"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }

    static func == (a: RealDevice, b: RealDevice) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Loads the devices of every connected platform once per screen.
@MainActor
@Observable
final class DeviceCatalog {
    private(set) var devices: [RealDevice] = []
    private(set) var errors: [String: String] = [:]
    private(set) var loading = false
    private(set) var loaded = false

    func load(_ model: AppModel) async {
        loading = true
        let (list, problems) = await model.allDevices()
        devices = list.map(RealDevice.init(raw:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        errors = problems
        loading = false
        loaded = true
    }

    func device(_ ref: PlanEditor.DeviceRef?) -> RealDevice? {
        guard let ref else { return nil }
        return devices.first { $0.ref == ref }
    }
}

/// Every lamp and AC of the plan and the real device it is linked to; tapping one picks
/// its device from the list of everything the connected platforms have.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var catalog = DeviceCatalog()
    @State private var picking: PlanEditor.Item?
    @State private var pickingSensor: PlanEditor.Item?
    @State private var adding = false

    private var editor: PlanEditor? { model.currentPlan.map(PlanEditor.init(plan:)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                if !model.hasAnyConnection {
                    noConnections
                } else if let errors = errorText {
                    ProblemLabel(text: errors)
                }
                if let editor {
                    ForEach(editor.rooms) { room in
                        let items = editor.items.filter { $0.room == room.id }
                        if !items.isEmpty { roomSection(room, items) }
                    }
                    if editor.items.isEmpty {
                        Card(padding: 16) {
                            Text("This home has no lamps or air conditioners yet. Add your devices to a room, or draw them in the editor.")
                                .font(.system(size: 15)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if model.hasAnyConnection {
                    Button { adding = true } label: { Label("Add devices to a room", systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!catalog.loaded)
                }
                Footnote(text: model.activePlan != "custom"
                         ? "Linking a device turns this demo into your own home, saved on this iPhone."
                         : model.macName.map { "Changes are saved at once and reach \($0)." } ?? "Changes are saved at once.")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if catalog.loading { ProgressView().tint(Theme.muted) }
            }
        }
        .refreshable { await catalog.load(model) }
        .task { if !catalog.loaded { await catalog.load(model) } }
        .sheet(item: $picking) { item in
            DevicePicker(title: item.name, kind: item.kind == .ac ? "ac" : "light", current: item.link,
                         used: editor?.usedDevices ?? [:], catalog: catalog) { device in
                model.editPlan { $0.link(item.id, to: device?.raw) }
                Haptics.shared.play("success")
            }
        }
        .sheet(item: $pickingSensor) { item in
            DevicePicker(title: "\(item.name) · room temperature", kind: "sensor", current: item.sensor,
                         used: editor?.usedDevices ?? [:], catalog: catalog,
                         include: { $0.service != "smartlife" || item.link?.service == "smartlife" }) { device in
                model.editPlan { $0.setSensor(item.id, to: device?.raw) }
                Haptics.shared.play("success")
            }
        }
        .sheet(isPresented: $adding) {
            AddDevicesView(catalog: catalog, used: editor?.usedDevices ?? [:], rooms: editor?.rooms ?? [])
        }
    }

    private var errorText: String? {
        let list = catalog.errors.map { "\(ConnectionLook.title($0.key)): \($0.value)" }
        return list.isEmpty ? nil : list.sorted().joined(separator: "\n")
    }

    private var noConnections: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(symbol: "link", tint: Theme.warm)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing connected yet").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Connect Smart Life, Home Assistant, Philips Hue or Apple Home in Settings first; their devices then appear here to choose from.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func roomSection(_ room: PlanEditor.Room, _ items: [PlanEditor.Item]) -> some View {
        VStack(spacing: 10) {
            SectionTitle(room.name)
            Card {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    Button { if model.hasAnyConnection { picking = item } } label: { row(item) }
                        .buttonStyle(RowButtonStyle())
                        .disabled(!model.hasAnyConnection)
                    if item.kind == .ac, model.hasAnyConnection {
                        Button { pickingSensor = item } label: { sensorRow(item) }
                            .buttonStyle(RowButtonStyle())
                    }
                }
            }
        }
    }

    private func row(_ item: PlanEditor.Item) -> some View {
        let device = catalog.device(item.link)
        return HStack(spacing: 14) {
            IconBadge(symbol: item.kind == .ac ? "air.conditioner.horizontal.fill" : "lightbulb.fill",
                      tint: item.link == nil ? Theme.muted : (item.kind == .ac ? Theme.accent : Theme.warm))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    if let link = item.link {
                        Image(systemName: ConnectionLook.symbol(link.service))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ConnectionLook.tint(link.service))
                        Text(device?.name ?? (catalog.loaded ? "Not found right now" : ConnectionLook.title(link.service)))
                            .foregroundStyle(device == nil && catalog.loaded ? Theme.red : Theme.muted)
                        if let device, !device.online { Text("· offline").foregroundStyle(Theme.red) }
                    } else {
                        Text("Simulated").foregroundStyle(Theme.faint)
                    }
                }
                .font(.system(size: 13.5))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 66)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose the real device")
    }

    private func sensorRow(_ item: PlanEditor.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.medium").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            Text("Room temperature").font(.system(size: 14)).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(catalog.device(item.sensor)?.name ?? (item.sensor == nil ? "Estimated" : "Not found right now"))
                .font(.system(size: 14)).foregroundStyle(Theme.faint).lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.leading, 66)
        .padding(.trailing, 14)
        .frame(minHeight: 40)
        .padding(.bottom, 6)
    }
}

/// The list of real devices of one kind to link a lamp, an AC or a thermometer to.
struct DevicePicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let kind: String
    let current: PlanEditor.DeviceRef?
    let used: [PlanEditor.DeviceRef: String]
    let catalog: DeviceCatalog
    var include: (RealDevice) -> Bool = { _ in true }
    let choose: (RealDevice?) -> Void
    @State private var search = ""

    private var candidates: [RealDevice] {
        catalog.devices.filter { $0.kind == kind && include($0) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.room ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    option(nil, name: kind == "sensor" ? "None — estimated" : "Not linked — simulated", detail: nil, symbol: "circle.dashed")
                }
                ForEach(["smartlife", "homeassistant", "hue", "homekit"], id: \.self) { service in
                    let list = candidates.filter { $0.service == service }
                    if !list.isEmpty {
                        Section(ConnectionLook.title(service)) {
                            ForEach(list) { device in
                                option(device, name: device.name, detail: detailLine(device), symbol: ConnectionLook.symbol(service))
                            }
                        }
                    }
                }
                if catalog.loaded, candidates.isEmpty {
                    Section {
                        Text(search.isEmpty ? "None of your connected platforms has a device of this kind." : "Nothing matches “\(search)”.")
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search devices")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay { if catalog.loading && !catalog.loaded { ProgressView().tint(Theme.muted) } }
        }
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func detailLine(_ device: RealDevice) -> String? {
        var parts = [device.detail]
        if !device.online { parts.append("offline") }
        if let user = used[device.ref], device.ref != current { parts.append("used by \(user)") }
        let line = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    private func option(_ device: RealDevice?, name: String, detail: String?, symbol: String) -> some View {
        let selected = device?.ref == current
        return Button {
            choose(device)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(device.map { ConnectionLook.tint($0.service) } ?? Theme.muted)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(device?.online == false ? Theme.muted : Theme.text)
                    if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Theme.faint).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Theme.surface)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Picks real devices that are not in the plan yet and puts them into a room, linked.
struct AddDevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let catalog: DeviceCatalog
    let used: [PlanEditor.DeviceRef: String]
    let rooms: [PlanEditor.Room]
    @State private var chosen: Set<String> = []
    @State private var room = ""
    @State private var newRoom = ""
    @State private var showAll = false

    private static let newRoomTag = "\u{0}new"

    private var candidates: [RealDevice] {
        catalog.devices.filter { $0.kind != "sensor" && (showAll || used[$0.ref] == nil) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Room", selection: $room) {
                        ForEach(rooms) { Text($0.name).tag($0.id) }
                        Text("New room…").tag(Self.newRoomTag)
                    }
                    .tint(Theme.accent)
                    if room == Self.newRoomTag {
                        TextField("Room name", text: $newRoom)
                            .textInputAutocapitalization(.words)
                    }
                } footer: {
                    Text("They are spread over the room; drag them into place later in the editor.")
                }
                .listRowBackground(Theme.surface)

                ForEach(["light", "ac"], id: \.self) { kind in
                    let list = candidates.filter { $0.kind == kind }
                    if !list.isEmpty {
                        Section(kind == "ac" ? "Air conditioners" : "Lights and plugs") {
                            ForEach(list) { device in row(device) }
                        }
                    }
                }
                Section {
                    Toggle("Show devices already in the plan", isOn: $showAll).tint(Theme.accent)
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.isEmpty ? "Add" : "Add \(chosen.count)") { add() }
                        .fontWeight(.semibold)
                        .disabled(chosen.isEmpty || (room == Self.newRoomTag && newRoom.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear { if room.isEmpty { room = rooms.first?.id ?? Self.newRoomTag } }
        }
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func row(_ device: RealDevice) -> some View {
        let on = chosen.contains(device.id)
        return Button {
            if on { chosen.remove(device.id) } else { chosen.insert(device.id) }
            Haptics.shared.play("tick")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(on ? Theme.accent : Theme.faint)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).foregroundStyle(Theme.text)
                    Text([ConnectionLook.title(device.service), device.detail, device.online ? nil : "offline",
                          used[device.ref].map { "in the plan as \($0)" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(Theme.faint).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Theme.surface)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func add() {
        let devices = catalog.devices.filter { chosen.contains($0.id) }.map(\.raw)
        let name = newRoom.trimmingCharacters(in: .whitespaces)
        let target = room
        model.editPlan { editor in
            let id = target == Self.newRoomTag ? editor.addRoom(named: name) : target
            editor.add(devices, to: id)
        }
        Haptics.shared.play("success")
        dismiss()
    }
}
