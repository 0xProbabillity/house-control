import SwiftUI

/// Settings › Language: the device's languages, or one of House Control's translations.
/// iOS sets an app's language as it starts, so a change takes effect when the app opens again.
/// Taken from GlassDash (`UI/LanguagePage.swift`), in the look of the settings here.
struct LanguagePage: View {
    @State private var chosen = AppLanguage.chosen
    @State private var askReopen = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Card { row(nil) }
                footnote(Device.isPad
                    ? String(localized: "House Control uses the first of your iPad's languages that it speaks, else English.",
                             comment: "Language settings: under the choice that follows the device's languages")
                    : String(localized: "House Control uses the first of your iPhone's languages that it speaks, else English.",
                             comment: "Language settings: under the choice that follows the device's languages"))
                Card {
                    ForEach(Array(AppLanguage.all.enumerated()), id: \.element) { index, language in
                        if index > 0 { RowDivider().padding(.leading, -52) }
                        row(language)
                    }
                }
                .padding(.top, 20)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .readableWidth()
        }
        .background(Theme.background)
        .navigationTitle(String(localized: "Language", comment: "Settings: the app's language"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .languageReopenAlert(isPresented: $askReopen)
    }

    private func row(_ language: String?) -> some View {
        Button {
            guard language != chosen else { return }
            chosen = language
            AppLanguage.choose(language)
            askReopen = AppLanguage.next != AppLanguage.code
            Haptics.shared.play("tick")
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.map(AppLanguage.ownName) ?? LanguageChoice.sameAsDevice)
                        .font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                    if let detail = detail(language) {
                        Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: language == chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(language == chosen ? Theme.accent : Theme.faint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityAddTraits(language == chosen ? .isSelected : [])
    }

    /// Under a language its name in the app's own language; under the device's choice, what that is now.
    private func detail(_ language: String?) -> String? {
        guard let language else { return AppLanguage.ownName(AppLanguage.device) }
        let name = AppLanguage.name(language)
        return name == AppLanguage.ownName(language) ? nil : name
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Language row of Settings: hands its label what the app is set to, read again whenever
/// the row comes back on screen (after the language page).
struct LanguageRow<Label: View>: View {
    @ViewBuilder var label: (String) -> Label
    @State private var detail = LanguageChoice.current

    var body: some View {
        label(detail).onAppear { detail = LanguageChoice.current }
    }
}

enum LanguageChoice {
    /// The chosen language's own name, or "Same as iPhone".
    static var current: String { AppLanguage.chosen.map(AppLanguage.ownName) ?? sameAsDevice }

    static var sameAsDevice: String {
        Device.isPad
            ? String(localized: "Same as iPad", comment: "Language settings: follow the device's languages")
            : String(localized: "Same as iPhone", comment: "Language settings: follow the device's languages")
    }
}

extension View {
    /// After the language changes: House Control takes it when it opens again, so offer to close it now.
    func languageReopenAlert(isPresented: Binding<Bool>) -> some View {
        alert(String(localized: "Reopen House Control", comment: "Alert title after choosing another language"), isPresented: isPresented) {
            Button(String(localized: "Close House Control", comment: "Alert button: quits the app so it opens in the new language")) {
                // iOS gives an app its language only as it starts.
                exit(0)
            }
            Button(String(localized: "Later", comment: "Alert button: keep using the app in the current language for now"), role: .cancel) {}
        } message: {
            Text("House Control will be in \(AppLanguage.ownName(AppLanguage.next)) the next time it opens.",
                 comment: "Alert after choosing another language; the placeholder is the language's own name, e.g. Deutsch")
        }
    }
}
