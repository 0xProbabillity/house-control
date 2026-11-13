#if ROOM_SCAN
import SwiftUI
import AVFoundation
import HouseCore

/// Scanning a home with the LiDAR camera, full screen: a few tips first, then the camera with
/// RoomPlan's live outline, then the floor plan it made.
struct ScanScreen: View {
    @Environment(AppModel.self) private var model
    @State private var controller: ScanController?
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller {
                if controller.phase == .review {
                    ScanReviewView(controller: controller)
                        .transition(.opacity)
                } else {
                    ScanLiveView(controller: controller)
                }
            } else {
                ScanIntroView(camera: camera, start: begin)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller?.phase)
        .preferredColorScheme(.dark)
        .onAppear {
            if controller == nil, let replay = model.scanReplay {
                controller = ScanController(homeName: model.scanName, replaying: replay)
            }
        }
        .onDisappear { controller?.close() }
    }

    private func begin() {
        if ScanController.previewing {
            controller = ScanController(homeName: model.scanName, saveURL: nil)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            controller = ScanController(homeName: model.scanName, saveURL: model.scanSaveURL)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    camera = granted ? .authorized : .denied
                    if granted { controller = ScanController(homeName: model.scanName, saveURL: model.scanSaveURL) }
                }
            }
        default:
            camera = .denied
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }
}

// MARK: - Before the camera

private struct ScanIntroView: View {
    @Environment(AppModel.self) private var model
    let camera: AVAuthorizationStatus
    let start: () -> Void

