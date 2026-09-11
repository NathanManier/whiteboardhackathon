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
    case blankBoard = "blank_board"
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

struct EditorState: Codable, Equatable, Sendable {
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

struct SourceBoard: Codable, Equatable, Sendable { let boardID: String; enum CodingKeys: String, CodingKey { case boardID = "board_id" } }
struct EditorGroup: Codable, Equatable, Sendable { let id: String?; let children: [String]? }
struct ObjectTransform: Codable, Equatable, Sendable { let x: Double; let y: Double; let scaleX: Double?; let scaleY: Double?; let deleted: Bool? }

/// Lossless JSON storage for provider metadata and additive graph fields that
/// this client does not understand yet. Graph semantics never depend on this
/// opaque state, but retaining it prevents a newer server/client from losing
/// data when an older compatible client performs an editor round trip.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func decodeAdditionalFields(from decoder: Decoder,
                                    excluding knownKeys: Set<String>) throws -> [String: JSONValue] {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    return try container.allKeys.reduce(into: [:]) { result, key in
        guard !knownKeys.contains(key.stringValue) else { return }
        result[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
    }
}

private func encodeAdditionalFields(_ fields: [String: JSONValue],
                                    excluding knownKeys: Set<String>,
                                    to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: DynamicCodingKey.self)
    for (name, value) in fields where !knownKeys.contains(name) {
        guard let key = DynamicCodingKey(stringValue: name) else { continue }
        try container.encode(value, forKey: key)
    }
}

struct GraphFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var hasFinitePositiveSize: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

/// Open raw-value model: known cases have constants while future server values
/// survive decode/encode exactly instead of collapsing to `unknown`.
struct GraphExpressionType: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let explicitFunction = Self(rawValue: "explicitFunction")
    static let implicitEquation = Self(rawValue: "implicitEquation")
    static let inequality = Self(rawValue: "inequality")
    static let verticalLine = Self(rawValue: "verticalLine")
    static let horizontalLine = Self(rawValue: "horizontalLine")
    static let point = Self(rawValue: "point")
    static let parametric = Self(rawValue: "parametric")
    static let polar = Self(rawValue: "polar")
    static let table = Self(rawValue: "table")
    static let unknown = Self(rawValue: "unknown")

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct GraphExpressionDisplayStyle: Codable, Equatable, Sendable {
    let color: String?
    let lineWidth: Double?
    let lineStyle: String?
    let opacity: Double?
    let pointStyle: String?

    enum CodingKeys: String, CodingKey {
        case color
        case lineWidth = "line_width"
        case lineStyle = "line_style"
        case opacity
        case pointStyle = "point_style"
    }

    init(color: String? = nil, lineWidth: Double? = nil, lineStyle: String? = nil,
         opacity: Double? = nil, pointStyle: String? = nil) {
        self.color = color
        self.lineWidth = lineWidth
        self.lineStyle = lineStyle
        self.opacity = opacity
        self.pointStyle = pointStyle
    }
}

struct GraphExpression: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let latex: String
    let type: GraphExpressionType
    let visible: Bool
    let displayStyle: GraphExpressionDisplayStyle?
    let restrictions: [String]
    let additionalFields: [String: JSONValue]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, latex, type, visible
        case displayStyle = "display_style"
        case restrictions
    }

    init(id: String, latex: String, type: GraphExpressionType, visible: Bool = true,
         displayStyle: GraphExpressionDisplayStyle? = nil, restrictions: [String] = [],
         additionalFields: [String: JSONValue] = [:]) {
        self.id = id
        self.latex = latex
        self.type = type
        self.visible = visible
        self.displayStyle = displayStyle
        self.restrictions = restrictions
        self.additionalFields = additionalFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        latex = try container.decode(String.self, forKey: .latex)
        type = try container.decodeIfPresent(GraphExpressionType.self, forKey: .type) ?? .unknown
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        displayStyle = try container.decodeIfPresent(GraphExpressionDisplayStyle.self,
                                                      forKey: .displayStyle)
        restrictions = try container.decodeIfPresent([String].self, forKey: .restrictions) ?? []
        additionalFields = try decodeAdditionalFields(
            from: decoder,
            excluding: Set(CodingKeys.allCases.map(\.stringValue))
        )
    }

    func encode(to encoder: Encoder) throws {
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        try encodeAdditionalFields(additionalFields, excluding: knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(latex, forKey: .latex)
        try container.encode(type, forKey: .type)
        try container.encode(visible, forKey: .visible)
        try container.encodeIfPresent(displayStyle, forKey: .displayStyle)
        if !restrictions.isEmpty { try container.encode(restrictions, forKey: .restrictions) }
    }
}

