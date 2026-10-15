import SwiftUI

/// Starts the user's own home on this phone: a name and something to start drawing from.
struct NewHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My home"
    @State private var template: String? = nil
    @State private var confirmReplace = false
    @FocusState private var typing: Bool

    private let templates: [(id: String?, title: String, detail: String, symbol: String)] = [
        (nil, "One room", "Draw the rest yourself, or add your devices to it", "square.dashed"),
        ("studio", "Studio layout", "3 rooms with furniture, to adapt", "square.split.bottomrightquarter.fill"),
        ("home", "Apartment layout", "5 rooms with furniture, to adapt", "building.2.fill"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        SectionTitle("Name")
                        Card(padding: 16) {
                            InputField(title: "What do you call it?", text: $name, prompt: "My home", focused: typing) {
                                TextField("", text: $name)
                                    .textInputAutocapitalization(.words)
                                    .focused($typing)
                                    .submitLabel(.done)
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        SectionTitle("Start from")
                        Card {
                            ForEach(Array(templates.enumerated()), id: \.offset) { index, option in
                                if index > 0 { RowDivider() }
                                Button { template = option.id } label: {
                                    HStack(spacing: 14) {
                                        IconBadge(symbol: option.symbol, tint: option.id == nil ? Theme.warm : Theme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                                            Text(option.detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: template == option.id ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(template == option.id ? Theme.accent : Theme.faint)
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 66)
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityAddTraits(template == option.id ? .isSelected : [])
                            }
                        }
                        Footnote(text: "The editor opens next: drag rooms and lamps with a finger, pinch to zoom. Lamps and air conditioners stay simulated until you link them to your real devices.")
                    }
                    Button {
                        if model.hasCustomPlan { confirmReplace = true } else { create() }
                    } label: { Label("Create and edit", systemImage: "pencil.and.ruler.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .confirmationDialog("Replace \(model.customPlanName ?? "your home")?", isPresented: $confirmReplace, titleVisibility: .visible) {
                            Button("Replace", role: .destructive) { create() }
                        } message: {
                            Text(model.macName == nil
                                 ? "This iPhone keeps one home of your own. Export the current one from the editor first if you want to keep it."
                                 : "This iPhone keeps one home of your own, and \(model.macName ?? "your Mac") gets the new one too.")
                        }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 32)
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

    private func create() {
        model.createHome(name: name.trimmingCharacters(in: .whitespaces), template: template)
        dismiss()
    }
}
