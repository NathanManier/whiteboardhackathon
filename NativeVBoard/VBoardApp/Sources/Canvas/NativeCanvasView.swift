import SwiftUI
import UIKit

struct NativeCanvasView: UIViewRepresentable {
    let boardID: String
    let document: SVGDocument
    let camera: CameraRect
    let objects: [CanvasObject]
    let importedTransforms: [String: ObjectTransform]
    let composition: SceneComposition
    var onStroke: (UserStroke) -> Void = { _ in }

    func makeUIView(context: Context) -> InfiniteCanvasUIView {
        InfiniteCanvasUIView(boardID: boardID, document: document, camera: camera,
                             objects: objects, importedTransforms: importedTransforms,
                             composition: composition, onStroke: onStroke)
    }

    func updateUIView(_ uiView: InfiniteCanvasUIView, context: Context) {
        uiView.update(boardID: boardID, document: document, camera: camera,
                      objects: objects, importedTransforms: importedTransforms,
                      composition: composition, onStroke: onStroke)
    }
}

/// UIKit owns the high-frequency input and layer composition. World-space
/// content is transformed as one GPU-composited layer; expensive visibility
/// refinement only runs after a gesture ends.
final class InfiniteCanvasUIView: UIView, UIGestureRecognizerDelegate {
    private let professor = ProfessorSVGView()
    private let userLayer = CALayer()
    private var userObjectLayers: [String: CALayer] = [:]
    private var strokeLayers: [String: CALayer] = [:]
    private var activeStrokeLayer: CAShapeLayer?
    private(set) var userStrokes: [UserStroke] = []
    private var activePoints: [StrokePoint] = []
    private var activeID: String?
    private var onStroke: (UserStroke) -> Void
    private var boardID: String
    private var document: SVGDocument
    private var controller: CameraController
    private var objects: [CanvasObject]
    private var importedTransforms: [String: ObjectTransform]
    private var composition: SceneComposition
    private var panStart = CGPoint.zero
    #if DEBUG
    private let perfLabel = UILabel()
    #endif

