import CoreGraphics
import Combine
import Foundation

struct StudySelectionBBox: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init?(rect: CGRect, minimumExtent: CGFloat = 1) {
        guard !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let minimum = max(minimumExtent, 0.001)
        let normalizedWidth = max(rect.width, minimum)
        let normalizedHeight = max(rect.height, minimum)
        guard max(abs(rect.midX - normalizedWidth / 2),
                  abs(rect.midY - normalizedHeight / 2),
                  normalizedWidth, normalizedHeight) <= 10_000_000 else { return nil }
        self.x = Double(rect.midX - normalizedWidth / 2)
        self.y = Double(rect.midY - normalizedHeight / 2)
        self.width = Double(normalizedWidth)
        self.height = Double(normalizedHeight)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Mirrors the working web editor's `selectedTextPayload` object. The source
/// Markdown remains canonical in editor.json; this is request context only.
struct StudySelectedTextObject: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let role: String
    let text: String
    let fontSize: Double?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let practiceProblemId: String?
    let sourceStudyInteractionId: String?
}

struct BoardStudySelection: Equatable, Sendable {
    let boardID: String
    let canonicalObjectIDs: [String]
    let localBBox: StudySelectionBBox
    let selectedTextObjects: [StudySelectedTextObject]
    /// Diagnostic provenance only. Never encoded in the single-board API.
    let lectureWorldBBox: CGRect?

    static func isolated(boardID: String,
                         selectedIDs: Set<String>,
                         document: SVGDocument,
                         editor: EditorState,
                         preferredLocalBBox: CGRect? = nil) -> BoardStudySelection? {
        let editorIDs = Set(editor.objects.map(\.id))
        let professorIDs = Set(document.paths.compactMap(\.id))
        let keys = Set(selectedIDs.compactMap { id -> SelectionKey? in
            if editorIDs.contains(id) {
                return SelectionKey(boardID: boardID, objectID: id, kind: .editorObject)
            }
            if professorIDs.contains(id) {
                return SelectionKey(boardID: boardID, objectID: id, kind: .professorPath)
            }
            return nil
        })
        return build(boardID: boardID, keys: keys, item: nil,
                     document: document, editor: editor,
                     preferredLocalBBox: preferredLocalBBox)
    }

    static func lecture(boardID: String,
                        selectionKeys: Set<SelectionKey>,
                        item: WorkspaceBoardItem,
                        scene: WorkspaceBoardScene,
                        preferredLocalBBox: CGRect? = nil) -> BoardStudySelection? {
        build(boardID: boardID,
              keys: Set(selectionKeys.filter { $0.boardID == boardID }),
              item: item, document: scene.document, editor: scene.editor,
              preferredLocalBBox: preferredLocalBBox)
    }

    private static func build(boardID: String,
                              keys: Set<SelectionKey>,
                              item: WorkspaceBoardItem?,
                              document: SVGDocument,
                              editor: EditorState,
                              preferredLocalBBox: CGRect?) -> BoardStudySelection? {
        guard !keys.isEmpty else { return nil }
        let editorByID = Dictionary(uniqueKeysWithValues:
            SceneComposition.canonicalEditorObjects(editor.objects).map { ($0.id, $0) })
        let professorByID = Dictionary(uniqueKeysWithValues:
            SceneComposition.canonicalProfessorPaths(document.paths).compactMap { path in
                path.id.map { ($0, path) }
            })

        var canonicalIDs = Set<String>()
        var localBounds = CGRect.null
        var selectedTextObjects: [StudySelectedTextObject] = []

        for key in keys {
            switch key.kind {
            case .editorObject:
                guard let object = editorByID[key.objectID] else { continue }
                let bounds = BoardHitTestPolicy.bounds(of: object)
                guard let validBounds = finiteBounds(bounds) else { continue }
                canonicalIDs.insert(object.id)
                localBounds = localBounds.union(validBounds)
                if object.type == "text", let text = object.text ?? object.sourceMarkdown,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedTextObjects.append(StudySelectedTextObject(
                        id: object.id,
                        type: "text",
                        role: object.role ?? "text",
                        text: text,
                        fontSize: object.fontSize,
                        x: Double(validBounds.minX), y: Double(validBounds.minY),
                        width: Double(validBounds.width), height: Double(validBounds.height),
                        practiceProblemId: object.role == "ai_practice_problem" ? object.id : nil,
                        sourceStudyInteractionId: object.sourceStudyInteractionID
                    ))
                }
            case .professorPath:
                guard let source = professorByID[key.objectID],
                      editor.importedTransforms[key.objectID]?.deleted != true,
                      let parsed = try? SVGPathParser.cachedPath(from: source.d) else { continue }
                var affine = CGAffineTransform.identity
                if let transform = editor.importedTransforms[key.objectID] {
                    affine = affine
                        .translatedBy(x: CGFloat(transform.x), y: CGFloat(transform.y))
                        .scaledBy(x: CGFloat(transform.scaleX ?? 1),
                                  y: CGFloat(transform.scaleY ?? 1))
                }
                let transformed = parsed.copy(using: &affine) ?? parsed
                let candidate = key.objectID == PDFBoardSource.logicalID
                    ? preferredLocalBBox ?? transformed.boundingBoxOfPath
                    : transformed.boundingBoxOfPath
                guard let validBounds = finiteBounds(candidate) else { continue }
                canonicalIDs.insert(key.objectID)
                localBounds = localBounds.union(validBounds)
            }
        }

