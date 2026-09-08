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
    private var document: SVGDocument
    private var controller: CameraController
    private var panStart = CGPoint.zero

    init(document: SVGDocument, camera: CameraRect) {
        self.document = document; controller = CameraController(camera: camera)
        super.init(frame: .zero); backgroundColor = .systemBackground; addSubview(professor)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:))); pan.minimumNumberOfTouches = 1; addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:))); addGestureRecognizer(pinch)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); professor.frame = bounds; render() }
    func update(document: SVGDocument, camera: CameraRect) { self.document = document; controller = CameraController(camera: camera); render() }
    @objc private func didPan(_ gesture: UIPanGestureRecognizer) { let translation = gesture.translation(in: self); if gesture.state == .began { panStart = translation }; controller.pan(screenTranslation: CGPoint(x: translation.x - panStart.x, y: translation.y - panStart.y), viewport: bounds.size); panStart = translation; render() }
    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) { guard gesture.state == .changed else { return }; controller.zoom(by: gesture.scale, anchoredAt: gesture.location(in: self), viewport: bounds.size); gesture.scale = 1; render() }
    private func render() { guard bounds.width > 0, bounds.height > 0 else { return }; professor.display(document, transform: WorldScreenTransform(camera: controller.camera, viewport: bounds.size)) }
}
