import CoreGraphics
import Foundation
import SwiftUI

enum WorkspacePersistenceStatus: Equatable {
    case loading
    case clean
    case dirty
    case saving
    case offlinePending
    case conflict
    case failed(String)

    var userLabel: String {
        switch self {
        case .loading: return "Loading…"
        case .clean: return "Saved"
        case .dirty: return "Unsaved changes"
        case .saving: return "Saving…"
        case .offlinePending: return "Saved locally"
        case .conflict: return "Layout needs review"
        case .failed: return "Couldn’t load lecture"
        }
    }
}

struct WorkspaceFocusRequest: Equatable {
    let id = UUID()
    let boardID: String
}

/// Owns only lecture placement/camera state and a bounded cache of separately
/// persisted board stores. It never constructs a merged editor document.
@MainActor
final class LectureWorkspaceStore: ObservableObject {
    private enum HistoryEntry {
        case workspace(LectureWorkspace)
        case boards([String])
    }

    @Published private(set) var workspace: LectureWorkspace?
    @Published private(set) var lecture: LectureResponse?
    @Published private(set) var scenes: [String: WorkspaceBoardScene] = [:]
    @Published private(set) var status: WorkspacePersistenceStatus = .loading
    @Published private(set) var selectedKeys = Set<SelectionKey>()
    @Published private(set) var focusRequest: WorkspaceFocusRequest?

    let folderID: String
    private var boardStores: [String: BoardDocumentStore] = [:]
    private var sceneLoadTasks: [String: Task<Void, Never>] = [:]
    private var sceneLoadTokens: [String: UUID] = [:]
    private var desiredFullDetail = Set<String>()
    private var lastSceneUse: [String: TimeInterval] = [:]
    private let sceneCacheLimit = 6
    private var saveTask: Task<Void, Never>?
    private var mutationGeneration = 0
    private var baseRevision = 0
    private var undoHistory: [HistoryEntry] = []
    private var redoHistory: [HistoryEntry] = []

    init(folderID: String) {
        self.folderID = folderID
    }

    deinit {
        saveTask?.cancel()
        sceneLoadTasks.values.forEach { $0.cancel() }
    }

    var boards: [LibraryBoard] { lecture?.boards ?? [] }
    var activeBoardID: String? { workspace?.activeBoardID }
    var canUndo: Bool { !undoHistory.isEmpty || activeBoardStore?.canUndo == true }
    var canRedo: Bool { !redoHistory.isEmpty || activeBoardStore?.canRedo == true }
    var activeBoardStore: BoardDocumentStore? {
        guard let activeBoardID else { return nil }
        return boardStores[activeBoardID]
    }

    func load(api: APIClient, focusBoardID: String? = nil) async {
        status = .loading
        do {
            let lecture = try await api.lecture(id: folderID)
            let serverWorkspace: LectureWorkspace
            do {
                serverWorkspace = try await api.lectureWorkspace(id: folderID)
            } catch APIError.server(let status, _, _) where status == 404 {
                serverWorkspace = LectureWorkspace.legacy(lecture: lecture)
                #if DEBUG
                print("[VBoard] WORKSPACE ENDPOINT UNAVAILABLE folder=\(folderID) using=isolated-local-manifest")
                #endif
            }
            self.lecture = lecture
            let local = readOutbox()
            if let local, local.baseRevision == serverWorkspace.revision {
                workspace = local.workspace
                baseRevision = local.baseRevision
                status = .offlinePending
                scheduleSave(api: api)
            } else {
                workspace = serverWorkspace
                baseRevision = serverWorkspace.revision
                status = .clean
                if local != nil { removeOutbox() }
            }
            if let focusBoardID, workspace?.items.contains(where: { $0.boardID == focusBoardID }) == true {
                setActiveBoard(focusBoardID, api: api, requestFocus: true)
            } else if let active = workspace?.activeBoardID {
                requestDetail(for: [active], api: api)
            }
        } catch {
            status = .failed("Your lecture workspace could not be loaded.")
        }
    }

    func refreshAfterImport(boardID: String, api: APIClient) async {
        do {
            let refreshedLecture = try await api.lecture(id: folderID)
            let refreshed: LectureWorkspace
            do {
                refreshed = try await api.lectureWorkspace(id: folderID)
            } catch APIError.server(let status, _, _) where status == 404 {
                refreshed = mergeLegacyRefresh(LectureWorkspace.legacy(lecture: refreshedLecture))
            }
            workspace = refreshed
            lecture = refreshedLecture
            baseRevision = refreshed.revision
            status = .clean
            removeOutbox()
            setActiveBoard(boardID, api: api, requestFocus: true)
        } catch {
            status = .offlinePending
        }
    }