        guard !canonicalIDs.isEmpty,
              let bbox = StudySelectionBBox(rect: localBounds) else { return nil }

        let lectureWorldBBox: CGRect?
        let canonicalLocalBBox: StudySelectionBBox
        if let item {
            // Make the lecture-world -> board-local conversion explicit. This
            // prevents placement translation from leaking into the board API.
            let lectureRect = LectureCoordinateTransform.boardLocalToLectureWorld(
                bbox.cgRect, board: item
            )
            guard let converted = StudySelectionBBox(
                rect: LectureCoordinateTransform.lectureWorldToBoardLocal(
                    lectureRect, board: item
                )
            ) else { return nil }
            lectureWorldBBox = lectureRect
            canonicalLocalBBox = converted
            #if DEBUG
            print("[VBoard] STUDY SELECTION CONVERSION board=\(boardID) lectureWorldBBox=\(lectureRect) boardLocalBBox=\(converted) canonicalIDs=\(canonicalIDs.sorted())")
            #endif
        } else {
            lectureWorldBBox = nil
            canonicalLocalBBox = bbox
            #if DEBUG
            print("[VBoard] STUDY SELECTION CONVERSION board=\(boardID) lectureWorldBBox=<isolated-board> boardLocalBBox=\(bbox) canonicalIDs=\(canonicalIDs.sorted())")
            #endif
        }

        return BoardStudySelection(
            boardID: boardID,
            canonicalObjectIDs: canonicalIDs.sorted(),
            localBBox: canonicalLocalBBox,
            selectedTextObjects: selectedTextObjects.sorted { $0.id < $1.id },
            lectureWorldBBox: lectureWorldBBox
        )
    }

    private static func finiteBounds(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }
}

struct BoardStudyExplainRequest: Encodable, Equatable, Sendable {
    let boardID: String
    let selectedObjectIds: [String]
    let selectedTextObjects: [StudySelectedTextObject]
    let selectionBBox: StudySelectionBBox
    let anchorX: Double
    let anchorY: Double
    let anchorOffsetNx: Double
    let anchorOffsetNy: Double
    let studyInteractionId: String
    let requestId: String
    let question: String
    let action: String

    enum CodingKeys: String, CodingKey {
        case selectedObjectIds, selectedTextObjects, selectionBBox
        case anchorX, anchorY, anchorOffsetNx, anchorOffsetNy
        case studyInteractionId, requestId, question, action
    }

    static func make(selection: BoardStudySelection,
                     action: String = "explain",
                     question: String? = nil,
                     requestID: String = makeRequestID()) -> BoardStudyExplainRequest {
        let resolvedQuestion = question ?? [
            "explain": "Explain this",
            "explain_across_boards": "How does this relate to the previous board?",
            "where_from": "Where did this come from?",
            "check_my_work": "Check my work"
        ][action] ?? "Explain this"
        let pad = max(10, max(selection.localBBox.width, selection.localBBox.height) * 0.01)
        let anchorX = selection.localBBox.x + selection.localBBox.width + pad
        let anchorY = selection.localBBox.y
        return BoardStudyExplainRequest(
            boardID: selection.boardID,
            selectedObjectIds: selection.canonicalObjectIDs,
            selectedTextObjects: selection.selectedTextObjects,
            selectionBBox: selection.localBBox,
            anchorX: anchorX,
            anchorY: anchorY,
            anchorOffsetNx: (anchorX - selection.localBBox.x) / selection.localBBox.width,
            anchorOffsetNy: (anchorY - selection.localBBox.y) / selection.localBBox.height,
            studyInteractionId: requestID,
            requestId: requestID,
            question: resolvedQuestion,
            action: action
        )
    }

    static func makeRequestID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(16))
    }

    var sanitizedJSON: String {
        let value: [String: Any] = [
            "selectedObjectIds": selectedObjectIds,
            "selectedTextObjects": selectedTextObjects.map {
                ["id": $0.id, "role": $0.role, "text": "<redacted>"]
            },
            "selectionBBox": [
                "x": selectionBBox.x, "y": selectionBBox.y,
                "width": selectionBBox.width, "height": selectionBBox.height
            ],
            "anchorX": anchorX, "anchorY": anchorY,
            "anchorOffsetNx": anchorOffsetNx, "anchorOffsetNy": anchorOffsetNy,
            "studyInteractionId": studyInteractionId,
            "requestId": requestId,
            "question": "<redacted>",
            "action": action
        ]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "<could not sanitize study request>"
        }
        return json
    }
}

/// One interaction owns one initial study request. This is explicit
/// single-flight ownership, not time-based debouncing.
@MainActor
final class StudySubmissionGate: ObservableObject {
    @Published private(set) var activeRequestID: String?

    func begin(requestID: String) -> Bool {
        guard activeRequestID == nil else { return false }
        activeRequestID = requestID
        return true
    }

    func end(requestID: String) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
    }
}
