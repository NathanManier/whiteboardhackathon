import SwiftUI
import UIKit

struct BoardView: View {
    @EnvironmentObject private var api: APIClient
    let board: LibraryBoard
    @State private var state: BoardLoadState = .loading(nil)
    @State private var activeLoadID: UUID?
    @State private var loadedPreview: UIImage?

    var body: some View {
        Group {
            switch state {
            case .loading(let preview):
                ZStack {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel("Board preview")
                    }
                    ProgressView("Opening editable board…")
                        .padding(14)
                        .background(.regularMaterial, in: Capsule())
                }
            case .ready(let document, let pdfData, let editor, let composition):
                BoardEditorSurface(board: board, document: document, previewImage: loadedPreview,
                                   pdfData: pdfData, editor: editor, composition: composition)
            case .failed(let message): ContentUnavailableView("Couldn’t open board", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(EditorNavigationGestureGuard())
        .task(id: board.id) { await load() }
    }
    private func load() async {
        let loadID = UUID()
        activeLoadID = loadID
        state = .loading(nil)
        loadedPreview = nil
        let trace = VBoardPerformanceTraceRegistry.shared.takeBoundTrace(
            for: board.id, operation: "board_open"
        )
        trace.event("board_open_requested", fields: ["board": board.id])
        let previewTask = Task { @MainActor () -> UIImage? in
            guard let path = board.thumbnailURL else { return nil }
            let started = ProcessInfo.processInfo.systemUptime
            guard let data = try? await api.cachedBoardAsset(
                boardID: board.id, path: path,
                version: board.updatedAt.map { String($0) }, trace: trace
            ), let image = UIImage(data: data), !Task.isCancelled,
                  activeLoadID == loadID else { return nil }
            loadedPreview = image
            if case .loading = state { state = .loading(image) }
            trace.event("first_useful_pixels", durationMilliseconds:
                (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                fields: ["source": "thumbnail", "bytes": data.count], once: true)
            return image
        }
        do {
            debug("BOARD OPEN START id=\(board.id)")
            // These immutable/isolated resources are independent. Starting
            // them together removes two avoidable production round trips.
            async let recordRequest = api.board(id: board.id, trace: trace)
            async let editorRequest = api.editor(id: board.id, trace: trace)
            async let sourceRequest = api.cachedProfessorSVG(
                id: board.id, version: board.updatedAt.map { String($0) }, trace: trace
            )
            let (record, editor, source) = try await (recordRequest, editorRequest, sourceRequest)
            trace.event("board_resources_ready", fields: [
                "editor_objects": editor.objects.count, "svg_bytes": source.utf8.count
            ])
            debug("BOARD OPEN METADATA SUCCEEDED id=\(board.id)")
            debug("BOARD OPEN EDITOR SUCCEEDED id=\(board.id) objects=\(editor.objects.count)")
            debug("BOARD OPEN SVG RESPONSE SUCCEEDED id=\(board.id) chars=\(source.utf8.count)")
            let sourceKind = record.sourceKind ?? board.sourceKind
            let parsedDocument = try await SVGDocument.parseOffMain(source, trace: trace)
            let document = PDFBoardSource.selectableDocument(parsedDocument, sourceKind: sourceKind)
            let pdfData: Data?
            if sourceKind.isPDF, let path = record.pdfURL ?? board.pdfURL {
                pdfData = try await api.cachedBoardAsset(
                    boardID: board.id,
                    path: path,
                    version: board.updatedAt.map { String($0) }, trace: trace
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
                previewTask.cancel()
                debug("BOARD OPEN RESULT DISCARDED id=\(board.id) reason=stale-load")
                return
            }
            state = .ready(document, pdfData, editor, composition)
            try? await api.recordBoardActivity(id: board.id)
            debug("BOARD OPEN FIRST SCENE READY id=\(board.id)")
            trace.event("scene_installed", fields: ["paths": document.paths.count])
        } catch let error as APIError {
            previewTask.cancel()
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
            case .workspaceConflict: message = "This class layout changed elsewhere. Reload it before editing."
            }
            state = .failed(message); debug("BOARD OPEN FAILED id=\(board.id) userMessage=\(message) technical=\(error.localizedDescription)")
        } catch {
            previewTask.cancel()
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

/// Owns the system's edge-back recognizer only while an editor destination is
/// onscreen. Canvas panning begins at the display edge, so allowing the
/// navigation controller to compete there causes accidental exits and lost
/// gesture sequences. The exact prior recognizer state is restored on exit.
@MainActor
final class EditorBackSwipeOwnership {
    private weak var recognizer: UIGestureRecognizer?
    private var previousIsEnabled = true
    private var previousDelegate: UIGestureRecognizerDelegate?
    private(set) var isActive = false

    func acquire(_ recognizer: UIGestureRecognizer) {
        if isActive, self.recognizer === recognizer {
            recognizer.isEnabled = false
            return
        }
        restore()
        self.recognizer = recognizer
        previousIsEnabled = recognizer.isEnabled
        previousDelegate = recognizer.delegate
        recognizer.isEnabled = false
        isActive = true
    }

    func restore() {
        guard isActive else { return }
        recognizer?.delegate = previousDelegate
        recognizer?.isEnabled = previousIsEnabled
        recognizer = nil
        previousDelegate = nil
        isActive = false
    }
}

struct EditorNavigationGestureGuard: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HostController {
        HostController()
    }

    func updateUIViewController(_ controller: HostController, context: Context) {
        controller.acquireNavigationGestureIfAvailable()
    }

    static func dismantleUIViewController(_ controller: HostController, coordinator: Void) {
        controller.restoreNavigationGesture()
    }

    @MainActor
    final class HostController: UIViewController {
        private let ownership = EditorBackSwipeOwnership()

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            acquireNavigationGestureIfAvailable()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            acquireNavigationGestureIfAvailable()
        }

        override func viewWillDisappear(_ animated: Bool) {
            restoreNavigationGesture()
            super.viewWillDisappear(animated)
        }

        func acquireNavigationGestureIfAvailable() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            ownership.acquire(gesture)
        }

        func restoreNavigationGesture() {
            ownership.restore()
        }
    }
}

private enum BoardLoadState {
    case loading(UIImage?)
    case ready(SVGDocument, Data?, EditorState, SceneComposition)
    case failed(String)
}

private struct BoardEditorSurface: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let board: LibraryBoard
    let document: SVGDocument
    let previewImage: UIImage?
    let pdfData: Data?
    let composition: SceneComposition
    @StateObject private var store: BoardDocumentStore
    @StateObject private var graphRecognition = GraphRecognitionController()
    @State private var showImport = false
    @State private var showStudy = false
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showConflict = false
    @State private var activeTool: CanvasTool = .pen
    @State private var previousPencilTool: CanvasTool = .pen
    @State private var pencilQuickPalettePoint: CGPoint?
    @State private var selectedIDs = Set<String>()
    @State private var selectedPDFRegion: CGRect?
    @State private var liveCamera: CameraRect?
    @State private var studyInitialAction: String?
    @State private var studyInteractions: [StudyInteraction] = []
    @State private var reopenedStudy: StudyInteraction?
    @State private var graphCreationRequest: GraphCreationRequest?
    @State private var editingGraph: GraphObject?
    @State private var interactiveGraph: GraphObject?
    @State private var canvasSize = CGSize.zero
    @AppStorage("vboard.study.inspectorWidth") private var studyPanelWidth = 0.0
    @AppStorage("vboard.study.panelCollapsed") private var studyPanelCollapsed = false
    @AppStorage("vboard.workspace.physicalPaper") private var physicalBoardShowsPaper = false
    @AppStorage("vboard.workspace.background") private var backgroundRaw = WorkspaceBackgroundStyle.dots.rawValue
    @AppStorage("vboard.pen.color") private var penColor = CanvasStrokeStyle.pen.colorHex
    @AppStorage("vboard.pen.width") private var penWidth = CanvasStrokeStyle.pen.width
    @AppStorage("vboard.marker.color") private var markerColor = CanvasStrokeStyle.marker.colorHex
    @AppStorage("vboard.marker.width") private var markerWidth = CanvasStrokeStyle.marker.width
    @AppStorage("vboard.marker.opacity") private var markerOpacity = CanvasStrokeStyle.marker.opacity
    @AppStorage("vboard.pencil.doubleTap") private var pencilDoubleTapRaw = PencilDoubleTapSetting.followSystem.rawValue
    @AppStorage("vboard.pencil.squeeze") private var pencilSqueezeRaw = PencilSqueezeSetting.followSystem.rawValue
    @AppStorage("vboard.pencil.hover") private var pencilHoverRaw = PencilHoverSetting.followSystem.rawValue
    #if DEBUG
    @AppStorage("vboard.developer.diagnostics") private var developerDiagnostics = false
    @State private var showPencilValidation = false
    #endif

    init(board: LibraryBoard, document: SVGDocument, previewImage: UIImage?, pdfData: Data?, editor: EditorState, composition: SceneComposition) {
        self.board = board; self.document = document; self.previewImage = previewImage
        self.pdfData = pdfData; self.composition = composition
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
                    PencilSettingsControls(doubleTapRaw: $pencilDoubleTapRaw,
                                           squeezeRaw: $pencilSqueezeRaw,
                                           hoverRaw: $pencilHoverRaw)
                    #if DEBUG
                    Toggle("Developer Diagnostics", isOn: $developerDiagnostics)
                    Button { showPencilValidation = true } label: {
                        Label("Apple Pencil Validation", systemImage: "pencil.and.scribble")
                    }
                    #endif
                    Button(role: .destructive) { Task { await deleteBoard() } } label: { Label("Delete Board", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showImport) { ImportFlowView(folderID: board.folderID) { _ in showImport = false } }
        .sheet(item: $graphCreationRequest) { request in
            GraphCreationSheet(
                target: request.target,
                recognition: graphRecognition,
                prepareSelection: { await store.saveNow(api: api) },
                onCreate: { expressions, requestID in
                    createGraph(expressions: expressions, requestID: requestID,
                                selection: request.selection,
                                sourceBoardIDs: request.sourceBoardIDs,
                                selectedObjectKeys: request.selectedObjectKeys)
                }
            )
            .environmentObject(api)
        }
        .sheet(item: $editingGraph) { graph in
            GraphExpressionEditor(graph: graph) { expressions in
                store.replaceGraph(graph.replacing(expressions: expressions), api: api)
            }
        }
        .sheet(item: $reopenedStudy) { interaction in
            SavedStudyInteractionView(interaction: interaction) {
                reopenedStudy = nil
                DispatchQueue.main.async { openStudy("explain", forceNew: true) }
            }
        }
        .sheet(isPresented: $showShare) { if let exportURL { ShareSheet(items: [exportURL]) } }
        #if DEBUG
        .sheet(isPresented: $showPencilValidation) { PencilHardwareValidationView() }
        #endif
        .alert("Couldn’t export board", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(exportError ?? "") }
        .alert("Board changed on the server", isPresented: $showConflict) {
            Button("Keep My Changes") { Task { await store.keepLocalChanges(api: api) } }
            Button("Reload Server Version", role: .destructive) { store.reloadServerVersion() }
        } message: { Text("Your local edits are preserved locally. Choose which version should remain.") }
        .onChange(of: store.status) { _, status in if status == .conflict { showConflict = true } }
        .onChange(of: activeTool) { oldTool, tool in
            if oldTool != tool && oldTool != .objectEraser { previousPencilTool = oldTool }
            if !GraphPencilInteractionPolicy.allowsAnnotation(for: tool) {
                interactiveGraph = nil
            }
        }
        .onChange(of: studySelection) { _, selection in
            // Graph recognition begins only after the explicit Graph action.
            // Selection changes must not spend AI work or leave an unexplained
            // spinner beside the study actions.
            graphRecognition.clear()
            if selection?.canonicalObjectIDs != interactiveGraph.map({ [$0.id] }) {
                interactiveGraph = nil
            }
        }
        .task {
            store.restoreLocalIfPresent(server: store.editor)
            studyInteractions = (try? await api.studyInteractions(boardID: board.id)) ?? []
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in store.persistForBackgrounding() }
    }

    private var editorCanvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
            // Keep one UIKit input surface alive for the board. Tool changes
            // update that surface in place so recognizers, responder focus,
            // and the live camera cannot be reset by SwiftUI identity churn.
            NativeCanvasView(
                boardID: board.id, document: document, previewImage: previewImage, pdfData: pdfData,
                sourceKind: board.sourceKind,
                camera: liveCamera ?? store.editor.viewport, objects: store.editor.objects,
                importedTransforms: store.editor.importedTransforms,
                composition: SceneComposition.build(boardID: board.id, document: document,
                                                    editor: store.editor),
                showsPaper: pdfData != nil || physicalBoardShowsPaper,
                backgroundStyle: WorkspaceBackgroundStyle(rawValue: backgroundRaw) ?? .dots,
                penStyle: CanvasStrokeStyle(colorHex: penColor, width: penWidth, opacity: 1),
                markerStyle: CanvasStrokeStyle(colorHex: markerColor, width: markerWidth,
                                               opacity: markerOpacity),
                pencilPreferences: pencilPreferences,
                isPencilPalettePresented: pencilQuickPalettePoint != nil,
                showsDeveloperDiagnostics: developerDiagnosticsIfAvailable,
                onStroke: { stroke in store.applyStroke(stroke, api: api) }, tool: activeTool,
                onSelectionChanged: { selectedIDs = $0 },
                onSelectionRegionChanged: { selectedPDFRegion = $0 },
                onMove: { ids, delta in selectedPDFRegion = nil; store.moveObjects(ids: ids, by: delta, api: api) },
                onResize: { ids, anchor, factor in selectedPDFRegion = nil; store.scaleObjects(ids: ids, around: anchor, by: factor, api: api) },
                onDelete: { ids in selectedPDFRegion = nil; store.deleteObjects(ids: ids, api: api) },
                onCameraChanged: { camera in liveCamera = camera; store.updateViewport(camera, api: api) },
                onUndo: { store.undo(api: api) }, onRedo: { store.redo(api: api) },
                onPencilAction: handlePencilAction,
                onPencilPaletteMoved: { pencilQuickPalettePoint = $0 },
                onPencilPaletteDismiss: { pencilQuickPalettePoint = nil }
            )
                .ignoresSafeArea(edges: .bottom)
            ForEach(store.editor.objects.compactMap(\.graph).filter {
                $0.id != interactiveGraph?.id
            }) { graph in
                let rect = graphScreenRect(graph, viewport: proxy.size)
                if rect.intersects(CGRect(origin: .zero, size: proxy.size)) {
                    GraphAccessibilityProxy(
                        graph: graph,
                        onInteract: { interactiveGraph = graph },
                        onEdit: { editingGraph = graph },
                        onDelete: {
                            selectedIDs.remove(graph.id)
                            store.deleteObjects(ids: Set([graph.id]), api: api)
                        }
                    )
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .position(x: rect.midX, y: rect.midY)
                    .zIndex(10)
                }
            }
            if interactiveGraph != nil {
                GraphOutsideInteractionShield { interactiveGraph = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(5)
            }
            if let graph = interactiveGraph {
                let rect = graphScreenRect(graph, viewport: proxy.size)
                if rect.intersects(CGRect(origin: .zero, size: proxy.size)) {
                GraphInteractiveSurface(
                    graph: graph,
                    canonicalStrokeObjects: GraphAnnotationOverlayPolicy.strokeObjectsAbove(
                        graphID: graph.id, in: store.editor.objects
                    ),
                    pencilAnnotationEnabled:
                        GraphPencilInteractionPolicy.allowsAnnotation(for: activeTool),
                    pencilStyle: activeTool == .highlighter
                        ? CanvasStrokeStyle(colorHex: markerColor, width: markerWidth,
                                            opacity: markerOpacity)
                        : CanvasStrokeStyle(colorHex: penColor, width: penWidth, opacity: 1),
                    pencilPreferences: pencilPreferences,
                    onPencilStroke: { store.applyStroke($0, api: api) },
                    onPencilRequestsPassiveMode: { interactiveGraph = nil },
                    onCommitViewport: { owningBoardID, graphID, viewport in
                        guard owningBoardID == board.id,
                              let current = store.editor.objects
                                .first(where: { $0.id == graphID })?.graph else { return }
                        let updated = current.replacing(viewport: viewport)
                        store.replaceGraph(updated, api: api)
                        if interactiveGraph?.id == graphID { interactiveGraph = updated }
                    },
                    onEdit: {
                        editingGraph = store.editor.objects
                            .first(where: { $0.id == graph.id })?.graph ?? graph
                        interactiveGraph = nil
                    },
                    onDone: { interactiveGraph = nil }
                )
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                .zIndex(20)
                }
            }
            WorkspaceToolPalette(activeTool: $activeTool, status: store.status.userLabel,
                                 penColor: $penColor, penWidth: $penWidth,
                                 markerColor: $markerColor, markerWidth: $markerWidth,
                                 markerOpacity: $markerOpacity)
            .padding(.bottom, 12)
            .zIndex(30)

            if let point = pencilQuickPalettePoint {
                let paletteSize = CGSize(width: 420, height: 56)
                let origin = PencilPalettePlacement.origin(
                    anchor: point, paletteSize: paletteSize,
                    safeBounds: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 8, dy: 8)
                )
                PencilQuickPalette(activeTool: activeTool, recentColors: [penColor, markerColor],
                                   width: activeTool == .highlighter ? $markerWidth : $penWidth,
                                   selectColor: { color in
                                       if activeTool == .highlighter { markerColor = color }
                                       else { penColor = color }
                                   },
                                   undo: { store.undo(api: api) }, redo: { store.redo(api: api) }) {
                    activeTool = $0
                    pencilQuickPalettePoint = nil
                }
                .position(x: origin.x + paletteSize.width / 2,
                          y: origin.y + paletteSize.height / 2)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .zIndex(31)
            }

            if interactiveGraph == nil, let rect = selectionScreenRect(viewport: proxy.size) {
                SelectionActionBar(canCheckWork: selectionCanCheckWork,
                                   graphPrimaryTitle: graphPrimaryTitle,
                                   graphIsLoading: false,
                                   explain: { openStudy("explain") },
                                   practice: { openStudy("practice_problems") },
                                   check: { openStudy("check_my_work") },
                                   graphPrimary: { performPrimaryGraphAction() },
                                   graphSelection: { openGraphCreation() },
                                   editGraph: selectedGraph.map { graph in { editingGraph = graph } },
                                   resetGraph: selectedGraph.map { graph in
                                       { store.replaceGraph(graph.replacing(viewport: .conventional), api: api) }
                                   },
                                   duplicateGraph: selectedGraph.map { graph in
                                       {
                                           if let id = store.duplicateGraph(id: graph.id, api: api) {
                                               selectedIDs = [id]
                                           }
                                       }
                                   },
                                   delete: { store.deleteObjects(ids: selectedIDs, api: api) })
                    .position(SelectionToolbarLayout.position(for: rect, viewport: proxy.size))
            }
            ForEach(Array(studyInteractions.enumerated()), id: \.offset) { index, interaction in
                if interaction.boardID == nil || interaction.boardID == board.id,
                   let anchor = StudyMarkerGeometry.boardLocalAnchor(
                       for: interaction, document: document, editor: store.editor
                   ) {
                    let transform = WorldScreenTransform(
                        camera: liveCamera ?? store.editor.viewport, viewport: proxy.size
                    )
                    let point = transform.screenPoint(for: anchor)
                    StudyMarkerButton(interaction: interaction) {
                        reopenedStudy = interaction
                    }
                    .position(x: point.x + StudyMarkerGeometry.screenOffset(index: index).x,
                              y: point.y + StudyMarkerGeometry.screenOffset(index: index).y)
                    .zIndex(25)
                }
            }
            // SwiftUI's command system is the reliable keyboard path when the
            // simulator captures the Mac keyboard; the canvas also exposes
            // the same commands through UIKeyCommand for device input.
            Button("") { store.undo(api: api) }.keyboardShortcut("z", modifiers: .command).frame(width: 0, height: 0).opacity(0.001)
            Button("") { store.redo(api: api) }.keyboardShortcut("z", modifiers: [.command, .shift]).frame(width: 0, height: 0).opacity(0.001)
            if interactiveGraph != nil {
                Button("") { interactiveGraph = nil }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0.001)
            }
            }
            .onAppear { canvasSize = proxy.size }
            .onChange(of: proxy.size) { _, value in canvasSize = value }
        }
    }

    private var developerDiagnosticsIfAvailable: Bool {
        #if DEBUG
        developerDiagnostics
        #else
        false
        #endif
    }

    private var pencilPreferences: PencilPreferences {
        PencilPreferences(
            doubleTap: PencilDoubleTapSetting(rawValue: pencilDoubleTapRaw) ?? .followSystem,
            squeeze: PencilSqueezeSetting(rawValue: pencilSqueezeRaw) ?? .followSystem,
            hover: PencilHoverSetting(rawValue: pencilHoverRaw) ?? .followSystem
        )
    }

    private func handlePencilAction(_ action: PencilLogicalAction, anchor: CGPoint?) {
        switch action {
        case .none, .runSystemShortcut: break
        case .switchEraser: togglePencilEraser()
        case .switchPrevious:
            let next = previousPencilTool == activeTool ? .pen : previousPencilTool
            previousPencilTool = activeTool
            activeTool = next
        case .showColorPalette, .showInkAttributes, .showToolPalette:
            withAnimation(.easeOut(duration: 0.16)) {
                pencilQuickPalettePoint = anchor ?? CGPoint(x: canvasSize.width / 2,
                                                            y: canvasSize.height / 2)
            }
        }
    }

    private func togglePencilEraser() {
        if activeTool == .objectEraser {
            activeTool = previousPencilTool == .objectEraser ? .pen : previousPencilTool
        } else {
            previousPencilTool = activeTool
            activeTool = .objectEraser
        }
    }

    @ViewBuilder private func studyPanel(compact: Bool) -> some View {
        if let selection = studySelection {
            StudyActionsView(selection: selection,
                             prepareSelection: { await store.saveNow(api: api) },
                             initialAction: studyInitialAction,
                             compact: compact,
                             onInteractionSaved: upsertStudyInteraction,
                             onPracticeProblems: { problems, interactionID in
                                 store.applyPracticeProblems(problems, interactionID: interactionID, api: api)
                             })
        } else {
            ContentUnavailableView("Select ink first", systemImage: "lasso",
                                   description: Text("Use Select or Lasso, then choose a study action."))
        }
    }

    private func openStudy(_ action: String, forceNew: Bool = false) {
        if action == "explain", !forceNew, let selection = studySelection,
           let existing = studyInteractions.first(where: {
               Set($0.selectedObjectIDs ?? []) == Set(selection.canonicalObjectIDs)
           }) {
            reopenedStudy = existing
            return
        }
        studyInitialAction = action == "explain" ? nil : action
        studyPanelCollapsed = false
        showStudy = true
    }

    private func upsertStudyInteraction(_ interaction: StudyInteraction) {
        guard let id = interaction.id else { return }
        if let index = studyInteractions.firstIndex(where: { $0.id == id }) {
            studyInteractions[index] = interaction
        } else {
            studyInteractions.append(interaction)
        }
    }

    private func selectionScreenRect(viewport: CGSize) -> CGRect? {
        guard let selection = studySelection else { return nil }
        let transform = WorldScreenTransform(camera: liveCamera ?? store.editor.viewport, viewport: viewport)
        let a = transform.screenPoint(for: CGPoint(x: selection.localBBox.x, y: selection.localBBox.y))
        let b = transform.screenPoint(for: CGPoint(x: selection.localBBox.x + selection.localBBox.width,
                                                    y: selection.localBBox.y + selection.localBBox.height))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func graphScreenRect(_ graph: GraphObject, viewport: CGSize) -> CGRect {
        let transform = WorldScreenTransform(camera: liveCamera ?? store.editor.viewport,
                                             viewport: viewport)
        let a = transform.screenPoint(for: graph.frame.cgRect.origin)
        let b = transform.screenPoint(for: CGPoint(x: graph.frame.cgRect.maxX,
                                                    y: graph.frame.cgRect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private var studySelection: BoardStudySelection? {
        BoardStudySelection.isolated(boardID: board.id, selectedIDs: selectedIDs,
                                     document: document, editor: store.editor,
                                     preferredLocalBBox: selectedPDFRegion)
    }
    private var selectedGraph: GraphObject? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return store.editor.objects.first(where: { $0.id == id })?.graph
    }
    private var graphPrimaryTitle: String? {
        if selectedGraph != nil { return "Interact" }
        return studySelection == nil ? nil : "Graph"
    }

    private func performPrimaryGraphAction() {
        if let graph = selectedGraph {
            interactiveGraph = graph
        } else {
            openGraphCreation()
        }
    }

    private func openGraphCreation() {
        guard let selection = studySelection, selectedGraph == nil else { return }
        graphCreationRequest = GraphCreationRequest(selection: selection)
    }

    private func createGraph(expressions: [GraphExpression], requestID: String?,
                             selection: BoardStudySelection,
                             sourceBoardIDs: [String], selectedObjectKeys: [String]) {
        let scale = canvasSize.width > 0 && canvasSize.height > 0
            ? WorldScreenTransform(camera: liveCamera ?? store.editor.viewport,
                                   viewport: canvasSize).scale : 1
        let occupied = store.editor.objects.map { BoardHitTestPolicy.bounds(of: $0) }
        let graph = GraphObjectFactory.make(
            boardID: board.id, selection: selection, expressions: expressions,
            recognitionRequestID: requestID, cameraScale: scale, occupied: occupied,
            sourceBoardIDs: sourceBoardIDs, selectedObjectKeys: selectedObjectKeys
        )
        store.addGraph(graph, api: api)
        selectedIDs = [graph.id]
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
    var onInteractionSaved: (StudyInteraction) -> Void = { _ in }
    let onPracticeProblems: ([PracticeProblem], String?) -> Void
    @StateObject private var submissionGate = StudySubmissionGate()
    @State private var loading = false
    @State private var loadingStage: LoadingStage = .preparingSelection
    @State private var result: StudyInteractionResponse?
    @State private var error: String?
    @State private var initialQuestion = ""
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
                    StudyRichHeading(
                        source: result.interaction?.title
                            ?? (result.problems == nil ? "Board explanation" : "Practice Problems")
                    )
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
                    TextField("Optional question or focus", text: $initialQuestion)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: compact ? .infinity : 700)
                        .onSubmit { submitInitial(question: initialQuestion) }
                    Button("Explain") { submitInitial(question: initialQuestion) }
                        .buttonStyle(.borderedProminent)
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

    private func submitInitial(action: String = "explain", followUpAction: String? = nil,
                               question: String? = nil) {
        let trimmedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = BoardStudyExplainRequest.make(
            selection: selection,
            action: action,
            question: trimmedQuestion?.isEmpty == false ? trimmedQuestion : nil
        )
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
                    apply(initial)
                }
            } catch {
                self.error = "AI is temporarily unavailable."
            }
        }
    }

    private func followUp(action: String = "followup") {
        guard !loading, let interactionID = result?.interaction?.id else { return }
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
        if let interaction = response.interaction {
            onInteractionSaved(interaction)
        }
        if let problems = response.problems, !problems.isEmpty {
            onPracticeProblems(Array(problems.prefix(2)), response.interaction?.id)
        }
        loading = false
    }
}

