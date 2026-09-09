import SwiftUI
import UIKit

struct NativeCanvasView: UIViewRepresentable {
    let boardID: String
    let document: SVGDocument
    let camera: CameraRect
    let objects: [CanvasObject]
    let importedTransforms: [String: ObjectTransform]
    let composition: SceneComposition
    func makeUIView(context: Context) -> InfiniteCanvasUIView { InfiniteCanvasUIView(boardID: boardID, document: document, camera: camera, objects: objects, importedTransforms: importedTransforms, composition: composition) }
    func updateUIView(_ uiView: InfiniteCanvasUIView, context: Context) { uiView.update(boardID: boardID, document: document, camera: camera, objects: objects, importedTransforms: importedTransforms, composition: composition) }
}

/// UIKit keeps gesture/input work off SwiftUI view diffing. This initial surface
/// uses the contract camera; Pencil stroke editing lands in the next module.
final class InfiniteCanvasUIView: UIView {
    private let professor = ProfessorSVGView()
    private let userLayer = CALayer()
    private var activeStrokeLayer: CAShapeLayer?
    private(set) var userStrokes: [UserStroke] = []
    private var activePoints: [StrokePoint] = []
    private var activeID: String?
    private var boardID: String
    private var document: SVGDocument
    private var controller: CameraController
    private var objects: [CanvasObject]
    private var importedTransforms: [String: ObjectTransform]
    private var composition: SceneComposition
    private var panStart = CGPoint.zero

