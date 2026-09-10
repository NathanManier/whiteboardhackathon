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
    private var hasRestored = false
    private var mutationGeneration = 0
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var saveTask: Task<Void, Never>?

    init(boardID: String, editor: EditorState) {
        self.boardID = boardID
        self.editor = editor
        self.baseRevision = editor.revision
    }

    deinit { saveTask?.cancel() }

    func replace(with editor: EditorState, status: EditorPersistenceStatus = .clean) {
        self.editor = editor
        if status == .clean { baseRevision = editor.revision }
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
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(editor); editor = previous; mutationGeneration += 1
        canUndo = !undoStack.isEmpty; canRedo = true; status = .dirty; persistOutbox(); scheduleSave(api: api)
    }

    func redo(api: APIClient) {
        guard let next = redoStack.popLast() else { return }
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
        for (offset, problem) in fresh.enumerated() {
            next.objects.append(CanvasObject(id: problem.id, type: "text", color: "#183153",
                                             width: editor.viewport.width * 0.35, opacity: 1,
                                             points: nil, translation: nil,
                                             sourceMarkdown: problem.text, text: problem.text,
                                             x: originX + Double(offset) * editor.viewport.width * 0.40,
                                             y: originY, height: editor.viewport.height * 0.28,
                                             fontSize: 28, role: "ai_practice_problem",
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
        guard !ids.isEmpty, (delta.x != 0 || delta.y != 0) else { return }
        var next = editor
        for id in ids {
            if let index = next.objects.firstIndex(where: { $0.id == id }) {
                next.objects[index] = next.objects[index].translated(by: delta)
            } else if let imported = next.importedTransforms[id] {
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

    func deleteObjects(ids: Set<String>, api: APIClient) {
        guard !ids.isEmpty else { return }
        var next = editor
        next.objects.removeAll { ids.contains($0.id) }
        for id in ids {
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
            editor = server; status = .clean; return
        }
        // A dirty snapshot is based on the server revision it was opened from.
        // If the server has advanced independently, retain both and require a
        // visible conflict decision rather than overwriting either version.
        if envelope.dirty, envelope.baseRevision == server.revision {
            editor = envelope.editor
            baseRevision = envelope.baseRevision
            status = .offlinePending
        } else if envelope.dirty, envelope.baseRevision != server.revision {
            editor = envelope.editor
            baseRevision = envelope.baseRevision
            conflictServerEditor = server
            status = .conflict
        } else {
            removeOutbox()
            editor = server; status = .clean
        }
    }

    func saveNow(api: APIClient) async {
        saveTask?.cancel()
        guard status == .dirty || status == .offlinePending else { return }
        status = .saving
        let candidate = editor
        let candidateGeneration = mutationGeneration
        do {
            let saved = try await api.save(editor: candidate, boardID: boardID)
            // Do not replace newer local edits that happened while the request
            // was in flight. They remain dirty and will be sent next.
            if mutationGeneration == candidateGeneration {
                editor = saved; baseRevision = saved.revision; status = .clean; removeOutbox()
            } else {
                status = .dirty; persistOutbox(); scheduleSave(api: api)
            }
        } catch let error as APIError {
            switch error {
            case .conflict(let server):
                conflictServerEditor = server; status = .conflict; persistOutbox()
            case .transport, .server:
                status = .offlinePending; persistOutbox()
            default:
                status = .failed; persistOutbox()
            }
        } catch {
            status = .offlinePending; persistOutbox()
        }
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
            conflictServerEditor = nil; status = .dirty; persistOutbox(); scheduleSave(api: api)
        } catch { status = .offlinePending; persistOutbox() }
    }

    func reloadServerVersion() {
        guard let server = conflictServerEditor else { return }
        editor = server; conflictServerEditor = nil; status = .clean; removeOutbox()
    }

    func persistForBackgrounding() { if status != .clean { persistOutbox() } }

    private func scheduleSave(api: APIClient) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.saveNow(api: api)
        }
    }

    private struct OutboxEnvelope: Codable {
        let boardID: String
        let baseRevision: Int
        let dirty: Bool
        let editor: EditorState
        enum CodingKeys: String, CodingKey { case boardID = "board_id", baseRevision = "base_revision", dirty, editor }
    }

    private var outboxURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VBoard/outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(boardID).json")
    }

    private func persistOutbox() {
        let envelope = OutboxEnvelope(boardID: boardID, baseRevision: baseRevision, dirty: true, editor: editor)
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