struct GraphViewport: Codable, Equatable, Sendable {
    let xMin: Double
    let xMax: Double
    let yMin: Double
    let yMax: Double

    enum CodingKeys: String, CodingKey {
        case xMin = "x_min"
        case xMax = "x_max"
        case yMin = "y_min"
        case yMax = "y_max"
    }

    static let conventional = GraphViewport(xMin: -10, xMax: 10, yMin: -10, yMax: 10)

    var isValid: Bool {
        xMin.isFinite && xMax.isFinite && yMin.isFinite && yMax.isFinite
            && xMin < xMax && yMin < yMax
    }
}

struct GraphSettings: Codable, Equatable, Sendable {
    let showXAxis: Bool
    let showYAxis: Bool
    let showGrid: Bool
    let showExpressionsPanel: Bool
    let lockViewport: Bool
    let angleMode: String?

    enum CodingKeys: String, CodingKey {
        case showXAxis = "show_x_axis"
        case showYAxis = "show_y_axis"
        case showGrid = "show_grid"
        case showExpressionsPanel = "show_expressions_panel"
        case lockViewport = "lock_viewport"
        case angleMode = "angle_mode"
    }

    init(showXAxis: Bool = true, showYAxis: Bool = true, showGrid: Bool = true,
         showExpressionsPanel: Bool = false, lockViewport: Bool = false,
         angleMode: String? = "radians") {
        self.showXAxis = showXAxis
        self.showYAxis = showYAxis
        self.showGrid = showGrid
        self.showExpressionsPanel = showExpressionsPanel
        self.lockViewport = lockViewport
        self.angleMode = angleMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showXAxis = try container.decodeIfPresent(Bool.self, forKey: .showXAxis) ?? true
        showYAxis = try container.decodeIfPresent(Bool.self, forKey: .showYAxis) ?? true
        showGrid = try container.decodeIfPresent(Bool.self, forKey: .showGrid) ?? true
        showExpressionsPanel = try container.decodeIfPresent(Bool.self,
                                                              forKey: .showExpressionsPanel) ?? false
        lockViewport = try container.decodeIfPresent(Bool.self, forKey: .lockViewport) ?? false
        angleMode = try container.decodeIfPresent(String.self, forKey: .angleMode) ?? "radians"
    }
}

struct GraphSourceSelection: Codable, Equatable, Sendable {
    let interactionID: String?
    let sourceBoardIDs: [String]
    let selectedObjectKeys: [String]
    let originalRecognitionRequestID: String?
    let originalSelectionBBox: GraphFrame?

    enum CodingKeys: String, CodingKey {
        case interactionID = "interaction_id"
        case sourceBoardIDs = "source_board_ids"
        case selectedObjectKeys = "selected_object_keys"
        case originalRecognitionRequestID = "original_recognition_request_id"
        case originalSelectionBBox = "original_selection_bbox"
    }

