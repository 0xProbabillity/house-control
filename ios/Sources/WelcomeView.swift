import SwiftUI

/// Shown once, over the demo home that is already running behind it.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "house.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.95, blue: 0.86))
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(colors: [Color(red: 0.36, green: 0.24, blue: 0.52), Color(red: 0.13, green: 0.16, blue: 0.36), Color(red: 0.05, green: 0.07, blue: 0.16)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Theme.warm.opacity(0.45), radius: 22)
                .padding(.top, 44)
                .accessibilityHidden(true)

            Text("Welcome to House Control")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            Text("Your home as a live 3D model, in your pocket.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 26) {
                feature("hand.tap.fill", Theme.warm, "Tap a lamp, drag to dim",
                        "Lights, colours, air conditioners and scenes, right on the floor plan.")
                feature("pencil.and.ruler.fill", Theme.accent, "Draw it here or on your Mac",
                        "Rooms, lamps and ACs, on this iPhone. Pair a Mac any time: both stay in sync.")
                feature("lightbulb.2.fill", Theme.green, "Your real devices",
                        AppModel.includesSmartLife
                            ? "Smart Life, Home Assistant, Philips Hue and Apple Home. Until you connect one, everything is simulated."
                            : "Home Assistant, Philips Hue and Apple Home. Until you connect one, everything is simulated.")
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)

            Button { model.finishWelcome(.setUpHere) } label: { Label("Set up my home", systemImage: "house.fill") }
                .buttonStyle(PrimaryButtonStyle())
            Button { model.finishWelcome(.pair) } label: { Label("Pair with my Mac", systemImage: "laptopcomputer.and.iphone") }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 10)
            Button("Explore the demo home") { model.finishWelcome(.demo) }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 50)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(false)
        .onDisappear { UserDefaults.standard.set(true, forKey: "welcomed") }
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            IconBadge(symbol: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
