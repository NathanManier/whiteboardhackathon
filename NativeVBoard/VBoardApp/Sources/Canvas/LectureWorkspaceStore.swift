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

/// Lecture manifests contain placement metadata rather than board content.
/// Non-overlapping board changes merge by stable board ID; camera and active
/// focus are local-device preferences and therefore never require a modal.
enum LectureWorkspaceThreeWayMerger {
    static func merge(base: LectureWorkspace,
                      local: LectureWorkspace,
                      server: LectureWorkspace) -> LectureWorkspace {
        let baseItems = Dictionary(uniqueKeysWithValues: base.items.map { ($0.boardID, $0) })
        let localItems = Dictionary(uniqueKeysWithValues: local.items.map { ($0.boardID, $0) })
        let serverItems = Dictionary(uniqueKeysWithValues: server.items.map { ($0.boardID, $0) })
        let ids = Set(baseItems.keys).union(localItems.keys).union(serverItems.keys)
        var mergedByID: [String: WorkspaceBoardItem] = [:]
        for id in ids {
            if let item = mergeItem(base: baseItems[id], local: localItems[id], server: serverItems[id]) {
                mergedByID[id] = item
            }
        }

        var ordered: [WorkspaceBoardItem] = []
        var emitted = Set<String>()
        for item in server.items + local.items {
            guard emitted.insert(item.boardID).inserted,
                  let merged = mergedByID[item.boardID] else { continue }
            ordered.append(merged)
        }
        return LectureWorkspace(
            schemaVersion: max(base.schemaVersion, max(local.schemaVersion, server.schemaVersion)),
            revision: server.revision,
            camera: local.camera,
            items: ordered,
            activeBoardID: local.activeBoardID ?? server.activeBoardID,
            lastViewedAt: local.lastViewedAt ?? server.lastViewedAt
        )
    }

    private static func mergeItem(base: WorkspaceBoardItem?,
                                  local: WorkspaceBoardItem?,
                                  server: WorkspaceBoardItem?) -> WorkspaceBoardItem? {
        switch (base, local, server) {
        case (nil, nil, nil): return nil
        case (nil, let local?, nil): return local
        case (nil, nil, let server?): return server
        case (nil, let local?, _): return local
        case (let base?, nil, let server?): return server == base ? nil : server
        case (let base?, let local?, nil): return local == base ? nil : local
        case (_, nil, nil): return nil
        case (let base?, let local?, let server?):
            return WorkspaceBoardItem(
                id: server.id,
                kind: server.kind,
                boardID: server.boardID,
                canvasX: resolve(base.canvasX, local.canvasX, server.canvasX),
                canvasY: resolve(base.canvasY, local.canvasY, server.canvasY),
                boardWidth: server.boardWidth,
                boardHeight: server.boardHeight,
                effectiveContentBounds: resolve(base.effectiveContentBounds,
                                                local.effectiveContentBounds,
                                                server.effectiveContentBounds),
                createdAt: server.createdAt,
                capturedAt: server.capturedAt,
                detectedBoardDate: server.detectedBoardDate,
                unitLabel: resolve(base.unitLabel, local.unitLabel, server.unitLabel),
                unitNumber: resolve(base.unitNumber, local.unitNumber, server.unitNumber),
                unitConfidence: resolve(base.unitConfidence,
                                        local.unitConfidence,
                                        server.unitConfidence),
                unitSource: resolve(base.unitSource, local.unitSource, server.unitSource),
                title: server.title,
                thumbnailURL: server.thumbnailURL,
                sourceKind: server.sourceKind,
                pdfURL: server.pdfURL,
                pdfPageNumber: server.pdfPageNumber,
                zIndex: resolve(base.zIndex, local.zIndex, server.zIndex)
            )
        }
    }