    init(boardID: String, document: SVGDocument, camera: CameraRect, objects: [CanvasObject] = [], importedTransforms: [String: ObjectTransform] = [:], composition: SceneComposition) {
        self.boardID = boardID; self.document = document; self.objects = objects; self.importedTransforms = importedTransforms; self.composition = composition; controller = CameraController(camera: camera)
        super.init(frame: .zero); backgroundColor = .systemBackground; addSubview(professor); layer.addSublayer(userLayer)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:))); pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 2; pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]; addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:))); addGestureRecognizer(pinch)
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); professor.frame = bounds; userLayer.frame = bounds; render() }
    func update(boardID: String, document: SVGDocument, camera: CameraRect, objects: [CanvasObject], importedTransforms: [String: ObjectTransform], composition: SceneComposition) { self.boardID = boardID; self.document = document; self.objects = objects; self.importedTransforms = importedTransforms; self.composition = composition; controller = CameraController(camera: camera); render() }
    @objc private func didPan(_ gesture: UIPanGestureRecognizer) { let translation = gesture.translation(in: self); if gesture.state == .began { panStart = translation }; controller.pan(screenTranslation: CGPoint(x: translation.x - panStart.x, y: translation.y - panStart.y), viewport: bounds.size); panStart = translation; render() }
    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) { guard gesture.state == .changed else { return }; controller.zoom(by: gesture.scale, anchoredAt: gesture.location(in: self), viewport: bounds.size); gesture.scale = 1; render() }
    private func render() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let transform = WorldScreenTransform(camera: controller.camera, viewport: bounds.size)
        professor.display(document, transform: transform, importedTransforms: importedTransforms, composition: composition)
        userLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for object in SceneComposition.canonicalEditorObjects(objects) {
            let provenance = composition.nodes.first(where: { node in
                node.sourceID == object.id && (node.sourceKind == .editorObject || node.sourceKind == .practiceProblem)
            })
            addObjectLayer(object, transform: transform, to: userLayer, provenance: provenance)
        }
        for stroke in userStrokes { addStrokeLayer(stroke, transform: transform, to: userLayer) }
        if let activeStrokeLayer { userLayer.addSublayer(activeStrokeLayer) }
    }

    // Pencil owns direct drawing. Finger touches continue to the UIKit pan/
    // pinch recognizers, keeping the two interaction modes deterministic.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { super.touchesBegan(touches, with: event); return }
        activeID = UUID().uuidString
        activePoints = samples(for: touch, event: event)
        activeStrokeLayer = CAShapeLayer(); activeStrokeLayer?.fillColor = UIColor.clear.cgColor
        activeStrokeLayer?.strokeColor = UIColor(svgHex: "#183153").cgColor; activeStrokeLayer?.lineWidth = 4; activeStrokeLayer?.lineCap = .round; activeStrokeLayer?.lineJoin = .round
        updateActiveStroke()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        activePoints.append(contentsOf: samples(for: touch, event: event)); updateActiveStroke()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        activePoints.append(contentsOf: samples(for: touch, event: event))
        if let activeID, activePoints.count > 0 { userStrokes.append(UserStroke(id: activeID, points: activePoints)) }
        activeStrokeLayer = nil; activePoints.removeAll(); self.activeID = nil; render()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .pencil }) { activeStrokeLayer = nil; activePoints.removeAll(); activeID = nil; render() }
    }

    private func samples(for touch: UITouch, event: UIEvent?) -> [StrokePoint] {
        let source = event?.coalescedTouches(for: touch) ?? [touch]
        let transform = WorldScreenTransform(camera: controller.camera, viewport: bounds.size)
        return source.map { item in let point = transform.worldPoint(for: item.location(in: self)); return StrokePoint(x: point.x, y: point.y, pressure: Double(item.force / max(item.maximumPossibleForce, 1))) }
    }

    private func updateActiveStroke() {
        guard let layer = activeStrokeLayer else { return }
        let transform = WorldScreenTransform(camera: controller.camera, viewport: bounds.size)
        let path = UIBezierPath(); for (index, point) in activePoints.enumerated() { let screen = transform.screenPoint(for: CGPoint(x: point.x, y: point.y)); if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) } }
        layer.path = path.cgPath; layer.lineWidth = 4; userLayer.addSublayer(layer)
    }

    private func addStrokeLayer(_ stroke: UserStroke, transform: WorldScreenTransform, to container: CALayer) {
        let layer = CAShapeLayer(); let path = UIBezierPath()
        for (index, point) in stroke.points.enumerated() { let screen = transform.screenPoint(for: CGPoint(x: point.x + stroke.translation.x, y: point.y + stroke.translation.y)); if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) } }
        layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor; layer.strokeColor = UIColor(svgHex: stroke.color).withAlphaComponent(CGFloat(stroke.opacity)).cgColor; layer.lineWidth = stroke.width * transform.scale; layer.lineCap = .round; layer.lineJoin = .round; applyProvenance(SceneNode(id: "live:\(stroke.id)", logicalID: stroke.id, boardID: boardID, sourceKind: .liveInteraction, sourceID: stroke.id, objectType: stroke.type, renderLayer: "live"), to: layer); container.addSublayer(layer)
    }

    private func addObjectLayer(_ object: CanvasObject, transform: WorldScreenTransform, to container: CALayer, provenance: SceneNode?) {
        if object.type == "text", let text = object.text ?? object.sourceMarkdown, let x = object.x, let y = object.y {
            let layer = CATextLayer(); layer.string = text; layer.foregroundColor = UIColor(svgHex: object.color ?? "#183153").cgColor; layer.fontSize = object.fontSize ?? 32; layer.alignmentMode = .left; layer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            let origin = transform.screenPoint(for: CGPoint(x: x + (object.translation?.x ?? 0), y: y + (object.translation?.y ?? 0))); layer.frame = CGRect(x: origin.x, y: origin.y, width: (object.width ?? 400) * transform.scale, height: (object.height ?? 100) * transform.scale); applyProvenance(provenance, to: layer); container.addSublayer(layer); return
        }
        guard let points = object.points, !points.isEmpty else { return }
        let layer = CAShapeLayer(); let path = UIBezierPath(); let tx = object.translation?.x ?? 0; let ty = object.translation?.y ?? 0
        for (index, point) in points.enumerated() { let screen = transform.screenPoint(for: CGPoint(x: point.x + tx, y: point.y + ty)); if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) } }
        layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor; layer.strokeColor = UIColor(svgHex: object.color ?? "#183153").withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor; layer.lineWidth = (object.width ?? 4) * transform.scale; layer.lineCap = .round; layer.lineJoin = .round; applyProvenance(provenance, to: layer); container.addSublayer(layer)
    }

    private func applyProvenance(_ node: SceneNode?, to layer: CALayer) {
        #if DEBUG
        guard let node else { return }
        layer.name = node.debugLabel
        layer.setValue(node.logicalID, forKey: "vboard.logicalID")
        layer.setValue(node.sourceKind.rawValue, forKey: "vboard.sourceKind")
        layer.setValue(node.sourceID, forKey: "vboard.sourceID")
        layer.setValue(node.renderLayer, forKey: "vboard.renderLayer")
        #endif
    }
}
