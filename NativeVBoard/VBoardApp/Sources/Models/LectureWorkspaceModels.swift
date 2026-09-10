import CoreGraphics
import Foundation

struct LectureWorkspaceEnvelope: Codable, Sendable {
    let workspace: LectureWorkspace
}

struct LectureWorkspace: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var revision: Int
    var camera: CameraRect
    var items: [WorkspaceBoardItem]
    var activeBoardID: String?
    var lastViewedAt: Double?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision, camera, items
        case activeBoardID = "active_board_id"
        case lastViewedAt = "last_viewed_at"
    }
}

extension LectureWorkspace {
    /// Compatibility for a server that has lecture summaries but has not yet
    /// deployed the additive workspace endpoint. This never merges board
    /// documents; it derives placement metadata from the ordered summaries.
    static func legacy(lecture: LectureResponse) -> LectureWorkspace {
        var items: [WorkspaceBoardItem] = []
        var rightmost = 0.0
        for (index, board) in lecture.boards.enumerated() {
            let width = max(board.width ?? 1, 1)
            let height = max(board.height ?? 1, 1)
            let x = items.isEmpty ? 0 : rightmost + WorkspaceLayout.defaultBoardGap
            let createdAt = board.createdAt ?? Date().timeIntervalSince1970 + Double(index) * 0.001
            let item = WorkspaceBoardItem(
                id: "board:\(board.id)", kind: "board", boardID: board.id,
                canvasX: x, canvasY: 0, boardWidth: width, boardHeight: height,
                effectiveContentBounds: CameraRect(x: x, y: 0, width: width, height: height * 1.5),
                createdAt: createdAt, capturedAt: nil, detectedBoardDate: nil,
                unitLabel: "No Unit", unitNumber: nil, unitConfidence: 0,
                unitSource: .none, title: board.name,
                thumbnailURL: board.thumbnailURL, sourceKind: board.sourceKind,
                pdfURL: board.pdfURL, zIndex: index
            )
            items.append(item)
            rightmost = x + width
        }
        let active = lecture.folder.workspaceBoardID ?? items.first?.boardID
        let first = items.first
        let camera = first.map {
            CameraRect(x: $0.canvasX - 64, y: $0.canvasY - 116,
                       width: $0.boardWidth + 128, height: $0.boardHeight + 180)
        } ?? CameraRect(x: -500, y: -350, width: 1_000, height: 700)
        return LectureWorkspace(schemaVersion: 1, revision: 0, camera: camera,
                                items: items, activeBoardID: active,
                                lastViewedAt: Date().timeIntervalSince1970)
    }
}

enum WorkspaceUnitSource: String, Codable, Sendable {
    case explicitAI = "explicit_ai"
    case explicitText = "explicit_text"
    case manual
    case none
}

