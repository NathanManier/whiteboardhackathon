import Foundation
import SwiftUI
import CoreGraphics

enum EditorPersistenceStatus: Equatable {
    case clean
    case dirty
    case saving
    case offlinePending
    case conflict
    case failed

    var userLabel: String {
        switch self {
        case .clean: return "Saved"
        case .dirty: return "Unsaved changes"
        case .saving: return "Saving…"
        case .offlinePending: return "Saved locally"
        case .conflict: return "Needs review"
        case .failed: return "Save failed"
        }
    }
}

struct EditorMergeResult: Equatable {
    let editor: EditorState
    let unresolvedObjectIDs: Set<String>

    var isAutomatic: Bool { unresolvedObjectIDs.isEmpty }
}

/// Stable-ID three-way merge used only after the server proves that the
/// client's acknowledged base revision is stale. Camera state is deliberately
/// local-last-write-wins and can never create a blocking content conflict.
enum EditorThreeWayMerger {
    static func merge(base: EditorState,
                      local: EditorState,
                      server: EditorState) -> EditorMergeResult {
        var unresolved = Set<String>()
        let baseObjects = Dictionary(uniqueKeysWithValues: base.objects.map { ($0.id, $0) })
        let localObjects = Dictionary(uniqueKeysWithValues: local.objects.map { ($0.id, $0) })
        let serverObjects = Dictionary(uniqueKeysWithValues: server.objects.map { ($0.id, $0) })
        let objectIDs = Set(baseObjects.keys).union(localObjects.keys).union(serverObjects.keys)
        var mergedByID: [String: CanvasObject] = [:]

        for id in objectIDs {
            if let object = mergeObject(id: id,
                                        base: baseObjects[id],
                                        local: localObjects[id],
                                        server: serverObjects[id],
                                        unresolved: &unresolved) {
                mergedByID[id] = object
            }
        }

        // Server order remains stable for its existing objects; locally-added
        // objects are appended in the order the user created them.
        var ordered: [CanvasObject] = []
        var emitted = Set<String>()
        for object in server.objects + local.objects {
            guard emitted.insert(object.id).inserted,
                  let merged = mergedByID[object.id] else { continue }
            ordered.append(merged)
        }

        let transformIDs = Set(base.importedTransforms.keys)
            .union(local.importedTransforms.keys)
            .union(server.importedTransforms.keys)
        var transforms: [String: ObjectTransform] = [:]
        for id in transformIDs {
            let identity = ObjectTransform(x: 0, y: 0, scaleX: 1, scaleY: 1, deleted: false)
            let baseValue = base.importedTransforms[id] ?? identity
            let localValue = local.importedTransforms[id] ?? identity
            let serverValue = server.importedTransforms[id] ?? identity
            var fieldConflict = false
            let merged = ObjectTransform(
                x: resolve(baseValue.x, localValue.x, serverValue.x, conflict: &fieldConflict),
                y: resolve(baseValue.y, localValue.y, serverValue.y, conflict: &fieldConflict),
                scaleX: resolve(baseValue.scaleX, localValue.scaleX, serverValue.scaleX,
                                conflict: &fieldConflict),
                scaleY: resolve(baseValue.scaleY, localValue.scaleY, serverValue.scaleY,
                                conflict: &fieldConflict),
                deleted: resolve(baseValue.deleted, localValue.deleted, serverValue.deleted,
                                 conflict: &fieldConflict)
            )
            if fieldConflict { unresolved.insert(id) }
            if local.importedTransforms[id] != nil || server.importedTransforms[id] != nil {
                transforms[id] = merged
            }
        }

        let groups = mergeGroups(base: base.groups, local: local.groups, server: server.groups,
                                 unresolved: &unresolved)
        let sourceBoards = stableUnion(server.sourceBoards, local.sourceBoards, key: \SourceBoard.boardID)
        let mergedBoardIDs = Array(Set(server.mergedBoardIDs).union(local.mergedBoardIDs)).sorted()
        return EditorMergeResult(
            editor: EditorState(
                schemaVersion: max(base.schemaVersion, max(local.schemaVersion, server.schemaVersion)),
                revision: server.revision,
                updatedAt: server.updatedAt,
                viewport: local.viewport,
                objects: ordered,
                groups: groups,
                importedTransforms: transforms,
                sourceBoards: sourceBoards,
                mergedBoardIDs: mergedBoardIDs
            ),
            unresolvedObjectIDs: unresolved
        )
    }

