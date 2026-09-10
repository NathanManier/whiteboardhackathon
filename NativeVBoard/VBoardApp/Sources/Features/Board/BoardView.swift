import SwiftUI
import UIKit

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
            case .workspaceConflict: message = "This lecture layout changed elsewhere. Reload it before editing."
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
    let composition: SceneComposition
    @StateObject private var store: BoardDocumentStore
    @State private var showImport = false
    @State private var showStudy = false
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showConflict = false
    @State private var activeTool: CanvasTool = .pen
    @State private var selectedIDs = Set<String>()
    @State private var liveCamera: CameraRect?

    init(board: LibraryBoard, document: SVGDocument, editor: EditorState, composition: SceneComposition) {
        self.board = board; self.document = document; self.composition = composition
        _store = StateObject(wrappedValue: BoardDocumentStore(boardID: board.id, editor: editor))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Keep one UIKit input surface alive for the board. Tool changes
            // update that surface in place so recognizers, responder focus,
            // and the live camera cannot be reset by SwiftUI identity churn.
            NativeCanvasView(boardID: board.id, document: document, camera: liveCamera ?? store.editor.viewport, objects: store.editor.objects, importedTransforms: store.editor.importedTransforms, composition: SceneComposition.build(boardID: board.id, document: document, editor: store.editor), onStroke: { stroke in store.applyStroke(stroke, api: api) }, tool: activeTool, onSelectionChanged: { selectedIDs = $0 }, onMove: { ids, delta in store.moveObjects(ids: ids, by: delta, api: api) }, onDelete: { ids in store.deleteObjects(ids: ids, api: api) }, onCameraChanged: { camera in liveCamera = camera; store.updateViewport(camera, api: api) }, onUndo: { store.undo(api: api) }, onRedo: { store.redo(api: api) })
                .ignoresSafeArea(edges: .bottom)
            HStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CanvasTool.allCases, id: \.self) { tool in
                            ToolButton(title: tool.title, icon: tool.icon, selected: activeTool == tool) { activeTool = tool }
                        }
                    }
                }
                Divider().frame(height: 28)
                Text(store.status.userLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 76, alignment: .leading)
                Button { showStudy = true } label: { Label("Explain", systemImage: "text.magnifyingglass") }.buttonStyle(.borderedProminent).controlSize(.small)
                Menu { Button { showImport = true } label: { Label("Add Whiteboard", systemImage: "plus") }; Button { Task { await export() } } label: { Label("Export SVG", systemImage: "square.and.arrow.up") }; Button(role: .destructive) { Task { await deleteBoard() } } label: { Label("Delete Board", systemImage: "trash") } } label: { Image(systemName: "ellipsis").font(.headline).frame(width: 32, height: 32) }.accessibilityLabel("Board actions")
            }.padding(.horizontal, 14).padding(.vertical, 8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(.horizontal, 14).padding(.bottom, 12)
            // SwiftUI's command system is the reliable keyboard path when the
            // simulator captures the Mac keyboard; the canvas also exposes
            // the same commands through UIKeyCommand for device input.
            Button("") { store.undo(api: api) }.keyboardShortcut("z", modifiers: .command).frame(width: 0, height: 0).opacity(0.001)
            Button("") { store.redo(api: api) }.keyboardShortcut("z", modifiers: [.command, .shift]).frame(width: 0, height: 0).opacity(0.001)
        }.navigationTitle(board.name).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItemGroup(placement: .navigationBarTrailing) { Button { store.undo(api: api) } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo); Button { store.redo(api: api) } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo); Button { showStudy = true } label: { Image(systemName: "text.magnifyingglass") }.accessibilityLabel("Explain selection") } }
        .sheet(isPresented: $showImport) { ImportFlowView(folderID: board.folderID) { _ in showImport = false } }
        .sheet(isPresented: $showStudy) { StudyActionsView(boardID: board.id, selectedObjectIDs: Array(selectedIDs)) { problems, interactionID in store.applyPracticeProblems(problems, interactionID: interactionID, api: api) } }
        .sheet(isPresented: $showShare) { if let exportURL { ShareSheet(items: [exportURL]) } }
        .alert("Couldn’t export board", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(exportError ?? "") }
        .alert("Board changed on the server", isPresented: $showConflict) {
            Button("Keep My Changes") { Task { await store.keepLocalChanges(api: api) } }
            Button("Reload Server Version", role: .destructive) { store.reloadServerVersion() }
        } message: { Text("Your local edits are preserved locally. Choose which version should remain.") }
        .onChange(of: store.status) { _, status in if status == .conflict { showConflict = true } }
        .task { store.restoreLocalIfPresent(server: store.editor) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in store.persistForBackgrounding() }
    }
    private func export() async {
        do {
            let data = try await api.exportSVG(boardID: board.id)
            let safeName = board.name.replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (safeName.isEmpty ? "V-Board" : safeName) + ".svg"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VBoardExports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            exportURL = url; showShare = true
        } catch { exportError = "The SVG could not be exported right now." }
    }
    private func deleteBoard() async { do { try await api.deleteBoard(id: board.id); dismiss() } catch { exportError = "The board could not be deleted." } }
}