/// Placement and navigation metadata only. The referenced board's professor
/// SVG, editor document, revision, and study state remain board-owned.
struct WorkspaceBoardItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let boardID: String
    var canvasX: Double
    var canvasY: Double
    let boardWidth: Double
    let boardHeight: Double
    var effectiveContentBounds: CameraRect
    let createdAt: Double
    let capturedAt: Double?
    let detectedBoardDate: String?
    var unitLabel: String
    var unitNumber: Int?
    var unitConfidence: Double
    var unitSource: WorkspaceUnitSource
    let title: String
    let thumbnailURL: String?
    let sourceKind: BoardSourceKind
    let pdfURL: String?
    let pdfPageNumber: Int?
    var zIndex: Int

    enum CodingKeys: String, CodingKey {
        case id, kind
        case boardID = "board_id"
        case canvasX = "canvas_x"
        case canvasY = "canvas_y"
        case boardWidth = "board_width"
        case boardHeight = "board_height"
        case effectiveContentBounds = "effective_content_bounds"
        case createdAt = "created_at"
        case capturedAt = "captured_at"
        case detectedBoardDate = "detected_board_date"
        case unitLabel = "unit_label"
        case unitNumber = "unit_number"
        case unitConfidence = "unit_confidence"
        case unitSource = "unit_source"
        case title
        case thumbnailURL = "thumbnail_url"
        case sourceKind = "source_kind"
        case pdfURL = "pdf_url"
        case pdfPageNumber = "pdf_page_number"
        case zIndex = "z_index"
    }

    init(id: String, kind: String, boardID: String, canvasX: Double, canvasY: Double,
         boardWidth: Double, boardHeight: Double, effectiveContentBounds: CameraRect,
         createdAt: Double, capturedAt: Double?, detectedBoardDate: String?,
         unitLabel: String, unitNumber: Int?, unitConfidence: Double,
         unitSource: WorkspaceUnitSource, title: String, thumbnailURL: String?,
         sourceKind: BoardSourceKind = .physicalWhiteboard, pdfURL: String? = nil,
         pdfPageNumber: Int? = nil,
         zIndex: Int) {
        self.id = id; self.kind = kind; self.boardID = boardID
        self.canvasX = canvasX; self.canvasY = canvasY
        self.boardWidth = boardWidth; self.boardHeight = boardHeight
        self.effectiveContentBounds = effectiveContentBounds
        self.createdAt = createdAt; self.capturedAt = capturedAt
        self.detectedBoardDate = detectedBoardDate; self.unitLabel = unitLabel
        self.unitNumber = unitNumber; self.unitConfidence = unitConfidence
        self.unitSource = unitSource; self.title = title
        self.thumbnailURL = thumbnailURL; self.sourceKind = sourceKind
        self.pdfURL = pdfURL; self.zIndex = zIndex
        self.pdfPageNumber = pdfPageNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        boardID = try c.decode(String.self, forKey: .boardID)
        canvasX = try c.decode(Double.self, forKey: .canvasX)
        canvasY = try c.decode(Double.self, forKey: .canvasY)
        boardWidth = try c.decode(Double.self, forKey: .boardWidth)
        boardHeight = try c.decode(Double.self, forKey: .boardHeight)
        effectiveContentBounds = try c.decode(CameraRect.self, forKey: .effectiveContentBounds)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        capturedAt = try c.decodeIfPresent(Double.self, forKey: .capturedAt)
        detectedBoardDate = try c.decodeIfPresent(String.self, forKey: .detectedBoardDate)
        unitLabel = try c.decode(String.self, forKey: .unitLabel)
        unitNumber = try c.decodeIfPresent(Int.self, forKey: .unitNumber)
        unitConfidence = try c.decode(Double.self, forKey: .unitConfidence)
        unitSource = try c.decode(WorkspaceUnitSource.self, forKey: .unitSource)
        title = try c.decode(String.self, forKey: .title)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        sourceKind = try c.decodeIfPresent(BoardSourceKind.self, forKey: .sourceKind) ?? .physicalWhiteboard
        pdfURL = try c.decodeIfPresent(String.self, forKey: .pdfURL)
        pdfPageNumber = try c.decodeIfPresent(Int.self, forKey: .pdfPageNumber)
        zIndex = try c.decode(Int.self, forKey: .zIndex)
    }

    var frame: CGRect {
        CGRect(x: CGFloat(canvasX), y: CGFloat(canvasY), width: CGFloat(boardWidth), height: CGFloat(boardHeight))
    }

    var effectiveFrame: CGRect { effectiveContentBounds.cgRect }
}

enum WorkspaceSelectionKind: String, Codable, Sendable {
    case professorPath
    case editorObject
}

/// SVG IDs are stable only within their owning board. Composite identity is
/// therefore required anywhere a lecture can contain more than one scene.
struct SelectionKey: Codable, Hashable, Sendable {
    let boardID: String
    let objectID: String
    let kind: WorkspaceSelectionKind
}

/// Defines deterministic layer ownership for point selection. Editor objects
/// render above immutable professor ink, so a point that intersects both must
/// select only the topmost editor object. Lasso selection intentionally remains
/// multi-object and is not routed through this policy.
enum BoardHitTestPolicy {
    static func topmostEditorObjectID(at point: CGPoint,
                                      objects: [CanvasObject],
                                      tolerance: CGFloat) -> String? {
        SceneComposition.canonicalEditorObjects(objects).reversed().first {
            bounds(of: $0).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }?.id
    }