    private static func mergeObject(id: String,
                                    base: CanvasObject?,
                                    local: CanvasObject?,
                                    server: CanvasObject?,
                                    unresolved: inout Set<String>) -> CanvasObject? {
        switch (base, local, server) {
        case (nil, nil, nil):
            return nil
        case (nil, let local?, nil):
            return local
        case (nil, nil, let server?):
            return server
        case (nil, let local?, let server?):
            guard local != server else { return local }
            unresolved.insert(id)
            return local
        case (let base?, nil, let server?):
            if server == base { return nil }
            unresolved.insert(id)
            return server
        case (let base?, let local?, nil):
            if local == base { return nil }
            unresolved.insert(id)
            return local
        case (_, nil, nil):
            return nil
        case (let base?, let local?, let server?):
            var conflict = false
            let merged = CanvasObject(
                id: id,
                type: resolve(base.type, local.type, server.type, conflict: &conflict),
                color: resolve(base.color, local.color, server.color, conflict: &conflict),
                width: resolve(base.width, local.width, server.width, conflict: &conflict),
                opacity: resolve(base.opacity, local.opacity, server.opacity, conflict: &conflict),
                points: resolve(base.points, local.points, server.points, conflict: &conflict),
                translation: resolve(base.translation, local.translation, server.translation,
                                     conflict: &conflict),
                sourceMarkdown: resolve(base.sourceMarkdown, local.sourceMarkdown,
                                        server.sourceMarkdown, conflict: &conflict),
                text: resolve(base.text, local.text, server.text, conflict: &conflict),
                x: resolve(base.x, local.x, server.x, conflict: &conflict),
                y: resolve(base.y, local.y, server.y, conflict: &conflict),
                height: resolve(base.height, local.height, server.height, conflict: &conflict),
                fontSize: resolve(base.fontSize, local.fontSize, server.fontSize, conflict: &conflict),
                scaleX: resolve(base.scaleX, local.scaleX, server.scaleX, conflict: &conflict),
                scaleY: resolve(base.scaleY, local.scaleY, server.scaleY, conflict: &conflict),
                d: resolve(base.d, local.d, server.d, conflict: &conflict),
                fill: resolve(base.fill, local.fill, server.fill, conflict: &conflict),
                role: resolve(base.role, local.role, server.role, conflict: &conflict),
                sourceStudyInteractionID: resolve(base.sourceStudyInteractionID,
                                                  local.sourceStudyInteractionID,
                                                  server.sourceStudyInteractionID,
                                                  conflict: &conflict),
                createdAt: resolve(base.createdAt, local.createdAt, server.createdAt,
                                   conflict: &conflict),
                unitLabel: resolve(base.unitLabel, local.unitLabel, server.unitLabel,
                                   conflict: &conflict),
                origin: resolve(base.origin, local.origin, server.origin, conflict: &conflict)
            )
            if conflict { unresolved.insert(id) }
            return merged
        }
    }

    private static func mergeGroups(base: [EditorGroup],
                                    local: [EditorGroup],
                                    server: [EditorGroup],
                                    unresolved: inout Set<String>) -> [EditorGroup] {
        func keyed(_ groups: [EditorGroup]) -> [String: EditorGroup] {
            Dictionary(uniqueKeysWithValues: groups.enumerated().map {
                ($0.element.id ?? "anonymous-\($0.offset)", $0.element)
            })
        }
        let baseByID = keyed(base), localByID = keyed(local), serverByID = keyed(server)
        let ids = Set(baseByID.keys).union(localByID.keys).union(serverByID.keys)
        return ids.sorted().compactMap { id in
            let baseValue = baseByID[id], localValue = localByID[id], serverValue = serverByID[id]
            if localValue == serverValue { return localValue }
            if localValue == baseValue { return serverValue }
            if serverValue == baseValue { return localValue }
            unresolved.insert("group:\(id)")
            return localValue ?? serverValue
        }
    }