    private let tips: [(symbol: String, title: String, detail: String)] = [
        ("lightbulb.max.fill", "Turn the lights on", "RoomPlan sees walls best in a well lit room. Open the doors you will walk through."),
        ("figure.walk", "Walk along the walls", "Slowly, the camera at chest height, pointing at the walls, the floor and the furniture."),
        ("arrow.forward.to.line", "One room at a time", "Tap Next room in the doorway: every room lands in the same plan, lined up."),
        ("plus.circle.fill", "Pin your devices as you go", "Point the circle at a lamp or an air conditioner and tap +, then pick the real device."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.showScan = false } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        .frame(width: 36, height: 36).background(Theme.surfaceHigh, in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Theme.accent.opacity(0.16)).frame(width: 92, height: 92)
                            Image(systemName: "cube.transparent.fill").font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(Theme.accent).symbolEffect(.pulse, options: .repeating)
                        }
                        HStack(spacing: 8) {
                            Text("Scan your home").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
                            BetaBadge()
                        }
                        Text("The LiDAR camera measures each room as you walk through it, and House Control draws it in 3D: walls, doors, windows and furniture.")
                            .font(.system(size: 15.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Card {
                        ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                            if index > 0 { RowDivider() }
                            HStack(alignment: .top, spacing: 14) {
                                IconBadge(symbol: tip.symbol, tint: index == 3 ? Theme.warm : Theme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tip.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text(tip.detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 20)
                .readableWidth()
            }
            VStack(spacing: 10) {
                if !ScanController.isSupported {
                    ProblemLabel(text: "Scanning needs an iPhone with a LiDAR camera: the Pro models since iPhone 12 Pro.")
                } else if camera == .denied || camera == .restricted {
                    ProblemLabel(text: "House Control may not use the camera. Allow it in Settings, then come back.")
                }
                Button(action: start) {
                    Label(camera == .denied || camera == .restricted ? "Open Settings" : "Start scanning",
                          systemImage: camera == .denied ? "gear" : "viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!ScanController.isSupported)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .readableWidth()
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 10.5, weight: .heavy))
            .kerning(0.8)
            .foregroundStyle(Theme.warm)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.warm.opacity(0.16), in: Capsule())
            .accessibilityLabel("Beta")
    }
}

// MARK: - Scanning

private struct CaptureHost: UIViewRepresentable {
    let controller: ScanController

    func makeUIView(context: Context) -> UIView {
        let view = controller.makeView()
        DispatchQueue.main.async { controller.start() }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

private struct ScanLiveView: View {
    @Environment(AppModel.self) private var model
    @Bindable var controller: ScanController
    @State private var confirmClose = false
    @State private var hintShown = true

    var body: some View {
        ZStack {
            CaptureHost(controller: controller).ignoresSafeArea()
            // Centred on the whole screen, where the pins' raycast aims.
            if controller.capturing {
                Reticle().frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea().allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                topBar
                if controller.hot {
                    Label("The iPhone is getting warm: finish this room soon", systemImage: "thermometer.high")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.warm)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if let note = controller.note {
                    Label(note.text, systemImage: note.symbol)
                        .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(note.id)
                } else if hintShown, controller.tags.isEmpty, controller.roomsDone == 0, controller.capturing {
                    Text("Walk slowly along the walls. Point the circle at a lamp or an AC and tap +")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 30)
                        .transition(.opacity)
                }
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controller.capturing)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controller.interrupted)
            .animation(.easeInOut, value: controller.hot)

            switch controller.phase {
            case .building: BuildingOverlay(rooms: max(1, controller.roomsDone))
            case .failed(let message): FailedOverlay(message: message) { model.showScan = false }
            default: EmptyView()
            }
        }
        .statusBarHidden()
        .task { if !controller.catalog.loaded { await controller.catalog.load(model) } }
        .task {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            withAnimation { hintShown = false }
        }
        .sheet(item: $controller.picking) { tag in
            ScanDevicePicker(tag: tag, controller: controller).environment(model)
        }
        .confirmationDialog("Leave the scan?", isPresented: $confirmClose, titleVisibility: .visible) {
            if controller.roomsDone > 0 || controller.capturing {
                Button("Finish and see the plan") { controller.finish() }
            }
            Button("Discard the scan", role: .destructive) { model.showScan = false }
        } message: {
            Text("Rooms scanned so far are lost unless you finish.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                if controller.roomsDone > 0 || !controller.tags.isEmpty { confirmClose = true } else { model.showScan = false }
            } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            HStack(spacing: 8) {
                StatusDot(color: controller.capturing ? Theme.green : Theme.warm, pulsing: controller.capturing)
                Text(controller.switching ? "Saving room \(controller.roomsDone + 1)…" : "Room \(controller.roomsDone + 1)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                BetaBadge()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm)
                Text("\(controller.tags.count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 40, minHeight: 40)
            .padding(.horizontal, controller.tags.isEmpty ? 0 : 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel("\(controller.tags.count) devices pinned")
        }
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            if controller.interrupted != nil {
                VStack(spacing: 10) {
                    Text(controller.interrupted ?? "").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button { controller.resume() } label: { Label("Continue scanning", systemImage: "viewfinder") }
                            .buttonStyle(PrimaryButtonStyle())
                        if controller.roomsDone > 0 {
                            Button { controller.finish() } label: { Text("Done") }
                                .buttonStyle(SecondaryButtonStyle())
                                .frame(width: 100)
                        }
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                SideButton(title: "Next room", symbol: "arrow.forward.to.line", busy: controller.switching) { controller.nextRoom() }
                    .disabled(!controller.capturing)
                Spacer()
                Button { controller.tag() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(
                            LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.45), Color(red: 1, green: 0.58, blue: 0.3)],
                                           startPoint: .top, endPoint: .bottom), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                        .shadow(color: Theme.warm.opacity(0.5), radius: 16, y: 6)
                }
                .buttonStyle(PressStyle())
                .disabled(!controller.capturing)
                .opacity(controller.capturing ? 1 : 0.45)
                .accessibilityLabel("Pin a device where the circle points")
                Spacer()
                SideButton(title: "Done", symbol: "checkmark", busy: false) { controller.finish() }
                    .disabled(!controller.capturing && controller.roomsDone == 0)
            }
        }
        .frame(minHeight: 84)
    }
}

private struct SideButton: View {
    let title: String
    let symbol: String
    let busy: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    if busy { ProgressView().tint(Theme.text) } else {
                        Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                    }
                }
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .opacity(enabled ? 1 : 0.45)
            .frame(width: 86)
        }
        .buttonStyle(PressStyle())
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Where a tap on + puts the device.
private struct Reticle: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: 46, height: 46)
            Circle().fill(.white).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
        .transition(.scale.combined(with: .opacity))
        .accessibilityHidden(true)
    }
}

private struct BuildingOverlay: View {
    let rooms: Int

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(Theme.text)
                Text("Drawing your floor plan").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text(rooms == 1 ? "Squaring up the room and its furniture" : "Squaring up \(rooms) rooms and lining them up")
                    .font(.system(size: 14.5)).foregroundStyle(Theme.muted)
            }
        }
        .transition(.opacity)
    }
}

