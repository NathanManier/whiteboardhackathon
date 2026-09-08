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
}

struct BoardDimensions: Codable, Sendable { let width: Double; let height: Double }
struct BoardAssets: Codable, Sendable { let svg: String? }

struct EditorEnvelope: Codable, Sendable { let editor: EditorState }

struct EditorState: Codable, Sendable {
    var schemaVersion: Int
    var revision: Int
    var updatedAt: Double?
    var viewport: CameraRect
    var objects: [CanvasObject]
    var importedTransforms: [String: ObjectTransform]
    var sourceBoards: [SourceBoard]
    var mergedBoardIDs: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", revision
        case updatedAt = "updated_at", viewport, objects
        case importedTransforms = "imported_transforms"
        case sourceBoards = "source_boards"
        case mergedBoardIDs = "merged_board_ids"
    }
}

struct SourceBoard: Codable, Sendable { let boardID: String; enum CodingKeys: String, CodingKey { case boardID = "board_id" } }
struct ObjectTransform: Codable, Sendable { let x: Double; let y: Double; let scaleX: Double?; let scaleY: Double? }

struct CanvasObject: Codable, Identifiable, Sendable {
    let id: String
    let type: String
    let color: String?
    let width: Double?
    let opacity: Double?
    let points: [WorldPoint]?
    let translation: WorldPoint?
    /// Canonical source is intentionally retained untouched for future text rendering.
    let sourceMarkdown: String?

    enum CodingKeys: String, CodingKey {
        case id, type, color, width, opacity, points, translation
        case sourceMarkdown = "source_markdown"
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
