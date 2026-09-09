import UIKit

/// Efficient native layer-backed rendering of immutable professor ink.
final class ProfessorSVGView: UIView {
    private var shapeLayers: [CAShapeLayer] = []

    func display(_ document: SVGDocument, transform: WorldScreenTransform, importedTransforms: [String: ObjectTransform] = [:], composition: SceneComposition? = nil) {
        shapeLayers.forEach { $0.removeFromSuperlayer() }; shapeLayers.removeAll(keepingCapacity: true)
        let cg = CGAffineTransform(translationX: transform.origin.x - CGFloat(transform.camera.x) * transform.scale, y: transform.origin.y - CGFloat(transform.camera.y) * transform.scale).scaledBy(x: transform.scale, y: transform.scale)
        for item in SceneComposition.canonicalProfessorPaths(document.paths) {
            var pathTransform = cg
            if let imported = item.id.flatMap({ importedTransforms[$0] }), imported.deleted != true {
                pathTransform = pathTransform.translatedBy(x: CGFloat(imported.x), y: CGFloat(imported.y)).scaledBy(x: CGFloat(imported.scaleX ?? 1), y: CGFloat(imported.scaleY ?? 1))
            } else if item.id.flatMap({ importedTransforms[$0] })?.deleted == true { continue }
            guard let path = try? SVGPathParser.path(from: item.d).copy(using: &pathTransform) else { continue }
            let layer = CAShapeLayer(); layer.path = path; layer.fillColor = item.fill.cgColor; layer.fillRule = item.fillRule
            #if DEBUG
            if let id = item.id, let node = composition?.nodes.first(where: { node in
                node.sourceID == id && (node.sourceKind == .professorSVG || node.sourceKind == .importedTransform)
            }) {
                layer.name = node.debugLabel
                layer.setValue(node.logicalID, forKey: "vboard.logicalID")
                layer.setValue(node.sourceKind.rawValue, forKey: "vboard.sourceKind")
                layer.setValue(node.sourceID, forKey: "vboard.sourceID")
                layer.setValue(node.renderLayer, forKey: "vboard.renderLayer")
            }
            #endif
            layer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            self.layer.addSublayer(layer); shapeLayers.append(layer)
        }
    }
}
