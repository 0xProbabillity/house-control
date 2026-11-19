import SwiftUI

/// Starts the user's own home on this phone: a name and something to start drawing from.
struct NewHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = String(localized: "My home", comment: "Name of the user's own home while it has none")
    @State private var template: String? = nil
    @State private var confirmReplace = false
    /// Scanning with LiDAR picked instead of a layout.
    @State private var scan = false
    @FocusState private var typing: Bool

    private let templates: [(id: String?, title: String, detail: String, symbol: String)] = [
        (nil, String(localized: "One room", comment: "New home: start from a single empty room"),
         String(localized: "Draw the rest yourself, or add your devices to it", comment: "New home: under One room"), "square.dashed"),
        ("studio", String(localized: "Studio layout", comment: "New home: start from the demo studio apartment"),
         String(localized: "3 rooms with furniture, to adapt", comment: "New home: under a layout to start from"), "square.split.bottomrightquarter.fill"),
        ("home", String(localized: "Apartment layout", comment: "New home: start from the demo apartment"),
         String(localized: "5 rooms with furniture, to adapt", comment: "New home: under a layout to start from"), "building.2.fill"),
        ("house", String(localized: "House on two floors", comment: "New home: start from the demo house"),
         String(localized: "10 rooms and stairs, to adapt", comment: "New home: under a layout to start from"), "stairs"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        SectionTitle("Name")
                        Card(padding: 16) {
                            InputField(title: String(localized: "What do you call it?", comment: "New home: label of the name field"), text: $name,
                                       prompt: String(localized: "My home", comment: "Name of the user's own home while it has none"), focused: typing) {
                                TextField("", text: $name)
                                    .textInputAutocapitalization(.words)
                                    .focused($typing)
                                    .submitLabel(.done)
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        SectionTitle("Start from")
                        #if ROOM_SCAN
                        if model.canScan {
                            Card {
                                Button { scan = true } label: {
                                    HStack(spacing: 14) {
                                        IconBadge(symbol: "cube.transparent.fill", tint: Theme.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 7) {
                                                Text("Scan with LiDAR").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                                BetaBadge()
                                            }
                                            Text("Walk through it with the camera; lamps and ACs pinned on the way")
                                                .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: scan ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(scan ? Theme.accent : Theme.faint)
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 72)
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityAddTraits(scan ? .isSelected : [])
                            }
                        }
                        #endif
                        Card {
                            ForEach(Array(templates.enumerated()), id: \.offset) { index, option in
                                if index > 0 { RowDivider() }
                                Button { template = option.id; scan = false } label: {
                                    HStack(spacing: 14) {
                                        IconBadge(symbol: option.symbol, tint: option.id == nil ? Theme.warm : Theme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                            Text(option.detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: !scan && template == option.id ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(!scan && template == option.id ? Theme.accent : Theme.faint)
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 66)
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityAddTraits(!scan && template == option.id ? .isSelected : [])
                            }
                        }
                        Footnote(text: scan ? String(localized: "The camera opens next. Nothing here changes until you save the scan.")
                                 : String(localized: "The editor opens next: drag rooms and lamps with a finger, pinch to zoom. Lamps and air conditioners stay simulated until you link them to your real devices."))
                    }
                    Button {
                        if scan { startScan() } else if model.hasCustomPlan { confirmReplace = true } else { create() }
                    } label: {
                        if scan { Label("Start scanning", systemImage: "viewfinder") }
                        else { Label("Create and edit", systemImage: "pencil.and.ruler.fill") }
                    }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .confirmationDialog(model.customPlanName.map { String(localized: "Replace \($0)?", comment: "New home: replace the user's own home; the placeholder is its name") }
                                            ?? String(localized: "Replace your home?"), isPresented: $confirmReplace, titleVisibility: .visible) {
                            Button("Replace", role: .destructive) { create() }
                        } message: {
                            Text(replaceMessage)
                        }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("New home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var replaceMessage: String {
        guard let mac = model.macName else {
            return Device.isPad
                ? String(localized: "This iPad keeps one home of your own. Export the current one from the editor first if you want to keep it.")
                : String(localized: "This iPhone keeps one home of your own. Export the current one from the editor first if you want to keep it.")
        }
        return Device.isPad
            ? String(localized: "This iPad keeps one home of your own, and \(mac) gets the new one too.", comment: "The placeholder is the paired computer's name")
            : String(localized: "This iPhone keeps one home of your own, and \(mac) gets the new one too.", comment: "The placeholder is the paired computer's name")
    }

    /// The scan asks before it replaces anything, once there is something to save.
    private func startScan() {
        #if ROOM_SCAN
        model.openScan(name: name.trimmingCharacters(in: .whitespaces))
        dismiss()
        #endif
    }

    private func create() {
        model.createHome(name: name.trimmingCharacters(in: .whitespaces), template: template)
        dismiss()
    }
}
