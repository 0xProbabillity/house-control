import SwiftUI
import AVFoundation
import VisionKit
import HouseCore

/// Pairs this iPhone with House Control on a Mac: scan the code the Mac shows, or paste
/// the pairing link copied there (the clipboard travels between your devices by itself).
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var camera: CameraState = .unknown
    @State private var rejected = false
    @State private var paired: String?

    private enum CameraState { case unknown, ready, denied, unavailable }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let paired {
                    success(model.macName ?? paired)
                } else {
                    steps
                    viewfinder
                    if rejected {
                        Label("That is not a House Control pairing code.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.red)
                            .transition(.opacity)
                    }
                    paste
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: paired)
            .animation(.easeOut(duration: 0.2), value: rejected)
        }
        .background(Theme.background)
        .navigationTitle("Pair with Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { await prepareCamera() }
        // The Mac may also hand the link over directly (AirDrop, Handoff, a tap on the link).
        .onChange(of: model.macName) { _, name in
            if let name, paired == nil { paired = name }
        }
    }

    private var steps: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                step(1, "On your Mac, right-click the House Control icon in the menu bar.")
                step(2, "Choose **Pair iPhone…** — a code appears.")
                step(3, "Point this iPhone at the code. Both devices need to be on the same Wi-Fi.")
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.accent.opacity(0.16), in: Circle())
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black.opacity(0.35))
            switch camera {
            case .ready:
                CodeScanner { accept($0) }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                ViewfinderCorners().stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round)).padding(46)
            case .denied:
                placeholder("camera.fill", "Camera access is off",
                            "Allow the camera for House Control in Settings, or paste the pairing link below.")
            case .unavailable:
                placeholder("qrcode.viewfinder", "No camera here",
                            "Use Copy Pairing Link on the Mac and paste it below.")
            case .unknown:
                ProgressView().tint(Theme.muted)
            }
        }
        .frame(height: 300)
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.line))
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(Theme.faint)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
    }

    private var paste: some View {
        VStack(spacing: 10) {
            // PasteButton reads the clipboard without the "allow paste" prompt.
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in accept(strings.first ?? "") }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .tint(Theme.accent)
            Text("Or press **Copy Pairing Link** on the Mac and paste it here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    private func success(_ name: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(Theme.green)
                .symbolEffect(.bounce, value: paired)
                .padding(.top, 50)
            Text("Paired with \(name)")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text(statusLine)
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

    private var statusLine: String {
        switch model.syncStatus {
        case .connected:
            return model.hasCustomPlan ? "Connected. Your floor plan now stays the same on both, whichever one you edit."
                : "Connected. Draw your home here or on the Mac; it appears on both."
        case .failed(let reason): return reason
        default: return "Looking for the Mac on this Wi-Fi…"
        }
    }

    private func accept(_ text: String) {
        guard paired == nil else { return }
        guard let pairing = SyncPairing(link: text) else {
            rejected = true
            Haptics.shared.play("error")
            return
        }
        rejected = false
        model.pair(pairing)
        paired = pairing.name
    }

    private func prepareCamera() async {
        guard DataScannerViewController.isSupported else { camera = .unavailable; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = .ready
        case .notDetermined: camera = await AVCaptureDevice.requestAccess(for: .video) ? .ready : .denied
        default: camera = .denied
        }
    }
}

/// The four corner brackets drawn over the camera picture.
private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let arm = side * 0.16, radius: CGFloat = 18
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                 (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0), (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * radius))
            path.addQuadCurve(to: CGPoint(x: corner.x + dx * radius, y: corner.y), control: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }
}

/// VisionKit's live scanner, limited to QR codes.
private struct CodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                if let text = code.payloadStringValue { onCode(text) }
            }
        }
    }
}