    private func mergeLegacyRefresh(_ generated: LectureWorkspace) -> LectureWorkspace {
        guard let current = workspace else { return generated }
        var result = generated
        let existing = Dictionary(uniqueKeysWithValues: current.items.map { ($0.boardID, $0) })
        var placed: [WorkspaceBoardItem] = []
        for var item in result.items {
            if let retained = existing[item.boardID] {
                item = retained
            } else {
                let position = WorkspaceLayout.placement(
                    for: CGSize(width: item.boardWidth, height: item.boardHeight),
                    after: placed
                )
                item.canvasX = Double(position.x)
                item.canvasY = Double(position.y)
                item.effectiveContentBounds = CameraRect(x: item.canvasX, y: item.canvasY,
                                                          width: item.boardWidth, height: item.boardHeight)
            }
            placed.append(item)
        }
        result.items = placed
        result.camera = current.camera
        result.revision = current.revision
        return result
    }

    func updateCamera(_ camera: CameraRect, api: APIClient) {
        guard var current = workspace, current.camera != camera else { return }
        current.camera = camera
        current.lastViewedAt = Date().timeIntervalSince1970
        workspace = current
        markDirty(api: api)
    }

    func setActiveBoard(_ boardID: String, api: APIClient, requestFocus: Bool = false) {
        guard var current = workspace,
              current.items.contains(where: { $0.boardID == boardID }) else { return }
        if current.activeBoardID != boardID {
            current.activeBoardID = boardID
            workspace = current
            markDirty(api: api)
        }
        if requestFocus { focusRequest = WorkspaceFocusRequest(boardID: boardID) }
        requestDetail(for: desiredFullDetail.union([boardID]), api: api)
    }

    func moveBoard(boardID: String, by lectureDelta: CGPoint, api: APIClient) {
        guard var current = workspace,
              let index = current.items.firstIndex(where: { $0.boardID == boardID }),
              lectureDelta != .zero else { return }
        recordWorkspaceUndo(current)
        current.items[index].canvasX += Double(lectureDelta.x)
        current.items[index].canvasY += Double(lectureDelta.y)
        current.items[index].effectiveContentBounds.x += Double(lectureDelta.x)
        current.items[index].effectiveContentBounds.y += Double(lectureDelta.y)
        current.activeBoardID = boardID
        workspace = current
        markDirty(api: api)
    }

    func setUnit(boardID: String, label: String, number: Int?, api: APIClient) {
        guard var current = workspace,
              let index = current.items.firstIndex(where: { $0.boardID == boardID }) else { return }
        recordWorkspaceUndo(current)
        current.items[index].unitLabel = label.isEmpty ? "No Unit" : label
        current.items[index].unitNumber = number
        current.items[index].unitConfidence = 1
        current.items[index].unitSource = .manual
        workspace = current
        markDirty(api: api)
    }

    func setSelection(_ keys: Set<SelectionKey>) {
        selectedKeys = keys
    }

    func requestDetail(for boardIDs: Set<String>, api: APIClient) {
        guard let workspace else { return }
        let valid = Set(workspace.items.map(\.boardID))
        let requested = boardIDs.intersection(valid)
        let ordered = requested.sorted { lhs, rhs in
            if lhs == workspace.activeBoardID { return true }
            if rhs == workspace.activeBoardID { return false }
            return lhs < rhs
        }
        desiredFullDetail = Set(ordered.prefix(BoardDetailPolicy.defaultFullDetailBudget))
        let obsolete = sceneLoadTasks.keys.filter { !desiredFullDetail.contains($0) }
        for boardID in obsolete {
            sceneLoadTasks[boardID]?.cancel()
            sceneLoadTasks.removeValue(forKey: boardID)
            sceneLoadTokens.removeValue(forKey: boardID)
        }
        for boardID in desiredFullDetail {
            if scenes[boardID] != nil {
                lastSceneUse[boardID] = Date().timeIntervalSinceReferenceDate
            } else if sceneLoadTasks[boardID] == nil {
                loadScene(boardID: boardID, api: api)
            }
        }
        evictScenesIfNeeded()
    }

    func applyStroke(_ stroke: UserStroke, boardID: String, api: APIClient) {
        guard let store = boardStores[boardID] else { return }
        recordBoardUndo([boardID])
        store.applyStroke(stroke, api: api)
        refreshSceneSnapshot(boardID, api: api)
    }

    func moveSelection(_ keys: Set<SelectionKey>, by lectureDelta: CGPoint, api: APIClient) {
        let grouped = Dictionary(grouping: keys, by: \.boardID)
        let affected = grouped.keys.filter { boardStores[$0] != nil }.sorted()
        guard !affected.isEmpty else { return }
        recordBoardUndo(affected)
        for (boardID, boardKeys) in grouped {
            guard let store = boardStores[boardID],
                  let item = workspace?.items.first(where: { $0.boardID == boardID }) else { continue }
            let localDelta = LectureCoordinateTransform.lectureDeltaToBoardLocal(lectureDelta, board: item)
            store.moveObjects(ids: Set(boardKeys.map(\.objectID)), by: localDelta, api: api)
            refreshSceneSnapshot(boardID, api: api)
        }
    }

