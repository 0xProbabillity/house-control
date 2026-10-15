import SwiftUI
import UniformTypeIdentifiers

/// The home editor, full screen: the same web editor as the Mac's, laid out for a phone.
/// Connections open as native sheets on top of it; files go through the system pickers.
struct EditorScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.background.ignoresSafeArea()
            if let web = model.editorWeb {
                HomeWebView(web: web).ignoresSafeArea()
            }
        }
        .sheet(item: $model.editorSheet, onDismiss: { model.editorSheetClosed() }) { route in
            NavigationStack {
                Group {
                    switch route {
                    #if SMART_LIFE
                    case .smartLife: SmartLifeView()
                    #endif
                    case .homeAssistant: HomeAssistantView()
                    case .hue: HueView()
                    default: EmptyView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.editorSheet = nil }.fontWeight(.semibold)
                    }
                }
            }
            .environment(\.insideEditor, true)
            .presentationBackground(Theme.background)
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .fileImporter(isPresented: $model.editorImporting, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            model.editorImported(result.map { $0.first }.flatMap { url in url.map { .success($0) } ?? .failure(CocoaError(.userCancelled)) })
        } onCancellation: {
            model.editorImported(nil)
        }
        .fileExporter(isPresented: Binding(get: { model.editorExport != nil }, set: { if !$0 { model.editorExported(false) } }),
                      document: model.editorExport, contentType: .json,
                      defaultFilename: model.editorExport?.filename) { result in
            model.editorExported((try? result.get()) != nil)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }
}

/// A floor plan file for the system's "Save to Files".
struct PlanFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    let name: String

    var filename: String {
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return safe.split(separator: "-").joined(separator: "-").isEmpty ? "home.json" : "\(safe.split(separator: "-").joined(separator: "-")).json"
    }

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = "Home"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
