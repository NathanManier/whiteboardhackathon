import SwiftUI
import UIKit

enum CanvasTool: String, CaseIterable, Sendable {
    case navigation, pen, highlighter, select, lasso, objectEraser
}

struct CanvasStrokeStyle: Equatable, Sendable {
    var colorHex: String
    var width: Double
    var opacity: Double

    static let pen = CanvasStrokeStyle(colorHex: "#183153", width: 4, opacity: 1)
    static let marker = CanvasStrokeStyle(colorHex: "#FFD60A", width: 22, opacity: 0.32)
}

private enum InputSource: String { case pencil, touch, indirectPointer, mouse, trackpad }
private enum InteractionState: String { case idle = "IDLE", drawing = "DRAWING", panning = "PANNING", pinching = "PINCHING", lassoing = "LASSOING", erasing = "ERASING", selecting = "SELECTING", movingSelection = "MOVING_SELECTION" }

struct NativeCanvasView: UIViewRepresentable {
    let boardID: String
    let document: SVGDocument
    let pdfData: Data?
    let camera: CameraRect
    let objects: [CanvasObject]
    let importedTransforms: [String: ObjectTransform]
    let composition: SceneComposition
    var showsPaper = true
    var backgroundStyle = WorkspaceBackgroundStyle.dots
    var penStyle = CanvasStrokeStyle.pen
    var markerStyle = CanvasStrokeStyle.marker
    var onStroke: (UserStroke) -> Void = { _ in }
    var tool: CanvasTool = .pen
    var onSelectionChanged: (Set<String>) -> Void = { _ in }
    var onSelectionRegionChanged: (CGRect?) -> Void = { _ in }
    var onMove: (Set<String>, CGPoint) -> Void = { _, _ in }
    var onDelete: (Set<String>) -> Void = { _ in }
    var onCameraChanged: (CameraRect) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}

    func makeUIView(context: Context) -> InfiniteCanvasUIView {
        InfiniteCanvasUIView(boardID: boardID, document: document, pdfData: pdfData, camera: camera,
                             objects: objects, importedTransforms: importedTransforms,
                             composition: composition, showsPaper: showsPaper, backgroundStyle: backgroundStyle,
                             penStyle: penStyle, markerStyle: markerStyle,
                             onStroke: onStroke, tool: tool,
                             onSelectionChanged: onSelectionChanged, onSelectionRegionChanged: onSelectionRegionChanged, onMove: onMove, onDelete: onDelete, onCameraChanged: onCameraChanged, onUndo: onUndo, onRedo: onRedo)
    }

    func updateUIView(_ uiView: InfiniteCanvasUIView, context: Context) {
        uiView.update(boardID: boardID, document: document, pdfData: pdfData, camera: camera,
                      objects: objects, importedTransforms: importedTransforms,
                      composition: composition, showsPaper: showsPaper, backgroundStyle: backgroundStyle,
                      penStyle: penStyle, markerStyle: markerStyle,
                      onStroke: onStroke, tool: tool,
                      onSelectionChanged: onSelectionChanged, onSelectionRegionChanged: onSelectionRegionChanged, onMove: onMove, onDelete: onDelete, onCameraChanged: onCameraChanged, onUndo: onUndo, onRedo: onRedo)
    }
}

/// UIKit owns the high-frequency input and layer composition. World-space
/// content is transformed as one GPU-composited layer; expensive visibility
/// refinement only runs after a gesture ends.
final class InfiniteCanvasUIView: UIView, UIGestureRecognizerDelegate {
    private let gridLayer = CAShapeLayer()
    /// The root view is intentionally never camera-transformed. It owns the
    /// input stream and stays in the same coordinate space as UIKit events.
    /// Every world-space layer is a descendant of this single container so a
    /// CameraRect change moves the visible pixels, not just the culling set.
    private let worldContainer = UIView()
    private let pdfSource = PDFPageRenderView()
    private let professor = ProfessorSVGView()
    private let userLayer = CALayer()
    private let paperLayer = CAShapeLayer()
    private var userObjectLayers: [String: CALayer] = [:]
    private var strokeLayers: [String: CALayer] = [:]
    private var activeStrokeLayer: CAShapeLayer?
    private(set) var userStrokes: [UserStroke] = []
    private var activePoints: [StrokePoint] = []
    private var predictedPoints: [StrokePoint] = []
    private var lastPencilPressure: CGFloat?
    private var activeID: String?
    private var onStroke: (UserStroke) -> Void
    private var activeTool: CanvasTool
    private var onSelectionChanged: (Set<String>) -> Void
    private var onSelectionRegionChanged: (CGRect?) -> Void
    private var onMove: (Set<String>, CGPoint) -> Void
    private var onDelete: (Set<String>) -> Void
    private var onCameraChanged: (CameraRect) -> Void
    private var onUndo: () -> Void
    private var onRedo: () -> Void
    private var selectedIDs = Set<String>()
    private var editStart = CGPoint.zero
    private var editStartScreen = CGPoint.zero
    private var lastEditPoint = CGPoint.zero
    private var moveDelta = CGPoint.zero
    private var moveActive = false
    private var lassoWorldPoints: [CGPoint] = []
    private let interactionLayer = CAShapeLayer()
    private var boardID: String
    private var document: SVGDocument
    private var pdfData: Data?
    private var controller: CameraController
    private var cameraInitializedForBoardID: String?
    private var persistedCamera: CameraRect
    private var lastAppliedCamera: CameraRect?
    private var objects: [CanvasObject]
    private var importedTransforms: [String: ObjectTransform]
    private var composition: SceneComposition
    private var showsPaper: Bool
    private var backgroundStyle: WorkspaceBackgroundStyle
    private var penStyle: CanvasStrokeStyle
    private var markerStyle: CanvasStrokeStyle
    private var panStart = CGPoint.zero
    private var panStartCamera = CameraRect(x: 0, y: 0, width: 1, height: 1)
    private var panGesture: UIPanGestureRecognizer!
    private var isSpacePressed = false
    private var interactionState: InteractionState = .idle
    private var activeInputSource: InputSource = .touch
    private var eraseIDs = Set<String>()
    private var pinchStartCamera = CameraRect(x: 0, y: 0, width: 1, height: 1)
    private var pinchStartMidpoint = CGPoint.zero
    #if DEBUG
    private let perfLabel = UILabel()
    private var lastRenderStats: RenderStats?
    private let crosshairLayer = CAShapeLayer()
    private var lastCameraMutationReason: CameraMutationReason?
    #endif