    static func bounds(of object: CanvasObject) -> CGRect {
        let translation = object.translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
        if let x = object.x, let y = object.y {
            return CGRect(x: x + translation.x, y: y + translation.y,
                          width: max(object.width ?? 400, 0),
                          height: max(object.height ?? 100, 0))
        }
        guard let first = object.points?.first else { return .null }
        return (object.points ?? []).dropFirst().reduce(
            CGRect(x: first.x + translation.x, y: first.y + translation.y,
                   width: 0, height: 0)
        ) { partial, point in
            partial.union(CGRect(x: point.x + translation.x,
                                 y: point.y + translation.y,
                                 width: 0, height: 0))
        }
    }
}

enum BoardRepresentation: Int, Comparable, Sendable {
    case unloaded
    case thumbnail
    case fullVector

    static func < (lhs: BoardRepresentation, rhs: BoardRepresentation) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WorkspaceBoardScene: Equatable {
    let boardID: String
    let document: SVGDocument
    let pdfData: Data?
    var editor: EditorState
    var composition: SceneComposition

    static func == (lhs: WorkspaceBoardScene, rhs: WorkspaceBoardScene) -> Bool {
        lhs.boardID == rhs.boardID
            && lhs.document == rhs.document
            && lhs.pdfData == rhs.pdfData
            && lhs.editor.revision == rhs.editor.revision
            && lhs.editor.objects == rhs.editor.objects
            && lhs.editor.importedTransforms == rhs.editor.importedTransforms
            && lhs.composition == rhs.composition
    }
}

enum LectureCoordinateTransform {
    static func boardLocalToLectureWorld(_ point: CGPoint, board: WorkspaceBoardItem) -> CGPoint {
        CGPoint(x: point.x + CGFloat(board.canvasX), y: point.y + CGFloat(board.canvasY))
    }

    static func lectureWorldToBoardLocal(_ point: CGPoint, board: WorkspaceBoardItem) -> CGPoint {
        CGPoint(x: point.x - CGFloat(board.canvasX), y: point.y - CGFloat(board.canvasY))
    }

    static func boardLocalToLectureWorld(_ rect: CGRect, board: WorkspaceBoardItem) -> CGRect {
        rect.offsetBy(dx: CGFloat(board.canvasX), dy: CGFloat(board.canvasY))
    }

    static func lectureWorldToBoardLocal(_ rect: CGRect, board: WorkspaceBoardItem) -> CGRect {
        rect.offsetBy(dx: -CGFloat(board.canvasX), dy: -CGFloat(board.canvasY))
    }

    /// Current board placement is translation-only, so a lecture delta and a
    /// board-local delta are identical. Keeping this function explicit avoids
    /// silently baking that assumption into selection code when scale support
    /// is added later.
    static func lectureDeltaToBoardLocal(_ delta: CGPoint, board: WorkspaceBoardItem) -> CGPoint {
        delta
    }
}

struct WorkspaceSpatialIndex: Sendable {
    private var index = SpatialIndex(cellSize: 2_048)
    private var itemsByID: [String: WorkspaceBoardItem] = [:]

    init(items: [WorkspaceBoardItem]) {
        for item in items {
            itemsByID[item.boardID] = item
            index.insert(id: item.boardID, bounds: item.effectiveFrame.union(item.frame))
        }
    }

    func query(_ rect: CGRect) -> [WorkspaceBoardItem] {
        index.query(rect).compactMap { itemsByID[$0] }
    }
}

enum WorkspaceLayout {
    static let defaultBoardGap = 96.0

