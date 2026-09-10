import Foundation
import CoreGraphics

/// The explicit visible world rectangle. World coordinates use a top-left
/// origin, positive Y downward, and intentionally permit negative coordinates.
struct CameraRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct WorldPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var pressure: Double?

    enum CodingKeys: String, CodingKey { case x, y, pressure = "p" }
}

struct LibraryResponse: Codable, Sendable {
    let schemaVersion: Int
    let folders: [LectureFolder]
    let boards: [LibraryBoard]

    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", folders, boards }
}

struct LectureFolder: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let workspaceBoardID: String?
    let boardOrder: [String]

    enum CodingKeys: String, CodingKey {
        case id, name
        case workspaceBoardID = "workspace_board_id"
        case boardOrder = "board_order"
    }
}

struct LibraryBoard: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let folderID: String?
    let status: String
    let width: Double?
    let height: Double?
    let thumbnailURL: String?
    let url: String?
    let createdAt: Double?
    let updatedAt: Double?
    let sourceKind: BoardSourceKind
    let pdfURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, width, height, url, title, dimensions, assets, pipeline
        case lectureBoards = "lecture_boards"
        case boardID = "board_id"
        case masterWidth = "master_width"
        case masterHeight = "master_height"
        case folderID = "folder_id"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceKind = "source_kind"
        case pdfURL = "pdf_url"
    }

    private struct AssetNames: Codable { let thumbnail: String?; let master: String? }
    private struct PipelineState: Codable { let status: String? }
    private struct LectureBoardSummary: Codable {
        let boardID: String
        let createdAt: Double?

        enum CodingKeys: String, CodingKey {
            case boardID = "boardId"
            case createdAt
        }
    }

    init(id: String, name: String, folderID: String?, status: String,
         width: Double?, height: Double?, thumbnailURL: String?, url: String?,
         createdAt: Double?, updatedAt: Double?,
         sourceKind: BoardSourceKind = .physicalWhiteboard, pdfURL: String? = nil) {
        self.id = id; self.name = name; self.folderID = folderID; self.status = status
        self.width = width; self.height = height; self.thumbnailURL = thumbnailURL
        self.url = url; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.sourceKind = sourceKind; self.pdfURL = pdfURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decode(String.self, forKey: .boardID)
        id = decodedID
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? "Whiteboard"
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        let pipeline = try container.decodeIfPresent(PipelineState.self, forKey: .pipeline)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? pipeline?.status ?? "unknown"
        let dimensions = try container.decodeIfPresent(BoardDimensions.self, forKey: .dimensions)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
            ?? container.decodeIfPresent(Double.self, forKey: .masterWidth)
            ?? dimensions?.width
        height = try container.decodeIfPresent(Double.self, forKey: .height)
            ?? container.decodeIfPresent(Double.self, forKey: .masterHeight)
            ?? dimensions?.height
        let assets = try container.decodeIfPresent(AssetNames.self, forKey: .assets)
        func assetPath(_ name: String) -> String {
            if name.hasPrefix("/") || name.hasPrefix("https://") || name.hasPrefix("http://") {
                return name
            }
            return "/boards/\(decodedID)/\(name)"
        }
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL)
            ?? assets?.thumbnail.map(assetPath)
            ?? assets?.master.map(assetPath)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        let lectureBoards = try container.decodeIfPresent([LectureBoardSummary].self, forKey: .lectureBoards) ?? []
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
            ?? lectureBoards.first(where: { $0.boardID == decodedID })?.createdAt
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt)
        sourceKind = try container.decodeIfPresent(BoardSourceKind.self, forKey: .sourceKind) ?? .physicalWhiteboard
        pdfURL = try container.decodeIfPresent(String.self, forKey: .pdfURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encodeIfPresent(pdfURL, forKey: .pdfURL)
    }
}

/// Server board JSON has additional fields by design. The native client only
/// decodes fields it uses, so newer server fields are not rejected or erased.
struct BoardRecord: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let dimensions: BoardDimensions?
    let assets: BoardAssets?
    let suggestedCorners: [[Double]]?
    let normalizedCorners: [[String: Double]]?
    let sourceKind: BoardSourceKind?
    let pdfURL: String?
    let pdfPageNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, dimensions, assets
        case suggestedCorners = "suggested_corners"
        case normalizedCorners = "normalized_corners"
        case sourceKind = "source_kind"
        case pdfURL = "pdf_url"
        case pdfPageNumber = "pdf_page_number"
    }
}

enum BoardSourceKind: String, Codable, Hashable, Sendable {
    case physicalWhiteboard = "physical_whiteboard"
    case freeformPDF = "freeform_pdf"
    case genericPDF = "generic_pdf"
    case image