    init(boardID: String, document: SVGDocument, camera: CameraRect,
         objects: [CanvasObject] = [], importedTransforms: [String: ObjectTransform] = [:],
         composition: SceneComposition, onStroke: @escaping (UserStroke) -> Void = { _ in }) {
        self.boardID = boardID; self.document = document; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition
        self.onStroke = onStroke
        controller = CameraController(camera: camera)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        isMultipleTouchEnabled = true
        clipsToBounds = true
        userLayer.anchorPoint = .zero
        userLayer.position = .zero
        layer.addSublayer(userLayer)
        #if DEBUG
        professor.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.updatePerformanceOverlay(stats) }
        }
        #endif
        addSubview(professor)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self; addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:)))
        pinch.delegate = self; addGestureRecognizer(pinch)
        rebuildUserLayers()
        #if DEBUG
        perfLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        perfLabel.textColor = .secondaryLabel
        perfLabel.numberOfLines = 3
        perfLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.82)
        perfLabel.layer.cornerRadius = 6; perfLabel.layer.masksToBounds = true
        addSubview(perfLabel)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        professor.frame = bounds
        userLayer.frame = bounds
        #if DEBUG
        perfLabel.frame = CGRect(x: 8, y: 8, width: 260, height: 58)
        #endif
        applyCamera(interacting: false)
    }

    func update(boardID: String, document: SVGDocument, camera: CameraRect,
                objects: [CanvasObject], importedTransforms: [String: ObjectTransform],
                composition: SceneComposition, onStroke: @escaping (UserStroke) -> Void = { _ in }) {
        let documentChanged = self.document != document || self.importedTransforms != importedTransforms
        let objectsChanged = self.objects.map(\.id) != objects.map(\.id)
        self.boardID = boardID; self.document = document; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition
        self.onStroke = onStroke
        controller.setCamera(camera)
        if documentChanged { professor.display(document, transform: worldTransform, importedTransforms: importedTransforms, composition: composition) }
        if objectsChanged { rebuildUserLayers() }
        applyCamera(interacting: false)
    }

    private var worldTransform: WorldScreenTransform {
        WorldScreenTransform(camera: controller.camera, viewport: bounds.size)
    }

    private func applyCamera(interacting: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let current = worldTransform
        professor.updateCamera(current, interacting: interacting)
        userLayer.setAffineTransform(current.affineTransform)
    }

    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            panStart = translation; professor.beginNavigation()
        case .changed:
            controller.pan(screenTranslation: CGPoint(x: translation.x - panStart.x, y: translation.y - panStart.y), viewport: bounds.size)
            panStart = translation; applyCamera(interacting: true)
        case .ended, .cancelled, .failed:
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
        default: break
        }
    }

    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: professor.beginNavigation()
        case .changed:
            controller.zoom(by: gesture.scale, anchoredAt: gesture.location(in: self), viewport: bounds.size)
            gesture.scale = 1; applyCamera(interacting: true)
        case .ended, .cancelled, .failed:
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    // Pencil owns direct drawing. The simulator's indirect pointer path uses
    // the same Stroke model with deterministic pressure=1 for Mac testing.
    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        if touch.type == .pencil { return true }
        #if targetEnvironment(simulator)
        return touch.type == .indirectPointer
        #else
        return false
        #endif
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, isDrawingTouch(touch) else { super.touchesBegan(touches, with: event); return }
        activeID = UUID().uuidString; activePoints = samples(for: touch, event: event)
        let layer = CAShapeLayer(); layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor(svgHex: "#183153").cgColor; layer.lineWidth = 4
        layer.lineCap = .round; layer.lineJoin = .round; activeStrokeLayer = layer
        updateActiveStroke()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, isDrawingTouch(touch) else { return }
        activePoints.append(contentsOf: samples(for: touch, event: event)); updateActiveStroke()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, isDrawingTouch(touch) else { return }
        activePoints.append(contentsOf: samples(for: touch, event: event))
        if let activeID, !activePoints.isEmpty {
            onStroke(UserStroke(id: activeID, points: activePoints))
        }
        activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
        activePoints.removeAll(); activeID = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { isDrawingTouch($0) }) {
            activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
            activePoints.removeAll(); activeID = nil
        }
    }

    private func samples(for touch: UITouch, event: UIEvent?) -> [StrokePoint] {
        let source = event?.coalescedTouches(for: touch) ?? [touch]
        return source.map { item in
            let point = worldTransform.worldPoint(for: item.location(in: self))
            #if targetEnvironment(simulator)
            let pressure = item.type == .indirectPointer ? 1.0 : Double(item.force / max(item.maximumPossibleForce, 1))
            #else
            let pressure = Double(item.force / max(item.maximumPossibleForce, 1))
            #endif
            return StrokePoint(x: point.x, y: point.y, pressure: pressure)
        }
    }

    private func updateActiveStroke() {
        guard let layer = activeStrokeLayer else { return }
        let path = UIBezierPath()
        for (index, point) in activePoints.enumerated() {
            let world = CGPoint(x: point.x, y: point.y)
            if index == 0 { path.move(to: world) } else { path.addLine(to: world) }
        }
        layer.path = path.cgPath; layer.frame = bounds
        if layer.superlayer == nil { userLayer.addSublayer(layer) }
    }

    private func rebuildUserLayers() {
        userObjectLayers.values.forEach { $0.removeFromSuperlayer() }
        userObjectLayers.removeAll(keepingCapacity: true)
        for object in SceneComposition.canonicalEditorObjects(objects) {
            let layer = makeObjectLayer(object)
            userObjectLayers[object.id] = layer; userLayer.addSublayer(layer)
        }
        for stroke in userStrokes where strokeLayers[stroke.id] == nil { addStrokeLayer(stroke) }
    }

    private func makeObjectLayer(_ object: CanvasObject) -> CALayer {
        if object.type == "text", let text = object.text ?? object.sourceMarkdown,
           let x = object.x, let y = object.y {
            let layer = CATextLayer(); layer.string = text
            layer.foregroundColor = UIColor(svgHex: object.color ?? "#183153").cgColor
            layer.fontSize = object.fontSize ?? 32; layer.alignmentMode = .left
            layer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            layer.frame = CGRect(x: x + (object.translation?.x ?? 0), y: y + (object.translation?.y ?? 0), width: object.width ?? 400, height: object.height ?? 100)
            applyProvenance(object.id, to: layer); return layer
        }
        let layer = CAShapeLayer(); let path = UIBezierPath()
        let tx = object.translation?.x ?? 0; let ty = object.translation?.y ?? 0
        for (index, point) in (object.points ?? []).enumerated() {
            let world = CGPoint(x: point.x + tx, y: point.y + ty)
            if index == 0 { path.move(to: world) } else { path.addLine(to: world) }
        }
        layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor(svgHex: object.color ?? "#183153").withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor
        layer.lineWidth = object.width ?? 4; layer.lineCap = .round; layer.lineJoin = .round
        applyProvenance(object.id, to: layer); return layer
    }

    private func addStrokeLayer(_ stroke: UserStroke) {
        let layer = CAShapeLayer(); let path = UIBezierPath()
        for (index, point) in stroke.points.enumerated() {
            let world = CGPoint(x: point.x + stroke.translation.x, y: point.y + stroke.translation.y)
            if index == 0 { path.move(to: world) } else { path.addLine(to: world) }
        }
        layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor(svgHex: stroke.color).withAlphaComponent(CGFloat(stroke.opacity)).cgColor
        layer.lineWidth = stroke.width; layer.lineCap = .round; layer.lineJoin = .round
        applyProvenance(stroke.id, to: layer); strokeLayers[stroke.id] = layer; userLayer.addSublayer(layer)
    }

    private func applyProvenance(_ id: String, to layer: CALayer) {
        #if DEBUG
        if let node = composition.nodes.first(where: { $0.sourceID == id }) {
            layer.name = node.debugLabel; layer.setValue(node.logicalID, forKey: "vboard.logicalID")
            layer.setValue(node.sourceKind.rawValue, forKey: "vboard.sourceKind")
            layer.setValue(node.sourceID, forKey: "vboard.sourceID")
            layer.setValue(node.renderLayer, forKey: "vboard.renderLayer")
        }
        #endif
    }

    #if DEBUG
    private func updatePerformanceOverlay(_ stats: RenderStats) {
        perfLabel.text = stats.overlayText
    }
    #endif
}
