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
            case .ready(let document, let pdfData, let editor, let composition): BoardEditorSurface(board: board, document: document, pdfData: pdfData, editor: editor, composition: composition)
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
            let record = try await api.board(id: board.id)
            debug("BOARD OPEN METADATA SUCCEEDED id=\(board.id)")
            let editor = try await api.editor(id: board.id)
            debug("BOARD OPEN EDITOR SUCCEEDED id=\(board.id) objects=\(editor.objects.count)")
            let source = try await api.professorSVG(id: board.id)
            debug("BOARD OPEN SVG RESPONSE SUCCEEDED id=\(board.id) chars=\(source.utf8.count)")
            let sourceKind = record.sourceKind ?? board.sourceKind
            let parsedDocument = try SVGDocument.parse(source)
            let document = PDFBoardSource.selectableDocument(parsedDocument, sourceKind: sourceKind)
            let pdfData: Data?
            if sourceKind.isPDF, let path = record.pdfURL ?? board.pdfURL {
                pdfData = try await api.cachedBoardAsset(
                    boardID: board.id,
                    path: path,
                    version: board.updatedAt.map { String($0) }
                )
            } else {
                pdfData = nil
            }
            debug("BOARD OPEN SVG PARSE SUCCEEDED id=\(board.id) paths=\(document.paths.count)")
            let composition = SceneComposition.build(boardID: board.id, document: document, editor: editor)
            let uniqueIDs = Set(composition.nodes.map(\.logicalID)).count
            let textObjects = editor.objects.filter { $0.type == "text" }.count
            debug("BOARD SCENE BUILD board=\(board.id) professorSVGPaths=\(document.paths.count) editorObjects=\(editor.objects.count) groups=\(editor.groups.count) importedTransforms=\(editor.importedTransforms.count) softDeletedImports=\(editor.importedTransforms.values.filter { $0.deleted == true }.count) textObjects=\(textObjects) renderNodes=\(composition.nodes.count) uniqueLogicalIDs=\(uniqueIDs) duplicateLogicalIDs=\(composition.duplicateLogicalIDs)")
            guard !Task.isCancelled, activeLoadID == loadID else {
                debug("BOARD OPEN RESULT DISCARDED id=\(board.id) reason=stale-load")
                return
            }
            state = .ready(document, pdfData, editor, composition)
            debug("BOARD OPEN FIRST SCENE READY id=\(board.id)")
        } catch let error as APIError {
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            let message: String
            switch error {
            case .transport: message = "Network unavailable. Check your connection and try again."
            case .authenticationExpired: message = "Your session expired. Sign in again."
            case .forbidden: message = "You don’t have permission to open this board."
            case .notFound: message = "This board is no longer available."
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

private enum BoardLoadState { case loading, ready(SVGDocument, Data?, EditorState, SceneComposition), failed(String) }

private struct BoardEditorSurface: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let board: LibraryBoard
    let document: SVGDocument
    let pdfData: Data?
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
    @State private var selectedPDFRegion: CGRect?
    @State private var liveCamera: CameraRect?
    @State private var studyInitialAction: String?
    @AppStorage("vboard.study.inspectorWidth") private var studyPanelWidth = 0.0
    @AppStorage("vboard.study.panelCollapsed") private var studyPanelCollapsed = false
    @AppStorage("vboard.workspace.physicalPaper") private var physicalBoardShowsPaper = false
    @AppStorage("vboard.workspace.background") private var backgroundRaw = WorkspaceBackgroundStyle.dots.rawValue
    @AppStorage("vboard.pen.color") private var penColor = CanvasStrokeStyle.pen.colorHex
    @AppStorage("vboard.pen.width") private var penWidth = CanvasStrokeStyle.pen.width
    @AppStorage("vboard.marker.color") private var markerColor = CanvasStrokeStyle.marker.colorHex
    @AppStorage("vboard.marker.width") private var markerWidth = CanvasStrokeStyle.marker.width
    @AppStorage("vboard.marker.opacity") private var markerOpacity = CanvasStrokeStyle.marker.opacity
    #if DEBUG
    @AppStorage("vboard.developer.diagnostics") private var developerDiagnostics = false
    #endif

    init(board: LibraryBoard, document: SVGDocument, pdfData: Data?, editor: EditorState, composition: SceneComposition) {
        self.board = board; self.document = document; self.pdfData = pdfData; self.composition = composition
        _store = StateObject(wrappedValue: BoardDocumentStore(boardID: board.id, editor: editor))
    }

    var body: some View {
        GeometryReader { outer in
            let docked = outer.size.width >= 820
            let panelWidth = showStudy && docked
                ? StudyPanelSizing.width(preferred: studyPanelWidth,
                                         availableWidth: outer.size.width,
                                         collapsed: studyPanelCollapsed)
                : 0
            ZStack(alignment: .trailing) {
                editorCanvas
                    .frame(width: outer.size.width, height: outer.size.height)
                if showStudy && docked {
                    StudyDock(width: $studyPanelWidth, collapsed: $studyPanelCollapsed,
                              availableWidth: outer.size.width,
                              onClose: { showStudy = false }) {
                        studyPanel(compact: true)
                    }
                    .frame(width: panelWidth, height: outer.size.height)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .sheet(isPresented: Binding(
                get: { showStudy && !docked },
                set: { if !$0 { showStudy = false } }
            )) { studyPanel(compact: false) }
        }
        .navigationTitle(board.name).navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { store.undo(api: api) } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo)
                Button { store.redo(api: api) } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo)
                Button { showImport = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Whiteboard")
                Menu {
                    Button { Task { await export() } } label: { Label("Export SVG", systemImage: "square.and.arrow.up") }
                    Picker("Workspace Background", selection: $backgroundRaw) {
                        ForEach(WorkspaceBackgroundStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
                    }
                    if pdfData == nil { Toggle("Show Whiteboard Paper", isOn: $physicalBoardShowsPaper) }
                    #if DEBUG
                    Toggle("Developer Diagnostics", isOn: $developerDiagnostics)
                    #endif
                    Button(role: .destructive) { Task { await deleteBoard() } } label: { Label("Delete Board", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showImport) { ImportFlowView(folderID: board.folderID) { _ in showImport = false } }
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

    private var editorCanvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
            // Keep one UIKit input surface alive for the board. Tool changes
            // update that surface in place so recognizers, responder focus,
            // and the live camera cannot be reset by SwiftUI identity churn.
            NativeCanvasView(boardID: board.id, document: document, pdfData: pdfData, camera: liveCamera ?? store.editor.viewport, objects: store.editor.objects, importedTransforms: store.editor.importedTransforms, composition: SceneComposition.build(boardID: board.id, document: document, editor: store.editor), showsPaper: pdfData != nil || physicalBoardShowsPaper, backgroundStyle: WorkspaceBackgroundStyle(rawValue: backgroundRaw) ?? .dots, penStyle: CanvasStrokeStyle(colorHex: penColor, width: penWidth, opacity: 1), markerStyle: CanvasStrokeStyle(colorHex: markerColor, width: markerWidth, opacity: markerOpacity), showsDeveloperDiagnostics: developerDiagnosticsIfAvailable, onStroke: { stroke in store.applyStroke(stroke, api: api) }, tool: activeTool, onSelectionChanged: { selectedIDs = $0 }, onSelectionRegionChanged: { selectedPDFRegion = $0 }, onMove: { ids, delta in selectedPDFRegion = nil; store.moveObjects(ids: ids, by: delta, api: api) }, onResize: { ids, anchor, factor in selectedPDFRegion = nil; store.scaleObjects(ids: ids, around: anchor, by: factor, api: api) }, onDelete: { ids in selectedPDFRegion = nil; store.deleteObjects(ids: ids, api: api) }, onCameraChanged: { camera in liveCamera = camera; store.updateViewport(camera, api: api) }, onUndo: { store.undo(api: api) }, onRedo: { store.redo(api: api) })
                .ignoresSafeArea(edges: .bottom)
            WorkspaceToolPalette(activeTool: $activeTool, status: store.status.userLabel,
                                 penColor: $penColor, penWidth: $penWidth,
                                 markerColor: $markerColor, markerWidth: $markerWidth,
                                 markerOpacity: $markerOpacity)
            .padding(.bottom, 12)

            if let rect = selectionScreenRect(viewport: proxy.size) {
                SelectionActionBar(canCheckWork: selectionCanCheckWork,
                                   explain: { openStudy("explain") },
                                   practice: { openStudy("practice_problems") },
                                   check: { openStudy("check_my_work") },
                                   delete: { store.deleteObjects(ids: selectedIDs, api: api) })
                    .position(SelectionToolbarLayout.position(for: rect, viewport: proxy.size))
            }
            // SwiftUI's command system is the reliable keyboard path when the
            // simulator captures the Mac keyboard; the canvas also exposes
            // the same commands through UIKeyCommand for device input.
            Button("") { store.undo(api: api) }.keyboardShortcut("z", modifiers: .command).frame(width: 0, height: 0).opacity(0.001)
            Button("") { store.redo(api: api) }.keyboardShortcut("z", modifiers: [.command, .shift]).frame(width: 0, height: 0).opacity(0.001)
            }
        }
    }

    private var developerDiagnosticsIfAvailable: Bool {
        #if DEBUG
        developerDiagnostics
        #else
        false
        #endif
    }

    @ViewBuilder private func studyPanel(compact: Bool) -> some View {
        if let selection = studySelection {
            StudyActionsView(selection: selection,
                             prepareSelection: { await store.saveNow(api: api) },
                             initialAction: studyInitialAction,
                             compact: compact) { problems, interactionID in
                store.applyPracticeProblems(problems, interactionID: interactionID, api: api)
            }
        } else {
            ContentUnavailableView("Select ink first", systemImage: "lasso",
                                   description: Text("Use Select or Lasso, then choose a study action."))
        }
    }

    private func openStudy(_ action: String) {
        studyInitialAction = action
        studyPanelCollapsed = false
        showStudy = true
    }

    private func selectionScreenRect(viewport: CGSize) -> CGRect? {
        guard let selection = studySelection else { return nil }
        let transform = WorldScreenTransform(camera: liveCamera ?? store.editor.viewport, viewport: viewport)
        let a = transform.screenPoint(for: CGPoint(x: selection.localBBox.x, y: selection.localBBox.y))
        let b = transform.screenPoint(for: CGPoint(x: selection.localBBox.x + selection.localBBox.width,
                                                    y: selection.localBBox.y + selection.localBBox.height))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private var studySelection: BoardStudySelection? {
        BoardStudySelection.isolated(boardID: board.id, selectedIDs: selectedIDs,
                                     document: document, editor: store.editor,
                                     preferredLocalBBox: selectedPDFRegion)
    }
    private var selectionCanCheckWork: Bool {
        let selectedObjects = store.editor.objects.filter { selectedIDs.contains($0.id) }
        return selectedObjects.contains(where: { $0.role == "ai_practice_problem" })
            && selectedObjects.contains(where: { $0.role != "ai_practice_problem" })
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

struct StudyActionsView: View {
    private enum LoadingStage {
        case preparingSelection
        case requestingExplanation
        case requestingPractice

        var label: String {
            switch self {
            case .preparingSelection: return "Reading selection…"
            case .requestingExplanation: return "Analyzing this board…"
            case .requestingPractice: return "Creating practice problems…"
            }
        }
    }
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let selection: BoardStudySelection
    let prepareSelection: () async -> Void
    var initialAction: String? = nil
    var compact = false
    let onPracticeProblems: ([PracticeProblem], String?) -> Void
    @StateObject private var submissionGate = StudySubmissionGate()
    @State private var loading = false
    @State private var loadingStage: LoadingStage = .preparingSelection
    @State private var result: StudyInteractionResponse?
    @State private var error: String?
    @State private var followUpQuestion = ""
    @State private var launchedInitialAction: String?

    var body: some View {
        Group {
            if compact {
                studyBody
            } else {
                NavigationStack {
                    studyBody
                        .navigationTitle("Study")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
            }
        }
        .task(id: initialAction) {
            guard let initialAction, launchedInitialAction != initialAction else { return }
            launchedInitialAction = initialAction
            switch initialAction {
            case "practice_problems": submitInitial(followUpAction: "practice_problems")
            case "check_my_work": submitInitial(action: "check_my_work")
            default: submitInitial()
            }
        }
    }

    private var studyBody: some View {
        VStack(spacing: compact ? 12 : 18) {
                if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(loadingStage.label)
                            .font(.subheadline.weight(.medium))
                        Text("Your selection stays visible while V-Board works.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result {
                    Text(result.interaction?.title ?? (result.problems == nil ? "Board explanation" : "Practice Problems"))
                        .font(.title2.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            StudyContentView(source: displayAnswer(result), maximumWidth: 700)
                            if let problems = result.problems, !problems.isEmpty {
                                ForEach(Array(problems.prefix(2))) { problem in
                                    StudyContentView(source: problem.text, maximumWidth: 660)
                                        .padding(14)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                }
                                Label("Added to this whiteboard", systemImage: "rectangle.on.rectangle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("Practice Problems") { followUp(action: "practice_problems") }
                            .buttonStyle(.bordered)
                        Button("Check My Work") { followUp(action: "check_my_work") }
                            .buttonStyle(.bordered)
                    }
                    HStack {
                        TextField("Ask a follow-up…", text: $followUpQuestion)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { followUp() }
                        Button("Send") { followUp() }
                            .buttonStyle(.borderedProminent)
                            .disabled(followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: compact ? .infinity : 700)
                } else {
                    Image(systemName: "text.magnifyingglass").font(compact ? .title2 : .largeTitle).foregroundStyle(.tint)
                    Text("Study the selected ink").font(compact ? .headline : .title2.bold())
                    Text("Explain a selected concept, create two practice problems, or check a handwritten solution.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Explain") { submitInitial() }.buttonStyle(.borderedProminent)
                    Button("Practice Problems") { submitInitial(followUpAction: "practice_problems") }.buttonStyle(.bordered)
                    Button("Check My Work") { submitInitial(action: "check_my_work") }.buttonStyle(.bordered)
                }
                if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(compact ? 16 : 28)
    }

    private func displayAnswer(_ response: StudyInteractionResponse) -> String {
        if let follow = response.interaction?.followUps?.last,
           follow.kind != "practice_problems", let answer = follow.answer, !answer.isEmpty { return answer }
        return response.interaction?.answer
            ?? response.problem
            ?? response.problems?.map(\.text).joined(separator: "\n\n")
            ?? "No study response was returned."
    }

    private func submitInitial(action: String = "explain", followUpAction: String? = nil) {
        let request = BoardStudyExplainRequest.make(selection: selection, action: action)
        guard submissionGate.begin(requestID: request.requestId) else {
            #if DEBUG
            print("[VBoard] STUDY REQUEST REJECTED reason=already-in-flight activeRequestID=\(submissionGate.activeRequestID ?? "<none>") attemptedRequestID=\(request.requestId)")
            #endif
            return
        }
        loading = true
        loadingStage = .preparingSelection
        error = nil
        Task {
            defer {
                submissionGate.end(requestID: request.requestId)
                loading = false
            }
            do {
                #if DEBUG
                let preparationStarted = Date().timeIntervalSinceReferenceDate
                #endif
                await prepareSelection()
                #if DEBUG
                print("[VBoard] AI TIMELINE request=\(request.requestId) stage=selectionPrepared milliseconds=\((Date().timeIntervalSinceReferenceDate - preparationStarted) * 1_000)")
                #endif
                loadingStage = .requestingExplanation
                let initial = try await api.explain(request: request)
                if let followUpAction {
                    guard let interactionID = initial.interaction?.id else {
                        throw APIError.decoding("The explanation did not include an interaction ID.")
                    }
                    loadingStage = followUpAction == "practice_problems"
                        ? .requestingPractice : .requestingExplanation
                    let response = try await api.followUp(
                        boardID: selection.boardID,
                        interactionID: interactionID,
                        action: followUpAction
                    )
                    apply(response)
                } else {
                    result = initial
                }
            } catch {
                self.error = "AI is temporarily unavailable."
            }
        }
    }

    private func followUp(action: String = "followup") {
        guard let interactionID = result?.interaction?.id else { return }
        let question = followUpQuestion
        loading = true
        loadingStage = action == "practice_problems" ? .requestingPractice : .requestingExplanation
        error = nil
        Task {
            do {
                let response = try await api.followUp(boardID: selection.boardID,
                                                      interactionID: interactionID,
                                                      action: action, question: question)
                followUpQuestion = ""
                apply(response)
            } catch {
                loading = false; self.error = "AI is temporarily unavailable."
            }
        }
    }

    private func apply(_ response: StudyInteractionResponse) {
        result = response
        if let problems = response.problems, !problems.isEmpty {
            onPracticeProblems(Array(problems.prefix(2)), response.interaction?.id)
        }
        loading = false
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