    var isPDF: Bool { self == .freeformPDF || self == .genericPDF }
}

struct BoardDimensions: Codable, Sendable { let width: Double; let height: Double }
struct BoardAssets: Codable, Sendable { let svg: String?; let pdf: String? }

struct UploadResponse: Codable, Sendable {
    let id: String
    let status: String
    let url: String?
}

struct PDFImportResponse: Codable, Sendable {
    let importID: String
    let sourceKind: BoardSourceKind
    let pageCount: Int
    let boards: [LibraryBoard]
    let folderID: String?

    enum CodingKeys: String, CodingKey {
        case importID = "import_id"
        case sourceKind = "source_kind"
        case pageCount = "page_count"
        case boards
        case folderID = "folder_id"
    }
}

struct LectureResponse: Codable, Sendable {
    let folder: LectureFolder
    let boards: [LibraryBoard]
    let studyGuide: StudyGuide?
    let studyGuideStale: Bool?

    enum CodingKeys: String, CodingKey {
        case folder, boards
        case studyGuide = "study_guide"
        case studyGuideStale = "study_guide_stale"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decode(LectureFolder.self, forKey: .folder)
        let decodedBoards = try container.decodeIfPresent([LibraryBoard].self, forKey: .boards) ?? []
        boards = decodedBoards
        studyGuide = try container.decodeIfPresent(StudyGuide.self, forKey: .studyGuide)
        studyGuideStale = try container.decodeIfPresent(Bool.self, forKey: .studyGuideStale)
    }

    init(folder: LectureFolder, boards: [LibraryBoard], studyGuide: StudyGuide?, studyGuideStale: Bool?) {
        self.folder = folder; self.boards = boards
        self.studyGuide = studyGuide; self.studyGuideStale = studyGuideStale
    }
}

struct StudyGuide: Codable, Sendable {
    let id: String?
    let title: String?
    let content: String?
    let version: Int?
    let stale: Bool?
    let sourceBoardIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, content, version, stale
        case sourceBoardIDs = "source_board_ids"
    }
}

struct StudyInteractionResponse: Codable, Sendable {
    let interaction: StudyInteraction?
    let problems: [PracticeProblem]?
    let problem: String?
}

struct StudyInteraction: Codable, Sendable {
    let title: String?
    let answer: String?
    let id: String?
    let followUps: [StudyFollowUp]?
}

struct StudyFollowUp: Codable, Identifiable, Sendable {
    let id: String
    let kind: String?
    let question: String?
    let answer: String?
    let problems: [PracticeProblem]?
}

struct PracticeProblem: Codable, Identifiable, Sendable {
    let id: String
    let text: String
    let solution: String?

    enum CodingKeys: String, CodingKey { case id, text, problem, solution }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try c.decodeIfPresent(String.self, forKey: .text)
            ?? c.decodeIfPresent(String.self, forKey: .problem) ?? ""
        solution = try c.decodeIfPresent(String.self, forKey: .solution)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
        try c.encodeIfPresent(solution, forKey: .solution)
    }
}

struct EditorEnvelope: Codable, Sendable { let editor: EditorState }

struct EditorState: Codable, Sendable {
    var schemaVersion: Int
    var revision: Int
    var updatedAt: Double?
    var viewport: CameraRect
    var objects: [CanvasObject]
    var groups: [EditorGroup]
    var importedTransforms: [String: ObjectTransform]
    var sourceBoards: [SourceBoard]
    var mergedBoardIDs: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", revision
        case updatedAt = "updated_at", viewport, objects, groups
        case importedTransforms = "imported_transforms"
        case sourceBoards = "source_boards"
        case mergedBoardIDs = "merged_board_ids"
    }

    init(schemaVersion: Int, revision: Int, updatedAt: Double?, viewport: CameraRect, objects: [CanvasObject], groups: [EditorGroup], importedTransforms: [String: ObjectTransform], sourceBoards: [SourceBoard], mergedBoardIDs: [String]) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.updatedAt = updatedAt; self.viewport = viewport; self.objects = objects; self.groups = groups; self.importedTransforms = importedTransforms; self.sourceBoards = sourceBoards; self.mergedBoardIDs = mergedBoardIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        viewport = try c.decode(CameraRect.self, forKey: .viewport)
        objects = try c.decodeIfPresent([CanvasObject].self, forKey: .objects) ?? []
        groups = try c.decodeIfPresent([EditorGroup].self, forKey: .groups) ?? []
        importedTransforms = try c.decodeIfPresent([String: ObjectTransform].self, forKey: .importedTransforms) ?? [:]
        sourceBoards = try c.decodeIfPresent([SourceBoard].self, forKey: .sourceBoards) ?? []
        mergedBoardIDs = try c.decodeIfPresent([String].self, forKey: .mergedBoardIDs) ?? []
    }
}

