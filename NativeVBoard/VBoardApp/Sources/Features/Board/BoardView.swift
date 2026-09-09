import SwiftUI

struct BoardView: View {
    @EnvironmentObject private var api: APIClient
    let board: LibraryBoard
    @State private var state: BoardLoadState = .loading
    @State private var activeLoadID: UUID?

    var body: some View {
        Group {
            switch state {
            case .loading: ProgressView("Opening board…")
            case .ready(let document, let editor, let composition): BoardEditorSurface(board: board, document: document, editor: editor, composition: composition)
            case .failed(let message): ContentUnavailableView("Couldn’t open board", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: board.id) { await load() }
    }
    private func load() async {
        let loadID = UUID()
        activeLoadID = loadID
        state = .loading
        do {
            debug("BOARD OPEN START id=\(board.id)")
            // Validate the canonical board metadata route first. The SVG and
            // editor routes remain separate so the board stays isolated.
            _ = try await api.board(id: board.id)
            debug("BOARD OPEN METADATA SUCCEEDED id=\(board.id)")
            let editor = try await api.editor(id: board.id)
            debug("BOARD OPEN EDITOR SUCCEEDED id=\(board.id) objects=\(editor.objects.count)")
            let source = try await api.professorSVG(id: board.id)
            debug("BOARD OPEN SVG RESPONSE SUCCEEDED id=\(board.id) chars=\(source.utf8.count)")
            let document = try SVGDocument.parse(source)
            debug("BOARD OPEN SVG PARSE SUCCEEDED id=\(board.id) paths=\(document.paths.count)")
            let composition = SceneComposition.build(boardID: board.id, document: document, editor: editor)
            let uniqueIDs = Set(composition.nodes.map(\.logicalID)).count
            let textObjects = editor.objects.filter { $0.type == "text" }.count
            debug("BOARD SCENE BUILD board=\(board.id) professorSVGPaths=\(document.paths.count) editorObjects=\(editor.objects.count) groups=\(editor.groups.count) importedTransforms=\(editor.importedTransforms.count) softDeletedImports=\(editor.importedTransforms.values.filter { $0.deleted == true }.count) textObjects=\(textObjects) renderNodes=\(composition.nodes.count) uniqueLogicalIDs=\(uniqueIDs) duplicateLogicalIDs=\(composition.duplicateLogicalIDs)")
            guard !Task.isCancelled, activeLoadID == loadID else {
                debug("BOARD OPEN RESULT DISCARDED id=\(board.id) reason=stale-load")
                return
            }
            state = .ready(document, editor, composition)
            debug("BOARD OPEN FIRST SCENE READY id=\(board.id)")
        } catch let error as APIError {
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            let message: String
            switch error {
            case .transport: message = "Network unavailable. Check your connection and try again."
            case .server(let status, _, _): message = "Couldn’t load board data (HTTP \(status))."
            case .decoding: message = "Couldn’t decode board data returned by the server."
            case .invalidBaseURL: message = "Couldn’t load board data because the server URL is invalid."
            case .conflict: message = "This board changed elsewhere. Reload it before editing."
            }
            state = .failed(message); debug("BOARD OPEN FAILED id=\(board.id) userMessage=\(message) technical=\(error.localizedDescription)")
        } catch {
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            state = .failed("Couldn’t parse board artwork."); debug("BOARD OPEN FAILED id=\(board.id) stage=svgParse technical=\(error)")
        }
    }

    private func debug(_ message: String) {
        #if DEBUG
        print("[VBoard] \(message)")
        #endif
    }
}

private enum BoardLoadState { case loading, ready(SVGDocument, EditorState, SceneComposition), failed(String) }

private struct BoardEditorSurface: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let board: LibraryBoard
    let document: SVGDocument
    let editor: EditorState
    let composition: SceneComposition
    @State private var showImport = false
    @State private var showStudy = false
    @State private var showShare = false
    @State private var exportData: Data?
    @State private var exportError: String?
    var body: some View {
        ZStack(alignment: .bottom) {
            NativeCanvasView(boardID: board.id, document: document, camera: editor.viewport, objects: editor.objects, importedTransforms: editor.importedTransforms, composition: composition).ignoresSafeArea(edges: .bottom)
            HStack(spacing: 10) { ToolButton(title: "Pen", icon: "pencil.tip", selected: true) {}; ToolButton(title: "Pan", icon: "hand.draw", selected: false) {}; Spacer(); Button { showStudy = true } label: { Label("Study", systemImage: "sparkles") }.buttonStyle(.borderedProminent); Menu { Button { showImport = true } label: { Label("Add Whiteboard", systemImage: "plus") }; Button { Task { await export() } } label: { Label("Export SVG", systemImage: "square.and.arrow.up") }; Button(role: .destructive) { Task { await deleteBoard() } } label: { Label("Delete Board", systemImage: "trash") } } label: { Image(systemName: "ellipsis.circle.fill").font(.title2) }.buttonStyle(.bordered) }.padding(12).background(.regularMaterial, in: Capsule()).padding(.horizontal, 18).padding(.bottom, 12)
        }.navigationTitle(board.name).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showStudy = true } label: { Image(systemName: "sparkles") } } }
        .sheet(isPresented: $showImport) { ImportFlowView(folderID: board.folderID) { _ in showImport = false } }
        .sheet(isPresented: $showStudy) { StudyActionsView(boardID: board.id) }
        .sheet(isPresented: $showShare) { if let exportData { ShareSheet(items: [exportData]) } }
        .alert("Couldn’t export board", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(exportError ?? "") }
    }
    private func export() async { do { exportData = try await api.exportSVG(boardID: board.id); showShare = true } catch { exportError = "The SVG could not be exported right now." } }
    private func deleteBoard() async { do { try await api.deleteBoard(id: board.id); dismiss() } catch { exportError = "The board could not be deleted." } }
}

private struct ToolButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    var body: some View { Button(action: action) { VStack(spacing: 3) { Image(systemName: icon); Text(title).font(.caption2) }.frame(minWidth: 54, minHeight: 42) }.buttonStyle(.bordered).tint(selected ? .accentColor : .secondary) }
}

private struct StudyActionsView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let boardID: String
    @State private var loading = false
    @State private var result: StudyInteractionResponse?
    @State private var error: String?
    var body: some View { NavigationStack { VStack(spacing: 18) { if loading { ProgressView("Thinking about this board…") } else if let result { Text(result.interaction?.title ?? "Study Notes").font(.title2.bold()); ScrollView { Text(result.interaction?.answer ?? result.problem ?? "No study response was returned.").frame(maxWidth: 700, alignment: .leading).textSelection(.enabled) }; Button("Ask Again") { explain() }.buttonStyle(.bordered) } else { Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint); Text("Study this board").font(.title2.bold()); Text("Ask V-Board to explain the visible lecture material or create practice prompts.").multilineTextAlignment(.center).foregroundStyle(.secondary); Button("Explain") { explain() }.buttonStyle(.borderedProminent); Button("Practice Problems") { explain(action: "practice_problems") }.buttonStyle(.bordered) }; if let error { Text(error).foregroundStyle(.red) } }.padding(28).navigationTitle("Study").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } } } }
    private func explain(action: String = "explain") { loading = true; error = nil; Task { do { result = try await api.explain(boardID: boardID, action: action); loading = false } catch { loading = false; self.error = "AI is temporarily unavailable." } } }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