    init(interactionID: String? = nil, sourceBoardIDs: [String] = [],
         selectedObjectKeys: [String] = [], originalRecognitionRequestID: String? = nil,
         originalSelectionBBox: GraphFrame? = nil) {
        self.interactionID = interactionID
        self.sourceBoardIDs = sourceBoardIDs
        self.selectedObjectKeys = selectedObjectKeys
        self.originalRecognitionRequestID = originalRecognitionRequestID
        self.originalSelectionBBox = originalSelectionBBox
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interactionID = try container.decodeIfPresent(String.self, forKey: .interactionID)
        sourceBoardIDs = try container.decodeIfPresent([String].self,
                                                       forKey: .sourceBoardIDs) ?? []
        selectedObjectKeys = try container.decodeIfPresent([String].self,
                                                           forKey: .selectedObjectKeys) ?? []
        originalRecognitionRequestID = try container.decodeIfPresent(
            String.self, forKey: .originalRecognitionRequestID
        )
        originalSelectionBBox = try container.decodeIfPresent(GraphFrame.self,
                                                               forKey: .originalSelectionBBox)
    }
}

/// Optional provider hints/caches. `GraphObject.expressions`, viewport and
/// settings remain sufficient to render the object without this metadata.
struct GraphProviderMetadata: Codable, Equatable, Sendable {
    let preference: String?
    let state: JSONValue?
    let semanticContentHash: String?
    let renderVersion: Int?

    enum CodingKeys: String, CodingKey {
        case preference, state
        case semanticContentHash = "semantic_content_hash"
        case renderVersion = "render_version"
    }

    init(preference: String? = nil, state: JSONValue? = nil,
         semanticContentHash: String? = nil, renderVersion: Int? = nil) {
        self.preference = preference
        self.state = state
        self.semanticContentHash = semanticContentHash
        self.renderVersion = renderVersion
    }
}

