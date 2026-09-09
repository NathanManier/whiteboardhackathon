import Foundation

enum SceneSourceKind: String, Sendable {
    case professorSVG
    case editorObject
    case importedTransform
    case legacyStroke
    case group
    case practiceProblem
    case studyObject
    case cache
    case liveInteraction
}

/// A node references one canonical source. Indexes and caches do not create
/// render nodes, which makes duplicate ownership observable in DEBUG builds.
struct SceneNode: Identifiable, Equatable, Sendable {
    let id: String
    let logicalID: String
    let boardID: String
    let sourceKind: SceneSourceKind
    let sourceID: String
    let objectType: String
    let renderLayer: String

    var debugLabel: String {
        "board=\(boardID) logical=\(logicalID) source=\(sourceKind.rawValue):\(sourceID) type=\(objectType) layer=\(renderLayer)"
    }
}

struct SceneComposition: Equatable, Sendable {
    let boardID: String
    let nodes: [SceneNode]

    static func build(boardID: String, document: SVGDocument, editor: EditorState) -> SceneComposition {
        var nodes: [SceneNode] = []
        for path in document.paths {
            guard let pathID = path.id, editor.importedTransforms[pathID]?.deleted != true else { continue }
            let hasTransform = editor.importedTransforms[pathID] != nil
            nodes.append(SceneNode(id: "professor:\(pathID)", logicalID: pathID, boardID: boardID, sourceKind: hasTransform ? .importedTransform : .professorSVG, sourceID: pathID, objectType: "path", renderLayer: hasTransform ? "professor.transformed" : "professor"))
        }
        for object in editor.objects {
            let kind: SceneSourceKind = object.type == "text" && object.sourceMarkdown?.contains("practice") == true ? .practiceProblem : .editorObject
            nodes.append(SceneNode(id: "editor:\(object.id)", logicalID: object.id, boardID: boardID, sourceKind: kind, sourceID: object.id, objectType: object.type, renderLayer: "editor"))
        }
        return SceneComposition(boardID: boardID, nodes: nodes)
    }

    /// Stable IDs are the ownership boundary. This protects the renderer from
    /// malformed/repeated array entries without comparing geometry.
    static func canonicalEditorObjects(_ objects: [CanvasObject]) -> [CanvasObject] {
        var seen = Set<String>()
        return objects.filter { seen.insert($0.id).inserted }
    }

    static func canonicalProfessorPaths(_ paths: [SVGPath]) -> [SVGPath] {
        var seen = Set<String>()
        return paths.filter { path in
            guard let id = path.id else { return true }
            return seen.insert(id).inserted
        }
    }

    var duplicateLogicalIDs: [String] {
        Dictionary(grouping: nodes, by: \.logicalID).compactMap { $0.value.count > 1 ? $0.key : nil }.sorted()
    }
}
