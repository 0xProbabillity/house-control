import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            HomeWebView(web: model.web)
                .ignoresSafeArea()
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(isPresented: $model.showWelcome) { WelcomeView() }
        .onOpenURL { model.open($0) }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

private struct BannerView: View {
    let banner: Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(banner.tint)
            Text(banner.text)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