    private static func resolve<T: Equatable>(_ base: T, _ local: T, _ server: T,
                                              conflict: inout Bool) -> T {
        if local == server { return local }
        if local == base { return server }
        if server == base { return local }
        conflict = true
        return local
    }

    private static func stableUnion<T>(_ first: [T], _ second: [T],
                                       key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert(key($0)).inserted }
    }
}

/// Server-authoritative editor state plus a recoverable local working copy.
/// The outbox stores the complete latest document, so unknown future fields
/// are not intentionally reconstructed or merged by the client.
@MainActor
final class BoardDocumentStore: ObservableObject {
    @Published private(set) var editor: EditorState
    @Published private(set) var status: EditorPersistenceStatus = .clean
    @Published private(set) var conflictServerEditor: EditorState?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private let boardID: String
    private var baseRevision: Int
    private var baseEditor: EditorState
    private var hasRestored = false
    private var mutationGeneration = 0
    private var saveSequence = 0
    private var saveInFlight = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var saveTask: Task<Void, Never>?

    init(boardID: String, editor: EditorState) {
        self.boardID = boardID
        self.editor = editor
        self.baseRevision = editor.revision
        self.baseEditor = editor
    }

    deinit { saveTask?.cancel() }

    func replace(with editor: EditorState, status: EditorPersistenceStatus = .clean) {
        self.editor = editor
        if status == .clean {
            baseRevision = editor.revision
            baseEditor = editor
        }
        self.status = status
        undoStack.removeAll(); redoStack.removeAll(); canUndo = false; canRedo = false
    }

    func apply(_ editor: EditorState, api: APIClient) {
        undoStack.append(self.editor)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll(); canUndo = true; canRedo = false
        self.editor = editor
        mutationGeneration += 1
        status = .dirty
        persistOutbox()
        scheduleSave(api: api)
    }

    func undo(api: APIClient) {
        guard var previous = undoStack.popLast() else { return }
        // History snapshots describe content, not a stale server precondition.
        // Rebase the restored content onto the latest accepted revision so an
        // undo performed after autosave does not immediately conflict.
        previous.revision = editor.revision
        previous.updatedAt = editor.updatedAt
        redoStack.append(editor); editor = previous; mutationGeneration += 1
        canUndo = !undoStack.isEmpty; canRedo = true; status = .dirty; persistOutbox(); scheduleSave(api: api)
    }

    func redo(api: APIClient) {
        guard var next = redoStack.popLast() else { return }
        next.revision = editor.revision
        next.updatedAt = editor.updatedAt
        undoStack.append(editor); editor = next; mutationGeneration += 1
        canUndo = true; canRedo = !redoStack.isEmpty; status = .dirty; persistOutbox(); scheduleSave(api: api)
    }

    func applyStroke(_ stroke: UserStroke, api: APIClient) {
        let object = CanvasObject(id: stroke.id, type: stroke.type, color: stroke.color,
                                  width: stroke.width, opacity: stroke.opacity,
                                  points: stroke.points.map { WorldPoint(x: $0.x, y: $0.y, pressure: $0.pressure) },
                                  translation: stroke.translation, sourceMarkdown: nil, text: nil,
                                  x: nil, y: nil, height: nil, fontSize: nil)
        var next = editor
        next.objects.append(object)
        apply(next, api: api)
    }

