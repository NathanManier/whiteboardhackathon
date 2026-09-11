import CoreGraphics
import Combine
import CryptoKit
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
    /// Hash of only the selected canonical visual content. Camera movement is
    /// deliberately absent, while stroke edits and imported-path transforms
    /// invalidate native recognition reuse before the server rasterizes again.
    let visualRevision: String

    init(boardID: String,
         canonicalObjectIDs: [String],
         localBBox: StudySelectionBBox,
         selectedTextObjects: [StudySelectedTextObject],
         lectureWorldBBox: CGRect?,
         visualRevision: String = "") {
        self.boardID = boardID
        self.canonicalObjectIDs = canonicalObjectIDs
        self.localBBox = localBBox
        self.selectedTextObjects = selectedTextObjects
        self.lectureWorldBBox = lectureWorldBBox
        self.visualRevision = visualRevision
    }

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
        var selectedEditorObjects: [CanvasObject] = []
        var selectedProfessorStates: [ProfessorVisualState] = []

        for key in keys {
            switch key.kind {
            case .editorObject:
                guard let object = editorByID[key.objectID] else { continue }
                let bounds = BoardHitTestPolicy.bounds(of: object)
                guard let validBounds = finiteBounds(bounds) else { continue }
                canonicalIDs.insert(object.id)
                selectedEditorObjects.append(object)
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
                } else if object.type == "graph", let graph = object.graph {
                    let semanticSource = graph.expressions
                        .filter(\.visible)
                        .map(\.latex)
                        .joined(separator: "\n")
                    if !semanticSource.isEmpty {
                        selectedTextObjects.append(StudySelectedTextObject(
                            id: object.id,
                            type: "graph",
                            role: "graph",
                            text: semanticSource,
                            fontSize: nil,
                            x: Double(validBounds.minX), y: Double(validBounds.minY),
                            width: Double(validBounds.width), height: Double(validBounds.height),
                            practiceProblemId: nil,
                            sourceStudyInteractionId: graph.sourceSelection?.interactionID
                        ))
                    }
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
                selectedProfessorStates.append(ProfessorVisualState(
                    id: key.objectID,
                    transform: editor.importedTransforms[key.objectID]
                ))
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
            lectureWorldBBox: lectureWorldBBox,
            visualRevision: recognitionVisualRevision(
                boardID: boardID,
                objects: selectedEditorObjects,
                professorStates: selectedProfessorStates
            )
        )
    }

    private struct ProfessorVisualState: Codable {
        let id: String
        let transform: ObjectTransform?
    }

    private struct RecognitionVisualFingerprint: Encodable {
        let boardID: String
        let objects: [CanvasObject]
        let professorStates: [ProfessorVisualState]
    }

    private static func recognitionVisualRevision(
        boardID: String,
        objects: [CanvasObject],
        professorStates: [ProfessorVisualState]
    ) -> String {
        let fingerprint = RecognitionVisualFingerprint(
            boardID: boardID,
            objects: objects.sorted { $0.id < $1.id },
            professorStates: professorStates.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(fingerprint) else {
            return (objects.map(\.id) + professorStates.map(\.id)).sorted()
                .joined(separator: "|")
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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

struct GraphRecognitionSelection: Encodable, Equatable, Sendable {
    let selectedObjectIds: [String]
    let bbox: StudySelectionBBox
}

/// Provider-neutral recognition ownership. A board editor always uses the
/// existing single-board route. A lecture selection spanning two to eight
/// boards uses the grouped lecture route, while retaining one board-local
/// selection for every source board.
enum GraphRecognitionTarget: Equatable, Sendable {
    static let minimumGroupedBoardCount = 2
    static let maximumGroupedBoardCount = 8

    case board(BoardStudySelection)
    case lecture(LectureGraphRecognitionTarget)

    static func makeLecture(folderID: String,
                            selections: [BoardStudySelection],
                            preferredPrimaryBoardID: String?) -> GraphRecognitionTarget? {
        guard !folderID.isEmpty, !selections.isEmpty else { return nil }
        let ordered = selections.sorted { $0.boardID < $1.boardID }
        guard Set(ordered.map(\.boardID)).count == ordered.count,
              ordered.allSatisfy({ !$0.canonicalObjectIDs.isEmpty }) else { return nil }

        // A one-board lecture selection deliberately stays on the established
        // board endpoint. The grouped endpoint requires two distinct boards.
        if ordered.count == 1 { return .board(ordered[0]) }
        guard (minimumGroupedBoardCount...maximumGroupedBoardCount).contains(ordered.count)
        else { return nil }

        let primaryBoardID = preferredPrimaryBoardID.flatMap { preferred in
            ordered.contains(where: { $0.boardID == preferred }) ? preferred : nil
        } ?? ordered[0].boardID
        return .lecture(LectureGraphRecognitionTarget(
            folderID: folderID,
            primaryBoardID: primaryBoardID,
            selections: ordered
        ))
    }

    var selections: [BoardStudySelection] {
        switch self {
        case .board(let selection): return [selection]
        case .lecture(let target): return target.selections
        }
    }

    var primarySelection: BoardStudySelection {
        switch self {
        case .board(let selection): return selection
        case .lecture(let target):
            // Construction guarantees that the primary board is present.
            return target.selections.first(where: { $0.boardID == target.primaryBoardID })
                ?? target.selections[0]
        }
    }

    var sourceBoardIDs: [String] { selections.map(\.boardID) }

    /// The controller cache/single-flight key includes every board-local
    /// selection and the grouped owner/primary identity. Ordering the board
    /// components prevents Set/dictionary iteration from causing false misses.
    var cacheSignature: String {
        let selectionComponents = selections
            .sorted { $0.boardID < $1.boardID }
            .map(Self.selectionSignature)
            .joined(separator: "||")
        switch self {
        case .board:
            return "board||\(selectionComponents)"
        case .lecture(let target):
            return "lecture|\(target.folderID)|primary=\(target.primaryBoardID)||"
                + selectionComponents
        }
    }

    private static func selectionSignature(_ selection: BoardStudySelection) -> String {
        let bbox = selection.localBBox
        let semantic = selection.selectedTextObjects
            .map { "\($0.id):\($0.text)" }.sorted().joined(separator: "|")
        let coordinates = String(
            format: "%.4f,%.4f,%.4f,%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            bbox.x, bbox.y, bbox.width, bbox.height
        )
        return "\(selection.boardID)|"
            + selection.canonicalObjectIDs.sorted().joined(separator: ",")
            + "|\(coordinates)|\(semantic)|visual=\(selection.visualRevision)"
    }
}

struct LectureGraphRecognitionTarget: Equatable, Sendable {
    let folderID: String
    let primaryBoardID: String
    let selections: [BoardStudySelection]

    fileprivate init(folderID: String, primaryBoardID: String,
                     selections: [BoardStudySelection]) {
        self.folderID = folderID
        self.primaryBoardID = primaryBoardID
        self.selections = selections
    }
}

struct GraphRecognitionRequest: Encodable, Equatable, Sendable {
    /// Routing-only ownership. The board ID is carried by the authenticated
    /// URL and deliberately omitted from the JSON body.
    let boardID: String
    let requestId: String
    let selection: GraphRecognitionSelection
    let contextScope: String
    let action: String

    enum CodingKeys: String, CodingKey {
        case requestId, selection, contextScope, action
    }

    static func make(selection: BoardStudySelection,
                     requestID: String = BoardStudyExplainRequest.makeRequestID())
        -> GraphRecognitionRequest {
        GraphRecognitionRequest(
            boardID: selection.boardID,
            requestId: requestID,
            selection: GraphRecognitionSelection(
                selectedObjectIds: selection.canonicalObjectIDs,
                bbox: selection.localBBox
            ),
            contextScope: "local",
            action: "graph_recognition"
        )
    }

    var sanitizedJSON: String {
        let value: [String: Any] = [
            "requestId": requestId,
            "selection": [
                "selectedObjectIds": selection.selectedObjectIds,
                "bbox": [
                    "x": selection.bbox.x, "y": selection.bbox.y,
                    "width": selection.bbox.width, "height": selection.bbox.height
                ]
            ],
            "contextScope": contextScope,
            "action": action
        ]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else {
            return "<could not sanitize graph-recognition request>"
        }
        return result
    }
}

struct LectureGraphRecognitionBoardSelection: Encodable, Equatable, Sendable {
    let boardId: String
    let selectedObjectIds: [String]
    let bbox: StudySelectionBBox

    init(selection: BoardStudySelection) {
        boardId = selection.boardID
        selectedObjectIds = selection.canonicalObjectIDs.sorted()
        bbox = selection.localBBox
    }
}

struct LectureGraphRecognitionRequest: Encodable, Equatable, Sendable {
    /// Routing-only ownership; omitted from the JSON body.
    let folderID: String
    let requestId: String
    let action: String
    let contextScope: String
    let primaryBoardId: String
    let boards: [LectureGraphRecognitionBoardSelection]

    enum CodingKeys: String, CodingKey {
        case requestId, action, contextScope, primaryBoardId, boards
    }

    init(target: LectureGraphRecognitionTarget,
         requestID: String = BoardStudyExplainRequest.makeRequestID()) {
        folderID = target.folderID
        requestId = requestID
        action = "graph_recognition"
        contextScope = "local"
        primaryBoardId = target.primaryBoardID
        boards = target.selections
            .sorted { $0.boardID < $1.boardID }
            .map(LectureGraphRecognitionBoardSelection.init(selection:))
    }

    var sanitizedJSON: String {
        let value: [String: Any] = [
            "requestId": requestId,
            "action": action,
            "contextScope": contextScope,
            "primaryBoardId": primaryBoardId,
            "boards": boards.map { board in
                [
                    "boardId": board.boardId,
                    "selectedObjectIds": board.selectedObjectIds,
                    "bbox": [
                        "x": board.bbox.x, "y": board.bbox.y,
                        "width": board.bbox.width, "height": board.bbox.height
                    ]
                ] as [String: Any]
            }
        ]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else {
            return "<could not sanitize grouped graph-recognition request>"
        }
        return result
    }
}

struct GraphRecognizedExpression: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let latex: String
    let type: GraphExpressionType
    let confidence: Double?

    var canonicalExpression: GraphExpression {
        GraphExpression(id: id, latex: latex, type: type)
    }
}

struct GraphRecognitionResult: Codable, Equatable, Sendable {
    let graphable: Bool
    let confidence: Double
    let expressions: [GraphRecognizedExpression]
    let warnings: [String]
    let requestID: String
    let recognitionVersion: Int

    enum CodingKeys: String, CodingKey {
        case graphable, confidence, expressions, warnings
        case requestID
        case recognitionVersion
    }

    func validated(maximumExpressions: Int = GraphRecognitionController.maximumExpressions) throws -> GraphRecognitionResult {
        guard confidence.isFinite, (0...1).contains(confidence),
              recognitionVersion > 0,
              !requestID.isEmpty, requestID.count <= 128,
              expressions.count <= maximumExpressions,
              warnings.count <= 16 else {
            throw APIError.decoding("The graph recognition response was invalid.")
        }
        if graphable && expressions.isEmpty {
            throw APIError.decoding("The graph recognition response contained no equations.")
        }
        for expression in expressions {
            guard !expression.id.isEmpty, expression.id.count <= 128,
                  !expression.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  expression.latex.count <= GraphRecognitionController.maximumLatexLength,
                  expression.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                throw APIError.decoding("The graph recognition response contained an invalid equation.")
            }
        }
        return self
    }
}

struct GraphRecognitionEnvelope: Codable, Equatable, Sendable {
    let result: GraphRecognitionResult
    let requestId: String
    let cacheHit: Bool
    let idempotentReplay: Bool?
}

enum GraphabilityPolicy {
    static let automaticThreshold = 0.86

    static func showsPrimaryAction(result: GraphRecognitionResult?) -> Bool {
        guard let result else { return false }
        return result.graphable && result.confidence >= automaticThreshold
            && !result.expressions.isEmpty
    }

    /// Free and synchronous high-confidence hint for persisted semantic text.
    /// Professor/user handwriting still goes through focused visual recognition.
    static func hasLocalSemanticHint(_ selection: BoardStudySelection?) -> Bool {
        guard let selection else { return false }
        return selection.selectedTextObjects.contains { item in
            let normalized = GraphLatexNormalizer.normalize(item.text)
            guard normalized.count <= 2_000 else { return false }
            if GraphEquationClassifier.point(in: normalized) != nil { return true }
            if GraphEquationClassifier.explicitRightHandSide(normalized) != nil { return true }
            if GraphEquationClassifier.constant(after: "x", in: normalized) != nil { return true }
            return GraphEquationClassifier.originCircleRadius(in: normalized) != nil
        }
    }
}
