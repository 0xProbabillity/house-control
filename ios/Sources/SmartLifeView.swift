import SwiftUI
import HouseCore

/// Signs this iPhone in to Smart Life. The login is confirmed by scanning a QR code with
/// the Smart Life app — which lives on this very phone, so the code has to be shown on
/// another screen: the paired Mac puts it up by itself.
struct SmartLifeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var userCode = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var login: Login?
    @State private var onMac = false
    @FocusState private var typing: Bool

    private struct Login: Equatable {
        let token: String
        let content: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if model.smartLifeConnected {
                    connected
                } else if let login {
                    code(login)
                } else {
                    entry
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: login)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.smartLifeConnected)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("Smart Life")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear { if userCode.isEmpty { userCode = model.suggestedUserCode } }
        .onChange(of: model.suggestedUserCode) { _, code in if userCode.isEmpty { userCode = code } }
        .onDisappear { _ = model.showOnMac(nil) }
        // Back from the Smart Life app: do not wait for the next poll to find out.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let login, !model.smartLifeConnected else { return }
            Task { _ = await model.finishLogin(token: login.token, userCode: userCode) }
        }
        // Ask every two seconds whether the login was confirmed, for as long as the code is up.
        .task(id: login) {
            guard let login else { return }
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if await model.finishLogin(token: login.token, userCode: userCode) { return }
            }
            self.login = nil
            problem = "The code expired before it was scanned. Show a new one."
        }
    }

    // MARK: - Step 1: the User Code

    private var entry: some View {
        VStack(spacing: 16) {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("User Code")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    TextField("", text: $userCode, prompt: Text("From the Smart Life app").foregroundStyle(Theme.faint))
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($typing)
                        .onSubmit { begin() }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(typing ? Theme.accent : Theme.line))
                    if !model.suggestedUserCode.isEmpty, userCode == model.suggestedUserCode {
                        Label("Filled in from your Mac", systemImage: "laptopcomputer")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            Button(action: begin) {
                if busy { ProgressView().tint(.white) } else { Label("Show sign-in code", systemImage: "qrcode") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || userCode.trimmingCharacters(in: .whitespaces).isEmpty)

            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Where is the User Code?", systemImage: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("In the Smart Life (or Tuya Smart) app: **Me → Settings → Account and Security**, at the bottom of the list. No Tuya developer account is needed.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func begin() {
        typing = false
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                let ticket = try await model.beginLogin(userCode: userCode)
                login = Login(token: ticket.token, content: ticket.qrContent)
                onMac = model.showOnMac(ticket.qrContent)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: - Step 2: the code

    private func code(_ login: Login) -> some View {
        VStack(spacing: 18) {
            if onMac, let mac = model.macName {
                Card(padding: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        IconBadge(symbol: "laptopcomputer", tint: Theme.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("The code is on \(mac)").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Switch to Smart Life on this iPhone, tap the scanner on its Home tab and point it at the Mac's screen. The code stays there while you are away; come back here when you have confirmed.")
                                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Card(padding: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        IconBadge(symbol: "qrcode.viewfinder", tint: Theme.warm)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scan this with Smart Life").font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("The Smart Life app on this iPhone has to scan it, so put the code on another screen: share it to a computer or tablet, or pair with your Mac and it appears there by itself.")
                                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let image = QRCode.image(for: login.content, scale: 12) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
                    .frame(width: 250, height: 250)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel("Smart Life sign-in code")
            }

            HStack(spacing: 8) {
                ProgressView().tint(Theme.muted).controlSize(.small)
                Text("Waiting for you to confirm in Smart Life…")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }

            HStack(spacing: 10) {
                if let png = QRCode.png(for: login.content, scale: 16) {
                    ShareLink(item: QRImage(png: png), preview: SharePreview("Smart Life sign-in code")) {
                        Label("Share code", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if !onMac, model.macName != nil {
                    Button { onMac = model.showOnMac(login.content) } label: { Label("Show on Mac", systemImage: "laptopcomputer") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            Button("Cancel") {
                _ = model.showOnMac(nil)
                self.login = nil
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.top, 4)
        }
    }

    // MARK: - Done

    private var connected: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(Theme.green)
                .symbolEffect(.bounce, value: model.smartLifeConnected)
                .padding(.top, 50)
            Text("Smart Life is connected")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(model.linkedDevices == 0
                 ? "Link lamps and air conditioners to your devices in the Mac's editor — they start working here as soon as the plan syncs."
                 : "\(model.linkedDevices) device\(model.linkedDevices == 1 ? "" : "s") in your floor plan \(model.linkedDevices == 1 ? "is" : "are") now the real thing.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button("Done") { model.showSettings = false }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 14)
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

/// The login code as a PNG, for the share sheet.
private struct QRImage: Transferable {
    let png: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName("Smart Life sign-in code.png")
    }
}