    /// Camera state is document state, but moving the viewport must not create
    /// an undoable content operation for every pointer sample.
    func updateViewport(_ viewport: CameraRect, api: APIClient) {
        guard editor.viewport != viewport else { return }
        editor.viewport = viewport
        mutationGeneration += 1
        status = .dirty
        persistOutbox()
        scheduleSave(api: api)
    }

    func applyPracticeProblems(_ problems: [PracticeProblem], interactionID: String? = nil,
                               unitLabel: String? = nil, api: APIClient) {
        let existing = Set(editor.objects.filter { $0.role == "ai_practice_problem" }.map(\.id))
        let fresh = problems.filter { !existing.contains($0.id) }.prefix(2)
        guard !fresh.isEmpty else { return }
        var next = editor
        let originX = editor.viewport.x + editor.viewport.width * 0.08
        let originY = editor.viewport.y + editor.viewport.height * 0.12
        let cardWidth = editor.viewport.width * 0.35
        let presentationFontSize = min(82, max(58, cardWidth * 0.06))
        for (offset, problem) in fresh.enumerated() {
            next.objects.append(CanvasObject(id: problem.id, type: "text", color: "#183153",
                                             width: cardWidth, opacity: 1,
                                             points: nil, translation: nil,
                                             sourceMarkdown: problem.text, text: problem.text,
                                             x: originX + Double(offset) * editor.viewport.width * 0.40,
                                             y: originY, height: editor.viewport.height * 0.28,
                                             fontSize: presentationFontSize, role: "ai_practice_problem",
                                             sourceStudyInteractionID: interactionID,
                                             createdAt: Date().timeIntervalSince1970,
                                             unitLabel: unitLabel,
                                             origin: "ai_practice"))
        }
        apply(next, api: api)
    }

    func addNote(markdown: String, at point: CGPoint, unitLabel: String?, api: APIClient) {
        let source = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        var next = editor
        next.objects.append(CanvasObject(
            id: "note-" + UUID().uuidString.lowercased(), type: "text",
            color: "#183153", width: 520, opacity: 1,
            points: nil, translation: nil, sourceMarkdown: source, text: source,
            x: point.x, y: point.y, height: 260, fontSize: 28,
            role: nil, sourceStudyInteractionID: nil,
            createdAt: Date().timeIntervalSince1970,
            unitLabel: unitLabel, origin: "study"
        ))
        apply(next, api: api)
    }

    func moveObject(id: String, by delta: CGPoint, api: APIClient) {
        moveObjects(ids: Set([id]), by: delta, api: api)
    }

    /// Applies one world-space delta to all selected objects as one document
    /// mutation, producing one undo entry and one outbox snapshot per drag.
    func moveObjects(ids: Set<String>, by delta: CGPoint, api: APIClient) {
        let editorIDs = Set(editor.objects.lazy.filter { ids.contains($0.id) }.map(\.id))
        moveObjects(editorObjectIDs: editorIDs,
                    professorPathIDs: ids.subtracting(editorIDs),
                    by: delta,
                    api: api)
    }

    /// Typed scene ownership prevents an editor object from also being
    /// promoted into `imported_transforms` when IDs happen to collide across
    /// the editor and professor layers.
    func moveObjects(editorObjectIDs: Set<String>,
                     professorPathIDs: Set<String>,
                     by delta: CGPoint,
                     api: APIClient) {
        guard !editorObjectIDs.isEmpty || !professorPathIDs.isEmpty,
              delta.x != 0 || delta.y != 0 else { return }
        var next = editor
        for id in editorObjectIDs {
            if let index = next.objects.firstIndex(where: { $0.id == id }) {
                next.objects[index] = next.objects[index].translated(by: delta)
            }
        }
        for id in professorPathIDs {
            if let imported = next.importedTransforms[id] {
                next.importedTransforms[id] = ObjectTransform(x: imported.x + delta.x, y: imported.y + delta.y,
                                                              scaleX: imported.scaleX, scaleY: imported.scaleY,
                                                              deleted: imported.deleted)
            } else {
                // A selected untransformed professor path is promoted to the
                // live layer by adding its first translation without touching board.svg.
                next.importedTransforms[id] = ObjectTransform(x: delta.x, y: delta.y, scaleX: 1, scaleY: 1, deleted: false)
            }
        }
        apply(next, api: api)
    }