    func deleteSelection(_ keys: Set<SelectionKey>, api: APIClient) {
        let grouped = Dictionary(grouping: keys, by: \.boardID)
        let affected = grouped.keys.filter { boardStores[$0] != nil }.sorted()
        guard !affected.isEmpty else { return }
        recordBoardUndo(affected)
        for (boardID, boardKeys) in grouped {
            guard let store = boardStores[boardID] else { continue }
            store.deleteObjects(ids: Set(boardKeys.map(\.objectID)), api: api)
            refreshSceneSnapshot(boardID, api: api)
        }
        selectedKeys.subtract(keys)
    }

    func applyPracticeProblems(_ problems: [PracticeProblem], interactionID: String?,
                               boardID: String, api: APIClient) {
        guard let store = boardStores[boardID] else { return }
        let before = store.editor.objects.count
        store.applyPracticeProblems(problems, interactionID: interactionID, api: api)
        guard store.editor.objects.count != before else { return }
        recordBoardUndo([boardID])
        refreshSceneSnapshot(boardID, api: api)
    }

    func undo(api: APIClient) {
        if let entry = undoHistory.popLast() {
            switch entry {
            case .workspace(let previous):
                guard let current = workspace else { return }
                redoHistory.append(.workspace(current))
                workspace = previous
                markDirty(api: api)
            case .boards(let boardIDs):
                for boardID in boardIDs {
                    boardStores[boardID]?.undo(api: api)
                    refreshSceneSnapshot(boardID, api: api)
                }
                redoHistory.append(.boards(boardIDs))
            }
            return
        }
        activeBoardStore?.undo(api: api)
        if let activeBoardID { refreshSceneSnapshot(activeBoardID, api: api) }
    }

    func redo(api: APIClient) {
        if let entry = redoHistory.popLast() {
            switch entry {
            case .workspace(let next):
                guard let current = workspace else { return }
                undoHistory.append(.workspace(current))
                workspace = next
                markDirty(api: api)
            case .boards(let boardIDs):
                for boardID in boardIDs {
                    boardStores[boardID]?.redo(api: api)
                    refreshSceneSnapshot(boardID, api: api)
                }
                undoHistory.append(.boards(boardIDs))
            }
            return
        }
        activeBoardStore?.redo(api: api)
        if let activeBoardID { refreshSceneSnapshot(activeBoardID, api: api) }
    }

    func persistForBackgrounding() {
        if status != .clean { persistOutbox() }
        boardStores.values.forEach { $0.persistForBackgrounding() }
    }

    func saveNow(api: APIClient) async {
        saveTask?.cancel()
        guard let candidate = workspace,
              status == .dirty || status == .offlinePending else { return }
        let generation = mutationGeneration
        status = .saving
        do {
            let saved = try await api.saveLectureWorkspace(candidate, folderID: folderID)
            if mutationGeneration == generation {
                workspace = saved
                baseRevision = saved.revision
                status = .clean
                removeOutbox()
            } else {
                status = .dirty
                persistOutbox()
                scheduleSave(api: api)
            }
        } catch APIError.workspaceConflict(_) {
            status = .conflict
            persistOutbox()
        } catch {
            status = .offlinePending
            persistOutbox()
        }
    }

    private func loadScene(boardID: String, api: APIClient) {
        let token = UUID()
        sceneLoadTokens[boardID] = token
        sceneLoadTasks[boardID] = Task { [weak self] in
            do {
                async let editorRequest = api.editor(id: boardID)
                async let svgRequest = api.professorSVG(id: boardID)
                let (editor, source) = try await (editorRequest, svgRequest)
                let document = try SVGDocument.parse(source)
                guard let self, !Task.isCancelled,
                      self.sceneLoadTokens[boardID] == token,
                      self.desiredFullDetail.contains(boardID) else { return }
                let boardStore = BoardDocumentStore(boardID: boardID, editor: editor)
                boardStore.restoreLocalIfPresent(server: editor)
                self.boardStores[boardID] = boardStore
                let effectiveEditor = boardStore.editor
                self.scenes[boardID] = WorkspaceBoardScene(
                    boardID: boardID,
                    document: document,
                    editor: effectiveEditor,
                    composition: SceneComposition.build(boardID: boardID, document: document, editor: effectiveEditor)
                )
                self.refreshEffectiveBounds(boardID: boardID, api: api)
                self.lastSceneUse[boardID] = Date().timeIntervalSinceReferenceDate
                self.sceneLoadTasks.removeValue(forKey: boardID)
                self.sceneLoadTokens.removeValue(forKey: boardID)
                self.evictScenesIfNeeded()
            } catch {
                guard let self, self.sceneLoadTokens[boardID] == token else { return }
                self.sceneLoadTasks.removeValue(forKey: boardID)
                self.sceneLoadTokens.removeValue(forKey: boardID)
                #if DEBUG
                print("[VBoard] LECTURE BOARD LOAD FAILED board=\(boardID) error=\(error)")
                #endif
            }
        }
    }

