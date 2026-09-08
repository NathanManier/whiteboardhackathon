import Foundation

enum SceneSourceKind: String, Sendable { case professorSVG, editorObject, importedTransform, legacyStroke, group, practiceProblem, studyObject, cache, liveInteraction }

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
}

struct SceneComposition: Equatable, Sendable {
    let boardID: String
    let nodes: [SceneNode]

    static func build(boardID: String, document: SVGDocument, editor: EditorState) -> SceneComposition {
        var nodes: [SceneNode] = []
        for path in document.paths {
            guard let pathID = path.id, editor.importedTransforms[pathID]?.deleted != true else { continue }
            nodes.append(SceneNode(id: "professor:\(pathID)", logicalID: pathID, boardID: boardID, sourceKind: .professorSVG, sourceID: pathID, objectType: "path", renderLayer: "professor"))
        }
        for object in editor.objects {
            let kind: SceneSourceKind = object.type == "text" && object.sourceMarkdown?.contains("practice") == true ? .practiceProblem : .editorObject
            nodes.append(SceneNode(id: "editor:\(object.id)", logicalID: object.id, boardID: boardID, sourceKind: kind, sourceID: object.id, objectType: object.type, renderLayer: "editor"))
        }
        return SceneComposition(boardID: boardID, nodes: nodes)
    }

    var duplicateLogicalIDs: [String] {
        Dictionary(grouping: nodes, by: \.logicalID).compactMap { $0.value.count > 1 ? $0.key : nil }.sorted()
    }
}