    func resizeTextObject(id: String, to size: CGSize, api: APIClient) {
        guard size.width >= 120, size.height >= 80,
              let index = editor.objects.firstIndex(where: { $0.id == id && $0.type == "text" }) else { return }
        var next = editor
        next.objects[index] = next.objects[index].resized(to: size)
        apply(next, api: api)
    }

    /// Commits one non-cumulative resize transaction for every selected item
    /// in this isolated board document. Professor paths retain their source
    /// SVG and editor objects retain their source points/path/markdown.
    func scaleObjects(editorObjectIDs: Set<String>,
                      professorPathIDs: Set<String>,
                      around anchor: CGPoint,
                      by factor: CGFloat,
                      api: APIClient) {
        guard !editorObjectIDs.isEmpty || !professorPathIDs.isEmpty,
              factor.isFinite, factor > 0, abs(factor - 1) > 0.001 else { return }

        // Clamp once for the complete selection. Clamping every object after
        // applying the requested factor would distort a mixed selection when
        // one item is already near the supported transform limits.
        var existingScales: [Double] = []
        existingScales.reserveCapacity(editorObjectIDs.count * 2 + professorPathIDs.count * 2)
        for object in editor.objects where editorObjectIDs.contains(object.id) && object.type != "text" {
            existingScales.append(object.scaleX ?? 1)
            existingScales.append(object.scaleY ?? 1)
        }
        for id in professorPathIDs {
            let transform = editor.importedTransforms[id]
            existingScales.append(transform?.scaleX ?? 1)
            existingScales.append(transform?.scaleY ?? 1)
        }
        let lowerBound = existingScales.map { 0.01 / max($0, 0.000_001) }.max() ?? 0.01
        let upperBound = existingScales.map { 100 / max($0, 0.000_001) }.min() ?? 100
        let boundedFactor = min(upperBound, max(lowerBound, Double(factor)))
        guard abs(boundedFactor - 1) > 0.001 else { return }

        var next = editor
        for id in editorObjectIDs {
            guard let index = next.objects.firstIndex(where: { $0.id == id }) else { continue }
            next.objects[index] = next.objects[index].scaled(around: anchor, by: CGFloat(boundedFactor))
        }
        for id in professorPathIDs {
            let existing = next.importedTransforms[id]
                ?? ObjectTransform(x: 0, y: 0, scaleX: 1, scaleY: 1, deleted: false)
            next.importedTransforms[id] = ObjectTransform(
                x: Double(anchor.x) + boundedFactor * (existing.x - Double(anchor.x)),
                y: Double(anchor.y) + boundedFactor * (existing.y - Double(anchor.y)),
                scaleX: (existing.scaleX ?? 1) * boundedFactor,
                scaleY: (existing.scaleY ?? 1) * boundedFactor,
                deleted: existing.deleted
            )
        }
        apply(next, api: api)
    }

    func deleteObjects(ids: Set<String>, api: APIClient) {
        let editorIDs = Set(editor.objects.lazy.filter { ids.contains($0.id) }.map(\.id))
        deleteObjects(editorObjectIDs: editorIDs,
                      professorPathIDs: ids.subtracting(editorIDs),
                      api: api)
    }

    /// Deletes user objects and soft-deletes professor paths as two distinct
    /// canonical operations. A deleted user stroke must never create a bogus
    /// imported-professor transform with the same ID.
    func deleteObjects(editorObjectIDs: Set<String>,
                       professorPathIDs: Set<String>,
                       api: APIClient) {
        guard !editorObjectIDs.isEmpty || !professorPathIDs.isEmpty else { return }
        var next = editor
        next.objects.removeAll { editorObjectIDs.contains($0.id) }
        for id in professorPathIDs {
            if let imported = next.importedTransforms[id] {
                next.importedTransforms[id] = ObjectTransform(x: imported.x, y: imported.y,
                                                               scaleX: imported.scaleX, scaleY: imported.scaleY, deleted: true)
            } else {
                next.importedTransforms[id] = ObjectTransform(x: 0, y: 0, scaleX: 1, scaleY: 1, deleted: true)
            }
        }
        apply(next, api: api)
    }