    static func placement(for size: CGSize,
                          after items: [WorkspaceBoardItem],
                          gap: Double = defaultBoardGap) -> CGPoint {
        guard !items.isEmpty else { return .zero }
        let rightmost = items.map { max($0.frame.maxX, $0.effectiveFrame.maxX) }.max() ?? 0
        let top = items.map(\.frame.minY).min() ?? 0
        return CGPoint(x: rightmost + CGFloat(gap), y: top)
    }
}

/// Computes the board-local extent owned by an editor document. The returned
/// rectangle is derived navigation/layout metadata; it never replaces or
/// rewrites the canonical object coordinates in the board editor document.
enum WorkspaceEffectiveBounds {
    /// A photographed board begins with a useful writing apron below the
    /// source image. The apron is layout metadata only: it never changes the
    /// professor SVG viewBox or canonical editor coordinates.
    static let initialRegionHeightMultiplier = 1.5

    static func boardLocal(editor: EditorState, boardSize: CGSize) -> CGRect {
        var result = CGRect(origin: .zero,
                            size: CGSize(width: max(boardSize.width, 1),
                                         height: max(boardSize.height * initialRegionHeightMultiplier, 1)))
        for object in SceneComposition.canonicalEditorObjects(editor.objects) {
            result = result.union(objectBounds(object))
        }
        return result
    }

    private static func objectBounds(_ object: CanvasObject) -> CGRect {
        BoardHitTestPolicy.bounds(of: object)
    }
}

enum BoardDetailPolicy {
    static let defaultFullDetailBudget = 3

    static func representations(items: [WorkspaceBoardItem],
                                camera: CameraRect,
                                viewport: CGSize,
                                activeBoardID: String?,
                                interactingBoardID: String? = nil,
                                fullDetailBudget: Int = defaultFullDetailBudget) -> [String: BoardRepresentation] {
        let scale = WorldScreenTransform(camera: camera, viewport: viewport).scale
        let preload = camera.cgRect.insetBy(dx: -camera.cgRect.width * 0.25,
                                            dy: -camera.cgRect.height * 0.25)
        let visible = items.filter { $0.effectiveFrame.union($0.frame).intersects(preload) }
        var result = Dictionary(uniqueKeysWithValues: items.map { ($0.boardID, BoardRepresentation.unloaded) })
        for item in visible { result[item.boardID] = .thumbnail }

        let eligible = visible.filter { item in
            let projectedWidth = item.boardWidth * Double(scale)
            let projectedHeight = item.boardHeight * Double(scale)
            return projectedWidth >= 180 || projectedHeight >= 140
                || item.boardID == activeBoardID
                || item.boardID == interactingBoardID
        }
        let cameraCenter = camera.center
        let prioritized = eligible.sorted { lhs, rhs in
            func priority(_ item: WorkspaceBoardItem) -> (Int, Int, Double, Double) {
                let active = item.boardID == activeBoardID ? 1 : 0
                let interacting = item.boardID == interactingBoardID ? 1 : 0
                let intersection = item.frame.intersection(camera.cgRect)
                let visibleArea = intersection.isNull ? 0 : intersection.width * intersection.height
                let distance = hypot(item.frame.midX - cameraCenter.x, item.frame.midY - cameraCenter.y)
                return (interacting, active, Double(visibleArea), -Double(distance))
            }
            let a = priority(lhs), b = priority(rhs)
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.3 > b.3
        }
        for item in prioritized.prefix(max(0, fullDetailBudget)) {
            result[item.boardID] = .fullVector
        }
        return result
    }
}

enum ExplicitUnitNormalizer {
    static func normalized(_ text: String) -> (label: String, number: Int)? {
        let pattern = #"(?i)(?:^|\b)unit\s+(\d{1,3}|[ivxlcdm]{1,8})(?:\b|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let token = String(text[range])
        if let number = Int(token), (1...999).contains(number) {
            return ("Unit \(number)", number)
        }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        let roman = token.uppercased()
        var total = 0
        var previous = 0
        for character in roman.reversed() {
            guard let current = values[character] else { return nil }
            total += current < previous ? -current : current
            previous = max(previous, current)
        }
        guard (1...999).contains(total), romanString(total) == roman else { return nil }
        return ("Unit \(total)", total)
    }

    private static func romanString(_ value: Int) -> String {
        var remaining = value
        var result = ""
        for (amount, token) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                                (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while remaining >= amount { result += token; remaining -= amount }
        }
        return result
    }
}
