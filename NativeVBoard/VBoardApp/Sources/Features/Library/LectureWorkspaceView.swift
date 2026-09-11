import SwiftUI

struct LectureWorkspaceView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folder: LectureFolder
    let initialFocusBoardID: String?
    @StateObject private var store: LectureWorkspaceStore
    @StateObject private var graphRecognition = GraphRecognitionController()
    @State private var activeTool: CanvasTool = .navigation
    @State private var showImporter = false
    @State private var showNavigator = false
    @State private var showGuide = false
    @State private var showStudy = false
    @State private var showNote = false
    @State private var showDelete = false
    @State private var showConflict = false
    @State private var showRenameBoard = false
    @State private var showSetUnit = false
    @State private var showDeleteBoard = false
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var actionError: String?
    @State private var selectionScreenBounds: CGRect?
    @State private var studyInitialAction: String?
    @State private var previousPencilTool: CanvasTool = .pen
    @State private var pencilQuickPalettePoint: CGPoint?
    @State private var graphCreationRequest: GraphCreationRequest?
    @State private var editingGraph: GraphObject?
    @State private var interactiveGraph: GraphObject?
    @State private var canvasSize = CGSize.zero
    @AppStorage("vboard.workspace.background") private var backgroundRaw = WorkspaceBackgroundStyle.dots.rawValue
    @AppStorage("vboard.workspace.physicalPaper") private var physicalBoardShowsPaper = false
    @AppStorage("vboard.study.inspectorWidth") private var studyPanelWidth = 0.0
    @AppStorage("vboard.study.panelCollapsed") private var studyPanelCollapsed = false
    @AppStorage("vboard.pen.color") private var penColor = CanvasStrokeStyle.pen.colorHex
    @AppStorage("vboard.pen.width") private var penWidth = CanvasStrokeStyle.pen.width
    @AppStorage("vboard.marker.color") private var markerColor = CanvasStrokeStyle.marker.colorHex
    @AppStorage("vboard.marker.width") private var markerWidth = CanvasStrokeStyle.marker.width
    @AppStorage("vboard.marker.opacity") private var markerOpacity = CanvasStrokeStyle.marker.opacity

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
                ContentUnavailableView("Couldn’t open lecture", systemImage: "rectangle.stack.badge.exclamationmark",
                                       description: Text(message))
                    .overlay(alignment: .bottom) {
                        Button("Retry") { Task { await store.load(api: api, focusBoardID: initialFocusBoardID) } }
                            .buttonStyle(.borderedProminent)
                            .padding(.bottom, 30)
                    }
            } else {
                ProgressView("Opening lecture workspace…")
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { store.undo(api: api) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!store.canUndo)
                Button { store.redo(api: api) } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!store.canRedo)
                Button { showNavigator = true } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Lecture navigator")
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
                .accessibilityLabel("Add to lecture")
                Button { showGuide = true } label: { Image(systemName: "text.book.closed") }
                    .accessibilityLabel("Study Guide")
                Menu {
                    if activeBoard != nil {
                        Button { showRenameBoard = true } label: { Label("Rename Whiteboard", systemImage: "pencil") }
                        Button { showSetUnit = true } label: { Label("Set Unit", systemImage: "tag") }
                        Button { Task { await exportActiveBoard() } } label: { Label("Export SVG", systemImage: "square.and.arrow.up") }
                        Divider()
                    }
                    Button { showNote = true } label: { Label("Add Note", systemImage: "note.text.badge.plus") }
                        .disabled(store.activeBoardStore == nil)
                    Picker("Workspace Background", selection: $backgroundRaw) {
                        ForEach(WorkspaceBackgroundStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
                    }
                    Toggle("Show Whiteboard Paper", isOn: $physicalBoardShowsPaper)
                    if activeBoard != nil {
                        Button(role: .destructive) { showDeleteBoard = true } label: { Label("Delete Whiteboard", systemImage: "trash") }
                    }
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete Lecture", systemImage: "trash") }
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
        .alert("Delete lecture?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await api.deleteLecture(id: folder.id, recursive: true); dismiss() }
                    catch { }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the lecture and all of its whiteboards.")
        }
        .alert("Lecture layout changed", isPresented: $showConflict) {
            Button("Keep My Layout") { store.keepLocalChanges(api: api) }
            Button("Reload Server Layout", role: .destructive) { store.reloadServerVersion() }
        } message: {
            Text("Your local camera and whiteboard placements are saved on this iPad. Choose which layout should remain.")
        }
        .confirmationDialog("Delete this whiteboard?", isPresented: $showDeleteBoard, titleVisibility: .visible) {
            Button("Delete Whiteboard", role: .destructive) { deleteActiveBoard() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The selected whiteboard and its edits will be permanently removed.") }
        .alert("Couldn’t complete that action", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(actionError ?? "") }
        .onChange(of: store.status) { _, status in
            if status == .conflict { showConflict = true }
        }
        .onChange(of: activeTool) { oldValue, newValue in
            if newValue != .objectEraser && oldValue != newValue {
                previousPencilTool = newValue
            }
            if !GraphPencilInteractionPolicy.allowsAnnotation(for: newValue) {
                interactiveGraph = nil
            }
        }
        .onChange(of: store.selectedKeys) { _, _ in
            let target = graphRecognitionTarget
            graphRecognition.selectionChanged(
                target, api: api,
                prepareSelection: { if let target { await prepareGraphRecognition(target) } }
            )
            if target?.primarySelection.canonicalObjectIDs != interactiveGraph.map({ [$0.id] }) {
                interactiveGraph = nil
            }
        }
        .task { await store.load(api: api, focusBoardID: initialFocusBoardID) }
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
            ZStack(alignment: .bottom) {
                LectureCanvasView(
                    workspace: workspace,
                    scenes: store.scenes,
                    selectedKeys: store.selectedKeys,
                    tool: activeTool,
                    backgroundStyle: WorkspaceBackgroundStyle(rawValue: backgroundRaw) ?? .dots,
                    physicalBoardShowsPaper: physicalBoardShowsPaper,
                    penStyle: CanvasStrokeStyle(colorHex: penColor, width: penWidth, opacity: 1),
                    markerStyle: CanvasStrokeStyle(colorHex: markerColor, width: markerWidth, opacity: markerOpacity),
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
                    onMoveSelection: { keys, delta in store.moveSelection(keys, by: delta, api: api) },
                    onResizeSelection: { keys, anchor, scale in
                        store.resizeSelection(keys, around: anchor, by: scale, api: api)
                    },
                    onDelete: { store.deleteSelection($0, api: api) },
                    onMoveBoard: { boardID, delta in store.moveBoard(boardID: boardID, by: delta, api: api) },
                    onUndo: { store.undo(api: api) },
                    onRedo: { store.redo(api: api) },
                    onPencilDoubleTap: { togglePencilEraser() },
                    onPencilSqueeze: { point in showPencilQuickPalette(at: point) }
                )
                .ignoresSafeArea(edges: .bottom)

                graphAccessibilityOverlays(workspace, viewport: proxy.size)

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
                        onPencilStroke: {
                            store.applyStroke($0, boardID: graph.owningBoardID, api: api)
                        },
                        onPencilRequestsPassiveMode: { interactiveGraph = nil },
                        onCommitViewport: { owningBoardID, graphID, viewport in
                            guard let current = store.scenes[owningBoardID]?.editor.objects
                                .first(where: { $0.id == graphID })?.graph else { return }
                            let updated = current.replacing(viewport: viewport)
                            store.replaceGraph(updated, boardID: owningBoardID, api: api)
                            if interactiveGraph?.id == graphID { interactiveGraph = updated }
                        },
                        onEdit: {
                            editingGraph = store.scenes[graph.owningBoardID]?.editor.objects
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

                WorkspaceToolPalette(activeTool: $activeTool, status: store.status.userLabel,
                                     penColor: $penColor, penWidth: $penWidth,
                                     markerColor: $markerColor, markerWidth: $markerWidth,
                                     markerOpacity: $markerOpacity)
                    .padding(.bottom, 12)
                    .zIndex(30)

                if interactiveGraph == nil, !store.selectedKeys.isEmpty, let selectionScreenBounds {
                    SelectionActionBar(
                        canCheckWork: selectionCanCheckWork,
                        graphPrimaryTitle: graphPrimaryTitle,
                        graphIsLoading: selectedGraph == nil && graphRecognition.isClassifying,
                        explain: { openStudy(action: "explain") },
                        practice: { openStudy(action: "practice_problems") },
                        check: { openStudy(action: "check_my_work") },
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
                    PencilQuickPalette(activeTool: activeTool) { tool in
                        activeTool = tool
                        pencilQuickPalettePoint = nil
                    }
                    .position(x: min(max(point.x, 150), proxy.size.width - 150),
                              y: min(max(point.y - 58, 42), proxy.size.height - 88))
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

    private func togglePencilEraser() {
        if activeTool == .objectEraser {
            activeTool = previousPencilTool == .objectEraser ? .pen : previousPencilTool
        } else {
            previousPencilTool = activeTool
            activeTool = .objectEraser
        }
    }

    private func showPencilQuickPalette(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.16)) { pencilQuickPalettePoint = point }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.16)) { pencilQuickPalettePoint = nil }
        }
    }

    @ViewBuilder private func studyContent(compact: Bool) -> some View {
        if selectedBoardIDs.count > 1 {
            LectureSelectionStudyView(folderID: folder.id,
                                      selectedObjectIDsByBoard: selectedObjectIDsByBoard,
                                      compact: compact)
        } else if let boardID = studyBoardID,
                  let selection = store.studySelection(for: boardID) {
            StudyActionsView(selection: selection,
                             prepareSelection: { await store.saveBoardNow(boardID, api: api) },
                             initialAction: studyInitialAction,
                             compact: compact) { problems, interactionID in
                store.applyPracticeProblems(problems, interactionID: interactionID,
                                            boardID: boardID, api: api)
            }
        } else {
            ContentUnavailableView("Select ink to study", systemImage: "lasso",
                                   description: Text("Use Select or Lasso, then choose an action beside the selection."))
        }
    }

    private func openStudy(action: String?) {
        studyInitialAction = action
        studyPanelCollapsed = false
        showStudy = true
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
        return GraphabilityPolicy.showsPrimaryAction(result: graphRecognition.result)
            ? "Graph" : nil
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
        var occupiedInLecture = workspace.items.map(\.effectiveFrame)
        for candidate in workspace.items {
            guard let candidateScene = store.scenes[candidate.boardID] else { continue }
            occupiedInLecture.append(contentsOf: candidateScene.editor.objects.map {
                LectureCoordinateTransform.boardLocalToLectureWorld(
                    BoardHitTestPolicy.bounds(of: $0), board: candidate
                )
            })
        }
        let occupiedInOwner = occupiedInLecture.map {
            LectureCoordinateTransform.lectureWorldToBoardLocal($0, board: item)
        }
        let graph = GraphObjectFactory.make(
            boardID: item.boardID, selection: selection, expressions: expressions,
            recognitionRequestID: requestID, cameraScale: scale, occupied: occupiedInOwner,
            sourceBoardIDs: sourceBoardIDs, selectedObjectKeys: selectedObjectKeys,
            placementSource: sourceInOwner
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
        let selectedObjects = store.selectedKeys.compactMap { key in
            store.scenes[key.boardID]?.editor.objects.first(where: { $0.id == key.objectID })
        }
        let hasProblem = selectedObjects.contains { $0.role == "ai_practice_problem" }
        let hasWork = selectedObjects.contains { $0.role != "ai_practice_problem" }
            || store.selectedKeys.contains { $0.kind == .professorPath }
        return hasProblem && hasWork
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

    private func deleteActiveBoard() {
        guard let board = activeBoard else { return }
        Task {
            do {
                try await api.deleteBoard(id: board.id)
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

    private func exportActiveBoard() async {
        guard let board = activeBoard else { return }
        do {
            let data = try await api.exportSVG(boardID: board.id)
            let safe = board.name.replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VBoardExports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent((safe.isEmpty ? "V-Board" : safe) + ".svg")
            try data.write(to: url, options: .atomic)
            exportURL = url
            showShare = true
        } catch { actionError = "The SVG could not be exported right now." }
    }

}

struct WorkspaceToolPalette: View {
    @Binding var activeTool: CanvasTool
    let status: String
    @Binding var penColor: String
    @Binding var penWidth: Double
    @Binding var markerColor: String
    @Binding var markerWidth: Double
    @Binding var markerOpacity: Double
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CanvasTool.allCases, id: \.self) { tool in
                WorkspaceToolButton(tool: tool, selected: activeTool == tool) {
                    if activeTool == tool && (tool == .pen || tool == .highlighter) { showOptions = true }
                    activeTool = tool
                }
            }
            if activeTool == .pen || activeTool == .highlighter {
                Button { showOptions = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 30, height: 30) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tool options")
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                        CanvasToolOptions(
                            title: activeTool == .pen ? "Pen" : "Marker",
                            color: activeTool == .pen ? $penColor : $markerColor,
                            width: activeTool == .pen ? $penWidth : $markerWidth,
                            opacity: activeTool == .pen ? .constant(1) : $markerOpacity,
                            showsOpacity: activeTool == .highlighter
                        )
                        .presentationCompactAdaptation(.popover)
                    }
            }
            Divider().frame(height: 24).padding(.horizontal, 3)
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 42)
        }
        .padding(6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 0.5) }
    }
}

private struct CanvasToolOptions: View {
    let title: String
    @Binding var color: String
    @Binding var width: Double
    @Binding var opacity: Double
    let showsOpacity: Bool
    private let colors = ["#183153", "#111111", "#C62828", "#1565C0", "#2E7D32", "#FFD60A", "#FF8A00"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { value in
                    Button { color = value } label: {
                        Circle().fill(Color(uiColor: UIColor(svgHex: value)))
                            .frame(width: 28, height: 28)
                            .overlay { if color == value { Circle().stroke(.primary, lineWidth: 2).padding(-3) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose color")
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

struct SelectionActionBar: View {
    let canCheckWork: Bool
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

    var body: some View {
        HStack(spacing: 2) {
            action("Explain", "text.magnifyingglass", explain)
            action("Practice", "list.bullet.clipboard", practice)
            if canCheckWork { action("Check", "checkmark.circle", check) }
            Group {
                if graphIsLoading {
                    ProgressView().controlSize(.small)
                } else if let graphPrimaryTitle {
                    action(graphPrimaryTitle,
                           graphPrimaryTitle == "Interact" ? "hand.tap" : "function",
                           graphPrimary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 70, height: 30)
            Menu {
                if editGraph != nil {
                    Button(action: { editGraph?() }) {
                        Label("Edit Equations", systemImage: "function")
                    }
                    Button(action: { resetGraph?() }) {
                        Label("Reset View", systemImage: "arrow.counterclockwise")
                    }
                    Button(action: { duplicateGraph?() }) {
                        Label("Duplicate Graph", systemImage: "plus.square.on.square")
                    }
                    Divider()
                } else {
                    Button(action: graphSelection) {
                        Label("Graph Selection", systemImage: "function")
                    }
                    Divider()
                }
                Button(role: .destructive, action: delete) { Label("Erase Selection", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
        }
        .font(.caption.weight(.semibold))
        .padding(5)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55), lineWidth: 0.5) }
    }

    private func action(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .padding(.horizontal, 7)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
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
            Text("Start this lecture").font(.title3.weight(.semibold))
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
                    Text(interaction.title ?? "Across this lecture").font(.title2.bold())
                    ScrollView {
                        StudyContentView(source: interaction.answer ?? "No explanation was returned.",
                                         maximumWidth: 700)
                    }
                } else {
                    Image(systemName: "rectangle.3.group.bubble.left")
                        .font(.largeTitle).foregroundStyle(.tint)
                    Text("Explain across whiteboards").font(.title2.bold())
                    Text("The selected regions stay owned by their original whiteboards. V-Board will connect only this evidence across the lecture.")
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

private struct WorkspaceToolButton: View {
    let tool: CanvasTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(title)
        .help(title)
    }

    private var title: String {
        switch tool {
        case .navigation: return "Hand"
        case .highlighter: return "Marker"
        case .objectEraser: return "Erase"
        default: return tool.rawValue.capitalized
        }
    }

    private var icon: String {
        switch tool {
        case .navigation: return "hand.draw"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .select: return "cursorarrow"
        case .lasso: return "lasso"
        case .objectEraser: return "eraser"
        }
    }
}

private struct PencilQuickPalette: View {
    let activeTool: CanvasTool
    let select: (CanvasTool) -> Void
    private let tools: [CanvasTool] = [.pen, .highlighter, .objectEraser, .lasso]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tools, id: \.rawValue) { tool in
                Button { select(tool) } label: {
                    Image(systemName: icon(for: tool))
                        .frame(width: 38, height: 34)
                        .background(activeTool == tool ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.rawValue.capitalized)
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
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
            .navigationTitle("Lecture Navigator")
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
                Text("Lecture").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Close lecture navigator")
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