    func restoreLocalIfPresent(server: EditorState) {
        guard !hasRestored else { return }
        hasRestored = true
        guard let envelope = readOutbox() else {
            editor = server; baseEditor = server; baseRevision = server.revision
            status = .clean; return
        }
        baseEditor = envelope.baseEditor ?? server
        if envelope.dirty, envelope.baseRevision == server.revision {
            editor = envelope.editor
            baseRevision = envelope.baseRevision
            status = .offlinePending
        } else if envelope.dirty, envelope.baseRevision != server.revision {
            let merged = EditorThreeWayMerger.merge(base: envelope.baseEditor ?? server,
                                                    local: envelope.editor,
                                                    server: server)
            editor = merged.editor
            baseEditor = server
            baseRevision = server.revision
            conflictServerEditor = merged.isAutomatic ? nil : server
            status = merged.isAutomatic ? .offlinePending : .conflict
            persistOutbox()
        } else {
            removeOutbox()
            editor = server; baseEditor = server; baseRevision = server.revision
            status = .clean
        }
    }

    func saveNow(api: APIClient) async {
        saveTask?.cancel()
        saveTask = nil
        await withCheckedContinuation { continuation in
            saveWaiters.append(continuation)
            Task { @MainActor in await drainSaveQueue(api: api) }
        }
    }

    /// Serializes all writes for this board. Main-actor reentrancy permits new
    /// drawing mutations while URLSession is awaiting a response, but a
    /// second PUT can never start until the first response has advanced the
    /// acknowledged base revision.
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

    /// Returns true only when the queue should immediately send a newer,
    /// rebased generation. Network failures stop the drain and retain outbox
    /// data for the next explicit/debounced retry.
    private func performSaveAttempt(
        api: APIClient,
        permitsConflictRetry: Bool
    ) async -> (shouldContinue: Bool, consumedConflictRetry: Bool) {
        guard status == .dirty || status == .offlinePending else {
            return (false, false)
        }
        status = .saving
        let candidate = editor
        let candidateGeneration = mutationGeneration
        saveSequence += 1
        let sequence = saveSequence
        #if DEBUG
        print("[VBoard] EDITOR SAVE BEGIN board=\(boardID) sequence=\(sequence) baseRevision=\(baseRevision) requestRevision=\(candidate.revision) generation=\(candidateGeneration) inFlight=1")
        #endif
        do {
            let saved = try await api.save(editor: candidate, boardID: boardID)
            baseEditor = saved
            baseRevision = saved.revision
            // Do not replace newer local edits that happened while the request
            // was in flight. They remain dirty and will be sent next.
            if mutationGeneration == candidateGeneration {
                editor = saved; status = .clean; removeOutbox()
                #if DEBUG
                print("[VBoard] EDITOR SAVE ACK board=\(boardID) sequence=\(sequence) serverRevision=\(saved.revision) generation=\(candidateGeneration) pending=false")
                #endif
                return (false, false)
            } else {
                // The candidate reached the server even though newer local
                // edits now exist. Keep those edits, but advance their
                // revision precondition to the revision just accepted.
                editor.revision = saved.revision
                editor.updatedAt = saved.updatedAt
                status = .dirty; persistOutbox()
                #if DEBUG
                print("[VBoard] EDITOR SAVE ACK board=\(boardID) sequence=\(sequence) serverRevision=\(saved.revision) generation=\(candidateGeneration) pending=true newestGeneration=\(mutationGeneration)")
                #endif
                return (true, false)
            }
        } catch let error as APIError {
            switch error {
            case .conflict(let server):
                let merged = EditorThreeWayMerger.merge(base: baseEditor,
                                                        local: editor,
                                                        server: server)
                editor = merged.editor
                baseEditor = server
                baseRevision = server.revision
                if merged.isAutomatic, permitsConflictRetry {
                    conflictServerEditor = nil
                    mutationGeneration += 1
                    status = .dirty
                    persistOutbox()
                    #if DEBUG
                    print("[VBoard] EDITOR SAVE AUTO-REBASE board=\(boardID) sequence=\(sequence) serverRevision=\(server.revision) retry=true")
                    #endif
                    return (true, true)
                }
                if merged.isAutomatic {
                    // Another external writer won a second race. Preserve the
                    // merged document locally and retry after the next
                    // debounce rather than interrupting the user.
                    conflictServerEditor = nil
                    status = .offlinePending
                    persistOutbox()
                } else {
                    conflictServerEditor = server
                    status = .conflict
                    persistOutbox()
                }
                #if DEBUG
                print("[VBoard] EDITOR SAVE CONFLICT board=\(boardID) sequence=\(sequence) serverRevision=\(server.revision) unresolved=\(merged.unresolvedObjectIDs.sorted()) retry=false")
                #endif
            case .transport, .server:
                status = .offlinePending; persistOutbox()
            default:
                status = .failed; persistOutbox()
            }
        } catch {
            status = .offlinePending; persistOutbox()
        }
        return (false, false)
    }