    private static func resolve<T: Equatable>(_ base: T, _ local: T, _ server: T) -> T {
        if local == server { return local }
        if local == base { return server }
        if server == base { return local }
        return local
    }
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
    @Published private(set) var selectedPDFRegions: [String: CGRect] = [:]
    @Published private(set) var focusRequest: WorkspaceFocusRequest?
    @Published private(set) var conflictServerWorkspace: LectureWorkspace?

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
    private var baseWorkspace: LectureWorkspace?
    private var saveSequence = 0
    private var saveInFlight = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
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
            } catch APIError.notFound {
                serverWorkspace = LectureWorkspace.legacy(lecture: lecture)
                #if DEBUG
                print("[VBoard] WORKSPACE ENDPOINT UNAVAILABLE folder=\(folderID) using=isolated-local-manifest")
                #endif
            }
            self.lecture = lecture
            conflictServerWorkspace = nil
            let local = readOutbox()
            if let local, local.baseRevision == serverWorkspace.revision {
                workspace = local.workspace
                baseRevision = local.baseRevision
                baseWorkspace = local.baseWorkspace ?? serverWorkspace
                status = .offlinePending
                scheduleSave(api: api)
            } else if let local {
                workspace = LectureWorkspaceThreeWayMerger.merge(
                    base: local.baseWorkspace ?? serverWorkspace,
                    local: local.workspace,
                    server: serverWorkspace
                )
                baseRevision = serverWorkspace.revision
                baseWorkspace = serverWorkspace
                status = .dirty
                persistOutbox()
                scheduleSave(api: api)
            } else {
                workspace = serverWorkspace
                baseRevision = serverWorkspace.revision
                baseWorkspace = serverWorkspace
                status = .clean
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
            } catch APIError.notFound {
                refreshed = mergeLegacyRefresh(LectureWorkspace.legacy(lecture: refreshedLecture))
            }
            workspace = refreshed
            lecture = refreshedLecture
            baseRevision = refreshed.revision
            baseWorkspace = refreshed
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

    func setSelection(_ keys: Set<SelectionKey>, pdfRegions: [String: CGRect] = [:]) {
        selectedKeys = keys
        selectedPDFRegions = pdfRegions.filter { boardID, rect in
            keys.contains(where: {
                $0.boardID == boardID && $0.objectID == PDFBoardSource.logicalID
            }) && !rect.isNull && !rect.isInfinite
        }
    }

    func studySelection(for boardID: String) -> BoardStudySelection? {
        guard let item = workspace?.items.first(where: { $0.boardID == boardID }),
              let scene = scenes[boardID] else { return nil }
        return BoardStudySelection.lecture(boardID: boardID,
                                           selectionKeys: selectedKeys,
                                           item: item,
                                           scene: scene,
                                           preferredLocalBBox: selectedPDFRegions[boardID])
    }

    func saveBoardNow(_ boardID: String, api: APIClient) async {
        await boardStores[boardID]?.saveNow(api: api)
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
            store.moveObjects(
                editorObjectIDs: Set(boardKeys.filter { $0.kind == .editorObject }.map(\.objectID)),
                professorPathIDs: Set(boardKeys.filter { $0.kind == .professorPath }.map(\.objectID)),
                by: localDelta,
                api: api
            )
            refreshSceneSnapshot(boardID, api: api)
        }
    }

    func resizeTextObject(_ key: SelectionKey, to localSize: CGSize, api: APIClient) {
        guard key.kind == .editorObject, let store = boardStores[key.boardID] else { return }
        recordBoardUndo([key.boardID])
        store.resizeTextObject(id: key.objectID, to: localSize, api: api)
        refreshSceneSnapshot(key.boardID, api: api)
    }

    /// Resizes a mixed or cross-board selection as one workspace history
    /// gesture while keeping each board's editor.json isolated.
    @discardableResult
    func resizeSelection(_ keys: Set<SelectionKey>,
                         around lectureAnchor: CGPoint,
                         by factor: CGFloat,
                         api: APIClient) -> CGFloat? {
        let grouped = Dictionary(grouping: keys, by: \.boardID)
        var prepared: [(boardID: String, store: BoardDocumentStore,
                        editorIDs: Set<String>, professorIDs: Set<String>,
                        localAnchor: CGPoint, bounds: SelectionScaleBounds)] = []
        for (boardID, boardKeys) in grouped {
            guard let store = boardStores[boardID],
                  let item = workspace?.items.first(where: { $0.boardID == boardID }) else {
                return nil
            }
            let localAnchor = LectureCoordinateTransform.lectureWorldToBoardLocal(lectureAnchor, board: item)
            let editorIDs = Set(boardKeys.filter { $0.kind == .editorObject }.map(\.objectID))
            let professorIDs = Set(boardKeys.filter { $0.kind == .professorPath }.map(\.objectID))
            guard let bounds = store.selectionScaleBounds(
                editorObjectIDs: editorIDs,
                professorPathIDs: professorIDs,
                around: localAnchor
            ) else { return nil }
            prepared.append((boardID, store, editorIDs, professorIDs, localAnchor, bounds))
        }
        guard !prepared.isEmpty else { return nil }

        // Lecture selections may span isolated board documents, but the
        // visual gesture is still one rigid selection. Intersect every
        // board-local constraint first, then commit exactly one factor to all
        // owners so a graph reaching its limit cannot distort other members.
        var sharedBounds = prepared[0].bounds
        for context in prepared.dropFirst() { sharedBounds.formIntersection(context.bounds) }
        guard let boundedFactor = sharedBounds.clampedFactor(factor) else { return nil }

        var mutatedBoardIDs: [String] = []
        for context in prepared.sorted(by: { $0.boardID < $1.boardID }) {
            guard context.store.scaleObjects(
                editorObjectIDs: context.editorIDs,
                professorPathIDs: context.professorIDs,
                around: context.localAnchor,
                by: boundedFactor,
                api: api
            ) != nil else { continue }
            mutatedBoardIDs.append(context.boardID)
            refreshSceneSnapshot(context.boardID, api: api)
        }
        guard !mutatedBoardIDs.isEmpty else { return nil }
        // History ownership is installed only after a canonical mutation.
        // A graph already at its bound must not create a workspace undo entry
        // that later pops an unrelated board-level edit.
        recordBoardUndo(mutatedBoardIDs)
        return boundedFactor
    }

    func deleteSelection(_ keys: Set<SelectionKey>, api: APIClient) {
        let grouped = Dictionary(grouping: keys, by: \.boardID)
        let affected = grouped.keys.filter { boardStores[$0] != nil }.sorted()
        guard !affected.isEmpty else { return }
        recordBoardUndo(affected)
        for (boardID, boardKeys) in grouped {
            guard let store = boardStores[boardID] else { continue }
            store.deleteObjects(
                editorObjectIDs: Set(boardKeys.filter { $0.kind == .editorObject }.map(\.objectID)),
                professorPathIDs: Set(boardKeys.filter { $0.kind == .professorPath }.map(\.objectID)),
                api: api
            )
            refreshSceneSnapshot(boardID, api: api)
        }
        selectedKeys.subtract(keys)
    }

    func applyPracticeProblems(_ problems: [PracticeProblem], interactionID: String?,
                               boardID: String, api: APIClient) {
        guard let store = boardStores[boardID] else { return }
        let before = store.editor.objects.count
        let unitLabel = workspace?.items.first(where: { $0.boardID == boardID })?.unitLabel
        store.applyPracticeProblems(problems, interactionID: interactionID,
                                    unitLabel: unitLabel, api: api)
        guard store.editor.objects.count != before else { return }
        recordBoardUndo([boardID])
        refreshSceneSnapshot(boardID, api: api)
    }

    func addGraph(_ graph: GraphObject, boardID: String, api: APIClient) {
        guard graph.owningBoardID == boardID,
              let store = boardStores[boardID] else { return }
        let before = store.editor.objects.count
        recordBoardUndo([boardID])
        store.addGraph(graph, api: api)
        guard store.editor.objects.count != before else {
            _ = undoHistory.popLast()
            return
        }
        refreshSceneSnapshot(boardID, api: api)
        selectedKeys = [SelectionKey(boardID: boardID, objectID: graph.id,
                                     kind: .editorObject, objectType: "graph")]
        selectedPDFRegions.removeAll()
    }

    func replaceGraph(_ graph: GraphObject, boardID: String, api: APIClient) {
        guard graph.owningBoardID == boardID,
              let store = boardStores[boardID],
              store.editor.objects.contains(where: { $0.id == graph.id && $0.graph != graph })
        else { return }
        recordBoardUndo([boardID])
        store.replaceGraph(graph, api: api)
        refreshSceneSnapshot(boardID, api: api)
    }

    @discardableResult
    func duplicateGraph(_ key: SelectionKey, api: APIClient) -> SelectionKey? {
        guard key.kind == .editorObject,
              let store = boardStores[key.boardID] else { return nil }
        recordBoardUndo([key.boardID])
        guard let id = store.duplicateGraph(id: key.objectID, api: api) else {
            _ = undoHistory.popLast()
            return nil
        }
        refreshSceneSnapshot(key.boardID, api: api)
        let duplicate = SelectionKey(boardID: key.boardID, objectID: id,
                                     kind: .editorObject, objectType: "graph")
        selectedKeys = [duplicate]
        selectedPDFRegions.removeAll()
        return duplicate
    }

    func addNote(_ markdown: String, api: APIClient) {
        guard let boardID = activeBoardID,
              let store = boardStores[boardID],
              let item = workspace?.items.first(where: { $0.boardID == boardID }) else { return }
        recordBoardUndo([boardID])
        store.addNote(markdown: markdown,
                      at: CGPoint(x: item.boardWidth + 72, y: 72),
                      unitLabel: item.unitLabel, api: api)
        refreshSceneSnapshot(boardID, api: api)
    }

    func undo(api: APIClient) {
        if let entry = undoHistory.popLast() {
            switch entry {
            case .workspace(var previous):
                guard let current = workspace else { return }
                redoHistory.append(.workspace(current))
                previous.revision = current.revision
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
            case .workspace(var next):
                guard let current = workspace else { return }
                undoHistory.append(.workspace(current))
                next.revision = current.revision
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
        saveTask = nil
        await withCheckedContinuation { continuation in
            saveWaiters.append(continuation)
            Task { @MainActor in await drainSaveQueue(api: api) }
        }
    }

    private func drainSaveQueue(api: APIClient) async {
        if saveInFlight { return }
        saveInFlight = true
        var automaticConflictRetries = 0
        while status == .dirty || status == .offlinePending {
            let result = await performSaveAttempt(
                api: api,
                permitsConflictRetry: automaticConflictRetries == 0
            )
            if result.consumedConflictRetry { automaticConflictRetries += 1 }
            if !result.shouldContinue { break }
        }
        saveInFlight = false
        let waiters = saveWaiters
        saveWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func performSaveAttempt(
        api: APIClient,
        permitsConflictRetry: Bool
    ) async -> (shouldContinue: Bool, consumedConflictRetry: Bool) {
        guard let candidate = workspace,
              status == .dirty || status == .offlinePending else {
            return (false, false)
        }
        let generation = mutationGeneration
        status = .saving
        saveSequence += 1
        let sequence = saveSequence
        #if DEBUG
        print("[VBoard] WORKSPACE SAVE BEGIN folder=\(folderID) sequence=\(sequence) baseRevision=\(baseRevision) requestRevision=\(candidate.revision) generation=\(generation) inFlight=1")
        #endif
        do {
            let saved = try await api.saveLectureWorkspace(candidate, folderID: folderID)
            baseWorkspace = saved
            baseRevision = saved.revision
            if mutationGeneration == generation {
                workspace = saved
                status = .clean
                removeOutbox()
                #if DEBUG
                print("[VBoard] WORKSPACE SAVE ACK folder=\(folderID) sequence=\(sequence) serverRevision=\(saved.revision) pending=false")
                #endif
                return (false, false)
            } else {
                // A camera/placement mutation happened while this request was
                // in flight. Its content remains local, but its next PUT must
                // be based on the revision the server has just accepted.
                workspace?.revision = saved.revision
                status = .dirty
                persistOutbox()
                #if DEBUG
                print("[VBoard] WORKSPACE SAVE ACK folder=\(folderID) sequence=\(sequence) serverRevision=\(saved.revision) pending=true newestGeneration=\(mutationGeneration)")
                #endif
                return (true, false)
            }
        } catch APIError.workspaceConflict(let serverWorkspace) {
            let merged = LectureWorkspaceThreeWayMerger.merge(
                base: baseWorkspace ?? candidate,
                local: workspace ?? candidate,
                server: serverWorkspace
            )
            workspace = merged
            baseWorkspace = serverWorkspace
            baseRevision = serverWorkspace.revision
            conflictServerWorkspace = nil
            mutationGeneration += 1
            status = permitsConflictRetry ? .dirty : .offlinePending
            persistOutbox()
            #if DEBUG
            print("[VBoard] WORKSPACE SAVE AUTO-REBASE folder=\(folderID) sequence=\(sequence) serverRevision=\(serverWorkspace.revision) retry=\(permitsConflictRetry)")
            #endif
            return (permitsConflictRetry, permitsConflictRetry)
        } catch {
            status = .offlinePending
            persistOutbox()
        }
        return (false, false)
    }

    func keepLocalChanges(api: APIClient) {
        guard var local = workspace, let server = conflictServerWorkspace else { return }
        local.revision = server.revision
        workspace = local
        baseRevision = server.revision
        baseWorkspace = server
        conflictServerWorkspace = nil
        mutationGeneration += 1
        status = .dirty
        persistOutbox()
        scheduleSave(api: api)
    }

    func reloadServerVersion() {
        guard let server = conflictServerWorkspace else { return }
        workspace = server
        baseRevision = server.revision
        baseWorkspace = server
        conflictServerWorkspace = nil
        selectedKeys.removeAll()
        status = .clean
        removeOutbox()
    }

    private func loadScene(boardID: String, api: APIClient) {
        let token = UUID()
        sceneLoadTokens[boardID] = token
        sceneLoadTasks[boardID] = Task { [weak self] in
            let loadStarted = Date().timeIntervalSinceReferenceDate
            do {
                async let editorRequest = api.editor(id: boardID)
                async let svgRequest = api.professorSVG(id: boardID)
                let (editor, source) = try await (editorRequest, svgRequest)
                #if DEBUG
                let downloadFinished = Date().timeIntervalSinceReferenceDate
                print("[VBoard] VECTOR TIMELINE board=\(boardID) stage=download editorObjects=\(editor.objects.count) svgBytes=\(source.utf8.count) milliseconds=\((downloadFinished - loadStarted) * 1_000)")
                #endif
                let board = self?.boards.first(where: { $0.id == boardID })
                let sourceKind = board?.sourceKind ?? .physicalWhiteboard
                let parseStarted = Date().timeIntervalSinceReferenceDate
                let parsedDocument = try SVGDocument.parse(source)
                let document = PDFBoardSource.selectableDocument(parsedDocument, sourceKind: sourceKind)
                #if DEBUG
                print("[VBoard] VECTOR TIMELINE board=\(boardID) stage=manifestParse paths=\(document.paths.count) milliseconds=\((Date().timeIntervalSinceReferenceDate - parseStarted) * 1_000)")
                #endif
                let pdfData: Data?
                if sourceKind.isPDF, let path = board?.pdfURL {
                    pdfData = try await api.cachedBoardAsset(
                        boardID: boardID,
                        path: path,
                        version: board?.updatedAt.map { String($0) }
                    )
                } else {
                    pdfData = nil
                }
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
                    pdfData: pdfData,
                    editor: effectiveEditor,
                    composition: SceneComposition.build(boardID: boardID, document: document, editor: effectiveEditor)
                )
                self.refreshEffectiveBounds(boardID: boardID, api: api)
                self.lastSceneUse[boardID] = Date().timeIntervalSinceReferenceDate
                self.sceneLoadTasks.removeValue(forKey: boardID)
                self.sceneLoadTokens.removeValue(forKey: boardID)
                self.evictScenesIfNeeded()
                #if DEBUG
                print("[VBoard] VECTOR TIMELINE board=\(boardID) stage=sceneInstalled previewRetained=true milliseconds=\((Date().timeIntervalSinceReferenceDate - loadStarted) * 1_000)")
                #endif
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
        let evicted = Array(candidates.prefix(max(0, scenes.count - sceneCacheLimit)))
        for boardID in evicted {
            scenes.removeValue(forKey: boardID)
            boardStores.removeValue(forKey: boardID)
            lastSceneUse.removeValue(forKey: boardID)
        }
        #if DEBUG
        print("[VBoard] LECTURE SCENE CACHE cached=\(scenes.count) cacheBudget=\(sceneCacheLimit) fullDetail=\(desiredFullDetail.count) fullDetailBudget=\(BoardDetailPolicy.defaultFullDetailBudget) evicted=\(evicted.sorted())")
        #endif
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
            self.saveTask = nil
            await self.drainSaveQueue(api: api)
        }
    }

    private struct OutboxEnvelope: Codable {
        let folderID: String
        let baseRevision: Int
        let baseWorkspace: LectureWorkspace?
        let workspace: LectureWorkspace

        enum CodingKeys: String, CodingKey {
            case folderID = "folder_id"
            case baseRevision = "base_revision"
            case baseWorkspace = "base_workspace"
            case workspace
        }
    }

    private var outboxURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VBoard/accounts/\(LocalAccountNamespace.value)/workspace-outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(folderID).json")
    }

    private func persistOutbox() {
        guard let workspace,
              let data = try? JSONEncoder().encode(OutboxEnvelope(folderID: folderID,
                                                                   baseRevision: baseRevision,
                                                                   baseWorkspace: baseWorkspace,
                                                                   workspace: workspace)) else { return }
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
