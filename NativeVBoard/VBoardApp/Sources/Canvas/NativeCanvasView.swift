import SwiftUI
import UIKit

struct NativeCanvasView: UIViewRepresentable {
    let document: SVGDocument
    let camera: CameraRect
    func makeUIView(context: Context) -> InfiniteCanvasUIView { InfiniteCanvasUIView(document: document, camera: camera) }
    func updateUIView(_ uiView: InfiniteCanvasUIView, context: Context) { uiView.update(document: document, camera: camera) }
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
    private var document: SVGDocument
    private var controller: CameraController
    private var panStart = CGPoint.zero

    init(document: SVGDocument, camera: CameraRect) {
        self.document = document; controller = CameraController(camera: camera)
        super.init(frame: .zero); backgroundColor = .systemBackground; addSubview(professor); layer.addSublayer(userLayer)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:))); pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 2; pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]; addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:))); addGestureRecognizer(pinch)
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); professor.frame = bounds; userLayer.frame = bounds; render() }
    func update(document: SVGDocument, camera: CameraRect) { self.document = document; controller = CameraController(camera: camera); render() }
    @objc private func didPan(_ gesture: UIPanGestureRecognizer) { let translation = gesture.translation(in: self); if gesture.state == .began { panStart = translation }; controller.pan(screenTranslation: CGPoint(x: translation.x - panStart.x, y: translation.y - panStart.y), viewport: bounds.size); panStart = translation; render() }
    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) { guard gesture.state == .changed else { return }; controller.zoom(by: gesture.scale, anchoredAt: gesture.location(in: self), viewport: bounds.size); gesture.scale = 1; render() }
    private func render() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let transform = WorldScreenTransform(camera: controller.camera, viewport: bounds.size)
        professor.display(document, transform: transform)
        userLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
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
        layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor; layer.strokeColor = UIColor(svgHex: stroke.color).withAlphaComponent(CGFloat(stroke.opacity)).cgColor; layer.lineWidth = stroke.width * transform.scale; layer.lineCap = .round; layer.lineJoin = .round; container.addSublayer(layer)
    }
}
