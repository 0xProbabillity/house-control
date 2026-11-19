import SwiftUI

/// Shown once, over the demo home that is already running behind it.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A short screen (iPhone Duo closed) drops the icon and tightens up; one shorter still
        // (iPhone Duo open in landscape) scrolls what does not fit.
        ViewThatFits(in: .vertical) {
            content(compact: false)
            content(compact: true)
            ScrollView { content(compact: true) }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(false)
        .onDisappear { UserDefaults.standard.set(true, forKey: "welcomed") }
    }

    private func content(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if !compact {
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
            }

            Text("Welcome to House Control")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .padding(.top, compact ? 34 : 20)
            Text(Device.isPad ? String(localized: "Your home as a live 3D model, on your iPad.", comment: "Welcome screen: under the title")
                 : String(localized: "Your home as a live 3D model, in your pocket.", comment: "Welcome screen: under the title"))
                .font(.system(size: 16))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: compact ? 20 : 26) {
                feature("hand.tap.fill", Theme.warm, String(localized: "Tap a lamp, drag to dim", comment: "Welcome screen: a feature's title"),
                        String(localized: "Lights, colours, air conditioners and scenes, right on the floor plan.", comment: "Welcome screen"))
                feature("pencil.and.ruler.fill", Theme.accent, String(localized: "Draw it here or on your computer", comment: "Welcome screen: a feature's title; “it” is the home"),
                        Device.isPad
                            ? String(localized: "Rooms, lamps and ACs, on this iPad. Pair a Mac or PC any time: both stay in sync.", comment: "Welcome screen")
                            : String(localized: "Rooms, lamps and ACs, on this iPhone. Pair a Mac or PC any time: both stay in sync.", comment: "Welcome screen"))
                feature("lightbulb.2.fill", Theme.green, String(localized: "Your real devices", comment: "Welcome screen: a feature's title"),
                        AppModel.includesSmartLife
                            ? String(localized: "Smart Life, Home Assistant, Philips Hue and Apple Home. Until you connect one, everything is simulated.", comment: "Welcome screen")
                            : String(localized: "Home Assistant, Philips Hue and Apple Home. Until you connect one, everything is simulated.", comment: "Welcome screen"))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, compact ? 20 : 28)
            .frame(maxHeight: .infinity)

            Button { model.finishWelcome(.setUpHere) } label: { Label("Set up my home", systemImage: "house.fill") }
                .buttonStyle(PrimaryButtonStyle())
            Button { model.finishWelcome(.pair) } label: { Label("Pair with Mac or PC", systemImage: "laptopcomputer.and.iphone") }
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
        .readableWidth(520)
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
