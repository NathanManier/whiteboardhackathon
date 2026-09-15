import SwiftUI

struct LectureWorkspaceView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folder: LectureFolder
    let initialFocusBoardID: String?
    @StateObject private var store: LectureWorkspaceStore
    @StateObject private var graphRecognition = GraphRecognitionController()
    @State private var activeTool: CanvasTool = .pen
    @State private var showImporter = false
    @State private var showNavigator = false
    @State private var showGuide = false
    @State private var showStudy = false
    @State private var showNote = false
    @State private var showDelete = false
    @State private var showConflict = false
    @State private var showRenameBoard = false
    @State private var showSetUnit = false
    @State private var pendingDeleteBoardID: String?
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var actionError: String?
    @State private var selectionScreenBounds: CGRect?
    @State private var studyInitialAction: StudyAction?
    @State private var studyInteractionsByBoard: [String: [StudyInteraction]] = [:]
    @State private var reopenedStudy: StudyInteraction?
    @State private var previousPencilTool: CanvasTool = .pen
    @State private var pencilQuickPalettePoint: CGPoint?
    @State private var pencilQuickPaletteHighlight = 0
    @State private var graphCreationRequest: GraphCreationRequest?
    @State private var editingGraph: GraphObject?
    @State private var interactiveGraph: GraphObject?
    @State private var canvasSize = CGSize.zero
    @State private var pendingGeneratedBoardOrigins = Set<String>()
    @AppStorage("vboard.workspace.background") private var backgroundRaw = WorkspaceBackgroundStyle.dots.rawValue
    @AppStorage("vboard.workspace.physicalPaper") private var physicalBoardShowsPaper = false
    @AppStorage("vboard.study.inspectorWidth") private var studyPanelWidth = 0.0
    @AppStorage("vboard.study.panelCollapsed") private var studyPanelCollapsed = false
    @AppStorage("vboard.pen.color") private var penColor = CanvasStrokeStyle.pen.colorHex
    @AppStorage("vboard.pen.width") private var penWidth = CanvasStrokeStyle.pen.width
    @AppStorage("vboard.marker.color") private var markerColor = CanvasStrokeStyle.marker.colorHex
    @AppStorage("vboard.marker.width") private var markerWidth = CanvasStrokeStyle.marker.width
    @AppStorage("vboard.marker.opacity") private var markerOpacity = CanvasStrokeStyle.marker.opacity
    @AppStorage("vboard.pencil.doubleTap") private var pencilDoubleTapRaw = PencilDoubleTapSetting.followSystem.rawValue
    @AppStorage("vboard.pencil.squeeze") private var pencilSqueezeRaw = PencilSqueezeSetting.followSystem.rawValue
    @AppStorage("vboard.pencil.hover") private var pencilHoverRaw = PencilHoverSetting.followSystem.rawValue
    @AppStorage("vboard.developer.diagnostics") private var developerDiagnostics = false
    #if DEBUG
    @State private var showPencilValidation = false
    #endif

    init(folder: LectureFolder, focusBoardID: String? = nil) {
        self.folder = folder
        initialFocusBoardID = focusBoardID
        _store = StateObject(wrappedValue: LectureWorkspaceStore(folderID: folder.id))
    }

    var body: some View {
        Group {
            if let workspace = store.workspace {
                workspaceSurface(workspace)
            } else if case .failed(let message) = store.status {
                ContentUnavailableView("Couldn’t open class", systemImage: "rectangle.stack.badge.exclamationmark",
                                       description: Text(message))
                    .overlay(alignment: .bottom) {
                        Button("Retry") { Task { await store.load(api: api, focusBoardID: initialFocusBoardID) } }
                            .buttonStyle(.borderedProminent)
                            .padding(.bottom, 30)
                    }
            } else {
                ProgressView("Opening class workspace…")
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(EditorNavigationGestureGuard())
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if interactiveGraph == nil {
                    WorkspaceToolPalette(
                        status: store.status.userLabel,
                        undo: { store.undo(api: api) },
                        redo: { store.redo(api: api) },
                        retry: { Task { await store.saveNow(api: api) } }
                    )
                }
                EditorToolMenu(activeTool: $activeTool)
                Button { store.undo(api: api) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!store.canUndo)
                Button { store.redo(api: api) } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!store.canRedo)
                Button { showNavigator.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Class navigator")
                Menu {
                    Button { createBlankBoard() } label: {
                        Label("Blank Board", systemImage: "rectangle.and.pencil.and.ellipsis")
                    }
                    Button { showImporter = true } label: {
                        Label("Import Whiteboard", systemImage: "camera.viewfinder")
                    }
                    if store.activeBoardStore != nil {
                        Button { showNote = true } label: {
                            Label("Note", systemImage: "note.text.badge.plus")
                        }
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add to class")
                Button { showGuide = true } label: { Image(systemName: "text.book.closed") }
                    .accessibilityLabel("Study Guide")
                Menu {
                    if activeBoard != nil {
                        Button { showRenameBoard = true } label: { Label("Rename Whiteboard", systemImage: "pencil") }
                        Button { showSetUnit = true } label: { Label("Set Unit", systemImage: "tag") }
                        Button { Task { await exportActiveBoard(.svg) } } label: { Label("Export SVG", systemImage: "doc.text") }
                        Button { Task { await exportActiveBoard(.png) } } label: { Label("Save Image", systemImage: "photo") }
                        Button { Task { await exportActiveBoard(.pdf) } } label: { Label("Export PDF", systemImage: "doc.richtext") }
                        Divider()
                    }
                    Button { showNote = true } label: { Label("Add Note", systemImage: "note.text.badge.plus") }
                        .disabled(store.activeBoardStore == nil)
                    Picker("Workspace Background", selection: $backgroundRaw) {
                        ForEach(WorkspaceBackgroundStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
                    }
                    Toggle("Show Whiteboard Paper", isOn: $physicalBoardShowsPaper)
                    PencilSettingsControls(doubleTapRaw: $pencilDoubleTapRaw,
                                           squeezeRaw: $pencilSqueezeRaw,
                                           hoverRaw: $pencilHoverRaw)
                    #if DEBUG
                    Toggle("Developer Diagnostics", isOn: $developerDiagnostics)
                    Button { showPencilValidation = true } label: {
                        Label("Apple Pencil Validation", systemImage: "pencil.and.scribble")
                    }
                    #endif
                    if activeBoard != nil {
                        Button(role: .destructive) {
                            pendingDeleteBoardID = store.activeBoardID
                        } label: { Label("Delete Whiteboard", systemImage: "trash") }
                    }
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete Class", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showImporter) {
            ImportFlowView(folderID: folder.id) { board in
                showImporter = false
                Task { await store.refreshAfterImport(boardID: board.id, api: api) }
            }
        }
        .sheet(isPresented: $showGuide) {
            StudyGuideView(folderID: folder.id, guide: store.lecture?.studyGuide)
        }
        .sheet(item: $graphCreationRequest) { request in
            GraphCreationSheet(
                target: request.target,
                recognition: graphRecognition,
                prepareSelection: { await prepareGraphRecognition(request.target) },
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
                store.replaceGraph(graph.replacing(expressions: expressions),
                                   boardID: graph.owningBoardID, api: api)
            }
        }
        .sheet(item: $reopenedStudy) { interaction in
            SavedStudyInteractionView(interaction: interaction) {
                reopenedStudy = nil
                DispatchQueue.main.async { openStudy(action: .explain, forceNew: true) }
            }
        }
        .sheet(isPresented: $showNote) {
            LectureNoteSheet(unitLabel: activeUnitLabel) { markdown in
                store.addNote(markdown, api: api)
                showNote = false
            }
        }
        .sheet(isPresented: $showRenameBoard) {
            if let board = activeBoard {
                WorkspaceRenameSheet(name: board.name) { name in renameActiveBoard(name) }
            }
        }
        .sheet(isPresented: $showSetUnit) {
            if let boardID = store.activeBoardID {
                UnitPickerSheet(current: activeUnitLabel) { label, number in
                    store.setUnit(boardID: boardID, label: label, number: number, api: api)
                    showSetUnit = false
                }
            }
        }
        .sheet(isPresented: $showShare) { if let exportURL { ShareSheet(items: [exportURL]) } }
        #if DEBUG
        .sheet(isPresented: $showPencilValidation) { PencilHardwareValidationView() }
        #endif
        .alert("Delete class?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await api.deleteLecture(id: folder.id, recursive: true); dismiss() }
                    catch { }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the class and all of its whiteboards.")
        }
        .alert("Class layout changed", isPresented: $showConflict) {
            Button("Keep My Layout") { store.keepLocalChanges(api: api) }
            Button("Reload Server Layout", role: .destructive) { store.reloadServerVersion() }
        } message: {
            Text("Your local camera and whiteboard placements are saved on this iPad. Choose which layout should remain.")
        }
        .confirmationDialog("Delete this board?", isPresented: Binding(
            get: { pendingDeleteBoardID != nil },
            set: { if !$0 { pendingDeleteBoardID = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Board", role: .destructive) {
                guard let boardID = pendingDeleteBoardID else { return }
                pendingDeleteBoardID = nil
                deleteBoard(boardID)
            }
            Button("Cancel", role: .cancel) { pendingDeleteBoardID = nil }
        } message: {
            Text("This removes content that belongs only to this board. Content crossing into another board is preserved there.")
        }
        .alert("Couldn’t complete that action", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(actionError ?? "") }
        .onChange(of: store.status) { _, status in
            if status == .conflict { showConflict = true }
        }
        .onChange(of: activeTool) { oldValue, newValue in
            if newValue != newValue.migratedForCurrentInputModel {
                activeTool = newValue.migratedForCurrentInputModel
                return
            }
            if oldValue != newValue && oldValue != .objectEraser { previousPencilTool = oldValue }
            if newValue != .lasso, !store.selectedKeys.isEmpty {
                store.setSelection([], pdfRegions: [:])
                graphRecognition.clear()
                selectionScreenBounds = nil
            }
            if !GraphPencilInteractionPolicy.allowsAnnotation(for: newValue) {
                interactiveGraph = nil
            }
        }
        .onChange(of: store.selectedKeys) { _, _ in
            let target = graphRecognitionTarget
            graphRecognition.clear()
            if target?.primarySelection.canonicalObjectIDs != interactiveGraph.map({ [$0.id] }) {
                interactiveGraph = nil
            }
        }
        .task(id: workspaceStudySignature) {
            if store.workspace == nil {
                await store.load(api: api, focusBoardID: initialFocusBoardID)
            }
            await loadStudyInteractions()
        }
        .onChange(of: interactiveGraph?.id) { _, graphID in
            if graphID != nil { pencilQuickPalettePoint = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            store.persistForBackgrounding()
        }
    }

    private func workspaceSurface(_ workspace: LectureWorkspace) -> some View {
        GeometryReader { proxy in
            let docked = proxy.size.width >= 820
            let dockedNavigator = showNavigator && proxy.size.width >= 700
            let navigatorWidth: CGFloat = dockedNavigator ? 250 : 0
            let canvasWidth = max(proxy.size.width - navigatorWidth, 320)
            let panelWidth = showStudy && docked
                ? StudyPanelSizing.width(preferred: studyPanelWidth,
                                         availableWidth: canvasWidth,
                                         collapsed: studyPanelCollapsed)
                : 0
            HStack(spacing: 0) {
                if dockedNavigator {
                    LectureNavigatorSidebar(store: store, api: api) { showNavigator = false }
                        .frame(width: navigatorWidth)
                }
                ZStack(alignment: .trailing) {
                    canvasSurface(workspace)
                        .frame(width: canvasWidth, height: proxy.size.height)
                    if showStudy && docked {
                        StudyDock(
                            width: $studyPanelWidth,
                            collapsed: $studyPanelCollapsed,
                            availableWidth: canvasWidth,
                            onClose: { showStudy = false },
                            content: { studyContent(compact: true) }
                        )
                        .frame(width: panelWidth, height: proxy.size.height)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { showStudy && !docked },
                set: { if !$0 { showStudy = false } }
            )) { studyContent(compact: false) }
            .sheet(isPresented: Binding(
                get: { showNavigator && !dockedNavigator },
                set: { if !$0 { showNavigator = false } }
            )) { LectureNavigatorSheet(store: store, api: api) }
        }
    }

    private func canvasSurface(_ workspace: LectureWorkspace) -> some View {
        GeometryReader { proxy in
            let canvasScenes = GraphEditingCanvasIsolation.scenesForCanvas(
                store.scenes, hiding: interactiveGraph
            )
            ZStack(alignment: .bottom) {
                LectureCanvasView(
                    workspace: workspace,
                    scenes: canvasScenes,
                    selectedKeys: store.selectedKeys,
                    tool: activeTool,
                    backgroundStyle: WorkspaceBackgroundStyle(rawValue: backgroundRaw) ?? .dots,
                    physicalBoardShowsPaper: physicalBoardShowsPaper,
                    penStyle: CanvasStrokeStyle(colorHex: penColor, width: penWidth, opacity: 1),
                    markerStyle: CanvasStrokeStyle(colorHex: markerColor, width: markerWidth, opacity: markerOpacity),
                    pencilPreferences: pencilPreferences,
                    isPencilPalettePresented: pencilQuickPalettePoint != nil,
                    showsDeveloperDiagnostics: developerDiagnosticsIfAvailable,
                    thumbnailURLs: Dictionary(uniqueKeysWithValues: workspace.items.compactMap { item in
                        api.resolvedURL(item.thumbnailURL).map { (item.boardID, $0) }
                    }),
                    loadAsset: { try await api.authorizedAsset(path: $0) },
                    focusRequest: store.focusRequest,
                    onCameraChanged: { store.updateCamera($0, api: api) },
                    onActiveBoardChanged: { store.setActiveBoard($0, api: api) },
                    onDetailDemand: { store.requestDetail(for: $0, api: api) },
                    onSelectionChanged: { keys, pdfRegions in store.setSelection(keys, pdfRegions: pdfRegions) },
                    onSelectionScreenBoundsChanged: { bounds in
                        DispatchQueue.main.async {
                            if selectionScreenBounds != bounds { selectionScreenBounds = bounds }
                        }
                    },
                    onStroke: { stroke, boardID in store.applyStroke(stroke, boardID: boardID, api: api) },
                    onBoardExpansionRequested: { boardID, localRegion in
                        store.expandBoardDownward(boardID: boardID,
                                                  to: localRegion,
                                                  api: api)
                    },
                    onBlankBoardCreationRequested: createGeneratedBoard,
                    onMoveSelection: { keys, delta in store.moveSelection(keys, by: delta, api: api) },
                    onResizeSelection: { keys, anchor, scale in
                        store.resizeSelection(keys, around: anchor, by: scale, api: api)
                    },
                    onResizeGraphHeight: { key, anchorY, factor in
                        store.resizeGraphHeight(key, around: anchorY,
                                                by: factor, api: api)
                    },
                    onGraphDoubleTap: { key in
                        interactiveGraph = store.scenes[key.boardID]?.editor.objects
                            .first(where: { $0.id == key.objectID })?.graph
                    },
                    onDelete: { store.deleteSelection($0, api: api) },
                    onMoveBoard: { boardID, delta in store.moveBoard(boardID: boardID, by: delta, api: api) },
                    onUndo: { store.undo(api: api) },
                    onRedo: { store.redo(api: api) },
                    onPencilAction: handlePencilAction,
                    onPencilPaletteMoved: { pencilQuickPalettePoint = $0 },
                    onPencilPaletteHighlight: { pencilQuickPaletteHighlight = $0 },
                    onPencilPaletteCommit: { index in
                        activeTool = PencilRadialPaletteModel.tool(at: index)
                        pencilQuickPalettePoint = nil
                    },
                    onPencilPaletteDismiss: { pencilQuickPalettePoint = nil }
                )
                .ignoresSafeArea(edges: .bottom)

                graphAccessibilityOverlays(workspace, viewport: proxy.size)
                studyMarkerOverlays(workspace, viewport: proxy.size)
                if interactiveGraph == nil {
                    boardDeleteOverlays(workspace, viewport: proxy.size)
                }

                if interactiveGraph != nil {
                    GraphOutsideInteractionShield { interactiveGraph = nil }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(5)
                }

                if let graph = interactiveGraph,
                   let rect = graphScreenRect(graph, workspace: workspace,
                                              viewport: proxy.size),
                   rect.intersects(CGRect(origin: .zero, size: proxy.size)) {
                    GraphInteractiveSurface(
                        graph: graph,
                        canonicalStrokeObjects: GraphAnnotationOverlayPolicy.strokeObjectsAbove(
                            graphID: graph.id,
                            in: store.scenes[graph.owningBoardID]?.editor.objects ?? []
                        ),
                        pencilAnnotationEnabled:
                            GraphPencilInteractionPolicy.allowsAnnotation(for: activeTool),
                        pencilStyle: activeTool == .highlighter
                            ? CanvasStrokeStyle(colorHex: markerColor, width: markerWidth,
                                                opacity: markerOpacity)
                            : CanvasStrokeStyle(colorHex: penColor, width: penWidth, opacity: 1),
                        pencilPreferences: pencilPreferences,
                        onPencilStroke: {
                            store.applyStroke($0, boardID: graph.owningBoardID, api: api)
                        },
                        onPencilRequestsPassiveMode: { interactiveGraph = nil },
                        onCommitViewport: { owningBoardID, graphID, viewport in
                            store.updateGraphViewportDuringEditing(
                                id: graphID, boardID: owningBoardID,
                                viewport: viewport, api: api
                            )
                        },
                        onCommitGraph: { updated in
                            guard updated.id == graph.id,
                                  updated.owningBoardID == graph.owningBoardID else { return }
                            store.updateGraphDuringEditing(
                                updated, boardID: updated.owningBoardID, api: api
                            )
                        },
                        onBeginGraphEditing: { owningBoardID, graphID in
                            store.beginGraphEditing(id: graphID, boardID: owningBoardID)
                        },
                        onEndGraphEditing: { owningBoardID, graphID in
                            store.endGraphEditing(id: graphID, boardID: owningBoardID)
                        },
                        onExplain: { openStudy(action: .explain) },
                        onPractice: { openStudy(action: .practice) },
                        onDelete: {
                            store.deleteSelection(Set([SelectionKey(
                                boardID: graph.owningBoardID,
                                objectID: graph.id,
                                kind: .editorObject,
                                objectType: "graph"
                            )]), api: api)
                        },
                        onEdit: {
                            editingGraph = store.scenes[graph.owningBoardID]?.editor.objects
                                .first(where: { $0.id == graph.id })?.graph ?? graph
                            interactiveGraph = nil
                        },
                        onDone: { interactiveGraph = nil }
                    )
                    .frame(width: max(proxy.size.width - 32, 1),
                           height: max(proxy.size.height - 112, 1))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                    .zIndex(20)
                }

                if interactiveGraph == nil, !store.selectedKeys.isEmpty, let selectionScreenBounds {
                    SelectionActionBar(
                        canCheckWork: selectionCanCheckWork,
                        selectionGeneration: store.selectionGeneration,
                        graphPrimaryTitle: graphPrimaryTitle,
                        graphIsLoading: false,
                        explain: { openStudy(action: .explain) },
                        practice: { openStudy(action: .practice) },
                        check: { openStudy(action: .checkWork) },
                        graphPrimary: { performPrimaryGraphAction() },
                        graphSelection: { openGraphCreation() },
                        editGraph: selectedGraph.map { graph in { editingGraph = graph } },
                        resetGraph: selectedGraph.map { graph in
                            {
                                store.replaceGraph(graph.replacing(viewport: .conventional),
                                                   boardID: graph.owningBoardID, api: api)
                            }
                        },
                        duplicateGraph: selectedGraphKey.map { key in
                            { _ = store.duplicateGraph(key, api: api) }
                        },
                        delete: { store.deleteSelection(store.selectedKeys, api: api) }
                    )
                    .position(SelectionToolbarLayout.position(for: selectionScreenBounds, viewport: proxy.size))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if workspace.items.isEmpty {
                    EmptyWorkspaceAction(
                        createBlankBoard: { createBlankBoard() },
                        importWhiteboard: { showImporter = true }
                    )
                }

                if let point = pencilQuickPalettePoint {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { pencilQuickPalettePoint = nil }
                        .zIndex(30.5)
                    let paletteRadius: CGFloat = 164
                    let center = PencilPalettePlacement.center(
                        anchor: point, radius: paletteRadius,
                        safeBounds: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 8, dy: 8)
                    )
                    PencilQuickPalette(activeTool: activeTool,
                                       highlightedIndex: pencilQuickPaletteHighlight,
                                       color: activeTool == .highlighter ? $markerColor : $penColor,
                                       width: activeTool == .highlighter ? $markerWidth : $penWidth,
                                       canUndo: store.canUndo,
                                       canRedo: store.canRedo,
                                       undo: { store.undo(api: api) },
                                       redo: { store.redo(api: api) }) { tool in
                        activeTool = tool
                        pencilQuickPalettePoint = nil
                    }
                    .position(center)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .zIndex(31)
                }

                Button("") { store.undo(api: api) }
                    .keyboardShortcut("z", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0.001)
                Button("") { store.redo(api: api) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .frame(width: 0, height: 0).opacity(0.001)
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

    @ViewBuilder
    private func graphAccessibilityOverlays(_ workspace: LectureWorkspace,
                                            viewport: CGSize) -> some View {
        let visibleRect = CGRect(origin: .zero, size: viewport)
        ForEach(workspace.items, id: \.boardID) { item in
            let graphs = (store.scenes[item.boardID]?.editor.objects ?? [])
                .compactMap(\.graph)
                .filter { $0.id != interactiveGraph?.id }
            ForEach(graphs) { graph in
                if let rect = graphScreenRect(graph, workspace: workspace, viewport: viewport),
                   rect.intersects(visibleRect) {
                    GraphAccessibilityProxy(
                        graph: graph,
                        onInteract: { interactiveGraph = graph },
                        onEdit: { editingGraph = graph },
                        onDelete: { deleteGraphFromAccessibility(graph) }
                    )
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .position(x: rect.midX, y: rect.midY)
                    .zIndex(10)
                }
            }
        }
    }

    private func deleteGraphFromAccessibility(_ graph: GraphObject) {
        let key = SelectionKey(boardID: graph.owningBoardID, objectID: graph.id,
                               kind: .editorObject, objectType: "graph")
        store.deleteSelection(Set([key]), api: api)
    }

    @ViewBuilder
    private func boardDeleteOverlays(_ workspace: LectureWorkspace,
                                     viewport: CGSize) -> some View {
        let transform = WorldScreenTransform(camera: workspace.camera, viewport: viewport)
        let visible = CGRect(origin: .zero, size: viewport).insetBy(dx: -30, dy: -30)
        ForEach(workspace.items, id: \.boardID) { item in
            let corner = transform.screenPoint(for: item.frame.origin)
            if visible.contains(corner) {
                BoardDeleteAffordance {
                    pendingDeleteBoardID = item.boardID
                }
                .position(x: corner.x + 14, y: corner.y + 14)
                .zIndex(12)
            }
        }
    }

    @ViewBuilder
    private func studyMarkerOverlays(_ workspace: LectureWorkspace,
                                     viewport: CGSize) -> some View {
        let transform = WorldScreenTransform(camera: workspace.camera, viewport: viewport)
        ForEach(workspace.items, id: \.boardID) { item in
            let interactions = studyInteractionsByBoard[item.boardID] ?? []
            ForEach(Array(interactions.enumerated()), id: \.offset) { index, interaction in
                if let scene = store.scenes[item.boardID],
                   let localAnchor = StudyMarkerGeometry.boardLocalAnchor(
                       for: interaction, document: scene.document, editor: scene.editor
                   ) {
                    let lecturePoint = LectureCoordinateTransform.boardLocalToLectureWorld(
                        localAnchor, board: item
                    )
                    let screenPoint = transform.screenPoint(for: lecturePoint)
                    StudyMarkerButton(interaction: interaction) {
                        reopenedStudy = interaction
                    }
                    .position(x: screenPoint.x + StudyMarkerGeometry.screenOffset(index: index).x,
                              y: screenPoint.y + StudyMarkerGeometry.screenOffset(index: index).y)
                    .zIndex(11)
                }
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

    private var pencilPreferences: PencilPreferences {
        PencilPreferences(
            doubleTap: PencilDoubleTapSetting(rawValue: pencilDoubleTapRaw) ?? .followSystem,
            squeeze: interactiveGraph == nil
                ? (PencilSqueezeSetting(rawValue: pencilSqueezeRaw) ?? .followSystem)
                : .off,
            hover: PencilHoverSetting(rawValue: pencilHoverRaw) ?? .followSystem
        )
    }

    private func handlePencilAction(_ action: PencilLogicalAction, anchor: CGPoint?) {
        switch action {
        case .none, .runSystemShortcut: break
        case .switchLasso: activeTool = .lasso
        case .switchEraser: togglePencilEraser()
        case .switchPrevious:
            let next = previousPencilTool == activeTool ? .pen : previousPencilTool
            previousPencilTool = activeTool
            activeTool = next
        case .showColorPalette, .showInkAttributes, .showToolPalette:
            pencilQuickPaletteHighlight = PencilRadialPaletteModel.index(for: activeTool)
            showPencilQuickPalette(at: anchor
                ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        }
    }

    private func showPencilQuickPalette(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.16)) { pencilQuickPalettePoint = point }
    }

    @ViewBuilder private func studyContent(compact: Bool) -> some View {
        if selectedBoardIDs.count > 1, studyInitialAction == .explain {
            LectureSelectionStudyView(folderID: folder.id,
                                      selectedObjectIDsByBoard: selectedObjectIDsByBoard,
                                      compact: compact)
        } else if let boardID = studyBoardID,
                  let selection = store.studySelection(for: boardID) {
            StudyActionsView(selection: selection,
                             prepareSelection: { await store.saveBoardNow(boardID, api: api) },
                             initialAction: studyInitialAction,
                             compact: compact,
                             onInteractionSaved: { upsertStudyInteraction($0, boardID: boardID) },
                             onPracticeProblems: { problems, interactionID in
                                 let scale: CGFloat
                                 if canvasSize.width > 0, canvasSize.height > 0,
                                    let workspace = store.workspace {
                                     scale = WorldScreenTransform(
                                         camera: workspace.camera, viewport: canvasSize
                                     ).scale
                                 } else {
                                     scale = 1
                                 }
                                 store.applyPracticeProblems(
                                     problems, interactionID: interactionID,
                                     boardID: boardID,
                                     sourceBounds: selection.localBBox.cgRect,
                                     cameraScale: scale, api: api
                                 )
                             })
        } else {
            ContentUnavailableView("Select ink to study", systemImage: "lasso",
                                   description: Text("Use Lasso, then choose an action beside the selection."))
        }
    }

    private func openStudy(action: StudyAction, forceNew: Bool = false) {
        if action == .explain, !forceNew, let boardID = studyBoardID,
           let selection = store.studySelection(for: boardID),
           let existing = studyInteractionsByBoard[boardID]?.first(where: {
               Set($0.selectedObjectIDs ?? []) == Set(selection.canonicalObjectIDs)
           }) {
            reopenedStudy = existing
            return
        }
        studyInitialAction = action
        studyPanelCollapsed = false
        showStudy = true
    }

    private var workspaceStudySignature: String {
        store.workspace?.items.map(\.boardID).sorted().joined(separator: "|") ?? "unloaded"
    }

    @MainActor
    private func loadStudyInteractions() async {
        guard let boardIDs = store.workspace?.items.map(\.boardID) else { return }
        await withTaskGroup(of: (String, [StudyInteraction]).self) { group in
            for boardID in boardIDs {
                group.addTask {
                    let interactions = (try? await api.studyInteractions(boardID: boardID)) ?? []
                    return (boardID, interactions)
                }
            }
            var loaded: [String: [StudyInteraction]] = [:]
            for await (boardID, interactions) in group {
                loaded[boardID] = interactions
            }
            studyInteractionsByBoard = loaded
        }
    }

    private func upsertStudyInteraction(_ interaction: StudyInteraction, boardID: String) {
        guard let id = interaction.id else { return }
        var interactions = studyInteractionsByBoard[boardID] ?? []
        if let index = interactions.firstIndex(where: { $0.id == id }) {
            interactions[index] = interaction
        } else if interaction.action == nil || interaction.action == "explain",
                  let index = interactions.firstIndex(where: {
                      ($0.action == nil || $0.action == "explain")
                          && Set($0.selectedObjectIDs ?? [])
                              == Set(interaction.selectedObjectIDs ?? [])
                  }) {
            interactions[index] = interaction
        } else {
            interactions.append(interaction)
        }
        studyInteractionsByBoard[boardID] = interactions
    }

    private var studyBoardID: String? {
        if selectedBoardIDs.count == 1 { return selectedBoardIDs.first }
        return nil
    }

    private var graphRecognitionTarget: GraphRecognitionTarget? {
        let boardIDs = selectedBoardIDs.sorted()
        guard !boardIDs.isEmpty else { return nil }
        let selections = boardIDs.compactMap(store.studySelection(for:))
        guard selections.count == boardIDs.count else { return nil }
        return GraphRecognitionTarget.makeLecture(
            folderID: folder.id,
            selections: selections,
            preferredPrimaryBoardID: store.activeBoardID
        )
    }

    private var selectedGraphKey: SelectionKey? {
        guard store.selectedKeys.count == 1, let key = store.selectedKeys.first,
              key.kind == .editorObject,
              store.scenes[key.boardID]?.editor.objects
                .first(where: { $0.id == key.objectID })?.graph != nil else { return nil }
        return key
    }

    private var selectedGraph: GraphObject? {
        guard let key = selectedGraphKey else { return nil }
        return store.scenes[key.boardID]?.editor.objects
            .first(where: { $0.id == key.objectID })?.graph
    }

    private var graphPrimaryTitle: String? {
        if selectedGraph != nil { return "Interact" }
        return graphRecognitionTarget == nil ? nil : "Graph"
    }

    private func performPrimaryGraphAction() {
        if let graph = selectedGraph {
            interactiveGraph = graph
        } else {
            openGraphCreation()
        }
    }

    private func openGraphCreation() {
        guard selectedGraph == nil, let target = graphRecognitionTarget else { return }
        let canonicalIDsByBoard = Dictionary(uniqueKeysWithValues:
            target.selections.map { ($0.boardID, Set($0.canonicalObjectIDs)) })
        let keys = store.selectedKeys.filter { key in
            canonicalIDsByBoard[key.boardID]?.contains(key.objectID) == true
        }.sorted {
            if $0.boardID == $1.boardID { return $0.objectID < $1.objectID }
            return $0.boardID < $1.boardID
        }.map { "\($0.boardID):\($0.kind.rawValue):\($0.objectID)" }
        graphCreationRequest = GraphCreationRequest(target: target, selectedObjectKeys: keys)
    }

    private func prepareGraphRecognition(_ target: GraphRecognitionTarget) async {
        // The server rasterizes canonical board state. Flush every participating
        // board before the single grouped request so no secondary selection is
        // recognized against stale editor JSON.
        for boardID in target.sourceBoardIDs {
            await store.saveBoardNow(boardID, api: api)
        }
    }

    private func createGraph(expressions: [GraphExpression], requestID: String?,
                             selection: BoardStudySelection,
                             sourceBoardIDs: [String], selectedObjectKeys: [String]) {
        guard let workspace = store.workspace,
              let item = workspace.items.first(where: { $0.boardID == selection.boardID }),
              store.scenes[selection.boardID] != nil else { return }
        let scale = canvasSize.width > 0 && canvasSize.height > 0
            ? WorldScreenTransform(camera: workspace.camera, viewport: canvasSize).scale : 1
        let sourceInLecture = selection.lectureWorldBBox
            ?? LectureCoordinateTransform.boardLocalToLectureWorld(
                selection.localBBox.cgRect, board: item
            )
        let sourceInOwner = LectureCoordinateTransform.lectureWorldToBoardLocal(
            sourceInLecture, board: item
        )
        // Score placement against lecture-world content from every board, then
        // translate those bounds into the owner document. Translation-only
        // board placement makes the score identical while keeping the created
        // GraphObject correctly board-local and board-owned.
        // Other boards are obstacles. The owning board is the container, not
        // an obstacle; counting it here would force every graph below the
        // board before the actual content-collision search even begins.
        var occupiedInLecture = workspace.items
            .filter { $0.boardID != item.boardID }
            .map(\.effectiveFrame)
        for candidate in workspace.items {
            guard let candidateScene = store.scenes[candidate.boardID] else { continue }
            occupiedInLecture.append(contentsOf: candidateScene.editor.objects.map {
                LectureCoordinateTransform.boardLocalToLectureWorld(
                    BoardHitTestPolicy.bounds(of: $0), board: candidate
                )
            })
            if let professorBounds = GraphPlacementGeometry.professorBounds(
                document: candidateScene.document, editor: candidateScene.editor
            ) {
                occupiedInLecture.append(
                    LectureCoordinateTransform.boardLocalToLectureWorld(
                        professorBounds, board: candidate
                    )
                )
            }
        }
        let occupiedInOwner = occupiedInLecture.map {
            LectureCoordinateTransform.lectureWorldToBoardLocal($0, board: item)
        }
        let graph = GraphObjectFactory.make(
            boardID: item.boardID, selection: selection, expressions: expressions,
            recognitionRequestID: requestID, cameraScale: scale, occupied: occupiedInOwner,
            sourceBoardIDs: sourceBoardIDs, selectedObjectKeys: selectedObjectKeys,
            placementSource: sourceInOwner,
            containerWidth: CGFloat(item.boardWidth)
        )
        store.addGraph(graph, boardID: item.boardID, api: api)
    }

    private func graphScreenRect(_ graph: GraphObject, workspace: LectureWorkspace,
                                 viewport: CGSize) -> CGRect? {
        guard let item = workspace.items.first(where: { $0.boardID == graph.owningBoardID })
        else { return nil }
        let lectureRect = LectureCoordinateTransform.boardLocalToLectureWorld(
            graph.frame.cgRect, board: item
        )
        let transform = WorldScreenTransform(camera: workspace.camera, viewport: viewport)
        let a = transform.screenPoint(for: lectureRect.origin)
        let b = transform.screenPoint(for: CGPoint(x: lectureRect.maxX, y: lectureRect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private var selectedBoardIDs: Set<String> { Set(store.selectedKeys.map(\.boardID)) }

    private var selectedObjectIDsByBoard: [String: [String]] {
        Dictionary(grouping: store.selectedKeys, by: \.boardID)
            .mapValues { keys in Array(Set(keys.map(\.objectID))).sorted() }
    }

    private var selectionCanCheckWork: Bool {
        let selectedObjects = store.selectedKeys.compactMap { key -> (String, CanvasObject)? in
            store.scenes[key.boardID]?.editor.objects
                .first(where: { $0.id == key.objectID }).map { (key.boardID, $0) }
        }
        return CheckWorkVisibilityPolicy.isVisible(selected: selectedObjects)
    }

    private var activeUnitLabel: String {
        store.workspace?.items.first(where: { $0.boardID == store.activeBoardID })?.unitLabel ?? "No Unit"
    }

    private var activeBoard: LibraryBoard? {
        guard let activeBoardID = store.activeBoardID else { return nil }
        return store.boards.first(where: { $0.id == activeBoardID })
    }

    private func renameActiveBoard(_ name: String) {
        guard let board = activeBoard else { return }
        showRenameBoard = false
        Task {
            do {
                await store.saveNow(api: api)
                _ = try await api.updateBoard(id: board.id, name: name)
                await store.load(api: api, focusBoardID: board.id)
            } catch { actionError = "The whiteboard name could not be saved." }
        }
    }

    private func deleteBoard(_ boardID: String) {
        Task {
            do {
                guard await store.prepareBoardDeletion(boardID, api: api) else {
                    actionError = "The board was left intact because its cross-board content could not be saved safely."
                    return
                }
                try await api.deleteBoard(id: boardID)
                await store.load(api: api)
            } catch { actionError = "The whiteboard could not be deleted." }
        }
    }

    private func createBlankBoard() {
        Task {
            do {
                let board = try await api.createBlankBoard(folderID: folder.id)
                await store.refreshAfterImport(boardID: board.id, api: api)
            } catch {
                actionError = "The blank board could not be created."
            }
        }
    }

    private func createGeneratedBoard(_ request: BlankBoardCreationRequest) {
        let originKey = "\(Int(request.origin.x.rounded())):\(Int(request.origin.y.rounded()))"
        guard pendingGeneratedBoardOrigins.insert(originKey).inserted else { return }
        if WorkspaceBoardCreationPolicy.hasBoard(
            at: request.origin, items: store.workspace?.items ?? []
        ) {
            pendingGeneratedBoardOrigins.remove(originKey)
            return
        }
        Task { @MainActor in
            do {
                // Re-check in the workspace owner immediately before the
                // external mutation so two near-simultaneous strokes cannot
                // create duplicate adjacent boards.
                guard !WorkspaceBoardCreationPolicy.hasBoard(
                    at: request.origin, items: store.workspace?.items ?? []
                ) else {
                    pendingGeneratedBoardOrigins.remove(originKey)
                    return
                }
                let board = try await api.createBlankBoard(folderID: folder.id)
                await store.refreshAfterImport(
                    boardID: board.id, api: api, requestFocus: false
                )
                store.placeGeneratedBoard(board.id, at: request.origin, api: api)
                if let worldStroke = request.worldStroke {
                    let localPoints = worldStroke.points.map { point in
                        StrokePoint(
                            x: point.x - request.origin.x,
                            y: point.y - request.origin.y,
                            pressure: point.pressure,
                            altitude: point.altitude,
                            azimuth: point.azimuth,
                            roll: point.roll,
                            timestamp: point.timestamp,
                            estimationUpdateIndex: point.estimationUpdateIndex
                        )
                    }
                    let localStroke = UserStroke(
                        id: worldStroke.id, color: worldStroke.color,
                        width: worldStroke.width, opacity: worldStroke.opacity,
                        points: localPoints, pencilTool: worldStroke.pencilTool
                    )
                    store.applyStrokeWhenSceneReady(
                        localStroke, boardID: board.id, api: api
                    )
                }
            } catch {
                pendingGeneratedBoardOrigins.remove(originKey)
                actionError = "The new writing board could not be created."
            }
        }
    }

    private func exportActiveBoard(_ format: APIClient.BoardExportFormat) async {
        guard let board = activeBoard else { return }
        do {
            await store.activeBoardStore?.saveNow(api: api)
            let data = try await api.exportBoard(boardID: board.id, format: format)
            let safe = board.name.replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VBoardExports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(
                (safe.isEmpty ? "V-Board" : safe) + ".\(format.rawValue)"
            )
            try data.write(to: url, options: .atomic)
            exportURL = url
            showShare = true
        } catch { actionError = "The board could not be exported right now." }
    }

}

enum EditorStatusPresentation: Equatable, Sendable {
    case saved, saving, unsaved, offline, error, loading

    init(_ status: String) {
        let value = status.lowercased()
        if value.contains("saving") { self = .saving }
        else if value.contains("unsaved") || value.contains("dirty") { self = .unsaved }
        else if value.contains("locally") || value.contains("offline") { self = .offline }
        else if value.contains("fail") || value.contains("review") || value.contains("couldn") {
            self = .error
        } else if value.contains("loading") { self = .loading }
        else { self = .saved }
    }

    var compactLabel: String {
        switch self {
        case .saved: return "Saved"
        case .saving: return "Saving"
        case .unsaved: return "Unsaved"
        case .offline: return "Offline"
        case .error: return "Error"
        case .loading: return "Loading"
        }
    }

    var isProgress: Bool { self == .saving || self == .loading }
}

struct WorkspaceToolPalette: View {
    let status: String
    let undo: () -> Void
    let redo: () -> Void
    let retry: () -> Void
    @State private var showStatus = false
    @State private var lastSavedAt: Date?

    var body: some View {
        Button { showStatus.toggle() } label: {
            HStack(spacing: 5) {
                if presentation.isProgress {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                }
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color(uiColor: CanvasDesignTokens.toolbarSurface), in: Capsule())
            .overlay(Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save status: \(status)")
        .accessibilityHint("Opens save details and history actions")
        .popover(isPresented: $showStatus, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Label(status, systemImage: statusIcon)
                    .font(.callout.weight(.semibold))
                if let lastSavedAt {
                    Text("Last saved \(lastSavedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    if presentation == .error || presentation == .offline {
                        Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    }
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                    Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(width: 330, alignment: .leading)
            .presentationCompactAdaptation(.popover)
            .environment(\.colorScheme, .light)
        }
        .environment(\.colorScheme, .light)
        .onAppear { recordSuccessfulSave(status) }
        .onChange(of: status) { _, value in recordSuccessfulSave(value) }
    }

    private var presentation: EditorStatusPresentation { EditorStatusPresentation(status) }

    private var statusColor: Color {
        switch presentation.indicatorRole {
        case .saved: return .green
        case .pending: return .orange
        case .error: return .red
        }
    }

    private var statusIcon: String {
        presentation == .error ? "exclamationmark.triangle" :
            (presentation == .offline ? "icloud.slash" : "checkmark.circle")
    }

    private func recordSuccessfulSave(_ value: String) {
        if EditorStatusPresentation(value) == .saved { lastSavedAt = Date() }
    }

}

struct BoardDeleteAffordance: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(uiColor: CanvasDesignTokens.canvasSecondaryText))
                .frame(width: 22, height: 22)
                .background(Color(uiColor: CanvasDesignTokens.toolbarSurface), in: Circle())
                .overlay(Circle().stroke(.separator.opacity(0.55), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Delete this board")
        .help("Delete this board")
    }
}

enum EditorStatusIndicatorRole: Equatable {
    case saved
    case pending
    case error
}

extension EditorStatusPresentation {
    var indicatorRole: EditorStatusIndicatorRole {
        switch self {
        case .saved: return .saved
        case .error: return .error
        case .saving, .unsaved, .offline, .loading: return .pending
        }
    }
}

private struct CanvasToolOptions: View {
    let title: String
    @Binding var color: String
    @Binding var width: Double
    @Binding var opacity: Double
    let showsOpacity: Bool
    private let colors = CanvasColorPalette.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { value in
                    CanvasColorSwatch(hex: value, selected: color == value) {
                        color = value
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Width").font(.caption).foregroundStyle(.secondary)
                Slider(value: $width, in: showsOpacity ? 10...40 : 1.5...14)
            }
            if showsOpacity {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opacity").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $opacity, in: 0.15...0.7)
                }
            }
        }
        .padding(18)
        .frame(width: 300)
    }

}

private struct CanvasColorSwatch: View {
    let hex: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle().fill(Color(uiColor: UIColor(svgHex: hex)))
                .frame(width: 28, height: 28)
                .overlay {
                    if selected {
                        Circle().stroke(.primary, lineWidth: 2).padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CanvasColorPalette.name(for: hex))
        .accessibilityValue(CanvasColorPalette.accessibilityValue(for: hex))
        .help("\(CanvasColorPalette.name(for: hex))\n\(CanvasColorPalette.accessibilityValue(for: hex))")
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) {
            if hovering {
                VStack(spacing: 1) {
                    Text(CanvasColorPalette.name(for: hex))
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text(CanvasColorPalette.accessibilityValue(for: hex))
                        .font(.system(size: 9).italic())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 6,
                                                 style: .continuous))
                .offset(y: -36)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .zIndex(hovering ? 1 : 0)
    }
}

struct EditorToolMenu: View {
    @Binding var activeTool: CanvasTool

    var body: some View {
        Menu {
            ForEach(CanvasTool.visibleTools, id: \.self) { tool in
                Button {
                    activeTool = tool
                } label: {
                    Label(title(tool), systemImage: icon(tool))
                }
            }
        } label: {
            Image(systemName: icon(activeTool.migratedForCurrentInputModel))
        }
        .accessibilityLabel("Drawing tool: \(title(activeTool.migratedForCurrentInputModel))")
    }

    private func title(_ tool: CanvasTool) -> String {
        switch tool.migratedForCurrentInputModel {
        case .highlighter: return "Marker"
        case .objectEraser: return "Eraser"
        case .lasso: return "Lasso"
        case .pen: return "Pen"
        case .navigation, .select: return "Pen"
        }
    }

    private func icon(_ tool: CanvasTool) -> String {
        switch tool.migratedForCurrentInputModel {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .objectEraser: return "eraser"
        case .lasso: return "lasso"
        case .navigation, .select: return "pencil.tip"
        }
    }
}

struct SelectionActionBar: View {
    let canCheckWork: Bool
    var selectionGeneration: Int = 0
    let graphPrimaryTitle: String?
    let graphIsLoading: Bool
    let explain: () -> Void
    let practice: () -> Void
    let check: () -> Void
    let graphPrimary: () -> Void
    let graphSelection: () -> Void
    let editGraph: (() -> Void)?
    let resetGraph: (() -> Void)?
    let duplicateGraph: (() -> Void)?
    let delete: () -> Void
    @State private var showsLearningLabels = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            action("Explain", "text.magnifyingglass", explain)
            action("Practice", "list.bullet.clipboard", practice)
            if canCheckWork { action("Check", "checkmark.circle", check) }
            if graphIsLoading {
                ProgressView().controlSize(.small).frame(width: 38, height: 38)
            } else {
                action(graphPrimaryTitle ?? "Graph",
                       graphPrimaryTitle == "Interact" ? "hand.tap" : "function",
                       graphPrimaryTitle == nil ? graphSelection : graphPrimary)
            }
            action("Delete", "trash", delete, destructive: true)
            Button { showsLearningLabels.toggle() } label: {
                VStack(spacing: 3) {
                    Image(systemName: showsLearningLabels ? "ellipsis.circle.fill" : "ellipsis")
                        .frame(width: 34, height: 30)
                    if showsLearningLabels { Text("Labels").font(.caption2) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsLearningLabels ? "Hide action labels" : "Show action labels")
            if showsLearningLabels, editGraph != nil {
                Menu {
                    Button(action: { editGraph?() }) {
                        Label("Edit Equations", systemImage: "function")
                    }
                    Button(action: { resetGraph?() }) {
                        Label("Reset View", systemImage: "arrow.counterclockwise")
                    }
                    Button(action: { duplicateGraph?() }) {
                        Label("Duplicate Graph", systemImage: "plus.square.on.square")
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Graph options")
            }
        }
        .id(selectionGeneration)
        .font(.caption.weight(.semibold))
        .padding(6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55), lineWidth: 0.5) }
    }

    private func action(_ title: String, _ icon: String, _ action: @escaping () -> Void,
                        destructive: Bool = false) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 30)
                if showsLearningLabels {
                    Text(title).font(.caption2).lineLimit(1)
                }
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

enum SelectionToolbarLayout {
    static let size = CGSize(width: 390, height: 42)

    static func position(for rect: CGRect, viewport: CGSize) -> CGPoint {
        let x = min(max(rect.midX, size.width / 2 + 12), viewport.width - size.width / 2 - 12)
        let above = rect.minY - size.height / 2 - 12
        let y = above >= 12
            ? above
            : min(rect.maxY + size.height / 2 + 12, viewport.height - size.height / 2 - 72)
        return CGPoint(x: x, y: y)
    }
}

enum StudyPanelSizing {
    static let collapsedWidth: CGFloat = 46

    static func limits(availableWidth: CGFloat) -> ClosedRange<CGFloat> {
        let minimum = min(280, max(250, availableWidth * 0.18))
        let maximum = max(minimum, availableWidth * 0.50)
        return minimum...maximum
    }

    static func width(preferred: Double,
                      availableWidth: CGFloat,
                      collapsed: Bool) -> CGFloat {
        guard !collapsed else { return collapsedWidth }
        let limits = limits(availableWidth: availableWidth)
        let requested = preferred > 0 ? CGFloat(preferred) : availableWidth * 0.20
        return min(limits.upperBound, max(limits.lowerBound, requested))
    }
}

struct StudyDock<Content: View>: View {
    @Binding var width: Double
    @Binding var collapsed: Bool
    let availableWidth: CGFloat
    let onClose: () -> Void
    let content: Content
    @State private var dragStartWidth: Double?

    init(width: Binding<Double>, collapsed: Binding<Bool>, availableWidth: CGFloat,
         onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        _width = width; _collapsed = collapsed
        self.availableWidth = availableWidth; self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if !collapsed {
                Rectangle()
                    .fill(.separator.opacity(0.45))
                    .frame(width: 1)
                    .contentShape(Rectangle().inset(by: -10))
                    .gesture(DragGesture().onChanged { value in
                        let resolved = Double(StudyPanelSizing.width(preferred: width,
                                                                    availableWidth: availableWidth,
                                                                    collapsed: false))
                        let start = dragStartWidth ?? resolved
                        if dragStartWidth == nil { dragStartWidth = resolved }
                        let limits = StudyPanelSizing.limits(availableWidth: availableWidth)
                        width = min(max(start - Double(value.translation.width),
                                        Double(limits.lowerBound)),
                                    Double(limits.upperBound))
                    }.onEnded { _ in dragStartWidth = nil })
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { collapsed.toggle() } label: {
                        Image(systemName: collapsed ? "sidebar.right" : "chevron.right")
                    }
                    .accessibilityLabel(collapsed ? "Expand Study" : "Collapse Study")
                    if !collapsed {
                        Text("Study").font(.headline)
                        Spacer()
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .accessibilityLabel("Close Study")
                    }
                }
                .padding(.horizontal, collapsed ? 10 : 14)
                .frame(height: 44)
                Divider().opacity(collapsed ? 0 : 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(collapsed ? 0 : 1)
                    .allowsHitTesting(!collapsed)
                    .accessibilityHidden(collapsed)
                    .clipped()
            }
            .background(Color(uiColor: .systemBackground))
        }
    }
}

private struct EmptyWorkspaceAction: View {
    let createBlankBoard: () -> Void
    let importWhiteboard: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text("Start this class").font(.title3.weight(.semibold))
            Text("Write on a blank board or bring in existing material.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Blank Board", action: createBlankBoard).buttonStyle(.borderedProminent)
                Button("Import Whiteboard", action: importWhiteboard).buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

enum LectureStudyRouting {
    static func isAvailable(selectedBoardIDs: Set<String>) -> Bool {
        !selectedBoardIDs.isEmpty
    }
}

private struct WorkspaceRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String) -> Void
    @State private var name: String

    init(name: String, onSave: @escaping (String) -> Void) {
        _name = State(initialValue: name); self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form { TextField("Whiteboard name", text: $name) }
                .navigationTitle("Rename Whiteboard")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct UnitPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    let onSelect: (String, Int?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button { onSelect("No Unit", nil) } label: { row("No Unit") }
                ForEach(1...12, id: \.self) { number in
                    Button { onSelect("Unit \(number)", number) } label: { row("Unit \(number)") }
                }
            }
            .navigationTitle("Set Unit")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ title: String) -> some View {
        HStack { Text(title); Spacer(); if title == current { Image(systemName: "checkmark").foregroundStyle(.tint) } }
    }
}

private struct LectureNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let unitLabel: String
    let onAdd: (String) -> Void
    @State private var markdown = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("This note will stay with the active whiteboard and inherit \(unitLabel).")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $markdown)
                    .font(.body)
                    .padding(8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if markdown.isEmpty {
                            Text("Write a study note…")
                                .foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(20)
            .navigationTitle("New Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Canvas") { onAdd(markdown) }
                        .disabled(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LectureSelectionStudyView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folderID: String
    let selectedObjectIDsByBoard: [String: [String]]
    var compact = false
    @State private var question = ""
    @State private var loading = false
    @State private var result: StudyInteractionResponse?
    @State private var error: String?

    var body: some View {
        Group {
            if compact {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Study Across Boards")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: compact ? 12 : 18) {
                if loading {
                    ProgressView("Connecting the selected whiteboards…")
                } else if let interaction = result?.interaction {
                    StudyRichHeading(source: interaction.title ?? "Across this class")
                    ScrollView {
                        StudyContentView(source: interaction.answer ?? "No explanation was returned.",
                                         maximumWidth: 700)
                    }
                } else {
                    Image(systemName: "rectangle.3.group.bubble.left")
                        .font(.largeTitle).foregroundStyle(.tint)
                    Text("Explain across whiteboards").font(.title2.bold())
                    Text("The selected regions stay owned by their original whiteboards. V-Board will connect only this evidence across the class.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .frame(maxWidth: 560)
                    TextField("Optional question", text: $question)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 560)
                    Button("Explain Selection") { explain() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedObjectIDsByBoard.count < 2 || selectedObjectIDsByBoard.count > 8)
                }
                if selectedObjectIDsByBoard.count > 8 {
                    Text("Select content from up to eight whiteboards at a time.").foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(compact ? 16 : 28)
    }

    private func explain() {
        loading = true; error = nil
        Task {
            do {
                result = try await api.explainLectureSelection(
                    folderID: folderID,
                    selectedObjectIDsByBoard: selectedObjectIDsByBoard,
                    question: question
                )
                loading = false
            } catch {
                loading = false
                self.error = "AI is temporarily unavailable. Your whiteboards are still saved."
            }
        }
    }
}

struct PencilQuickPalette: View {
    let activeTool: CanvasTool
    let highlightedIndex: Int
    @Binding var color: String
    @Binding var width: Double
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    let select: (CanvasTool) -> Void
    private let tools = PencilRadialPaletteModel.tools
    private let colors = CanvasColorPalette.pencilQuick
    private let center = CGPoint(x: 164, y: 166)

    var body: some View {
        ZStack {
            PencilArcBandShape()
                .fill(.regularMaterial)
                .overlay { PencilArcBandShape().stroke(.separator.opacity(0.5), lineWidth: 0.5) }

            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                radialToolButton(tool, index: index)
                    .position(arcPoint(index: index, radius: 96))
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(colors, id: \.self) { option in
                        Button {
                            color = option
                        } label: {
                            Label(CanvasColorPalette.name(for: option),
                                  systemImage: option == color
                                    ? "checkmark.circle.fill" : "circle.fill")
                        }
                        .accessibilityValue(CanvasColorPalette.accessibilityValue(for: option))
                    }
                } label: {
                    Circle()
                        .fill(Color(uiColor: UIColor(svgHex: color)))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                        .overlay(Circle().stroke(.separator.opacity(0.65), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ink color")

                Capsule()
                    .fill(Color(uiColor: UIColor(svgHex: color)))
                    .frame(width: max(3, min(18, width)), height: 8)
                    .accessibilityHidden(true)
                Slider(value: $width, in: activeTool == .highlighter ? 10...40 : 1.5...14)
                    .frame(width: 96)
                    .accessibilityLabel("Stroke width")
                    .accessibilityValue("\(width, specifier: "%.1f")")

                Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain)
                    .disabled(!canUndo)
                    .accessibilityLabel("Undo")
                Button(action: redo) { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(.plain)
                    .disabled(!canRedo)
                    .accessibilityLabel("Redo")
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(.separator.opacity(0.5), lineWidth: 0.5) }
            .position(x: center.x, y: 226)
        }
        .frame(width: 328, height: 258)
        .accessibilityElement(children: .contain)
    }

    private func radialToolButton(_ tool: CanvasTool, index: Int) -> some View {
        let highlighted = highlightedIndex == index
        return Button { select(tool) } label: {
            Image(systemName: icon(for: tool))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .frame(width: 48, height: 48)
                .background(highlighted ? Color.accentColor : Color.primary.opacity(0.07),
                            in: Circle())
                .overlay {
                    Circle().stroke(activeTool == tool ? Color.accentColor : .clear,
                                    lineWidth: highlighted ? 0 : 2)
                }
                .scaleEffect(highlighted ? 1.08 : 1)
                .animation(.easeOut(duration: 0.1), value: highlighted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName(for: tool))
        .accessibilityValue(highlighted ? "Highlighted" : "")
    }

    private func arcPoint(index: Int, radius: CGFloat) -> CGPoint {
        let angle = PencilArcPaletteLayout.angle(for: index, count: tools.count)
        return CGPoint(x: center.x + cos(angle) * radius,
                       y: center.y + sin(angle) * radius)
    }

    private func accessibilityName(for tool: CanvasTool) -> String {
        switch tool {
        case .highlighter: return "Marker"
        case .objectEraser: return "Eraser"
        case .lasso: return "Lasso"
        case .pen: return "Pen"
        default: return tool.rawValue.capitalized
        }
    }

    private func icon(for tool: CanvasTool) -> String {
        switch tool {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .objectEraser: return "eraser"
        case .lasso: return "lasso"
        default: return "cursorarrow"
        }
    }
}

private struct PencilArcBandShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.height * 0.643)
        let outer: CGFloat = 128
        let inner: CGFloat = 64
        let samples = 28
        var path = Path()
        for index in 0...samples {
            let angle = PencilArcPaletteLayout.startAngle
                + PencilArcPaletteLayout.sweepAngle * CGFloat(index) / CGFloat(samples)
            let point = CGPoint(x: center.x + cos(angle) * outer,
                                y: center.y + sin(angle) * outer)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        for index in (0...samples).reversed() {
            let angle = PencilArcPaletteLayout.startAngle
                + PencilArcPaletteLayout.sweepAngle * CGFloat(index) / CGFloat(samples)
            path.addLine(to: CGPoint(x: center.x + cos(angle) * inner,
                                      y: center.y + sin(angle) * inner))
        }
        path.closeSubpath()
        return path
    }
}

private struct LectureNavigatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LectureWorkspaceStore
    let api: APIClient

    private var sections: [(String, [WorkspaceBoardItem])] {
        guard let items = store.workspace?.items else { return [] }
        let grouped = Dictionary(grouping: items.sorted { $0.createdAt < $1.createdAt }, by: \.unitLabel)
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "No Unit" { return false }
            if rhs == "No Unit" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { section in
                    Section(section.0.uppercased()) {
                        ForEach(section.1) { item in
                            Button {
                                store.setActiveBoard(item.boardID, api: api, requestFocus: true)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).foregroundStyle(.primary)
                                        Text(dateLabel(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.boardID == store.activeBoardID {
                                        Image(systemName: "location.fill").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .contextMenu {
                                Button("No Unit") { store.setUnit(boardID: item.boardID, label: "No Unit", number: nil, api: api) }
                                ForEach(1...12, id: \.self) { number in
                                    Button("Unit \(number)") {
                                        store.setUnit(boardID: item.boardID, label: "Unit \(number)", number: number, api: api)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Class Navigator")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func dateLabel(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

private struct LectureNavigatorSidebar: View {
    @ObservedObject var store: LectureWorkspaceStore
    let api: APIClient
    let close: () -> Void

    private var sections: [(String, [WorkspaceBoardItem])] {
        guard let items = store.workspace?.items else { return [] }
        let grouped = Dictionary(grouping: items.sorted { $0.createdAt < $1.createdAt }, by: \.unitLabel)
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "No Unit" { return false }
            if rhs == "No Unit" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Class").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Close class navigator")
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            List {
                ForEach(sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { item in
                            Button {
                                store.setActiveBoard(item.boardID, api: api, requestFocus: true)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).lineLimit(2).foregroundStyle(.primary)
                                    Text(Date(timeIntervalSince1970: item.createdAt).formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .trailing) { Rectangle().fill(.separator.opacity(0.45)).frame(width: 0.5) }
    }
}
