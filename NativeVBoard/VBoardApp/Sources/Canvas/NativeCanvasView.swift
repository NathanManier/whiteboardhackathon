import SwiftUI
import UIKit

enum CanvasTool: String, CaseIterable, Sendable {
    case navigation, pen, highlighter, select, lasso, objectEraser
}

private enum InputSource: String { case pencil, touch, indirectPointer, mouse, trackpad }
private enum InteractionState: String { case idle = "IDLE", drawing = "DRAWING", panning = "PANNING", pinching = "PINCHING", lassoing = "LASSOING", erasing = "ERASING", selecting = "SELECTING", movingSelection = "MOVING_SELECTION" }

struct NativeCanvasView: UIViewRepresentable {
    let boardID: String
    let document: SVGDocument
    let camera: CameraRect
    let objects: [CanvasObject]
    let importedTransforms: [String: ObjectTransform]
    let composition: SceneComposition
    var onStroke: (UserStroke) -> Void = { _ in }
    var tool: CanvasTool = .pen
    var onSelectionChanged: (Set<String>) -> Void = { _ in }
    var onMove: (String, CGPoint) -> Void = { _, _ in }
    var onDelete: (Set<String>) -> Void = { _ in }
    var onCameraChanged: (CameraRect) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}

    func makeUIView(context: Context) -> InfiniteCanvasUIView {
        InfiniteCanvasUIView(boardID: boardID, document: document, camera: camera,
                             objects: objects, importedTransforms: importedTransforms,
                             composition: composition, onStroke: onStroke, tool: tool,
                             onSelectionChanged: onSelectionChanged, onMove: onMove, onDelete: onDelete, onCameraChanged: onCameraChanged, onUndo: onUndo, onRedo: onRedo)
    }

    func updateUIView(_ uiView: InfiniteCanvasUIView, context: Context) {
        uiView.update(boardID: boardID, document: document, camera: camera,
                      objects: objects, importedTransforms: importedTransforms,
                      composition: composition, onStroke: onStroke, tool: tool,
                      onSelectionChanged: onSelectionChanged, onMove: onMove, onDelete: onDelete, onCameraChanged: onCameraChanged, onUndo: onUndo, onRedo: onRedo)
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
    private var activeTool: CanvasTool
    private var onSelectionChanged: (Set<String>) -> Void
    private var onMove: (String, CGPoint) -> Void
    private var onDelete: (Set<String>) -> Void
    private var onCameraChanged: (CameraRect) -> Void
    private var onUndo: () -> Void
    private var onRedo: () -> Void
    private var selectedIDs = Set<String>()
    private var editStart = CGPoint.zero
    private var lastEditPoint = CGPoint.zero
    private var lassoWorldPoints: [CGPoint] = []
    private let interactionLayer = CAShapeLayer()
    private var boardID: String
    private var document: SVGDocument
    private var controller: CameraController
    private var objects: [CanvasObject]
    private var importedTransforms: [String: ObjectTransform]
    private var composition: SceneComposition
    private var panStart = CGPoint.zero
    private var panStartCamera = CameraRect(x: 0, y: 0, width: 1, height: 1)
    private var panGesture: UIPanGestureRecognizer!
    private var isSpacePressed = false
    private var interactionState: InteractionState = .idle
    private var activeInputSource: InputSource = .touch
    private var eraseIDs = Set<String>()
    #if DEBUG
    private let perfLabel = UILabel()
    private var lastRenderStats: RenderStats?
    private let crosshairLayer = CAShapeLayer()
    #endif

    init(boardID: String, document: SVGDocument, camera: CameraRect,
         objects: [CanvasObject] = [], importedTransforms: [String: ObjectTransform] = [:],
         composition: SceneComposition, onStroke: @escaping (UserStroke) -> Void = { _ in },
         tool: CanvasTool = .pen, onSelectionChanged: @escaping (Set<String>) -> Void = { _ in },
         onMove: @escaping (String, CGPoint) -> Void = { _, _ in }, onDelete: @escaping (Set<String>) -> Void = { _ in }, onCameraChanged: @escaping (CameraRect) -> Void = { _ in }, onUndo: @escaping () -> Void = {}, onRedo: @escaping () -> Void = {}) {
        self.boardID = boardID; self.document = document; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition
        self.onStroke = onStroke
        self.activeTool = tool; self.onSelectionChanged = onSelectionChanged
        self.onMove = onMove; self.onDelete = onDelete; self.onCameraChanged = onCameraChanged; self.onUndo = onUndo; self.onRedo = onRedo
        controller = CameraController(camera: camera)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        isMultipleTouchEnabled = true
        clipsToBounds = true
        userLayer.anchorPoint = .zero
        userLayer.position = .zero
        layer.addSublayer(userLayer)
        interactionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        interactionLayer.strokeColor = UIColor.systemBlue.cgColor; interactionLayer.lineWidth = 2
        interactionLayer.lineDashPattern = [6, 4]; interactionLayer.isHidden = true
        layer.addSublayer(interactionLayer)
        #if DEBUG
        crosshairLayer.strokeColor = UIColor.systemPink.cgColor
        crosshairLayer.fillColor = UIColor.clear.cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.isHidden = true
        layer.addSublayer(crosshairLayer)
        #endif
        #if DEBUG
        professor.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.updatePerformanceOverlay(stats) }
        }
        #endif
        addSubview(professor)
        // ProfessorSVGView is a render-only subview. If it participates in
        // hit-testing, the parent never receives the simulator mouse/Pencil
        // stream and every editing tool appears inert.
        professor.isUserInteractionEnabled = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pan.allowedScrollTypesMask = .all
        pan.cancelsTouchesInView = false
        pan.delegate = self; panGesture = pan; addGestureRecognizer(pan)
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
        updateInputHUD()
        debugViewHierarchy()
        #endif
        becomeFirstResponder()
        NotificationCenter.default.addObserver(self, selector: #selector(clearTransientInput), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        professor.frame = bounds
        userLayer.frame = bounds
        #if DEBUG
        perfLabel.frame = CGRect(x: 8, y: 8, width: 360, height: 112)
        #endif
        applyCamera(interacting: false)
    }

    func update(boardID: String, document: SVGDocument, camera: CameraRect,
                objects: [CanvasObject], importedTransforms: [String: ObjectTransform],
                composition: SceneComposition, onStroke: @escaping (UserStroke) -> Void = { _ in },
                tool: CanvasTool = .pen, onSelectionChanged: @escaping (Set<String>) -> Void = { _ in },
                onMove: @escaping (String, CGPoint) -> Void = { _, _ in }, onDelete: @escaping (Set<String>) -> Void = { _ in }, onCameraChanged: @escaping (CameraRect) -> Void = { _ in }, onUndo: @escaping () -> Void = {}, onRedo: @escaping () -> Void = {}) {
        let documentChanged = self.document != document || self.importedTransforms != importedTransforms
        let objectsChanged = self.objects != objects
        self.boardID = boardID; self.document = document; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition
        self.onStroke = onStroke
        if self.activeTool != tool {
            #if DEBUG
            print("[VBoard] TOOL CHANGED \(self.activeTool.rawValue) -> \(tool.rawValue) board=\(boardID)")
            #endif
        }
        self.activeTool = tool; self.onSelectionChanged = onSelectionChanged
        self.onMove = onMove; self.onDelete = onDelete; self.onCameraChanged = onCameraChanged; self.onUndo = onUndo; self.onRedo = onRedo
        // Hand owns the root touch stream directly because the simulator's
        // indirect-pointer drag is not consistently promoted to a
        // UIPanGestureRecognizer. Other tools keep the recognizer available
        // exclusively for the Space-pan override.
        panGesture.isEnabled = tool != .navigation
        controller.setCamera(camera)
        if documentChanged { professor.display(document, transform: worldTransform, importedTransforms: importedTransforms, composition: composition) }
        if objectsChanged { rebuildUserLayers() }
        applyCamera(interacting: false)
    }

    private var worldTransform: WorldScreenTransform {
        WorldScreenTransform(camera: controller.camera, viewport: bounds.size)
    }

    private func canvasPoint(_ point: CGPoint, from sourceView: UIView?) -> CGPoint {
        guard let sourceView else { return point }
        return sourceView.convert(point, to: self)
    }

    private func worldPoint(_ point: CGPoint, from sourceView: UIView?) -> CGPoint {
        CanvasCoordinateMapper.viewPointToWorld(point, from: sourceView ?? self, in: self, camera: controller.camera)
    }

    private func applyCamera(interacting: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let current = worldTransform
        professor.updateCamera(current, interacting: interacting)
        userLayer.setAffineTransform(current.affineTransform)
        interactionLayer.setAffineTransform(current.affineTransform)
        updateSelectionOverlay()
    }

    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        // Once a pan owns the gesture, continue servicing it through changed
        // and terminal states even if Space is released or SwiftUI changes the
        // selected tool. Otherwise the state machine can remain wedged in
        // PANNING and the terminal camera commit is skipped.
        guard activeTool == .navigation || interactionState == .panning || (isSpacePressed && activeStrokeLayer == nil) else { return }
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            interactionState = .panning; debugInputOperation("PAN BEGIN")
            panStart = translation; panStartCamera = controller.camera; professor.beginNavigation(); debugPan("BEGIN", screen: translation); updateInputHUD()
        case .changed:
            controller.setCamera(panStartCamera)
            controller.pan(screenTranslation: CGPoint(x: translation.x - panStart.x, y: translation.y - panStart.y), viewport: bounds.size)
            applyCamera(interacting: true); debugInputOperation("PAN UPDATE"); debugPan("UPDATE", screen: translation)
        case .ended, .cancelled, .failed:
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; debugInputOperation("PAN END"); debugPan("END"); updateInputHUD()
            panStart = .zero
        default: break
        }
    }

    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: interactionState = .pinching; professor.beginNavigation(); debugInputOperation("PINCH BEGIN"); updateInputHUD()
        case .changed:
            controller.zoom(by: gesture.scale, anchoredAt: gesture.location(in: self), viewport: bounds.size)
            gesture.scale = 1; applyCamera(interacting: true)
        case .ended, .cancelled, .failed:
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; debugInputOperation("PINCH END"); updateInputHUD()
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        return activeTool == .navigation || (isSpacePressed && activeStrokeLayer == nil)
    }

    // Pencil owns direct drawing. Simulator mouse/touch uses the same
    // canonical Stroke model with deterministic pressure=1.
    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        if touch.type == .pencil { return true }
        #if targetEnvironment(simulator)
        return touch.type == .indirectPointer || touch.type == .direct
        #else
        return false
        #endif
    }

    private func source(for touch: UITouch) -> InputSource {
        if touch.type == .pencil { return .pencil }
        #if targetEnvironment(simulator)
        return touch.type == .indirectPointer ? .indirectPointer : .mouse
        #else
        return .touch
        #endif
    }

    #if DEBUG
    private func debugInput(_ phase: String, touch: UITouch) {
        // Indirect-pointer touches can report different `touch.view` values
        // as they cross render sublayers. Always sample in this stable,
        // untransformed root interaction surface instead of mixing child
        // view origins between begin/move/end.
        let raw = touch.location(in: self); let screen = raw; let world = worldPoint(raw, from: self)
        let roundTrip = CanvasCoordinateMapper.worldToViewPoint(world, in: self, camera: controller.camera)
        let error = hypot(roundTrip.x - screen.x, roundTrip.y - screen.y)
        activeInputSource = source(for: touch)
        let windowFrame = self.superview?.convert(self.frame, to: self.window)
        print("[VBoard] INPUT \(phase) source=\(activeInputSource.rawValue) tool=\(activeTool.rawValue) rawPoint=(\(raw.x),\(raw.y)) canvasPoint=(\(screen.x),\(screen.y)) worldPoint=(\(world.x),\(world.y)) roundTrip=(\(roundTrip.x),\(roundTrip.y)) error=\(error) canvasFrame=\(self.frame) canvasFrameInWindow=\(String(describing: windowFrame)) canvasBounds=\(self.bounds) canvasTransform=\(self.transform) professorFrame=\(professor.frame) professorTransform=\(professor.layer.affineTransform()) camera=\(controller.camera) state=\(interactionState.rawValue)")
        if error >= 0.5 { print("[VBoard] ROUND_TRIP_FAILURE error=\(error) raw=\(raw) canvas=\(screen) world=\(world) roundTrip=\(roundTrip)") }
        updateCrosshair(screen: screen, roundTrip: roundTrip)
    }
    private func debugInputOperation(_ operation: String) {
        print("[VBoard] \(operation) tool=\(activeTool.rawValue) state=\(interactionState.rawValue) selected=\(selectedIDs.count)")
    }
    private func debugPan(_ phase: String, screen: CGPoint? = nil) {
        print("[VBoard] PAN \(phase) screen=\(String(describing: screen)) start=\(panStart) camera=\(controller.camera) state=\(interactionState.rawValue)")
    }
    private func debugViewHierarchy() {
        func dump(_ view: UIView, _ depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            print("[VBoard] VIEW_TREE \(indent)\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) transform=\(view.transform) userInteraction=\(view.isUserInteractionEnabled)")
            for child in view.subviews { dump(child, depth + 1) }
        }
        dump(self, 0)
    }
    private func updateInputHUD() {
        renderDebugHUD()
    }
    #else
    private func debugInput(_ phase: String, touch: UITouch) {}
    private func debugInputOperation(_ operation: String) {}
    private func debugPan(_ phase: String, screen: CGPoint? = nil) {}
    private func updateInputHUD() {}
    #endif

    #if DEBUG
    private func updateCrosshair(screen: CGPoint, roundTrip: CGPoint) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: screen.x - 8, y: screen.y)); path.addLine(to: CGPoint(x: screen.x + 8, y: screen.y))
        path.move(to: CGPoint(x: screen.x, y: screen.y - 8)); path.addLine(to: CGPoint(x: screen.x, y: screen.y + 8))
        path.move(to: CGPoint(x: roundTrip.x - 4, y: roundTrip.y)); path.addLine(to: CGPoint(x: roundTrip.x + 4, y: roundTrip.y))
        path.move(to: CGPoint(x: roundTrip.x, y: roundTrip.y - 4)); path.addLine(to: CGPoint(x: roundTrip.x, y: roundTrip.y + 4))
        crosshairLayer.path = path.cgPath; crosshairLayer.isHidden = false
    }
    #endif

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "+", modifierFlags: [.command], action: #selector(zoomInKey)),
         UIKeyCommand(input: "=", modifierFlags: [.command], action: #selector(zoomInKey)),
         UIKeyCommand(input: "-", modifierFlags: [.command], action: #selector(zoomOutKey)),
         UIKeyCommand(input: "0", modifierFlags: [.command], action: #selector(resetZoomKey)),
         UIKeyCommand(input: "z", modifierFlags: [.command], action: #selector(undoKey)),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoKey))]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            isSpacePressed = true
            if interactionState == .idle { updateInputHUD() }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            isSpacePressed = false
            if interactionState == .panning { interactionState = .idle; updateInputHUD() }
        }
        super.pressesEnded(presses, with: event)
    }

    @objc private func clearTransientInput() {
        isSpacePressed = false; interactionState = .idle; activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
        lassoWorldPoints.removeAll(); updateInteractionPath(); updateInputHUD()
    }

    private func applyKeyboardZoom(_ factor: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        controller.zoom(by: factor, anchoredAt: center, viewport: bounds.size)
        applyCamera(interacting: false)
        onCameraChanged(controller.camera)
    }
    @objc private func zoomInKey() { applyKeyboardZoom(1.25) }
    @objc private func zoomOutKey() { applyKeyboardZoom(0.8) }
    @objc private func resetZoomKey() {
        controller.setCamera(CameraRect(x: document.viewBox.minX, y: document.viewBox.minY, width: document.viewBox.width, height: document.viewBox.height))
        applyCamera(interacting: false)
        onCameraChanged(controller.camera)
    }
    @objc private func undoKey() { onUndo() }
    @objc private func redoKey() { onRedo() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        debugInput("BEGIN", touch: touch)
        let point = worldPoint(touch.location(in: self), from: self)
        if activeTool == .navigation {
            let screen = touch.location(in: self)
            panStart = screen; panStartCamera = controller.camera
            interactionState = .panning; professor.beginNavigation(); debugInputOperation("PAN BEGIN"); debugPan("BEGIN", screen: screen); updateInputHUD(); return
        }
        if activeTool != .pen && activeTool != .highlighter { beginEditing(at: point); return }
        guard isDrawingTouch(touch) else { super.touchesBegan(touches, with: event); return }
        interactionState = .drawing; debugInputOperation("STROKE BEGIN"); updateInputHUD()
        activeID = UUID().uuidString; activePoints = samples(for: touch, event: event)
        let layer = CAShapeLayer(); layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = strokeColor.cgColor; layer.lineWidth = strokeWidth
        layer.lineCap = .round; layer.lineJoin = .round; activeStrokeLayer = layer
        updateActiveStroke()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        debugInput("MOVE", touch: touch)
        if activeTool == .navigation {
            let screen = touch.location(in: self)
            controller.setCamera(panStartCamera)
            controller.pan(screenTranslation: CGPoint(x: screen.x - panStart.x, y: screen.y - panStart.y), viewport: bounds.size)
            applyCamera(interacting: true); debugInputOperation("PAN UPDATE"); debugPan("UPDATE", screen: screen); return
        }
        if activeTool != .pen && activeTool != .highlighter { continueEditing(at: worldPoint(touch.location(in: self), from: self)); return }
        guard isDrawingTouch(touch) else { return }
        activePoints.append(contentsOf: samples(for: touch, event: event)); updateActiveStroke(); debugInputOperation("STROKE APPEND")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        debugInput("END", touch: touch)
        if activeTool == .navigation {
            // The Mac/iPad simulator may coalesce an indirect-pointer drag
            // into only BEGIN/END callbacks. Derive the final camera from the
            // immutable pan-start state and the root-space endpoint so that
            // this path remains deterministic and never depends on MOVE
            // delivery frequency.
            let screen = touch.location(in: self)
            controller.setCamera(panStartCamera)
            controller.pan(screenTranslation: CGPoint(x: screen.x - panStart.x, y: screen.y - panStart.y), viewport: bounds.size)
            professor.endNavigation(worldTransform); applyCamera(interacting: false); onCameraChanged(controller.camera)
            interactionState = .idle; panStart = .zero; debugInputOperation("PAN END"); debugPan("END", screen: screen); updateInputHUD(); return
        }
        if activeTool != .pen && activeTool != .highlighter {
            finishEditing(at: worldPoint(touch.location(in: self), from: self)); return
        }
        guard isDrawingTouch(touch) else { return }
        activePoints.append(contentsOf: samples(for: touch, event: event))
        if let activeID, !activePoints.isEmpty {
            onStroke(UserStroke(id: activeID, color: strokeColorHex, width: strokeWidth, opacity: strokeOpacity, points: activePoints))
            debugInputOperation("STROKE FINALIZE")
        }
        activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
        activePoints.removeAll(); activeID = nil; interactionState = .idle; updateInputHUD()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTool == .navigation {
            professor.endNavigation(worldTransform); interactionState = .idle; panStart = .zero; updateInputHUD(); return
        }
        if activeTool != .pen && activeTool != .highlighter { finishEditing(at: nil); return }
        if touches.contains(where: { isDrawingTouch($0) }) {
            activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
            activePoints.removeAll(); activeID = nil
        }
    }

    private func beginEditing(at point: CGPoint) {
        editStart = point; lastEditPoint = point
        if activeTool == .navigation {
            interactionState = .panning
            return
        } else if activeTool == .lasso {
            interactionState = .lassoing; lassoWorldPoints = [point]; debugInputOperation("LASSO BEGIN"); updateInteractionPath()
        } else if activeTool == .objectEraser {
            interactionState = .erasing; eraseIDs.removeAll(); eraseSegment(from: point, to: point); debugInputOperation("ERASER BEGIN")
        } else if activeTool == .select {
            selectedIDs = hitTestIDs(at: point)
            interactionState = selectedIDs.isEmpty ? .idle : .selecting
            #if DEBUG
            print("[VBoard] SELECT HIT ids=\(Array(selectedIDs))")
            print("[VBoard] SELECTION_CHANGED count=\(selectedIDs.count) ids=\(Array(selectedIDs))")
            #endif
            onSelectionChanged(selectedIDs); updateSelectionOverlay(); updateInputHUD()
        }
    }

    private func continueEditing(at point: CGPoint) {
        switch activeTool {
        case .navigation:
            break
        case .lasso:
            lassoWorldPoints.append(point); updateInteractionPath(); debugInputOperation("LASSO UPDATE")
        case .select:
            let delta = CGPoint(x: point.x - lastEditPoint.x, y: point.y - lastEditPoint.y)
            if !selectedIDs.isEmpty, (delta.x != 0 || delta.y != 0) {
                interactionState = .movingSelection; debugInputOperation("MOVE UPDATE")
                for id in selectedIDs { onMove(id, delta) }
            }
        case .objectEraser: eraseSegment(from: lastEditPoint, to: point); debugInputOperation("ERASER SEGMENT")
        case .pen, .highlighter: break
        }
        lastEditPoint = point
    }

    private func finishEditing(at endpoint: CGPoint?) {
        if activeTool == .lasso, let endpoint, lassoWorldPoints.count == 1 { lassoWorldPoints.append(endpoint) }
        if activeTool == .lasso, lassoWorldPoints.count >= 2 {
            // A simulator drag is delivered as a begin/end pair by the Mac
            // automation layer. Treat that two-point gesture as the natural
            // rectangular lasso fallback; Pencil and touch still provide a
            // free-form polygon with every move sample.
            let polygon: [CGPoint]
            if lassoWorldPoints.count == 2 {
                let a = lassoWorldPoints[0], b = lassoWorldPoints[1]
                polygon = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y)]
            } else { polygon = lassoWorldPoints }
            let bounds = polygon.reduce(into: CGRect.null) { result, point in result = result.union(CGRect(x: point.x, y: point.y, width: 0, height: 0)) }
            let selected = Set(objects.filter { object in
                let points = object.points?.map { CGPoint(x: $0.x + (object.translation?.x ?? 0), y: $0.y + (object.translation?.y ?? 0)) } ?? []
                guard !points.isEmpty, points.contains(where: { bounds.contains($0) }) else { return false }
                let inside = points.filter { polygonContains($0, polygon: polygon) }.count
                return Double(inside) / Double(points.count) >= 0.65
            }.map(\.id))
            let professorIDs = professor.ids(intersecting: bounds)
            selectedIDs = selected.union(professorIDs); onSelectionChanged(selectedIDs); updateSelectionOverlay()
            #if DEBUG
            print("[VBoard] LASSO CANDIDATES objects=\(selected.count) professor=\(professorIDs.count)")
            print("[VBoard] SELECTION_CHANGED count=\(selectedIDs.count) ids=\(Array(selectedIDs))")
            #endif
            debugInputOperation("LASSO FINALIZE")
        }
        lassoWorldPoints.removeAll(); interactionState = .idle; updateInteractionPath(); updateInputHUD()
    }

    private func eraseSegment(from start: CGPoint, to end: CGPoint) {
        let segmentBounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -14, dy: -14)
        var hit = Set(objects.compactMap { object -> String? in
            let points = object.points?.map { CGPoint(x: $0.x + (object.translation?.x ?? 0), y: $0.y + (object.translation?.y ?? 0)) } ?? []
            if let x = object.x, let y = object.y { return segmentBounds.intersects(CGRect(x: x, y: y, width: object.width ?? 400, height: object.height ?? 100)) ? object.id : nil }
            guard let first = points.first else { return nil }
            let objectBounds = points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 0, height: 0)) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0)) }.insetBy(dx: -12, dy: -12)
            return segmentBounds.intersects(objectBounds) ? object.id : nil
        })
        hit.formUnion(professor.ids(intersecting: segmentBounds))
        let fresh = hit.subtracting(eraseIDs)
        guard !fresh.isEmpty else { return }
        eraseIDs.formUnion(fresh); selectedIDs.formUnion(fresh); onDelete(fresh); onSelectionChanged(selectedIDs)
        #if DEBUG
        print("[VBoard] ERASER HITS ids=\(Array(fresh))")
        #endif
    }

    private func hitTestIDs(at point: CGPoint) -> Set<String> {
        var result = Set(objects.compactMap { object in
            let points = object.points?.map { CGPoint(x: $0.x + (object.translation?.x ?? 0), y: $0.y + (object.translation?.y ?? 0)) } ?? []
            if object.type == "text", let x = object.x, let y = object.y { return CGRect(x: x, y: y, width: object.width ?? 400, height: object.height ?? 100).contains(point) ? object.id : nil }
            guard let first = points.first else { return nil }
            let bounds = points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 0, height: 0)) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0)) }.insetBy(dx: -12, dy: -12)
            return bounds.contains(point) ? object.id : nil
        })
        if let professorID = professor.hitTest(point) { result.insert(professorID) }
        return result
    }

    private func updateInteractionPath() {
        guard !lassoWorldPoints.isEmpty else { interactionLayer.isHidden = true; return }
        let path = UIBezierPath(); for (index, point) in lassoWorldPoints.enumerated() { if index == 0 { path.move(to: point) } else { path.addLine(to: point) } }
        interactionLayer.path = path.cgPath; interactionLayer.isHidden = false
    }

    private func updateSelectionOverlay() {
        guard !selectedIDs.isEmpty else { interactionLayer.isHidden = lassoWorldPoints.isEmpty; return }
        var bounds = CGRect.null
        for object in objects where selectedIDs.contains(object.id) {
            let points = object.points?.map { CGPoint(x: $0.x + (object.translation?.x ?? 0), y: $0.y + (object.translation?.y ?? 0)) } ?? []
            if let first = points.first { bounds = bounds.union(points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 0, height: 0)) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0)) }) }
            if let x = object.x, let y = object.y { bounds = bounds.union(CGRect(x: x, y: y, width: object.width ?? 400, height: object.height ?? 100)) }
        }
        for id in selectedIDs { bounds = bounds.union(professor.bounds(for: id)) }
        guard !bounds.isNull else { return }
        interactionLayer.path = UIBezierPath(rect: bounds.insetBy(dx: -10, dy: -10)).cgPath; interactionLayer.isHidden = false
    }

    private func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        for i in polygon.indices {
            let j = i == polygon.startIndex ? polygon.index(before: polygon.endIndex) : polygon.index(before: i)
            let a = polygon[i], b = polygon[j]
            let denominator = b.y - a.y
            if abs(denominator) > CGFloat.ulpOfOne,
               ((a.y > point.y) != (b.y > point.y)),
               point.x < (b.x - a.x) * (point.y - a.y) / denominator + a.x { inside.toggle() }
        }
        return inside
    }

    private func samples(for touch: UITouch, event: UIEvent?) -> [StrokePoint] {
        let source = event?.coalescedTouches(for: touch) ?? [touch]
        return source.map { item in
            let point = worldPoint(item.location(in: item.view ?? self), from: item.view ?? self)
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

    private var strokeColorHex: String { activeTool == .highlighter ? "#FFD60A" : "#183153" }
    private var strokeColor: UIColor { UIColor(svgHex: strokeColorHex).withAlphaComponent(CGFloat(strokeOpacity)) }
    private var strokeWidth: CGFloat { activeTool == .highlighter ? 22 : 4 }
    private var strokeOpacity: Double { activeTool == .highlighter ? 0.32 : 1 }

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
        lastRenderStats = stats
        renderDebugHUD()
    }

    private func renderDebugHUD() {
        var text = "Tool: \(activeTool.rawValue)\nInput: \(activeInputSource.rawValue)\nState: \(interactionState.rawValue)  Selected: \(selectedIDs.count) Space: \(isSpacePressed)\nCamera: x=\(Int(controller.camera.x)) y=\(Int(controller.camera.y)) w=\(Int(controller.camera.width)) h=\(Int(controller.camera.height))"
        if let stats = lastRenderStats { text += "\n" + stats.overlayText }
        perfLabel.text = text
    }
    #endif
}