/// Provider-independent graph semantics. It encodes directly as a flat
/// `objects[]` record so the existing editor/outbox/revision architecture is
/// the sole canonical persistence path.
struct GraphObject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let owningBoardID: String
    let frame: GraphFrame
    let expressions: [GraphExpression]
    let viewport: GraphViewport
    let settings: GraphSettings
    let sourceSelection: GraphSourceSelection?
    let providerMetadata: GraphProviderMetadata?
    let createdAt: Double
    let updatedAt: Double
    let version: Int
    let additionalFields: [String: JSONValue]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, type
        case owningBoardID = "owning_board_id"
        case frame, expressions, viewport, settings
        case sourceSelection = "source_selection"
        case providerMetadata = "provider_metadata"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case version
    }

    init(id: String, owningBoardID: String, frame: GraphFrame,
         expressions: [GraphExpression], viewport: GraphViewport = .conventional,
         settings: GraphSettings = GraphSettings(),
         sourceSelection: GraphSourceSelection? = nil,
         providerMetadata: GraphProviderMetadata? = nil,
         createdAt: Double = Date().timeIntervalSince1970,
         updatedAt: Double = Date().timeIntervalSince1970, version: Int = 1,
         additionalFields: [String: JSONValue] = [:]) {
        self.id = id
        self.owningBoardID = owningBoardID
        self.frame = frame
        self.expressions = expressions
        self.viewport = viewport
        self.settings = settings
        self.sourceSelection = sourceSelection
        self.providerMetadata = providerMetadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.additionalFields = additionalFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let objectType = try container.decodeIfPresent(String.self, forKey: .type),
           objectType != "graph" {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "Expected graph object")
        }
        id = try container.decode(String.self, forKey: .id)
        owningBoardID = try container.decode(String.self, forKey: .owningBoardID)
        frame = try container.decode(GraphFrame.self, forKey: .frame)
        expressions = try container.decodeIfPresent([GraphExpression].self,
                                                    forKey: .expressions) ?? []
        viewport = try container.decodeIfPresent(GraphViewport.self, forKey: .viewport)
            ?? .conventional
        settings = try container.decodeIfPresent(GraphSettings.self, forKey: .settings)
            ?? GraphSettings()
        sourceSelection = try container.decodeIfPresent(GraphSourceSelection.self,
                                                         forKey: .sourceSelection)
        providerMetadata = try container.decodeIfPresent(GraphProviderMetadata.self,
                                                          forKey: .providerMetadata)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        additionalFields = try decodeAdditionalFields(
            from: decoder,
            excluding: Set(CodingKeys.allCases.map(\.stringValue))
        )
    }

    func encode(to encoder: Encoder) throws {
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        try encodeAdditionalFields(additionalFields, excluding: knownKeys, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("graph", forKey: .type)
        try container.encode(owningBoardID, forKey: .owningBoardID)
        try container.encode(frame, forKey: .frame)
        try container.encode(expressions, forKey: .expressions)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(sourceSelection, forKey: .sourceSelection)
        try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(version, forKey: .version)
    }

    func translated(by delta: CGPoint) -> GraphObject {
        replacing(frame: GraphFrame(x: frame.x + Double(delta.x),
                                    y: frame.y + Double(delta.y),
                                    width: frame.width, height: frame.height))
    }

    func resized(to size: CGSize) -> GraphObject {
        replacing(frame: GraphFrame(x: frame.x, y: frame.y,
                                    width: Double(size.width), height: Double(size.height)))
    }

    func scaled(around anchor: CGPoint, by factor: Double) -> GraphObject {
        replacing(frame: GraphFrame(
            x: Double(anchor.x) + factor * (frame.x - Double(anchor.x)),
            y: Double(anchor.y) + factor * (frame.y - Double(anchor.y)),
            width: frame.width * factor,
            height: frame.height * factor
        ))
    }

    func replacing(frame: GraphFrame) -> GraphObject {
        GraphObject(id: id, owningBoardID: owningBoardID, frame: frame,
                    expressions: expressions, viewport: viewport, settings: settings,
                    sourceSelection: sourceSelection, providerMetadata: providerMetadata,
                    createdAt: createdAt, updatedAt: updatedAt, version: version,
                    additionalFields: additionalFields)
    }

    func replacing(expressions: [GraphExpression]) -> GraphObject {
        GraphObject(id: id, owningBoardID: owningBoardID, frame: frame,
                    expressions: expressions, viewport: viewport, settings: settings,
                    sourceSelection: sourceSelection, providerMetadata: providerMetadata,
                    createdAt: createdAt, updatedAt: updatedAt, version: version,
                    additionalFields: additionalFields)
    }

    func replacing(viewport: GraphViewport) -> GraphObject {
        GraphObject(id: id, owningBoardID: owningBoardID, frame: frame,
                    expressions: expressions, viewport: viewport, settings: settings,
                    sourceSelection: sourceSelection, providerMetadata: providerMetadata,
                    createdAt: createdAt, updatedAt: updatedAt, version: version,
                    additionalFields: additionalFields)
    }

    func replacing(settings: GraphSettings) -> GraphObject {
        GraphObject(id: id, owningBoardID: owningBoardID, frame: frame,
                    expressions: expressions, viewport: viewport, settings: settings,
                    sourceSelection: sourceSelection, providerMetadata: providerMetadata,
                    createdAt: createdAt, updatedAt: updatedAt, version: version,
                    additionalFields: additionalFields)
    }
}

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
    /// Canonical non-destructive object scale used by the web editor and
    /// server export pipeline for strokes and editable vector paths.
    let scaleX: Double?
    let scaleY: Double?
    /// Editable vector objects keep their original source path verbatim.
    let d: String?
    let fill: String?
    let role: String?
    let sourceStudyInteractionID: String?
    let createdAt: Double?
    let unitLabel: String?
    let origin: String?
    /// Populated only for `type == "graph"`. Graph fields encode flat into the
    /// canonical editor object rather than into a parallel document collection.
    let graph: GraphObject?

    enum CodingKeys: String, CodingKey {
        case id, type, color, width, opacity, points, translation
        case sourceMarkdown = "source_markdown", text, x, y, height
        case fontSize = "font_size", scaleX, scaleY, d, fill, role
        case sourceStudyInteractionID = "source_study_interaction_id"
        case createdAt = "created_at"
        case unitLabel = "unit_label"
        case origin
    }

    init(id: String, type: String, color: String?, width: Double?, opacity: Double?,
         points: [WorldPoint]?, translation: WorldPoint?, sourceMarkdown: String?,
         text: String?, x: Double?, y: Double?, height: Double?, fontSize: Double?,
         scaleX: Double? = nil, scaleY: Double? = nil, d: String? = nil, fill: String? = nil,
         role: String? = nil, sourceStudyInteractionID: String? = nil,
         createdAt: Double? = nil, unitLabel: String? = nil, origin: String? = nil,
         graph: GraphObject? = nil) {
        self.id = id; self.type = type; self.color = color; self.width = width
        self.opacity = opacity; self.points = points; self.translation = translation
        self.sourceMarkdown = sourceMarkdown; self.text = text; self.x = x; self.y = y
        self.height = height; self.fontSize = fontSize; self.scaleX = scaleX; self.scaleY = scaleY
        self.d = d; self.fill = fill; self.role = role
        self.sourceStudyInteractionID = sourceStudyInteractionID
        self.createdAt = createdAt; self.unitLabel = unitLabel; self.origin = origin
        self.graph = graph
    }

    init(graph: GraphObject) {
        id = graph.id; type = "graph"; color = nil; width = nil; opacity = nil
        points = nil; translation = nil; sourceMarkdown = nil; text = nil
        x = nil; y = nil; height = nil; fontSize = nil; scaleX = nil; scaleY = nil
        d = nil; fill = nil; role = nil; sourceStudyInteractionID = nil
        createdAt = graph.createdAt; unitLabel = nil; origin = nil
        self.graph = graph
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        if type == "graph" {
            let value = try GraphObject(from: decoder)
            color = nil; width = nil; opacity = nil; points = nil; translation = nil
            sourceMarkdown = nil; text = nil; x = nil; y = nil; height = nil
            fontSize = nil; scaleX = nil; scaleY = nil; d = nil; fill = nil
            role = nil; sourceStudyInteractionID = nil; createdAt = value.createdAt
            unitLabel = nil; origin = nil; graph = value
            return
        }
        color = try container.decodeIfPresent(String.self, forKey: .color)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        points = try container.decodeIfPresent([WorldPoint].self, forKey: .points)
        translation = try container.decodeIfPresent(WorldPoint.self, forKey: .translation)
        sourceMarkdown = try container.decodeIfPresent(String.self, forKey: .sourceMarkdown)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        x = try container.decodeIfPresent(Double.self, forKey: .x)
        y = try container.decodeIfPresent(Double.self, forKey: .y)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
        scaleX = try container.decodeIfPresent(Double.self, forKey: .scaleX)
        scaleY = try container.decodeIfPresent(Double.self, forKey: .scaleY)
        d = try container.decodeIfPresent(String.self, forKey: .d)
        fill = try container.decodeIfPresent(String.self, forKey: .fill)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        sourceStudyInteractionID = try container.decodeIfPresent(
            String.self, forKey: .sourceStudyInteractionID
        )
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        unitLabel = try container.decodeIfPresent(String.self, forKey: .unitLabel)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
        graph = nil
    }

    func encode(to encoder: Encoder) throws {
        if type == "graph", let graph {
            try graph.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(opacity, forKey: .opacity)
        try container.encodeIfPresent(points, forKey: .points)
        try container.encodeIfPresent(translation, forKey: .translation)
        try container.encodeIfPresent(sourceMarkdown, forKey: .sourceMarkdown)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(x, forKey: .x)
        try container.encodeIfPresent(y, forKey: .y)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(fontSize, forKey: .fontSize)
        try container.encodeIfPresent(scaleX, forKey: .scaleX)
        try container.encodeIfPresent(scaleY, forKey: .scaleY)
        try container.encodeIfPresent(d, forKey: .d)
        try container.encodeIfPresent(fill, forKey: .fill)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(sourceStudyInteractionID,
                                      forKey: .sourceStudyInteractionID)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(unitLabel, forKey: .unitLabel)
        try container.encodeIfPresent(origin, forKey: .origin)
    }

    func translated(by delta: CGPoint) -> CanvasObject {
        if let graph { return CanvasObject(graph: graph.translated(by: delta)) }
        let existing = translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
        return CanvasObject(id: id, type: type, color: color, width: width,
                           opacity: opacity, points: points, translation: WorldPoint(x: existing.x + delta.x, y: existing.y + delta.y, pressure: nil),
                           sourceMarkdown: sourceMarkdown, text: text, x: x, y: y,
                           height: height, fontSize: fontSize,
                           scaleX: scaleX, scaleY: scaleY, d: d, fill: fill, role: role,
                           sourceStudyInteractionID: sourceStudyInteractionID,
                           createdAt: createdAt, unitLabel: unitLabel, origin: origin)
    }

    func resized(to size: CGSize) -> CanvasObject {
        if let graph { return CanvasObject(graph: graph.resized(to: size)) }
        return CanvasObject(id: id, type: type, color: color,
                            width: Double(size.width), opacity: opacity,
                            points: points, translation: translation,
                            sourceMarkdown: sourceMarkdown, text: text, x: x, y: y,
                            height: Double(size.height), fontSize: fontSize,
                            scaleX: scaleX, scaleY: scaleY, d: d, fill: fill, role: role,
                            sourceStudyInteractionID: sourceStudyInteractionID,
                            createdAt: createdAt, unitLabel: unitLabel, origin: origin)
    }

    /// Scales the displayed object uniformly around a board-local anchor.
    /// Strokes and paths retain their source geometry and compose the new
    /// scale with their canonical translation. Text remains editable and
    /// reflows into a resized frame instead of becoming flattened artwork.
    func scaled(around anchor: CGPoint, by factor: CGFloat) -> CanvasObject {
        let safeFactor = Double(max(0.01, min(factor, 100)))
        if let graph { return CanvasObject(graph: graph.scaled(around: anchor, by: safeFactor)) }
        let existingTranslation = translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
        let nextTranslation = WorldPoint(
            x: Double(anchor.x) + safeFactor * (existingTranslation.x - Double(anchor.x)),
            y: Double(anchor.y) + safeFactor * (existingTranslation.y - Double(anchor.y)),
            pressure: nil
        )

        if type == "text", let x, let y {
            let displayedX = x + existingTranslation.x
            let displayedY = y + existingTranslation.y
            let nextDisplayedX = Double(anchor.x) + safeFactor * (displayedX - Double(anchor.x))
            let nextDisplayedY = Double(anchor.y) + safeFactor * (displayedY - Double(anchor.y))
            return CanvasObject(
                id: id, type: type, color: color,
                width: max(4, (width ?? 400) * safeFactor), opacity: opacity,
                points: points,
                translation: WorldPoint(x: nextDisplayedX - x, y: nextDisplayedY - y, pressure: nil),
                sourceMarkdown: sourceMarkdown, text: text, x: x, y: y,
                height: max(4, (height ?? 100) * safeFactor), fontSize: fontSize,
                scaleX: scaleX, scaleY: scaleY, d: d, fill: fill, role: role,
                sourceStudyInteractionID: sourceStudyInteractionID,
                createdAt: createdAt, unitLabel: unitLabel, origin: origin
            )
        }

        return CanvasObject(
            id: id, type: type, color: color, width: width, opacity: opacity,
            points: points, translation: nextTranslation,
            sourceMarkdown: sourceMarkdown, text: text, x: x, y: y,
            height: height, fontSize: fontSize,
            scaleX: (scaleX ?? 1) * safeFactor,
            scaleY: (scaleY ?? 1) * safeFactor,
            d: d, fill: fill, role: role,
            sourceStudyInteractionID: sourceStudyInteractionID,
            createdAt: createdAt, unitLabel: unitLabel, origin: origin
        )
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