private struct FailedOverlay: View {
    let message: String
    let close: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(Theme.warm)
                Text("Nothing to draw yet").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text(message).font(.system(size: 14.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Close", action: close).buttonStyle(SecondaryButtonStyle()).frame(maxWidth: 220)
            }
            .padding(30)
        }
    }
}

// MARK: - Choosing a pinned device

/// What a pin is: a lamp or an AC of a connected platform, or one to link later. Half high
/// over the camera, so scanning carries on behind it.
private struct ScanDevicePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tag: RoomScan.Tag
    let controller: ScanController
    @State private var kind: String
    @State private var search = ""

    init(tag: RoomScan.Tag, controller: ScanController) {
        self.tag = tag
        self.controller = controller
        _kind = State(initialValue: tag.kind == "ac" ? "ac" : "light")
    }

    private var current: PlanEditor.DeviceRef? { tag.device.map { .init(service: $0.service, id: $0.id) } }

    private var candidates: [RealDevice] {
        let used = controller.taggedDevices
        return controller.catalog.devices
            .filter { $0.kind == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.room ?? "").localizedCaseInsensitiveContains(search) }
            .sorted { (used[$0.ref] == nil ? 0 : 1, $0.name) < (used[$1.ref] == nil ? 0 : 1, $1.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Lamp").tag("light")
                        Text("Air conditioner").tag("ac")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    row(nil, name: "\(ScanController.genericName(kind)) — link later", detail: "Simulated until you link it",
                        symbol: kind == "ac" ? "air.conditioner.horizontal" : "lightbulb")
                }
                ForEach(["smartlife", "homeassistant", "hue", "homekit"], id: \.self) { service in
                    let list = candidates.filter { $0.service == service }
                    if !list.isEmpty {
                        Section(ConnectionLook.title(service)) {
                            ForEach(list) { device in
                                row(device, name: device.name, detail: detail(device), symbol: ConnectionLook.symbol(service))
                            }
                        }
                    }
                }
                if controller.catalog.loading && !controller.catalog.loaded {
                    Section { HStack { ProgressView().tint(Theme.muted); Text("Looking for your devices…").foregroundStyle(Theme.muted) } }
                } else if !model.hasAnyConnection {
                    Section {
                        Text("Connect Smart Life, Home Assistant, Philips Hue or Apple Home in Settings, and their devices show up here to pick.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    }
                } else if candidates.isEmpty {
                    Section {
                        Text(search.isEmpty ? "No \(kind == "ac" ? "air conditioner" : "lamp") among your connected devices."
                                            : "Nothing matches “\(search)”.").foregroundStyle(Theme.muted)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        controller.remove(tag.id)
                        dismiss()
                    } label: { Label("Remove this pin", systemImage: "trash").foregroundStyle(Theme.red) }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search devices")
            .navigationTitle("What is it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if tag.device == nil, kind != tag.kind { controller.assign(tag.id, kind: kind, device: nil) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationBackground(Theme.background.opacity(0.94))
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onDisappear {
            // Swiped away after switching to AC: the pin follows the switch.
            if tag.device == nil, kind != tag.kind, controller.tags.contains(where: { $0.id == tag.id && $0.device == nil && $0.kind == tag.kind }) {
                controller.assign(tag.id, kind: kind, device: nil)
            }
        }
    }

    private func detail(_ device: RealDevice) -> String? {
        var parts = [device.detail]
        if !device.online { parts.append("offline") }
        if let user = controller.taggedDevices[device.ref], device.ref != current { parts.append("pinned as \(user)") }
        let line = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    private func row(_ device: RealDevice?, name: String, detail: String?, symbol: String) -> some View {
        let selected = device == nil ? current == nil && tag.kind == kind : device?.ref == current
        return Button {
            controller.assign(tag.id, kind: kind, device: device)
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
#endif
