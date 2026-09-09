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

    enum CodingKeys: String, CodingKey {
        case id, name, status, width, height, url
        case folderID = "folder_id"
        case thumbnailURL = "thumbnail_url"
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

    enum CodingKeys: String, CodingKey {
        case id, name, dimensions, assets
        case suggestedCorners = "suggested_corners"
        case normalizedCorners = "normalized_corners"
    }
}

struct BoardDimensions: Codable, Sendable { let width: Double; let height: Double }
struct BoardAssets: Codable, Sendable { let svg: String? }

struct UploadResponse: Codable, Sendable {
    let id: String
    let status: String
    let url: String?
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
}

struct StudyGuide: Codable, Sendable {
    let title: String?
    let content: String?
    let stale: Bool?
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

    enum CodingKeys: String, CodingKey {
        case id, type, color, width, opacity, points, translation
        case sourceMarkdown = "source_markdown", text, x, y, height
        case fontSize = "font_size", role
        case sourceStudyInteractionID = "source_study_interaction_id"
    }

    init(id: String, type: String, color: String?, width: Double?, opacity: Double?,
         points: [WorldPoint]?, translation: WorldPoint?, sourceMarkdown: String?,
         text: String?, x: Double?, y: Double?, height: Double?, fontSize: Double?,
         role: String? = nil, sourceStudyInteractionID: String? = nil) {
        self.id = id; self.type = type; self.color = color; self.width = width
        self.opacity = opacity; self.points = points; self.translation = translation
        self.sourceMarkdown = sourceMarkdown; self.text = text; self.x = x; self.y = y
        self.height = height; self.fontSize = fontSize; self.role = role
        self.sourceStudyInteractionID = sourceStudyInteractionID
    }

    func translated(by delta: CGPoint) -> CanvasObject {
        let existing = translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
        return CanvasObject(id: id, type: type, color: color, width: width,
                           opacity: opacity, points: points, translation: WorldPoint(x: existing.x + delta.x, y: existing.y + delta.y, pressure: nil),
                           sourceMarkdown: sourceMarkdown, text: text, x: x, y: y,
                           height: height, fontSize: fontSize, role: role,
                           sourceStudyInteractionID: sourceStudyInteractionID)
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