    init(boardID: String, document: SVGDocument, pdfData: Data? = nil, camera: CameraRect,
         objects: [CanvasObject] = [], importedTransforms: [String: ObjectTransform] = [:],
         composition: SceneComposition, showsPaper: Bool = true,
         backgroundStyle: WorkspaceBackgroundStyle = .dots,
         penStyle: CanvasStrokeStyle = .pen, markerStyle: CanvasStrokeStyle = .marker,
         onStroke: @escaping (UserStroke) -> Void = { _ in },
         tool: CanvasTool = .pen, onSelectionChanged: @escaping (Set<String>) -> Void = { _ in },
         onSelectionRegionChanged: @escaping (CGRect?) -> Void = { _ in },
         onMove: @escaping (Set<String>, CGPoint) -> Void = { _, _ in }, onDelete: @escaping (Set<String>) -> Void = { _ in }, onCameraChanged: @escaping (CameraRect) -> Void = { _ in }, onUndo: @escaping () -> Void = {}, onRedo: @escaping () -> Void = {}) {
        self.boardID = boardID; self.document = document; self.pdfData = pdfData; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition; self.showsPaper = showsPaper
        self.penStyle = penStyle; self.markerStyle = markerStyle
        self.backgroundStyle = backgroundStyle
        self.onStroke = onStroke
        self.activeTool = tool; self.onSelectionChanged = onSelectionChanged
        self.onSelectionRegionChanged = onSelectionRegionChanged
        self.onMove = onMove; self.onDelete = onDelete; self.onCameraChanged = onCameraChanged; self.onUndo = onUndo; self.onRedo = onRedo
        controller = CameraController(camera: camera)
        persistedCamera = camera
        super.init(frame: .zero)
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1)
                : UIColor(red: 0.965, green: 0.968, blue: 0.972, alpha: 1)
        }
        isMultipleTouchEnabled = true
        clipsToBounds = true
        gridLayer.fillColor = UIColor.clear.cgColor
        gridLayer.lineWidth = 1
        gridLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(gridLayer)
        worldContainer.backgroundColor = .clear
        worldContainer.clipsToBounds = false
        worldContainer.isUserInteractionEnabled = false
        worldContainer.layer.anchorPoint = .zero
        worldContainer.layer.position = .zero
        userLayer.anchorPoint = .zero
        userLayer.position = .zero
        WorldOverlayLayerLayout.pin(interactionLayer, to: worldContainer.bounds)
        paperLayer.anchorPoint = .zero
        paperLayer.position = .zero
        paperLayer.fillColor = boardSurfaceColor(showsPaper: showsPaper).cgColor
        paperLayer.strokeColor = boardBoundaryColor().cgColor
        paperLayer.lineWidth = 1.25
        paperLayer.name = "VBoardPaper"
        pdfSource.layer.name = "VBoardPDFSource"
        professor.layer.name = "VBoardProfessorSource"
        userLayer.name = "VBoardUserContent"
        interactionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        interactionLayer.strokeColor = UIColor.systemBlue.cgColor; interactionLayer.lineWidth = 2
        interactionLayer.lineDashPattern = [6, 4]; interactionLayer.isHidden = true
        // This is a world-space diagnostic/selection overlay. It is kept in
        // the world container so it follows the exact same camera transform
        // as paper, professor ink, and user content. It is non-interactive
        // and therefore can never become an input-coordinate reference.
        worldContainer.layer.addSublayer(interactionLayer)
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
        addSubview(worldContainer)
        // The paper is the bottom-most board source. Keeping it inside the
        // user layer placed an opaque rectangle above PDF/professor content,
        // which explained why reopened imported boards showed annotations but
        // not their source page.
        worldContainer.layer.addSublayer(paperLayer)
        worldContainer.addSubview(pdfSource)
        worldContainer.addSubview(professor)
        worldContainer.layer.addSublayer(userLayer)
        worldContainer.layer.addSublayer(interactionLayer)
        // ProfessorSVGView is a render-only subview. If it participates in
        // hit-testing, the parent never receives the simulator mouse/Pencil
        // stream and every editing tool appears inert.
        professor.isUserInteractionEnabled = false
        if let pdfData { pdfSource.display(data: pdfData) }
        else { pdfSource.isHidden = true }
        if pdfData != nil {
            PDFBoardSource.apply(transform: importedTransforms[PDFBoardSource.logicalID], to: pdfSource)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pan.allowedScrollTypesMask = .all
        pan.cancelsTouchesInView = false
        pan.delegate = self; panGesture = pan; addGestureRecognizer(pan)
        #if targetEnvironment(simulator)
        // Simulator pointer drags are owned by the root touch overrides
        // below. Keeping the recognizer enabled at the same time lets UIKit
        // compete for the same stream and can produce a partial/teleporting
        // pan. Physical-device gesture routing remains available.
        panGesture.isEnabled = false
        #endif
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:)))
        pinch.delegate = self; addGestureRecognizer(pinch)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: InfiniteCanvasUIView, _) in
            view.updateWorkspaceBackground()
        }
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
        // Build the immutable professor layer as part of the initial scene.
        // The first SwiftUI update can be a no-op when its value types are
        // unchanged, so relying on updateUIView alone leaves an empty SVG
        // renderer and shows only cached/user scribbles.
        professor.display(document, transform: worldTransform,
                          importedTransforms: importedTransforms,
                          composition: composition)
        #if DEBUG
        print("[VBoard] BLUE RECTANGLE SOURCE layer=interactionLayer owner=InfiniteCanvasUIView.worldContainer coordinateSpace=world purpose=lasso-and-selection-overlay interactive=false")
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(clearTransientInput), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var sourceLayerOrderForTesting: [String] {
        worldContainer.layer.sublayers?.compactMap(\.name) ?? []
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gridLayer.frame = bounds
        // Never assign `frame` to a transformed layer. Establish the stable
        // untransformed geometry first, then apply the camera transform in
        // `applyCamera`.
        worldContainer.bounds = CGRect(origin: .zero, size: bounds.size)
        worldContainer.layer.position = .zero
        professor.frame = worldContainer.bounds
        pdfSource.bounds = CGRect(origin: .zero, size: document.viewBox.size)
        pdfSource.layer.position = document.viewBox.origin
        userLayer.bounds = worldContainer.bounds
        userLayer.position = .zero
        paperLayer.bounds = worldContainer.bounds
        paperLayer.position = .zero
        WorldOverlayLayerLayout.pin(interactionLayer, to: worldContainer.bounds)
        #if DEBUG
        perfLabel.frame = CGRect(x: 8, y: 8, width: 360, height: 112)
        #endif
        resolveInitialCameraIfNeeded()
        applyCamera(interacting: false)
    }

    func update(boardID: String, document: SVGDocument, pdfData: Data? = nil, camera: CameraRect,
                objects: [CanvasObject], importedTransforms: [String: ObjectTransform],
                composition: SceneComposition, showsPaper: Bool = true,
                backgroundStyle: WorkspaceBackgroundStyle = .dots,
                penStyle: CanvasStrokeStyle = .pen, markerStyle: CanvasStrokeStyle = .marker,
                onStroke: @escaping (UserStroke) -> Void = { _ in },
                tool: CanvasTool = .pen, onSelectionChanged: @escaping (Set<String>) -> Void = { _ in },
                onSelectionRegionChanged: @escaping (CGRect?) -> Void = { _ in },
                onMove: @escaping (Set<String>, CGPoint) -> Void = { _, _ in }, onDelete: @escaping (Set<String>) -> Void = { _ in }, onCameraChanged: @escaping (CameraRect) -> Void = { _ in }, onUndo: @escaping () -> Void = {}, onRedo: @escaping () -> Void = {}) {
        let boardChanged = self.boardID != boardID
        let documentChanged = self.document != document || self.importedTransforms != importedTransforms
        let pdfChanged = self.pdfData != pdfData
        let objectsChanged = self.objects != objects
        self.boardID = boardID; self.document = document; self.pdfData = pdfData; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition; self.showsPaper = showsPaper
        self.penStyle = penStyle; self.markerStyle = markerStyle
        self.backgroundStyle = backgroundStyle
        paperLayer.fillColor = boardSurfaceColor(showsPaper: showsPaper).cgColor
        paperLayer.strokeColor = boardBoundaryColor().cgColor
        updateWorkspaceBackground()
        if boardChanged {
            persistedCamera = camera
            cameraInitializedForBoardID = nil
            lastAppliedCamera = nil
            setCamera(camera, reason: .restorePersistedViewport)
        }
        self.onStroke = onStroke
        if self.activeTool != tool {
            #if DEBUG
            print("[VBoard] TOOL CHANGED \(self.activeTool.rawValue) -> \(tool.rawValue) board=\(boardID)")
            #endif
        }
        self.activeTool = tool; self.onSelectionChanged = onSelectionChanged
        self.onSelectionRegionChanged = onSelectionRegionChanged
        self.onMove = onMove; self.onDelete = onDelete; self.onCameraChanged = onCameraChanged; self.onUndo = onUndo; self.onRedo = onRedo
        // Hand and simulator Space-pan own the root touch stream directly.
        // This keeps one camera owner for indirect-pointer drags; physical
        // devices retain the recognizer path below.
        #if targetEnvironment(simulator)
        panGesture.isEnabled = false
        #else
        panGesture.isEnabled = tool != .navigation
        #endif
        updateInputHUD()
        // `camera` is the store's persisted snapshot. It is consumed only
        // when a board identity changes; ordinary SwiftUI refreshes must not
        // overwrite the live camera after a pan or zoom.
        if documentChanged { professor.display(document, transform: worldTransform, importedTransforms: importedTransforms, composition: composition) }
        if pdfChanged {
            if let pdfData { pdfSource.display(data: pdfData); pdfSource.isHidden = false }
            else { pdfSource.clear(); pdfSource.isHidden = true }
        }
        if pdfData != nil {
            PDFBoardSource.apply(transform: importedTransforms[PDFBoardSource.logicalID], to: pdfSource)
        } else {
            pdfSource.isHidden = true
        }
        if objectsChanged { rebuildUserLayers() }
        resolveInitialCameraIfNeeded()
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
        #if DEBUG
        let previousWorldTransform = worldContainer.layer.affineTransform()
        let previousCamera = lastAppliedCamera
        #endif
        paperLayer.path = UIBezierPath(rect: document.viewBox).cgPath
        // CameraRect is the single source of truth. The world container is
        // the only node that receives the camera transform; descendants keep
        // canonical world-space geometry and are moved as one composited
        // surface by Core Animation.
        worldContainer.layer.setAffineTransform(current.affineTransform)
        updateWorkspaceBackground()
        professor.updateCamera(current, interacting: interacting)
        userLayer.setAffineTransform(.identity)
        interactionLayer.setAffineTransform(.identity)
        updateSelectionOverlay()
        lastAppliedCamera = controller.camera
        #if DEBUG
        let visible = current.camera.cgRect
        let reason = lastCameraMutationReason?.rawValue ?? "unspecified"
        assert(self.transform == .identity, "Root canvas must remain untransformed")
        assert(worldContainer.layer.affineTransform() == current.affineTransform, "World container transform must equal CameraRect transform")
        assert(interactionLayer.affineTransform() == .identity, "World overlay must not receive a second camera transform")
        print("[VBoard] CAMERA APPLY reason=\(reason) interacting=\(interacting) camera=\(controller.camera) previousCamera=\(String(describing: previousCamera)) worldTransformOld=\(String(describing: previousWorldTransform)) worldTransformNew=\(worldContainer.layer.affineTransform()) worldContainerFrame=\(worldContainer.frame) worldContainerBounds=\(worldContainer.bounds) worldContainerPosition=\(worldContainer.layer.position) visibleWorldRect=\(visible)")
        #endif
    }

    private func updateWorkspaceBackground() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        gridLayer.isHidden = backgroundStyle == .blank
        guard backgroundStyle != .blank else { gridLayer.path = nil; return }
        let transform = worldTransform
        let worldSpacing = WorkspaceDotFieldPolicy.worldSpacing(forScale: transform.scale)
        let spacing = max(worldSpacing * transform.scale, 1)
        let origin = transform.screenPoint(for: .zero)
        let firstX = origin.x.truncatingRemainder(dividingBy: spacing)
        let firstY = origin.y.truncatingRemainder(dividingBy: spacing)
        let path = UIBezierPath()
        let radius: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.8 : 0.7
        var x = firstX - spacing
        while x <= bounds.maxX + spacing {
            var y = firstY - spacing
            while y <= bounds.maxY + spacing {
                path.append(UIBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius,
                                                        width: radius * 2, height: radius * 2)))
                y += spacing
            }
            x += spacing
        }
        gridLayer.fillColor = workspaceGridColor(alpha: WorkspaceDotFieldPolicy.opacity(forScale: transform.scale)).cgColor
        gridLayer.strokeColor = UIColor.clear.cgColor
        gridLayer.path = path.cgPath
    }

    private func boardSurfaceColor(showsPaper: Bool) -> UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return showsPaper
                    ? UIColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1)
                    : UIColor(red: 0.09, green: 0.095, blue: 0.105, alpha: 1)
            }
            return showsPaper
                ? UIColor(red: 0.982, green: 0.982, blue: 0.975, alpha: 1)
                : UIColor(red: 0.972, green: 0.974, blue: 0.973, alpha: 1)
        }
    }

    private func boardBoundaryColor() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.30)
                : UIColor(red: 0.25, green: 0.29, blue: 0.32, alpha: 0.42)
        }
    }

    private func workspaceGridColor(alpha: CGFloat) -> UIColor {
        traitCollection.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(alpha)
            : UIColor(red: 0.18, green: 0.25, blue: 0.32, alpha: alpha)
    }

    private func resolveInitialCameraIfNeeded() {
        guard bounds.width > 0, bounds.height > 0, cameraInitializedForBoardID != boardID else { return }
        var contentBounds = document.viewBox
        for object in objects {
            contentBounds = contentBounds.union(BoardHitTestPolicy.bounds(of: object))
        }
        let resolution = CameraResolver.resolve(persisted: persistedCamera, boardRect: document.viewBox, contentBounds: contentBounds, viewport: bounds.size)
        let cameraWasCorrected = resolution.camera != controller.camera
        if cameraWasCorrected { setCamera(resolution.camera, reason: resolution.reason ?? .restorePersistedViewport) }
        cameraInitializedForBoardID = boardID
        if cameraWasCorrected, resolution.reason == .boardInitialFit {
            // Persist the one-time correction without publishing SwiftUI
            // state from inside layoutSubviews. The live UIKit camera is
            // already correct; this callback only updates the store/outbox so
            // the next open starts from the same stable viewport.
            let resolvedBoardID = boardID
            let resolvedCamera = resolution.camera
            DispatchQueue.main.async { [weak self] in
                guard let self, self.boardID == resolvedBoardID,
                      self.cameraInitializedForBoardID == resolvedBoardID else { return }
                self.onCameraChanged(resolvedCamera)
            }
        }
        #if DEBUG
        print("[VBoard] BOARD OPEN CAMERA board=\(boardID) boardRect=\(document.viewBox) saved=\(persistedCamera) resolved=\(resolution.camera) reason=\(String(describing: resolution.reason)) canvas=\(bounds)")
        #endif
    }

    private func setCamera(_ camera: CameraRect, reason: CameraMutationReason) {
        let old = controller.camera
        controller.setCamera(camera)
        #if DEBUG
        if old != camera {
            lastCameraMutationReason = reason
            print("[VBoard] CAMERA MUTATION reason=\(reason.rawValue) old=\(old) new=\(camera) tool=\(activeTool.rawValue) state=\(interactionState.rawValue)")
        }
        #endif
    }

    private func mutateCamera(reason: CameraMutationReason, _ mutation: (inout CameraController) -> Void) {
        let old = controller.camera
        mutation(&controller)
        #if DEBUG
        if old != controller.camera {
            lastCameraMutationReason = reason
            print("[VBoard] CAMERA MUTATION reason=\(reason.rawValue) old=\(old) new=\(controller.camera) tool=\(activeTool.rawValue) state=\(interactionState.rawValue)")
        }
        #endif
    }

    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        // Pinch owns the camera while two fingers are scaling. The pan
        // recognizer may still receive simultaneous callbacks, but it must not
        // apply a second camera mutation or restore its stale pan-start state
        // when the pinch ends.
        if interactionState == .pinching { return }
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            let twoFingerNavigation = gesture.numberOfTouches >= 2
            guard activeTool == .navigation || twoFingerNavigation || (isSpacePressed && activeStrokeLayer == nil) else { return }
            interactionState = .panning; debugInputOperation("PAN BEGIN")
            panStart = translation; panStartCamera = controller.camera; professor.beginNavigation(); debugPan("BEGIN", screen: translation); updateInputHUD()
        case .changed:
            guard interactionState == .panning else { return }
            setCamera(panStartCamera, reason: .handPan)
            mutateCamera(reason: .handPan) { $0.pan(screenTranslation: CGPoint(x: translation.x - panStart.x, y: translation.y - panStart.y), viewport: bounds.size) }
            applyCamera(interacting: true); debugInputOperation("PAN UPDATE"); debugPan("UPDATE", screen: translation)
        case .ended, .cancelled, .failed:
            guard interactionState == .panning else { return }
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; debugInputOperation("PAN END"); debugPan("END"); updateInputHUD()
            panStart = .zero
        default: break
        }
    }

    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartCamera = controller.camera
            pinchStartMidpoint = gesture.location(in: self)
            interactionState = .pinching
            professor.beginNavigation(); debugInputOperation("PINCH BEGIN"); updateInputHUD()
        case .changed:
            guard interactionState == .pinching else { return }
            let midpoint = gesture.location(in: self)
            mutateCamera(reason: .pinch) { $0.pinch(startCamera: pinchStartCamera,
                                                     startMidpoint: pinchStartMidpoint,
                                                     currentMidpoint: midpoint,
                                                     magnification: gesture.scale,
                                                     viewport: bounds.size) }
            applyCamera(interacting: true)
        case .ended, .cancelled, .failed:
            guard interactionState == .pinching else { return }
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; pinchStartMidpoint = .zero; debugInputOperation("PINCH END"); updateInputHUD()
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        return activeTool == .navigation || panGesture.numberOfTouches >= 2 || (isSpacePressed && activeStrokeLayer == nil)
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
            // Do not end a live pointer session from the keyboard event. The
            // next touch-up owns pan cleanup; ending here would leave a drag
            // half-panned and route its remaining samples to the content tool.
            updateInputHUD()
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        isSpacePressed = false
        if interactionState == .panning {
            professor.endNavigation(worldTransform)
            interactionState = .idle
            panStart = .zero
        }
        updateInputHUD()
        super.pressesCancelled(presses, with: event)
    }

    @objc private func clearTransientInput() {
        isSpacePressed = false
        if interactionState == .panning { professor.endNavigation(worldTransform) }
        interactionState = .idle; panStart = .zero
        activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
        activePoints.removeAll(); predictedPoints.removeAll(); lastPencilPressure = nil; activeID = nil
        lassoWorldPoints.removeAll(); updateInteractionPath(); updateInputHUD()
    }

    private func applyKeyboardZoom(_ factor: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        mutateCamera(reason: .keyboardZoom) { $0.zoom(by: factor, anchoredAt: center, viewport: bounds.size) }
        applyCamera(interacting: false)
        onCameraChanged(controller.camera)
    }
    @objc private func zoomInKey() { applyKeyboardZoom(1.25) }
    @objc private func zoomOutKey() { applyKeyboardZoom(0.8) }
    @objc private func resetZoomKey() {
        setCamera(CameraResolver.fitBoard(boardRect: document.viewBox, viewport: bounds.size), reason: .explicitFitBoard)
        applyCamera(interacting: false)
        onCameraChanged(controller.camera)
    }
    @objc private func undoKey() { onUndo() }
    @objc private func redoKey() { onRedo() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        debugInput("BEGIN", touch: touch)
        let screen = touch.location(in: self)
        let point = worldPoint(screen, from: self)
        // Space is a modal simulator hand-pan override. It is checked before
        // the active content tool so a Pen/Lasso/Eraser drag never mutates
        // the document while the user is navigating.
        if isSpacePressed {
            panStart = screen; panStartCamera = controller.camera
            interactionState = .panning; professor.beginNavigation()
            debugInputOperation("PAN BEGIN"); debugPan("BEGIN", screen: screen); updateInputHUD(); return
        }
        if activeTool == .navigation {
            panStart = screen; panStartCamera = controller.camera
            interactionState = .panning; professor.beginNavigation(); debugInputOperation("PAN BEGIN"); debugPan("BEGIN", screen: screen); updateInputHUD(); return
        }
        if activeTool != .pen && activeTool != .highlighter { beginEditing(at: point, screen: screen); return }
        guard isDrawingTouch(touch) else { super.touchesBegan(touches, with: event); return }
        interactionState = .drawing; debugInputOperation("STROKE BEGIN"); updateInputHUD()
        lastPencilPressure = nil
        predictedPoints.removeAll(keepingCapacity: true)
        activeID = UUID().uuidString; activePoints = samples(for: touch, event: event)
        let layer = CAShapeLayer(); layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = strokeColor.cgColor; layer.lineWidth = strokeWidth
        layer.lineCap = .round; layer.lineJoin = .round; activeStrokeLayer = layer
        updateActiveStroke()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        debugInput("MOVE", touch: touch)
        if interactionState == .panning {
            let screen = touch.location(in: self)
            setCamera(panStartCamera, reason: .handPan)
            mutateCamera(reason: .handPan) { $0.pan(screenTranslation: CGPoint(x: screen.x - panStart.x, y: screen.y - panStart.y), viewport: bounds.size) }
            applyCamera(interacting: true); debugInputOperation("PAN UPDATE"); debugPan("UPDATE", screen: screen); return
        }
        if activeTool != .pen && activeTool != .highlighter { continueEditing(at: worldPoint(touch.location(in: self), from: self), screen: touch.location(in: self)); return }
        guard isDrawingTouch(touch) else { return }
        activePoints.append(contentsOf: samples(for: touch, event: event))
        predictedPoints = predictedSamples(for: touch, event: event)
        updateActiveStroke(); debugInputOperation("STROKE APPEND")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        debugInput("END", touch: touch)
        if interactionState == .panning {
            // The Mac/iPad simulator may coalesce an indirect-pointer drag
            // into only BEGIN/END callbacks. Derive the final camera from the
            // immutable pan-start state and the root-space endpoint so that
            // this path remains deterministic and never depends on MOVE
            // delivery frequency.
            let screen = touch.location(in: self)
            setCamera(panStartCamera, reason: .handPan)
            mutateCamera(reason: .handPan) { $0.pan(screenTranslation: CGPoint(x: screen.x - panStart.x, y: screen.y - panStart.y), viewport: bounds.size) }
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
        activePoints.removeAll(); predictedPoints.removeAll(); lastPencilPressure = nil
        activeID = nil; interactionState = .idle; updateInputHUD()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if interactionState == .panning {
            professor.endNavigation(worldTransform); interactionState = .idle; panStart = .zero; updateInputHUD(); return
        }
        if activeTool != .pen && activeTool != .highlighter { finishEditing(at: nil); return }
        if touches.contains(where: { isDrawingTouch($0) }) {
            activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
            activePoints.removeAll(); predictedPoints.removeAll(); lastPencilPressure = nil; activeID = nil
        }
    }

    private func beginEditing(at point: CGPoint, screen: CGPoint) {
        editStart = point; editStartScreen = screen; lastEditPoint = point
        moveDelta = .zero; moveActive = false
        if activeTool == .navigation {
            interactionState = .panning
            return
        } else if activeTool == .lasso {
            interactionState = .lassoing; lassoWorldPoints = [point]; debugInputOperation("LASSO BEGIN"); updateInteractionPath()
        } else if activeTool == .objectEraser {
            interactionState = .erasing; eraseIDs.removeAll(); eraseSegment(from: point, to: point); debugInputOperation("ERASER BEGIN")
        } else if activeTool == .select {
            let hitIDs = hitTestIDs(at: point)
            // Clicking inside an already-selected member preserves the full
            // selection so a lasso-selected set moves as one group. Clicking
            // an unrelated object intentionally replaces the selection.
            if selectedIDs.isEmpty || hitIDs.isDisjoint(with: selectedIDs) {
                selectedIDs = hitIDs
            }
            interactionState = selectedIDs.isEmpty ? .idle : .selecting
            #if DEBUG
            print("[VBoard] SELECT HIT ids=\(Array(selectedIDs))")
            print("[VBoard] SELECTION_CHANGED count=\(selectedIDs.count) ids=\(Array(selectedIDs))")
            #endif
            onSelectionRegionChanged(nil); onSelectionChanged(selectedIDs); updateSelectionOverlay(); updateInputHUD()
        }
    }

    private func continueEditing(at point: CGPoint, screen: CGPoint) {
        switch activeTool {
        case .navigation:
            break
        case .lasso:
            lassoWorldPoints.append(point); updateInteractionPath(); debugInputOperation("LASSO UPDATE")
        case .select:
            let screenDistance = hypot(screen.x - editStartScreen.x, screen.y - editStartScreen.y)
            if !selectedIDs.isEmpty, screenDistance >= 4 {
                moveActive = true
                moveDelta = CGPoint(x: point.x - editStart.x, y: point.y - editStart.y)
                interactionState = .movingSelection; debugInputOperation("MOVE UPDATE")
                previewMove(moveDelta)
            }
        case .objectEraser: eraseSegment(from: lastEditPoint, to: point); debugInputOperation("ERASER SEGMENT")
        case .pen, .highlighter: break
        }
        lastEditPoint = point
    }

    private func finishEditing(at endpoint: CGPoint?) {
        if activeTool == .select {
            if let endpoint, !selectedIDs.isEmpty {
                let delta = CGPoint(x: endpoint.x - editStart.x, y: endpoint.y - editStart.y)
                if moveActive || hypot(delta.x, delta.y) > 0 {
                    moveDelta = delta
                    onMove(selectedIDs, delta)
                    debugInputOperation("MOVE COMMIT")
                }
            }
            clearMovePreview()
            moveActive = false; moveDelta = .zero
            interactionState = .idle; updateSelectionOverlay(); updateInputHUD()
            return
        }
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
                let points = selectionSamples(for: object)
                guard !points.isEmpty, points.contains(where: { bounds.contains($0) }) else { return false }
                let inside = points.filter { polygonContains($0, polygon: polygon) }.count
                return Double(inside) / Double(points.count) >= 0.65
            }.map(\.id))
            let professorIDs = professor.ids(intersecting: bounds)
            selectedIDs = selected.union(professorIDs)
            let pdfRegion = selectedIDs.contains(PDFBoardSource.logicalID)
                ? bounds.intersection(document.viewBox)
                : nil
            onSelectionRegionChanged(pdfRegion?.isNull == false ? pdfRegion : nil)
            onSelectionChanged(selectedIDs); updateSelectionOverlay()
            #if DEBUG
            print("[VBoard] LASSO CANDIDATES objects=\(selected.count) professor=\(professorIDs.count)")
            print("[VBoard] SELECTION_CHANGED count=\(selectedIDs.count) ids=\(Array(selectedIDs))")
            #endif
            debugInputOperation("LASSO FINALIZE")
        }
        lassoWorldPoints.removeAll(); interactionState = .idle; updateInteractionPath(); updateInputHUD()
    }

    private func previewMove(_ delta: CGPoint) {
        for id in selectedIDs {
            userObjectLayers[id]?.setAffineTransform(CGAffineTransform(translationX: delta.x, y: delta.y))
        }
        professor.previewTranslation(ids: selectedIDs, delta: delta)
        updateSelectionOverlay()
    }

    private func clearMovePreview() {
        for id in selectedIDs { userObjectLayers[id]?.setAffineTransform(.identity) }
        professor.clearPreviewTranslation(ids: selectedIDs)
    }

    private func eraseSegment(from start: CGPoint, to end: CGPoint) {
        let segmentBounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -14, dy: -14)
        var hit = Set(objects.compactMap { object -> String? in
            let objectBounds = BoardHitTestPolicy.bounds(of: object).insetBy(dx: -12, dy: -12)
            return segmentBounds.intersects(objectBounds) ? object.id : nil
        })
        hit.formUnion(professor.ids(intersecting: segmentBounds))
        let fresh = hit.subtracting(eraseIDs)
        guard !fresh.isEmpty else { return }
        eraseIDs.formUnion(fresh); selectedIDs.formUnion(fresh); onSelectionRegionChanged(nil); onDelete(fresh); onSelectionChanged(selectedIDs)
        #if DEBUG
        print("[VBoard] ERASER HITS ids=\(Array(fresh))")
        #endif
    }

    private func hitTestIDs(at point: CGPoint) -> Set<String> {
        var result = Set(objects.compactMap { object in
            let bounds = BoardHitTestPolicy.bounds(of: object).insetBy(dx: -12, dy: -12)
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
            bounds = bounds.union(BoardHitTestPolicy.bounds(of: object))
        }
        for id in selectedIDs { bounds = bounds.union(professor.bounds(for: id)) }
        guard !bounds.isNull else { return }
        if moveActive { bounds = bounds.offsetBy(dx: moveDelta.x, dy: moveDelta.y) }
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

    private func selectionSamples(for object: CanvasObject) -> [CGPoint] {
        if let points = object.points, !points.isEmpty {
            let translation = object.translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
            let scaleX = object.scaleX ?? 1
            let scaleY = object.scaleY ?? 1
            let stride = max(1, points.count / 40)
            return points.enumerated().compactMap { index, point in
                guard index % stride == 0 || index == points.count - 1 else { return nil }
                return CGPoint(x: point.x * scaleX + translation.x,
                               y: point.y * scaleY + translation.y)
            }
        }
        let bounds = BoardHitTestPolicy.bounds(of: object)
        guard !bounds.isNull else { return [] }
        return [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.midX, y: bounds.midY)]
    }

    private func samples(for touch: UITouch, event: UIEvent?) -> [StrokePoint] {
        let source = event?.coalescedTouches(for: touch) ?? [touch]
        return source.map { item in
            sample(for: item, updatesPressure: true)
        }
    }

    private func predictedSamples(for touch: UITouch, event: UIEvent?) -> [StrokePoint] {
        (event?.predictedTouches(for: touch) ?? []).map { sample(for: $0, updatesPressure: false) }
    }

    private func sample(for touch: UITouch, updatesPressure: Bool) -> StrokePoint {
        let point = worldPoint(touch.location(in: touch.view ?? self), from: touch.view ?? self)
        #if targetEnvironment(simulator)
        let pressure: CGFloat = 1
        #else
        let normalized = touch.force / max(touch.maximumPossibleForce, 1)
        let pressure = updatesPressure
            ? PencilPressureResponse.smoothed(previous: lastPencilPressure, sample: normalized)
            : PencilPressureResponse.curved(normalized)
        if updatesPressure { lastPencilPressure = pressure }
        #endif
        return StrokePoint(x: point.x, y: point.y, pressure: Double(pressure))
    }

    private func updateActiveStroke() {
        guard let layer = activeStrokeLayer else { return }
        let path = UIBezierPath()
        for (index, point) in (activePoints + predictedPoints).enumerated() {
            let world = CGPoint(x: point.x, y: point.y)
            if index == 0 { path.move(to: world) } else { path.addLine(to: world) }
        }
        layer.path = path.cgPath
        layer.lineWidth = strokeWidth * PencilPressureResponse.widthMultiplier(for: lastPencilPressure ?? 1)
        layer.frame = bounds
        if layer.superlayer == nil { userLayer.addSublayer(layer) }
    }

    private var activeStrokeStyle: CanvasStrokeStyle { activeTool == .highlighter ? markerStyle : penStyle }
    private var strokeColorHex: String { activeStrokeStyle.colorHex }
    private var strokeColor: UIColor { UIColor(svgHex: strokeColorHex).withAlphaComponent(CGFloat(strokeOpacity)) }
    private var strokeWidth: CGFloat { CGFloat(activeStrokeStyle.width) }
    private var strokeOpacity: Double { activeStrokeStyle.opacity }

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
        if object.type == "text", object.text != nil || object.sourceMarkdown != nil,
           object.x != nil, object.y != nil {
            let layer = CompactStudyPresentation.layer(
                for: object,
                frame: BoardHitTestPolicy.bounds(of: object),
                contentsScale: window?.screen.scale ?? UIScreen.main.scale
            )
            applyProvenance(object.id, to: layer); return layer
        }
        let layer = CAShapeLayer()
        if object.type == "path", let definition = object.d,
           let parsed = try? SVGPathParser.cachedPath(from: definition) {
            var transform = CGAffineTransform.identity
                .translatedBy(x: CGFloat(object.translation?.x ?? 0),
                              y: CGFloat(object.translation?.y ?? 0))
                .scaledBy(x: CGFloat(object.scaleX ?? 1), y: CGFloat(object.scaleY ?? 1))
            layer.path = parsed.copy(using: &transform)
            layer.fillColor = UIColor(svgHex: object.fill ?? object.color ?? "#183153")
                .withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor
            layer.fillRule = .evenOdd
            applyProvenance(object.id, to: layer)
            return layer
        }
        let path = UIBezierPath()
        let tx = object.translation?.x ?? 0; let ty = object.translation?.y ?? 0
        let scaleX = object.scaleX ?? 1; let scaleY = object.scaleY ?? 1
        for (index, point) in (object.points ?? []).enumerated() {
            let world = CGPoint(x: point.x * scaleX + tx, y: point.y * scaleY + ty)
            if index == 0 { path.move(to: world) } else { path.addLine(to: world) }
        }
        layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor(svgHex: object.color ?? "#183153").withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor
        layer.lineWidth = (object.width ?? 4) * sqrt(abs(scaleX * scaleY))
        layer.lineCap = .round; layer.lineJoin = .round
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
        var text = "Tool: \(activeTool.rawValue)\nInput: \(activeInputSource.rawValue)\nState: \(interactionState.rawValue)  Selected: \(selectedIDs.count) Space: \(isSpacePressed)\nCamera: x=\(Int(controller.camera.x)) y=\(Int(controller.camera.y)) w=\(Int(controller.camera.width)) h=\(Int(controller.camera.height))\nBoard: \(Int(document.viewBox.width))×\(Int(document.viewBox.height))  Paper: \(!paperLayer.isHidden)\nLast camera: \(lastCameraMutationReason?.rawValue ?? "none")"
        if let stats = lastRenderStats { text += "\n" + stats.overlayText }
        perfLabel.text = text
    }
    #endif
}