struct StudyRichHeading: View {
    let source: String

    var body: some View {
        StudyContentView(source: "## \(source)", maximumWidth: 700)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct StudyMarkerButton: View {
    let interaction: StudyInteraction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open saved explanation")
        .accessibilityHint(CompactStudyPresentation.readableText(
            from: interaction.title ?? "Study note"
        ))
    }
}

enum StudyMarkerGeometry {
    static func screenOffset(index: Int) -> CGPoint {
        guard index > 0 else { return .zero }
        let slot = (index - 1) % 8
        let ring = CGFloat((index - 1) / 8 + 1)
        let angle = CGFloat(slot) * (.pi / 4)
        return CGPoint(x: cos(angle) * 18 * ring, y: sin(angle) * 18 * ring)
    }

    static func boardLocalAnchor(for interaction: StudyInteraction,
                                 document: SVGDocument,
                                 editor: EditorState) -> CGPoint? {
        guard let fallbackX = interaction.anchorX, let fallbackY = interaction.anchorY,
              fallbackX.isFinite, fallbackY.isFinite else { return nil }
        guard let ids = interaction.selectedObjectIDs, !ids.isEmpty,
              let current = BoardStudySelection.isolated(
                  boardID: interaction.boardID ?? "study-marker",
                  selectedIDs: Set(ids), document: document, editor: editor
              )?.localBBox,
              let original = interaction.selectionBBox else {
            return CGPoint(x: fallbackX, y: fallbackY)
        }
        let nx = interaction.anchorOffsetNX
            ?? ((fallbackX - original.x) / max(original.width, 0.001))
        let ny = interaction.anchorOffsetNY
            ?? ((fallbackY - original.y) / max(original.height, 0.001))
        let x = current.x + nx * current.width
        let y = current.y + ny * current.height
        guard x.isFinite, y.isFinite else { return CGPoint(x: fallbackX, y: fallbackY) }
        return CGPoint(x: x, y: y)
    }
}

struct SavedStudyInteractionView: View {
    @Environment(\.dismiss) private var dismiss
    let interaction: StudyInteraction
    let onNewExplanation: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StudyRichHeading(source: interaction.title ?? "Saved explanation")
                    if let question = interaction.question,
                       !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label(CompactStudyPresentation.readableText(from: question),
                              systemImage: "quote.bubble")
                            .foregroundStyle(.secondary)
                    }
                    StudyContentView(
                        source: interaction.answer ?? "No explanation was saved.",
                        maximumWidth: 760
                    )
                    ForEach(interaction.followUps ?? []) { followUp in
                        VStack(alignment: .leading, spacing: 8) {
                            if let question = followUp.question, !question.isEmpty {
                                StudyContentView(source: "### \(question)", maximumWidth: 760)
                            }
                            if let answer = followUp.answer, !answer.isEmpty {
                                StudyContentView(source: answer, maximumWidth: 760)
                            }
                            ForEach(followUp.problems ?? []) { problem in
                                StudyContentView(source: problem.text, maximumWidth: 720)
                                    .padding(12)
                                    .background(.secondary.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Saved Study Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Explanation") {
                        dismiss()
                        onNewExplanation()
                    }
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