    private func refreshSceneSnapshot(_ boardID: String, api: APIClient) {
        guard var scene = scenes[boardID], let store = boardStores[boardID] else { return }
        scene.editor = store.editor
        scene.composition = SceneComposition.build(boardID: boardID, document: scene.document, editor: store.editor)
        scenes[boardID] = scene
        lastSceneUse[boardID] = Date().timeIntervalSinceReferenceDate
        refreshEffectiveBounds(boardID: boardID, api: api)
    }

    private func refreshEffectiveBounds(boardID: String, api: APIClient) {
        guard var current = workspace,
              let index = current.items.firstIndex(where: { $0.boardID == boardID }),
              let scene = scenes[boardID] else { return }
        let item = current.items[index]
        var local = WorkspaceEffectiveBounds.boardLocal(
            editor: scene.editor,
            boardSize: CGSize(width: item.boardWidth, height: item.boardHeight)
        )
        let pathsByID = Dictionary(uniqueKeysWithValues: scene.document.paths.compactMap { path in
            path.id.map { ($0, path) }
        })
        for (pathID, transform) in scene.editor.importedTransforms where transform.deleted != true {
            guard let source = pathsByID[pathID],
                  let path = try? SVGPathParser.cachedPath(from: source.d) else { continue }
            var affine = CGAffineTransform.identity
                .translatedBy(x: CGFloat(transform.x), y: CGFloat(transform.y))
                .scaledBy(x: CGFloat(transform.scaleX ?? 1), y: CGFloat(transform.scaleY ?? 1))
            guard
                  let transformed = path.copy(using: &affine) else { continue }
            local = local.union(transformed.boundingBoxOfPath)
        }
        let lecture = LectureCoordinateTransform.boardLocalToLectureWorld(local, board: item)
        let next = CameraRect(x: lecture.minX, y: lecture.minY,
                              width: max(lecture.width, 1), height: max(lecture.height, 1))
        guard next != item.effectiveContentBounds else { return }
        current.items[index].effectiveContentBounds = next
        workspace = current
        markDirty(api: api)
    }

    private func evictScenesIfNeeded() {
        guard scenes.count > sceneCacheLimit else { return }
        let candidates = scenes.keys.filter { !desiredFullDetail.contains($0) }
            .sorted { (lastSceneUse[$0] ?? 0) < (lastSceneUse[$1] ?? 0) }
        for boardID in candidates.prefix(max(0, scenes.count - sceneCacheLimit)) {
            scenes.removeValue(forKey: boardID)
            boardStores.removeValue(forKey: boardID)
            lastSceneUse.removeValue(forKey: boardID)
        }
    }

    private func recordWorkspaceUndo(_ current: LectureWorkspace) {
        undoHistory.append(.workspace(current))
        trimHistory()
        redoHistory.removeAll()
    }

    private func recordBoardUndo(_ boardIDs: [String]) {
        guard !boardIDs.isEmpty else { return }
        undoHistory.append(.boards(boardIDs))
        trimHistory()
        redoHistory.removeAll()
    }

    private func trimHistory() {
        if undoHistory.count > 100 { undoHistory.removeFirst() }
    }

    private func markDirty(api: APIClient) {
        mutationGeneration += 1
        status = .dirty
        persistOutbox()
        scheduleSave(api: api)
    }

    private func scheduleSave(api: APIClient) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.saveNow(api: api)
        }
    }

    private struct OutboxEnvelope: Codable {
        let folderID: String
        let baseRevision: Int
        let workspace: LectureWorkspace

        enum CodingKeys: String, CodingKey {
            case folderID = "folder_id"
            case baseRevision = "base_revision"
            case workspace
        }
    }

    private var outboxURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VBoard/workspace-outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(folderID).json")
    }

    private func persistOutbox() {
        guard let workspace,
              let data = try? JSONEncoder().encode(OutboxEnvelope(folderID: folderID, baseRevision: baseRevision, workspace: workspace)) else { return }
        try? data.write(to: outboxURL, options: .atomic)
    }

    private func readOutbox() -> OutboxEnvelope? {
        guard let data = try? Data(contentsOf: outboxURL) else { return nil }
        return try? JSONDecoder().decode(OutboxEnvelope.self, from: data)
    }

    private func removeOutbox() {
        try? FileManager.default.removeItem(at: outboxURL)
    }
}