    func keepLocalChanges(api: APIClient) async {
        // A safe "keep mine" operation refreshes the server revision first;
        // it never retries the stale revision blindly.
        do {
            let latest = try await api.editor(id: boardID)
            editor = EditorState(schemaVersion: editor.schemaVersion, revision: latest.revision,
                                 updatedAt: editor.updatedAt, viewport: editor.viewport,
                                 objects: editor.objects, groups: editor.groups,
                                 importedTransforms: editor.importedTransforms,
                                 sourceBoards: latest.sourceBoards, mergedBoardIDs: latest.mergedBoardIDs)
            baseRevision = latest.revision
            baseEditor = latest
            conflictServerEditor = nil; status = .dirty; persistOutbox(); scheduleSave(api: api)
        } catch { status = .offlinePending; persistOutbox() }
    }

    func reloadServerVersion() {
        guard let server = conflictServerEditor else { return }
        editor = server; baseEditor = server; baseRevision = server.revision
        conflictServerEditor = nil; status = .clean; removeOutbox()
    }

    func persistForBackgrounding() { if status != .clean { persistOutbox() } }

    private func scheduleSave(api: APIClient) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            await self.drainSaveQueue(api: api)
        }
    }

    private struct OutboxEnvelope: Codable {
        let boardID: String
        let baseRevision: Int
        let baseEditor: EditorState?
        let dirty: Bool
        let editor: EditorState
        enum CodingKeys: String, CodingKey {
            case boardID = "board_id"
            case baseRevision = "base_revision"
            case baseEditor = "base_editor"
            case dirty, editor
        }
    }

    private var outboxURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VBoard/accounts/\(LocalAccountNamespace.value)/outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(boardID).json")
    }

    private func persistOutbox() {
        let envelope = OutboxEnvelope(boardID: boardID, baseRevision: baseRevision,
                                      baseEditor: baseEditor, dirty: true, editor: editor)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let temp = outboxURL.appendingPathExtension("tmp")
        do { try data.write(to: temp, options: .atomic); _ = try? FileManager.default.replaceItemAt(outboxURL, withItemAt: temp) }
        catch { try? data.write(to: outboxURL, options: .atomic) }
    }

    private func readOutbox() -> OutboxEnvelope? {
        guard let data = try? Data(contentsOf: outboxURL) else { return nil }
        return try? JSONDecoder().decode(OutboxEnvelope.self, from: data)
    }

    private func removeOutbox() { try? FileManager.default.removeItem(at: outboxURL) }
}
