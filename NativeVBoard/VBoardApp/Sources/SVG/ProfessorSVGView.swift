import UIKit

/// Efficient native layer-backed rendering of immutable professor ink.
final class ProfessorSVGView: UIView {
    private var shapeLayers: [CAShapeLayer] = []

    func display(_ document: SVGDocument, transform: WorldScreenTransform) {
        shapeLayers.forEach { $0.removeFromSuperlayer() }; shapeLayers.removeAll(keepingCapacity: true)
        var cg = CGAffineTransform(translationX: transform.origin.x - CGFloat(transform.camera.x) * transform.scale, y: transform.origin.y - CGFloat(transform.camera.y) * transform.scale).scaledBy(x: transform.scale, y: transform.scale)
        for item in document.paths {
            guard let path = try? SVGPathParser.path(from: item.d).copy(using: &cg) else { continue }
            let layer = CAShapeLayer(); layer.path = path; layer.fillColor = item.fill.cgColor; layer.fillRule = item.fillRule
            layer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            self.layer.addSublayer(layer); shapeLayers.append(layer)
        }
    }
}