struct SourceBoard: Codable, Sendable { let boardID: String; enum CodingKeys: String, CodingKey { case boardID = "board_id" } }
struct EditorGroup: Codable, Sendable { let id: String?; let children: [String]? }
struct ObjectTransform: Codable, Equatable, Sendable { let x: Double; let y: Double; let scaleX: Double?; let scaleY: Double?; let deleted: Bool? }

struct CanvasObject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let type: String
    let color: String?
    let width: Double?
    let opacity: Double?
    let points: [WorldPoint]?
    let translation: WorldPoint?
    /// Canonical source is intentionally retained untouched for future text rendering.
    let sourceMarkdown: String?
    let text: String?
    let x: Double?
    let y: Double?
    let height: Double?
    let fontSize: Double?
    let role: String?
    let sourceStudyInteractionID: String?
    let createdAt: Double?
    let unitLabel: String?
    let origin: String?

    enum CodingKeys: String, CodingKey {
        case id, type, color, width, opacity, points, translation
        case sourceMarkdown = "source_markdown", text, x, y, height
        case fontSize = "font_size", role
        case sourceStudyInteractionID = "source_study_interaction_id"
        case createdAt = "created_at"
        case unitLabel = "unit_label"
        case origin
    }

    init(id: String, type: String, color: String?, width: Double?, opacity: Double?,
         points: [WorldPoint]?, translation: WorldPoint?, sourceMarkdown: String?,
         text: String?, x: Double?, y: Double?, height: Double?, fontSize: Double?,
         role: String? = nil, sourceStudyInteractionID: String? = nil,
         createdAt: Double? = nil, unitLabel: String? = nil, origin: String? = nil) {
        self.id = id; self.type = type; self.color = color; self.width = width
        self.opacity = opacity; self.points = points; self.translation = translation
        self.sourceMarkdown = sourceMarkdown; self.text = text; self.x = x; self.y = y
        self.height = height; self.fontSize = fontSize; self.role = role
        self.sourceStudyInteractionID = sourceStudyInteractionID
        self.createdAt = createdAt; self.unitLabel = unitLabel; self.origin = origin
    }

    func translated(by delta: CGPoint) -> CanvasObject {
        let existing = translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
        return CanvasObject(id: id, type: type, color: color, width: width,
                           opacity: opacity, points: points, translation: WorldPoint(x: existing.x + delta.x, y: existing.y + delta.y, pressure: nil),
                           sourceMarkdown: sourceMarkdown, text: text, x: x, y: y,
                           height: height, fontSize: fontSize, role: role,
                           sourceStudyInteractionID: sourceStudyInteractionID,
                           createdAt: createdAt, unitLabel: unitLabel, origin: origin)
    }

    func resized(to size: CGSize) -> CanvasObject {
        CanvasObject(id: id, type: type, color: color,
                     width: Double(size.width), opacity: opacity,
                     points: points, translation: translation,
                     sourceMarkdown: sourceMarkdown, text: text, x: x, y: y,
                     height: Double(size.height), fontSize: fontSize, role: role,
                     sourceStudyInteractionID: sourceStudyInteractionID,
                     createdAt: createdAt, unitLabel: unitLabel, origin: origin)
    }
}

/// Canonical Pencil data. This deliberately mirrors the server's stroke
/// points instead of serializing UIKit/PencilKit implementation state.
struct StrokePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let pressure: Double?

    enum CodingKeys: String, CodingKey { case x, y, pressure = "p" }
}

struct UserStroke: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var type: String = "stroke"
    var color: String = "#183153"
    var width: Double = 4
    var opacity: Double = 1
    var points: [StrokePoint]
    var translation: WorldPoint = WorldPoint(x: 0, y: 0, pressure: nil)

    func asCanvasObject(boardID: String? = nil) -> [String: Any] {
        // This helper documents the exact server shape; EditorState remains
        // Codable and the next persistence module will use a typed envelope.
        var result: [String: Any] = ["id": id, "type": type, "color": color,
                                     "width": width, "opacity": opacity,
                                     "points": points.map { ["x": $0.x, "y": $0.y, "p": $0.pressure as Any] },
                                     "translation": ["x": translation.x, "y": translation.y]]
        if let boardID { result["board_id"] = boardID }
        return result
    }
}
