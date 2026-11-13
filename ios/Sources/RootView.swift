import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            HomeWebView(web: model.web)
                .ignoresSafeArea()
                #if ROOM_SCAN
                .fullScreenCover(isPresented: $model.showScan) { ScanScreen().environment(model) }
                #endif
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        // Each one is handed the model itself: on a Mac (the iPhone app running there) SwiftUI sizes
        // a sheet before it has the environment of the view it comes from, and a view reading
        // the model then stops the app ("No Observable object of type AppModel found").
        .sheet(isPresented: $model.showSettings) { SettingsView().environment(model) }
        .sheet(isPresented: $model.showWelcome) { WelcomeView().environment(model) }
        .sheet(isPresented: $model.showNewHome) { NewHomeView().environment(model) }
        .fullScreenCover(isPresented: $model.showEditor, onDismiss: { model.editorClosed() }) { EditorScreen().environment(model) }
        .alert("Which home do you keep?", isPresented: Binding(get: { model.planChoice != nil && !model.showEditor },
                                                               set: { if !$0, model.planChoice != nil { model.planChoice = nil } }),
               presenting: model.planChoice) { choice in
            Button("Keep this iPhone’s") { model.resolvePlanChoice(keepPhone: true) }
            Button("Keep \(choice.macName)’s") { model.resolvePlanChoice(keepPhone: false) }
            Button("Decide later", role: .cancel) {}
        } message: { choice in
            Text(choice.macPlanName == choice.phonePlanName
                 ? "“\(choice.phonePlanName)” was changed both here and on \(choice.macName) since they last synced. The one you keep replaces the other on both."
                 : "This iPhone has “\(choice.phonePlanName)”, \(choice.macName) has “\(choice.macPlanName)”. The one you keep replaces the other on both.")
        }
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
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