private extension CanvasTool {
    var title: String { rawValue == "objectEraser" ? "Erase" : rawValue == "navigation" ? "Hand" : rawValue.capitalized }
    var icon: String { switch self { case .navigation: return "hand.draw"; case .pen: return "pencil.tip"; case .highlighter: return "highlighter"; case .select: return "cursorarrow"; case .lasso: return "lasso"; case .objectEraser: return "eraser" } }
}

private struct ToolButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 36, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(title)
        .help(title)
    }
}

struct StudyActionsView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let boardID: String
    let selectedObjectIDs: [String]
    let onPracticeProblems: ([PracticeProblem], String?) -> Void
    @State private var loading = false
    @State private var result: StudyInteractionResponse?
    @State private var error: String?
    var body: some View { NavigationStack { VStack(spacing: 18) { if loading { ProgressView("Reading the selected board…") } else if let result { Text(result.interaction?.title ?? (result.problems == nil ? "Board explanation" : "Practice Problems")).font(.title2.bold()); ScrollView { Text(result.interaction?.answer ?? result.problem ?? result.problems?.map(\.text).joined(separator: "\n\n") ?? "No study response was returned.").frame(maxWidth: 700, alignment: .leading).textSelection(.enabled) }; if let problems = result.problems, !problems.isEmpty { Label("Added to this board", systemImage: "rectangle.on.rectangle") .foregroundStyle(.secondary); Button("Add Again") { onPracticeProblems(problems, result.interaction?.id) }.buttonStyle(.bordered) }; HStack { Button("Explain Again") { explain() }.buttonStyle(.bordered); Button("Check My Work") { explain(action: "check_my_work") }.buttonStyle(.bordered) } } else { Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(.tint); Text("Study the selected ink").font(.title2.bold()); Text("Explain a selected concept, create two practice problems, or check a handwritten solution.").multilineTextAlignment(.center).foregroundStyle(.secondary); Button("Explain") { explain() }.buttonStyle(.borderedProminent); Button("Practice Problems") { explain(action: "practice_problems") }.buttonStyle(.bordered); Button("Check My Work") { explain(action: "check_my_work") }.buttonStyle(.bordered) }; if let error { Text(error).foregroundStyle(.red) } }.padding(28).navigationTitle("Study").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } } } }
    private func explain(action: String = "explain") { loading = true; error = nil; Task { do { result = try await api.explain(boardID: boardID, action: action, selectedObjectIDs: selectedObjectIDs); if action == "practice_problems", let problems = result?.problems { onPracticeProblems(problems, result?.interaction?.id) }; loading = false } catch { loading = false; self.error = "AI is temporarily unavailable." } } }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
