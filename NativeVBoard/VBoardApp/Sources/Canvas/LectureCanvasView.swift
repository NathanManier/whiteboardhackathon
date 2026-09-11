import SwiftUI
import UIKit

enum WorkspaceBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case dots
    case blank

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dots: return "Dots"
        case .blank: return "Blank"
        }
    }
}

enum WorkspaceDotFieldPolicy {
    static let worldIntervals: [CGFloat] = [
        12.5, 17.5, 25, 35, 50, 70, 100, 140, 200, 280, 400, 560,
        800, 1_120, 1_600, 2_240, 3_200, 4_480, 6_400, 8_960,
        12_800, 17_920, 25_600, 35_840, 51_200
    ]

    /// Chooses a stable, clean world interval near Freeform-like screen spacing.
    /// It changes only when a neighboring interval becomes a better match, so dots do
    /// not continuously crawl or resize while the camera moves.
    static func worldSpacing(forScale scale: CGFloat, targetScreenSpacing: CGFloat = 60) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 100 }
        return worldIntervals.min { lhs, rhs in
            abs(log(max(lhs * scale, 0.001) / targetScreenSpacing))
                < abs(log(max(rhs * scale, 0.001) / targetScreenSpacing))
        } ?? 100
    }

    static func opacity(forScale scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 0 }
        if scale >= 12 { return 0 }
        if scale > 4 { return 0.23 * (12 - scale) / 8 }
        return 0.23
    }
}

enum PencilPressureResponse {
    static func curved(_ normalized: CGFloat) -> CGFloat {
        pow(min(1, max(0, normalized)), 0.72)
    }

    static func smoothed(previous: CGFloat?, sample: CGFloat) -> CGFloat {
        let next = curved(sample)
        guard let previous else { return next }
        return previous * 0.68 + next * 0.32
    }

    static func widthMultiplier(for pressure: CGFloat) -> CGFloat {
        0.68 + curved(pressure) * 0.52
    }
}

enum BoardVectorLoadState: Equatable, Sendable {
    case unloaded
    case previewReady
    case vectorLoading
    case vectorPartial
    case vectorReady
    case vectorFailed

    var isWorking: Bool { self == .vectorLoading || self == .vectorPartial }
    var userLabel: String {
        switch self {
        case .vectorLoading: return "Preparing editable ink…"
        case .vectorPartial: return "Refining editable ink…"
        case .vectorFailed: return "Editable ink unavailable"
        default: return ""
        }
    }
}

enum VectorLoadingIndicatorPolicy {
    static let appearanceDelay: TimeInterval = 0.20
    static let minimumVisibleDuration: TimeInterval = 0.50
}

enum VectorProgressivePresentationPolicy {
    /// A raster preview stays visually complete until the first exact vector
    /// group is ready. During later refinements the already-visible exact
    /// group is the stable proxy, so the thumbnail must not reappear.
    static func previewOpacity(progress: Double, hasStableVectorPresentation: Bool) -> CGFloat {
        guard progress < 0.999, !hasStableVectorPresentation else { return 0 }
        return 1
    }
}

/// A board-local indicator whose lifetime follows actual professor-path
/// progress. Delays only prevent flicker; they never mark unfinished work as
/// complete.
final class BoardVectorLoadingIndicator: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private var transitionTask: Task<Void, Never>?
    private var visibleSince: TimeInterval?
    private(set) var state: BoardVectorLoadState = .unloaded

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        layer.cornerRadius = 12
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.spacing = 7
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
        alpha = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func transition(to next: BoardVectorLoadState) {
        guard state != next else { return }
        state = next
        transitionTask?.cancel()
        label.text = next.userLabel
        if next.isWorking {
            spinner.startAnimating()
            if !isHidden {
                return
            }
            transitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(VectorLoadingIndicatorPolicy.appearanceDelay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.state.isWorking else { return }
                self.isHidden = false
                self.visibleSince = CACurrentMediaTime()
                UIView.animate(withDuration: 0.16) { self.alpha = 1 }
            }
        } else if !isHidden {
            let elapsed = CACurrentMediaTime() - (visibleSince ?? CACurrentMediaTime())
            let delay = max(0, VectorLoadingIndicatorPolicy.minimumVisibleDuration - elapsed)
            transitionTask = Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled, let self, !self.state.isWorking else { return }
                UIView.animate(withDuration: 0.16, animations: { self.alpha = 0 }) { _ in
                    guard !self.state.isWorking else { return }
                    self.isHidden = true
                    self.visibleSince = nil
                    self.spinner.stopAnimating()
                }
            }
        } else {
            spinner.stopAnimating()
        }
    }
}

enum SelectionResizeHandle: CaseIterable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft

    func point(in bounds: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: bounds.minX, y: bounds.minY)
        case .topRight: return CGPoint(x: bounds.maxX, y: bounds.minY)
        case .bottomRight: return CGPoint(x: bounds.maxX, y: bounds.maxY)
        case .bottomLeft: return CGPoint(x: bounds.minX, y: bounds.maxY)
        }
    }

    func oppositePoint(in bounds: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return SelectionResizeHandle.bottomRight.point(in: bounds)
        case .topRight: return SelectionResizeHandle.bottomLeft.point(in: bounds)
        case .bottomRight: return SelectionResizeHandle.topLeft.point(in: bounds)
        case .bottomLeft: return SelectionResizeHandle.topRight.point(in: bounds)
        }
    }
}

struct SelectionResizeSession {
    let keys: Set<SelectionKey>
    let startBounds: CGRect
    let handle: SelectionResizeHandle
    let startPointer: CGPoint

    var anchor: CGPoint { handle.oppositePoint(in: startBounds) }
}

enum SelectionResizeGeometry {
    static func scale(session: SelectionResizeSession, currentPointer: CGPoint) -> CGFloat {
        let handleStart = session.handle.point(in: session.startBounds)
        let desiredHandle = CGPoint(x: handleStart.x + currentPointer.x - session.startPointer.x,
                                    y: handleStart.y + currentPointer.y - session.startPointer.y)
        let base = CGPoint(x: handleStart.x - session.anchor.x,
                           y: handleStart.y - session.anchor.y)
        let desired = CGPoint(x: desiredHandle.x - session.anchor.x,
                              y: desiredHandle.y - session.anchor.y)
        let denominator = base.x * base.x + base.y * base.y
        guard denominator > 0.001 else { return 1 }
        let projected = (desired.x * base.x + desired.y * base.y) / denominator
        let minimumFactor = max(0.01, 24 / max(min(session.startBounds.width,
                                                   session.startBounds.height), 24))
        return min(100, max(minimumFactor, projected))
    }

    static func bounds(session: SelectionResizeSession, scale: CGFloat) -> CGRect {
        let anchor = session.anchor
        let dragged = session.handle.point(in: session.startBounds)
        let next = CGPoint(x: anchor.x + (dragged.x - anchor.x) * scale,
                           y: anchor.y + (dragged.y - anchor.y) * scale)
        return CGRect(x: min(anchor.x, next.x), y: min(anchor.y, next.y),
                      width: abs(next.x - anchor.x), height: abs(next.y - anchor.y))
    }
}

private enum LectureInteraction {
    case idle
    case panning(startScreen: CGPoint, startCamera: CameraRect)
    case drawing(boardID: String, strokeID: String)
    case lassoing
    case erasing(boardID: String?, erased: Set<SelectionKey>)
    case movingSelection(startWorld: CGPoint, clickSelection: Set<SelectionKey>?)
    case resizingSelection(SelectionResizeSession)
    case movingBoard(boardID: String, startWorld: CGPoint)
}

struct LectureCanvasView: UIViewRepresentable {
    let workspace: LectureWorkspace
    let scenes: [String: WorkspaceBoardScene]
    let selectedKeys: Set<SelectionKey>
    let tool: CanvasTool
    let backgroundStyle: WorkspaceBackgroundStyle
    let physicalBoardShowsPaper: Bool
    let penStyle: CanvasStrokeStyle
    let markerStyle: CanvasStrokeStyle
    let thumbnailURLs: [String: URL]
    var loadAsset: (String) async throws -> Data
    let focusRequest: WorkspaceFocusRequest?
    var onCameraChanged: (CameraRect) -> Void
    var onActiveBoardChanged: (String) -> Void
    var onDetailDemand: (Set<String>) -> Void
    var onSelectionChanged: (Set<SelectionKey>, [String: CGRect]) -> Void
    var onSelectionScreenBoundsChanged: (CGRect?) -> Void
    var onStroke: (UserStroke, String) -> Void
    var onMoveSelection: (Set<SelectionKey>, CGPoint) -> Void
    var onResizeSelection: (Set<SelectionKey>, CGPoint, CGFloat) -> Void
    var onDelete: (Set<SelectionKey>) -> Void
    var onMoveBoard: (String, CGPoint) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onPencilDoubleTap: () -> Void
    var onPencilSqueeze: (CGPoint) -> Void

    func makeUIView(context: Context) -> LectureCanvasUIView {
        LectureCanvasUIView(
            workspace: workspace,
            scenes: scenes,
            selectedKeys: selectedKeys,
            tool: tool,
            backgroundStyle: backgroundStyle,
            physicalBoardShowsPaper: physicalBoardShowsPaper,
            penStyle: penStyle,
            markerStyle: markerStyle,
            thumbnailURLs: thumbnailURLs,
            loadAsset: loadAsset,
            callbacks: callbacks
        )
    }

    func updateUIView(_ view: LectureCanvasUIView, context: Context) {
        view.update(workspace: workspace, scenes: scenes, selectedKeys: selectedKeys,
                    tool: tool, backgroundStyle: backgroundStyle,
                    physicalBoardShowsPaper: physicalBoardShowsPaper,
                    penStyle: penStyle, markerStyle: markerStyle,
                    thumbnailURLs: thumbnailURLs,
                    loadAsset: loadAsset,
                    focusRequest: focusRequest, callbacks: callbacks)
    }

    private var callbacks: LectureCanvasCallbacks {
        LectureCanvasCallbacks(onCameraChanged: onCameraChanged,
                               onActiveBoardChanged: onActiveBoardChanged,
                               onDetailDemand: onDetailDemand,
                               onSelectionChanged: onSelectionChanged,
                               onSelectionScreenBoundsChanged: onSelectionScreenBoundsChanged,
                               onStroke: onStroke,
                               onMoveSelection: onMoveSelection,
                               onResizeSelection: onResizeSelection,
                               onDelete: onDelete,
                               onMoveBoard: onMoveBoard,
                               onUndo: onUndo,
                               onRedo: onRedo,
                               onPencilDoubleTap: onPencilDoubleTap,
                               onPencilSqueeze: onPencilSqueeze)
    }
}

struct LectureCanvasCallbacks {
    var onCameraChanged: (CameraRect) -> Void
    var onActiveBoardChanged: (String) -> Void
    var onDetailDemand: (Set<String>) -> Void
    var onSelectionChanged: (Set<SelectionKey>, [String: CGRect]) -> Void
    var onSelectionScreenBoundsChanged: (CGRect?) -> Void
    var onStroke: (UserStroke, String) -> Void
    var onMoveSelection: (Set<SelectionKey>, CGPoint) -> Void
    var onResizeSelection: (Set<SelectionKey>, CGPoint, CGFloat) -> Void
    var onDelete: (Set<SelectionKey>) -> Void
    var onMoveBoard: (String, CGPoint) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onPencilDoubleTap: () -> Void
    var onPencilSqueeze: (CGPoint) -> Void
}

final class LectureCanvasUIView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let gridMinorLayer = CAShapeLayer()
    private let worldContainer = UIView()
    private let regionContainer = UIView()
    private let interactionLayer = CAShapeLayer()
    private let pencilHoverLayer = CAShapeLayer()
    private var boardViews: [String: LectureBoardRenderView] = [:]
    private var regionLayers: [String: CAShapeLayer] = [:]
    private var sourceSurfaceLayers: [String: CAShapeLayer] = [:]
    private var workspace: LectureWorkspace
    private var scenes: [String: WorkspaceBoardScene]
    private var selectedKeys: Set<SelectionKey>
    private var activeTool: CanvasTool
    private var backgroundStyle: WorkspaceBackgroundStyle
    private var physicalBoardShowsPaper: Bool
    private var penStyle: CanvasStrokeStyle
    private var markerStyle: CanvasStrokeStyle
    private var thumbnailURLs: [String: URL]
    private var loadAsset: (String) async throws -> Data
    private var callbacks: LectureCanvasCallbacks
    private var controller: CameraController
    private var spatialIndex: WorkspaceSpatialIndex
    private var representations: [String: BoardRepresentation] = [:]
    private var lastDetailDemand = Set<String>()
    private var interaction: LectureInteraction = .idle
    private var lassoPoints: [CGPoint] = []
    private var liveStrokePoints: [StrokePoint] = []
    private var predictedStrokePoints: [StrokePoint] = []
    private var lastPencilPressure: CGFloat?
    private var liveStrokeBoardID: String?
    private var movePreviewDelta = CGPoint.zero
    private var resizePreviewBounds: CGRect?
    private var lastEraseWorld: CGPoint?
    private var lastFocusRequestID: UUID?
    private var isSpacePressed = false
    private var twoTouchStartCamera: CameraRect?
    private var twoTouchStartMidpoint = CGPoint.zero
    private var twoTouchCurrentMidpoint = CGPoint.zero
    private var twoTouchMagnification: CGFloat = 1
    private var panRecognizer: UIPanGestureRecognizer!
    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var lastHandledSqueezeTimestamp: TimeInterval = -1
    private var previousViewportSize: CGSize = .zero

    init(workspace: LectureWorkspace,
         scenes: [String: WorkspaceBoardScene],
         selectedKeys: Set<SelectionKey>,
         tool: CanvasTool,
         backgroundStyle: WorkspaceBackgroundStyle,
         physicalBoardShowsPaper: Bool,
         penStyle: CanvasStrokeStyle,
         markerStyle: CanvasStrokeStyle,
         thumbnailURLs: [String: URL],
         loadAsset: @escaping (String) async throws -> Data,
         callbacks: LectureCanvasCallbacks) {
        self.workspace = workspace
        self.scenes = scenes
        self.selectedKeys = selectedKeys
        self.activeTool = tool
        self.backgroundStyle = backgroundStyle
        self.physicalBoardShowsPaper = physicalBoardShowsPaper
        self.penStyle = penStyle
        self.markerStyle = markerStyle
        self.thumbnailURLs = thumbnailURLs
        self.loadAsset = loadAsset
        self.callbacks = callbacks
        controller = CameraController(camera: workspace.camera)
        spatialIndex = WorkspaceSpatialIndex(items: workspace.items)
        super.init(frame: .zero)

        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1)
                : UIColor(red: 0.965, green: 0.968, blue: 0.972, alpha: 1)
        }
        clipsToBounds = true
        isMultipleTouchEnabled = true
        configureGridLayer(gridMinorLayer)
        layer.addSublayer(gridMinorLayer)
        worldContainer.backgroundColor = .clear
        worldContainer.clipsToBounds = false
        worldContainer.isUserInteractionEnabled = false
        worldContainer.layer.anchorPoint = .zero
        worldContainer.layer.position = .zero
        addSubview(worldContainer)
        regionContainer.backgroundColor = .clear
        regionContainer.isUserInteractionEnabled = false
        worldContainer.addSubview(regionContainer)

        interactionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        interactionLayer.strokeColor = UIColor.systemBlue.cgColor
        interactionLayer.lineWidth = 2
        interactionLayer.lineDashPattern = [8, 5]
        interactionLayer.isHidden = true
        WorldOverlayLayerLayout.pin(interactionLayer, to: worldContainer.bounds)
        worldContainer.layer.addSublayer(interactionLayer)

        pencilHoverLayer.fillColor = UIColor.clear.cgColor
        pencilHoverLayer.strokeColor = UIColor.label.withAlphaComponent(0.55).cgColor
        pencilHoverLayer.lineWidth = 1
        pencilHoverLayer.isHidden = true
        layer.addSublayer(pencilHoverLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delegate = self
        addGestureRecognizer(pan)
        panRecognizer = pan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                   NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pinchRecognizer = pinch

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(pencilHover(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        addGestureRecognizer(hover)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: LectureCanvasUIView, _) in
            view.updateWorkspaceBackground()
            view.updateRegionDecorations()
        }
        becomeFirstResponder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        callbacks.onPencilDoubleTap()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveTap tap: UIPencilInteraction.Tap) {
        callbacks.onPencilDoubleTap()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .began || squeeze.phase == .ended else { return }
        guard squeeze.timestamp != lastHandledSqueezeTimestamp else { return }
        lastHandledSqueezeTimestamp = squeeze.timestamp
        callbacks.onPencilSqueeze(squeeze.hoverPose?.location
                                  ?? CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc private func pencilHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else {
            pencilHoverLayer.isHidden = true
            pencilHoverLayer.path = nil
            return
        }
        let point = recognizer.location(in: self)
        let scale = max(worldTransform.scale, 0.001)
        let path = UIBezierPath()
        switch activeTool {
        case .pen:
            let radius = max(2.5, CGFloat(penStyle.width) * scale * 0.5)
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)))
        case .highlighter:
            let width = max(8, CGFloat(markerStyle.width) * scale)
            let height = max(3, width * max(0.18, sin(recognizer.altitudeAngle)))
            let nib = UIBezierPath(ovalIn: CGRect(x: -width / 2, y: -height / 2,
                                                 width: width, height: height))
            let transform = CGAffineTransform(translationX: point.x, y: point.y)
                .rotated(by: recognizer.azimuthAngle(in: self))
            nib.apply(transform)
            path.append(nib)
        case .objectEraser:
            let radius = max(8, 14 * scale)
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)))
        case .lasso, .select, .navigation:
            path.move(to: CGPoint(x: point.x - 5, y: point.y))
            path.addLine(to: CGPoint(x: point.x + 5, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - 5))
            path.addLine(to: CGPoint(x: point.x, y: point.y + 5))
        }
        pencilHoverLayer.path = path.cgPath
        pencilHoverLayer.isHidden = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newViewportSize = bounds.size
        if previousViewportSize.width > 0, previousViewportSize.height > 0,
           newViewportSize != previousViewportSize {
            controller.resizeViewport(from: previousViewportSize, to: newViewportSize)
            let resizedCamera = controller.camera
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.callbacks.onCameraChanged(resizedCamera)
            }
        }
        previousViewportSize = newViewportSize
        worldContainer.bounds = CGRect(origin: .zero, size: bounds.size)
        worldContainer.layer.position = .zero
        regionContainer.frame = worldContainer.bounds
        gridMinorLayer.frame = bounds
        WorldOverlayLayerLayout.pin(interactionLayer, to: worldContainer.bounds)
        applyCamera(interacting: false)
        refineRepresentations()
    }

    func update(workspace: LectureWorkspace,
                scenes: [String: WorkspaceBoardScene],
                selectedKeys: Set<SelectionKey>,
                tool: CanvasTool,
                backgroundStyle: WorkspaceBackgroundStyle,
                physicalBoardShowsPaper: Bool,
                penStyle: CanvasStrokeStyle,
                markerStyle: CanvasStrokeStyle,
                thumbnailURLs: [String: URL],
                loadAsset: @escaping (String) async throws -> Data,
                focusRequest: WorkspaceFocusRequest?,
                callbacks: LectureCanvasCallbacks) {
        let placementsChanged = self.workspace.items != workspace.items
        let scenesChanged = self.scenes != scenes
        self.workspace = workspace
        self.scenes = scenes
        self.selectedKeys = selectedKeys
        self.activeTool = tool
        let appearanceChanged = self.backgroundStyle != backgroundStyle
            || self.physicalBoardShowsPaper != physicalBoardShowsPaper
        self.backgroundStyle = backgroundStyle
        self.physicalBoardShowsPaper = physicalBoardShowsPaper
        self.penStyle = penStyle
        self.markerStyle = markerStyle
        self.thumbnailURLs = thumbnailURLs
        self.loadAsset = loadAsset
        self.callbacks = callbacks
        if controller.camera != workspace.camera, !isInteracting {
            controller.setCamera(workspace.camera)
        }
        if placementsChanged { spatialIndex = WorkspaceSpatialIndex(items: workspace.items) }
        if placementsChanged || scenesChanged || appearanceChanged { refineRepresentations(force: true) }
        updateSelectionOverlay()
        if let focusRequest, focusRequest.id != lastFocusRequestID, bounds.width > 0, bounds.height > 0 {
            lastFocusRequestID = focusRequest.id
            focus(boardID: focusRequest.boardID)
        } else {
            applyCamera(interacting: isInteracting)
        }
    }

    private var isInteracting: Bool {
        if twoTouchStartCamera != nil { return true }
        if case .idle = interaction { return false }
        return true
    }

    private var worldTransform: WorldScreenTransform {
        WorldScreenTransform(camera: controller.camera, viewport: bounds.size)
    }

    private func screenToWorld(_ point: CGPoint) -> CGPoint { worldTransform.worldPoint(for: point) }

    #if DEBUG
    private var interactionLabel: String {
        switch interaction {
        case .idle: return "IDLE"
        case .panning: return "PANNING"
        case .drawing: return "DRAWING"
        case .lassoing: return "LASSOING"
        case .erasing: return "ERASING"
        case .movingSelection: return "MOVING_SELECTION"
        case .resizingSelection: return "RESIZING_SELECTION"
        case .movingBoard: return "MOVING_BOARD"
        }
    }

    private func debugInput(_ phase: String, touch: UITouch, screen: CGPoint, world: CGPoint) {
        let source: String
        switch touch.type {
        case .pencil: source = "pencil"
        case .indirectPointer: source = "indirectPointer"
        case .direct: source = "touch"
        default: source = "other(\(touch.type.rawValue))"
        }
        let roundTrip = worldTransform.screenPoint(for: world)
        let error = hypot(roundTrip.x - screen.x, roundTrip.y - screen.y)
        print("[VBoard] LECTURE INPUT \(phase) source=\(source) tool=\(activeTool.rawValue) screen=\(screen) world=\(world) roundTrip=\(roundTrip) error=\(error) state=\(interactionLabel) camera=\(controller.camera)")
        assert(error < 0.5, "Lecture canvas input round-trip must be subpixel")
    }
    #endif

    private func applyCamera(interacting: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldContainer.layer.setAffineTransform(worldTransform.affineTransform)
        CATransaction.commit()
        updateWorkspaceBackground()
        for (boardID, region) in regionLayers {
            region.lineWidth = (boardID == workspace.activeBoardID ? 1.5 : 1) / max(worldTransform.scale, 0.001)
        }
        for (boardID, view) in boardViews {
            guard let item = workspace.items.first(where: { $0.boardID == boardID }) else { continue }
            let localCamera = LectureCoordinateTransform.lectureWorldToBoardLocal(controller.camera.cgRect, board: item)
            view.updateVisibility(localCamera: localCamera, viewport: bounds.size, interacting: interacting)
        }
        if !selectedKeys.isEmpty { updateSelectionOverlay() }
    }

    private func configureGridLayer(_ layer: CAShapeLayer) {
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 1
        layer.contentsScale = UIScreen.main.scale
        layer.isHidden = true
    }

    /// Draws a small viewport-sized path only when the camera changes. The
    /// pattern is screen-space for a stable one-pixel stroke, but its origin
    /// is derived from world coordinates so it remains spatially anchored.
    private func updateWorkspaceBackground() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        gridMinorLayer.isHidden = backgroundStyle == .blank
        guard backgroundStyle != .blank else {
            gridMinorLayer.path = nil
            return
        }

        let transform = worldTransform
        let worldSpacing = WorkspaceDotFieldPolicy.worldSpacing(forScale: transform.scale)
        let screenSpacing = max(worldSpacing * transform.scale, 1)
        let worldOrigin = transform.screenPoint(for: .zero)
        let firstX = worldOrigin.x.truncatingRemainder(dividingBy: screenSpacing)
        let firstY = worldOrigin.y.truncatingRemainder(dividingBy: screenSpacing)

        let dots = UIBezierPath()
        let radius = traitCollection.userInterfaceStyle == .dark ? 0.95 : 0.9
        var x = firstX - screenSpacing
        while x <= bounds.maxX + screenSpacing {
            var y = firstY - screenSpacing
            while y <= bounds.maxY + screenSpacing {
                dots.append(UIBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius,
                                                        width: radius * 2, height: radius * 2)))
                y += screenSpacing
            }
            x += screenSpacing
        }
        gridMinorLayer.fillColor = gridColor(alpha: WorkspaceDotFieldPolicy.opacity(forScale: transform.scale)).cgColor
        gridMinorLayer.strokeColor = UIColor.clear.cgColor
        gridMinorLayer.path = dots.cgPath
    }

    private func gridColor(alpha: CGFloat) -> UIColor {
        traitCollection.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(alpha)
            : UIColor(red: 0.18, green: 0.25, blue: 0.32, alpha: alpha)
    }

    private func refineRepresentations(force: Bool = false) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let next = BoardDetailPolicy.representations(items: workspace.items,
                                                     camera: controller.camera,
                                                     viewport: bounds.size,
                                                     activeBoardID: workspace.activeBoardID,
                                                     interactingBoardID: interactingBoardID)
        if !force, next == representations { return }
        representations = next
        updateRegionDecorations()
        let desiredFull = Set(next.compactMap { $0.value == .fullVector ? $0.key : nil })
        #if DEBUG
        let thumbnailCount = next.values.filter { $0 == .thumbnail }.count
        let unloadedCount = next.values.filter { $0 == .unloaded }.count
        print("[VBoard] LECTURE LOD full=\(desiredFull.count) thumbnails=\(thumbnailCount) unloaded=\(unloadedCount) active=\(workspace.activeBoardID ?? "none")")
        #endif
        if desiredFull != lastDetailDemand {
            lastDetailDemand = desiredFull
            callbacks.onDetailDemand(desiredFull)
        }

        for item in workspace.items {
            let representation = next[item.boardID] ?? .unloaded
            if representation == .unloaded {
                boardViews.removeValue(forKey: item.boardID)?.removeFromSuperview()
                continue
            }
            let boardView = boardViews[item.boardID] ?? {
                let view = LectureBoardRenderView()
                worldContainer.addSubview(view)
                boardViews[item.boardID] = view
                return view
            }()
            boardView.frame = item.frame
            boardView.configure(item: item,
                                scene: representation == .fullVector ? scenes[item.boardID] : nil,
                                representation: representation,
                                physicalBoardShowsPaper: physicalBoardShowsPaper,
                                thumbnailURL: thumbnailURLs[item.boardID],
                                loadAsset: loadAsset)
        }
        if let activeBoardID = workspace.activeBoardID, let activeView = boardViews[activeBoardID] {
            worldContainer.bringSubviewToFront(activeView)
        }
        interactionLayer.removeFromSuperlayer()
        worldContainer.layer.addSublayer(interactionLayer)
        updateSelectionOverlay()
        applyCamera(interacting: false)
    }

    private func updateRegionDecorations() {
        let currentIDs = Set(workspace.items.map(\.boardID))
        for stale in regionLayers.keys where !currentIDs.contains(stale) {
            regionLayers.removeValue(forKey: stale)?.removeFromSuperlayer()
        }
        for stale in sourceSurfaceLayers.keys where !currentIDs.contains(stale) {
            sourceSurfaceLayers.removeValue(forKey: stale)?.removeFromSuperlayer()
        }
        for item in workspace.items {
            let sourceSurface = sourceSurfaceLayers[item.boardID] ?? {
                let layer = CAShapeLayer()
                layer.lineWidth = 0
                regionContainer.layer.addSublayer(layer)
                sourceSurfaceLayers[item.boardID] = layer
                return layer
            }()
            let region = regionLayers[item.boardID] ?? {
                let layer = CAShapeLayer()
                layer.fillColor = UIColor.clear.cgColor
                layer.lineJoin = .round
                regionContainer.layer.addSublayer(layer)
                regionLayers[item.boardID] = layer
                return layer
            }()
            sourceSurface.path = UIBezierPath(rect: item.sourceContentFrame).cgPath
            sourceSurface.fillColor = item.sourceKind == .blankBoard
                ? UIColor.clear.cgColor
                : boardRegionSurfaceColor(isPDF: item.sourceKind.isPDF).cgColor
            sourceSurface.strokeColor = UIColor.clear.cgColor

            let initial = item.initialWorkspaceRegionFrame
            let effective = initial.union(item.effectiveFrame)
            let inset = max(10, min(item.boardWidth, item.boardHeight) * 0.012)
            let boundary = effective.insetBy(dx: -inset, dy: -inset)
            let nextPath = UIBezierPath(roundedRect: boundary, cornerRadius: max(12, inset)).cgPath
            if let previous = region.path, previous.boundingBox != nextPath.boundingBox,
               !UIAccessibility.isReduceMotionEnabled {
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = previous
                animation.toValue = nextPath
                animation.duration = 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                region.add(animation, forKey: "region-boundary")
            }
            region.path = nextPath
            let isActive = item.boardID == workspace.activeBoardID
            let isPDF = item.sourceKind.isPDF
            region.fillColor = UIColor.clear.cgColor
            region.strokeColor = boardRegionBoundaryColor(active: isActive).cgColor
            region.lineWidth = (isActive ? 1.5 : 1.2) / max(worldTransform.scale, 0.001)
        }
    }

    private func boardRegionSurfaceColor(isPDF: Bool) -> UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return isPDF
                    ? UIColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1)
                    : UIColor(red: 0.09, green: 0.095, blue: 0.105, alpha: 1)
            }
            return isPDF
                ? UIColor(red: 0.982, green: 0.982, blue: 0.975, alpha: 1)
                : UIColor(red: 0.972, green: 0.974, blue: 0.973, alpha: 1)
        }
    }

    private func boardRegionBoundaryColor(active: Bool) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(active ? 0.34 : 0.24)
                : UIColor(red: 0.25, green: 0.29, blue: 0.32,
                          alpha: active ? 0.48 : 0.36)
        }
    }

    private var interactingBoardID: String? {
        switch interaction {
        case .drawing(let boardID, _), .movingBoard(let boardID, _): return boardID
        case .erasing(let boardID, _): return boardID
        default: return workspace.activeBoardID
        }
    }

    private func focus(boardID: String) {
        guard let item = workspace.items.first(where: { $0.boardID == boardID }) else { return }
        let initialRegion = CGRect(x: item.frame.minX, y: item.frame.minY,
                                   width: item.frame.width,
                                   height: item.frame.height * WorkspaceEffectiveBounds.initialRegionHeightMultiplier)
        let headerAndPaper = initialRegion.union(item.effectiveFrame).insetBy(dx: -32, dy: -32).union(
            CGRect(x: item.frame.minX, y: item.frame.minY - 40, width: item.frame.width, height: 40)
        )
        let camera = CameraResolver.fitBoard(boardRect: headerAndPaper, viewport: bounds.size)
        controller.setCamera(camera)
        applyCamera(interacting: false)
        refineRepresentations(force: true)
        callbacks.onCameraChanged(camera)
        callbacks.onActiveBoardChanged(boardID)
    }

    private func boardItem(at lecturePoint: CGPoint, includeHeader: Bool = false) -> WorkspaceBoardItem? {
        workspace.items.sorted { $0.zIndex > $1.zIndex }.first { item in
            let rect = includeHeader
                ? item.frame.union(CGRect(x: item.frame.minX, y: item.frame.minY - 40, width: item.frame.width, height: 40))
                : item.effectiveFrame.union(item.frame)
            return rect.contains(lecturePoint)
        }
    }

    private func isHeader(_ point: CGPoint, item: WorkspaceBoardItem) -> Bool {
        CGRect(x: item.frame.minX, y: item.frame.minY - 40, width: item.frame.width, height: 40).contains(point)
    }

    // MARK: - Two-finger camera navigation

    @objc private func twoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let midpoint = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            beginTwoTouchNavigation(midpoint: midpoint)
        case .changed:
            beginTwoTouchNavigation(midpoint: twoTouchStartMidpoint)
            let translation = recognizer.translation(in: self)
            if pinchRecognizer.state != .began && pinchRecognizer.state != .changed {
                twoTouchCurrentMidpoint = CGPoint(x: twoTouchStartMidpoint.x + translation.x,
                                                  y: twoTouchStartMidpoint.y + translation.y)
            }
            updateTwoTouchNavigation()
        case .ended, .cancelled, .failed:
            finishTwoTouchNavigationIfPossible()
        default: break
        }
    }

    @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
        let midpoint = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            beginTwoTouchNavigation(midpoint: midpoint)
        case .changed:
            beginTwoTouchNavigation(midpoint: midpoint)
            twoTouchCurrentMidpoint = midpoint
            twoTouchMagnification = recognizer.scale
            updateTwoTouchNavigation()
        case .ended, .cancelled, .failed:
            finishTwoTouchNavigationIfPossible()
        default: break
        }
    }

    private func beginTwoTouchNavigation(midpoint: CGPoint) {
        guard twoTouchStartCamera == nil else { return }
        cancelContentInteraction()
        twoTouchStartCamera = controller.camera
        twoTouchStartMidpoint = midpoint
        twoTouchCurrentMidpoint = midpoint
        twoTouchMagnification = 1
        boardViews.values.forEach { $0.beginNavigation() }
    }

    private func updateTwoTouchNavigation() {
        guard let start = twoTouchStartCamera else { return }
        controller.pinch(startCamera: start,
                         startMidpoint: twoTouchStartMidpoint,
                         currentMidpoint: twoTouchCurrentMidpoint,
                         magnification: twoTouchMagnification,
                         viewport: bounds.size)
        applyCamera(interacting: true)
    }

    private func finishTwoTouchNavigationIfPossible() {
        let panActive = panRecognizer.state == .began || panRecognizer.state == .changed
        let pinchActive = pinchRecognizer.state == .began || pinchRecognizer.state == .changed
        guard !panActive, !pinchActive, twoTouchStartCamera != nil else { return }
        twoTouchStartCamera = nil
        twoTouchMagnification = 1
        boardViews.values.forEach { $0.endNavigation() }
        applyCamera(interacting: false)
        refineRepresentations(force: true)
        callbacks.onCameraChanged(controller.camera)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === panRecognizer && otherGestureRecognizer === pinchRecognizer)
            || (gestureRecognizer === pinchRecognizer && otherGestureRecognizer === panRecognizer)
    }

    // MARK: - Pointer, Pencil, and tool routing

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard twoTouchStartCamera == nil, let touch = touches.first else { return }
        if touches.count > 1 && touch.type == .direct { return }
        let screen = touch.location(in: self)
        let world = screenToWorld(screen)
        #if DEBUG
        debugInput("BEGIN", touch: touch, screen: screen, world: world)
        #endif
        if isSpacePressed || activeTool == .navigation {
            interaction = .panning(startScreen: screen, startCamera: controller.camera)
            boardViews.values.forEach { $0.beginNavigation() }
            return
        }
        if activeTool == .select || activeTool == .lasso,
           let bounds = selectionWorldBounds(),
           let handle = resizeHandle(at: world, bounds: bounds) {
            let session = SelectionResizeSession(keys: selectedKeys, startBounds: bounds,
                                                 handle: handle, startPointer: world)
            resizePreviewBounds = bounds
            interaction = .resizingSelection(session)
            if let boardID = selectedKeys.first?.boardID { callbacks.onActiveBoardChanged(boardID) }
            return
        }
        if activeTool == .lasso,
           let bounds = selectionWorldBounds(),
           bounds.insetBy(dx: -10, dy: -10).contains(world) {
            interaction = .movingSelection(startWorld: world, clickSelection: nil)
            return
        }
        if activeTool == .lasso {
            lassoPoints = [world]
            interaction = .lassoing
            updateInteractionOverlay()
            return
        }
        if activeTool == .select,
           let item = boardItem(at: world, includeHeader: true), isHeader(world, item: item) {
            interaction = .movingBoard(boardID: item.boardID, startWorld: world)
            callbacks.onActiveBoardChanged(item.boardID)
            return
        }
        if activeTool == .objectEraser {
            lastEraseWorld = world
            interaction = .erasing(boardID: boardItem(at: world)?.boardID, erased: [])
            erase(from: world, to: world)
            return
        }
        if activeTool == .select {
            let hit = hitTest(world)
            let clickedInsideExistingSelection = !hit.isEmpty && !hit.isDisjoint(with: selectedKeys)
            if !clickedInsideExistingSelection { selectedKeys = hit }
            callbacks.onSelectionChanged(selectedKeys, [:])
            updateSelectionOverlay()
            #if DEBUG
            let hitLabels = hit.map { "\($0.kind.rawValue):\($0.objectID)" }.sorted()
            let selectedLabels = selectedKeys.map { "\($0.kind.rawValue):\($0.objectID)" }.sorted()
            print("[VBoard] LECTURE SELECT HIT hit=\(hitLabels) selected=\(selectedLabels) preservesGroupForDrag=\(clickedInsideExistingSelection)")
            #endif
            if !selectedKeys.isEmpty {
                // Preserve a multi-selection long enough to support dragging
                // it as a group. If the pointer is released without a drag,
                // touchesEnded collapses to the single topmost click hit.
                interaction = .movingSelection(
                    startWorld: world,
                    clickSelection: clickedInsideExistingSelection ? hit : nil
                )
                if let boardID = selectedKeys.first?.boardID { callbacks.onActiveBoardChanged(boardID) }
            }
            return
        }
        guard activeTool == .pen || activeTool == .highlighter,
              isDrawingTouch(touch),
              let item = boardItem(at: world),
              boardViews[item.boardID]?.hasFullScene == true else {
            if let item = boardItem(at: world) {
                callbacks.onActiveBoardChanged(item.boardID)
                callbacks.onDetailDemand([item.boardID])
            }
            return
        }
        let local = LectureCoordinateTransform.lectureWorldToBoardLocal(world, board: item)
        let strokeID = UUID().uuidString
        lastPencilPressure = nil
        predictedStrokePoints.removeAll(keepingCapacity: true)
        liveStrokeBoardID = item.boardID
        liveStrokePoints = [sample(local, touch: touch)]
        boardViews[item.boardID]?.showLiveStroke(points: liveStrokePoints,
                                                color: strokeColor,
                                                width: strokeWidth,
                                                pressure: lastPencilPressure)
        callbacks.onActiveBoardChanged(item.boardID)
        interaction = .drawing(boardID: item.boardID, strokeID: strokeID)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard twoTouchStartCamera == nil, let touch = touches.first else { return }
        let screen = touch.location(in: self)
        let world = screenToWorld(screen)
        #if DEBUG
        debugInput("MOVE", touch: touch, screen: screen, world: world)
        #endif
        switch interaction {
        case .panning(let startScreen, let startCamera):
            controller.setCamera(startCamera)
            controller.pan(screenTranslation: CGPoint(x: screen.x - startScreen.x,
                                                       y: screen.y - startScreen.y),
                           viewport: bounds.size)
            applyCamera(interacting: true)
        case .drawing(let boardID, _):
            guard let item = workspace.items.first(where: { $0.boardID == boardID }) else { return }
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            liveStrokePoints.append(contentsOf: samples.map {
                let world = screenToWorld($0.location(in: self))
                return sample(LectureCoordinateTransform.lectureWorldToBoardLocal(world, board: item), touch: $0)
            })
            predictedStrokePoints = (event?.predictedTouches(for: touch) ?? []).map {
                let predictedWorld = screenToWorld($0.location(in: self))
                return sample(LectureCoordinateTransform.lectureWorldToBoardLocal(predictedWorld, board: item),
                              touch: $0, updatesPressure: false)
            }
            boardViews[boardID]?.showLiveStroke(points: liveStrokePoints + predictedStrokePoints,
                                                color: strokeColor,
                                                width: strokeWidth,
                                                pressure: lastPencilPressure)
        case .lassoing:
            lassoPoints.append(world)
            updateInteractionOverlay()
        case .erasing:
            erase(from: lastEraseWorld ?? world, to: world)
            lastEraseWorld = world
        case .movingSelection(let startWorld, _):
            movePreviewDelta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
            previewSelectionMove(movePreviewDelta)
        case .resizingSelection(let session):
            let scale = SelectionResizeGeometry.scale(session: session, currentPointer: world)
            resizePreviewBounds = SelectionResizeGeometry.bounds(session: session, scale: scale)
            previewSelectionResize(session: session, scale: scale)
            updateSelectionOverlay()
        case .movingBoard(let boardID, let startWorld):
            let delta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
            if let item = workspace.items.first(where: { $0.boardID == boardID }) {
                boardViews[boardID]?.frame = item.frame.offsetBy(dx: delta.x, dy: delta.y)
                regionLayers[boardID]?.setAffineTransform(CGAffineTransform(translationX: delta.x, y: delta.y))
            }
        case .idle: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard twoTouchStartCamera == nil, let touch = touches.first else { return }
        let screen = touch.location(in: self)
        let world = screenToWorld(screen)
        #if DEBUG
        debugInput("END", touch: touch, screen: screen, world: world)
        #endif
        switch interaction {
        case .panning(let startScreen, let startCamera):
            // Some Simulator/Mac pointer paths coalesce a quick drag into
            // begin/end without an intermediate move callback. Always derive
            // the final camera from the immutable gesture start and the
            // release point so a valid drag cannot collapse to a no-op.
            controller.setCamera(startCamera)
            controller.pan(screenTranslation: CGPoint(x: screen.x - startScreen.x,
                                                       y: screen.y - startScreen.y),
                           viewport: bounds.size)
            boardViews.values.forEach { $0.endNavigation() }
            applyCamera(interacting: false)
            refineRepresentations(force: true)
            callbacks.onCameraChanged(controller.camera)
        case .drawing(let boardID, let strokeID):
            if let item = workspace.items.first(where: { $0.boardID == boardID }) {
                let local = LectureCoordinateTransform.lectureWorldToBoardLocal(world, board: item)
                let endpoint = sample(local, touch: touch)
                if let last = liveStrokePoints.last,
                   hypot(last.x - endpoint.x, last.y - endpoint.y) > 0.001 {
                    liveStrokePoints.append(endpoint)
                }
            }
            if !liveStrokePoints.isEmpty {
                callbacks.onStroke(UserStroke(id: strokeID,
                                              color: strokeColor,
                                              width: strokeWidth,
                                              opacity: strokeOpacity,
                                              points: liveStrokePoints), boardID)
            }
            boardViews[boardID]?.clearLiveStroke()
            liveStrokePoints.removeAll()
            predictedStrokePoints.removeAll()
            lastPencilPressure = nil
            liveStrokeBoardID = nil
        case .lassoing:
            finishLasso(endpoint: world)
        case .erasing:
            erase(from: lastEraseWorld ?? world, to: world)
            if case .erasing(_, let erased) = interaction, !erased.isEmpty {
                selectedKeys.subtract(erased)
                callbacks.onSelectionChanged(selectedKeys, [:])
            }
            lastEraseWorld = nil
        case .movingSelection(let startWorld, let clickSelection):
            let delta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
            let screenDistance = hypot(delta.x, delta.y) * worldTransform.scale
            if screenDistance >= 3 {
                retainSelectionMovePreview(delta)
                callbacks.onMoveSelection(selectedKeys, delta)
            } else if let clickSelection {
                clearSelectionMovePreview()
                selectedKeys = clickSelection
                callbacks.onSelectionChanged(clickSelection, [:])
            } else {
                clearSelectionMovePreview()
            }
        case .resizingSelection(let session):
            let scale = SelectionResizeGeometry.scale(session: session, currentPointer: world)
            if abs(scale - 1) > 0.001 {
                retainSelectionResizePreview(session: session, scale: scale)
                callbacks.onResizeSelection(session.keys, session.anchor, scale)
            } else {
                clearSelectionResizePreview(keys: session.keys)
            }
        case .movingBoard(let boardID, let startWorld):
            let delta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
            regionLayers[boardID]?.setAffineTransform(.identity)
            if delta != .zero { callbacks.onMoveBoard(boardID, delta) }
        case .idle: break
        }
        interaction = .idle
        movePreviewDelta = .zero
        resizePreviewBounds = nil
        updateSelectionOverlay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelContentInteraction()
    }

    private func cancelContentInteraction() {
        if case .drawing(let boardID, _) = interaction { boardViews[boardID]?.clearLiveStroke() }
        if case .panning = interaction { boardViews.values.forEach { $0.endNavigation() } }
        if case .movingSelection = interaction { clearSelectionMovePreview() }
        if case .resizingSelection(let session) = interaction {
            clearSelectionResizePreview(keys: session.keys)
        }
        if case .movingBoard(let boardID, _) = interaction,
           let item = workspace.items.first(where: { $0.boardID == boardID }) {
            boardViews[boardID]?.frame = item.frame
            regionLayers[boardID]?.setAffineTransform(.identity)
        }
        lassoPoints.removeAll()
        liveStrokePoints.removeAll()
        predictedStrokePoints.removeAll()
        lastPencilPressure = nil
        liveStrokeBoardID = nil
        lastEraseWorld = nil
        resizePreviewBounds = nil
        interaction = .idle
        updateSelectionOverlay()
    }

    private func finishLasso(endpoint: CGPoint) {
        if lassoPoints.count == 1 { lassoPoints.append(endpoint) }
        let polygon: [CGPoint]
        if lassoPoints.count == 2 {
            let a = lassoPoints[0], b = lassoPoints[1]
            polygon = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y)]
        } else { polygon = lassoPoints }
        guard polygon.count >= 3 else {
            lassoPoints.removeAll()
            updateInteractionOverlay()
            return
        }
        let bounds = polygon.reduce(into: CGRect.null) { result, point in
            result = result.union(CGRect(origin: point, size: .zero))
        }
        var selected = Set<SelectionKey>()
        var selectedPDFRegions: [String: CGRect] = [:]
        for item in spatialIndex.query(bounds) {
            guard let boardView = boardViews[item.boardID], boardView.hasFullScene else {
                callbacks.onDetailDemand([item.boardID])
                continue
            }
            let localPolygon = polygon.map { LectureCoordinateTransform.lectureWorldToBoardLocal($0, board: item) }
            let boardSelection = boardView.selectionKeys(containedBy: localPolygon)
            selected.formUnion(boardSelection)
            if boardSelection.contains(where: {
                $0.kind == .professorPath && $0.objectID == PDFBoardSource.logicalID
            }) {
                let localBounds = bounds.offsetBy(dx: -CGFloat(item.canvasX), dy: -CGFloat(item.canvasY))
                    .intersection(CGRect(x: 0, y: 0, width: item.boardWidth, height: item.boardHeight))
                if !localBounds.isNull { selectedPDFRegions[item.boardID] = localBounds }
            }
        }
        selectedKeys = selected
        lassoPoints.removeAll()
        #if DEBUG
        print("[VBoard] LECTURE LASSO boardsQueried=\(spatialIndex.query(bounds).count) selected=\(selected.count) ids=\(selected.map { "\($0.boardID):\($0.objectID)" }.sorted())")
        #endif
        callbacks.onSelectionChanged(selected, selectedPDFRegions)
        if let boardID = selected.first?.boardID { callbacks.onActiveBoardChanged(boardID) }
        updateSelectionOverlay()
    }

    private func hitTest(_ world: CGPoint) -> Set<SelectionKey> {
        guard let item = boardItem(at: world), let view = boardViews[item.boardID], view.hasFullScene else {
            if let item = boardItem(at: world) {
                callbacks.onActiveBoardChanged(item.boardID)
                callbacks.onDetailDemand([item.boardID])
            }
            return []
        }
        let local = LectureCoordinateTransform.lectureWorldToBoardLocal(world, board: item)
        return view.hitTestKeys(at: local)
    }

    private func erase(from start: CGPoint, to end: CGPoint) {
        let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -14, dy: -14)
        var hits = Set<SelectionKey>()
        for item in spatialIndex.query(bounds) {
            guard let view = boardViews[item.boardID], view.hasFullScene else { continue }
            let localStart = LectureCoordinateTransform.lectureWorldToBoardLocal(start, board: item)
            let localEnd = LectureCoordinateTransform.lectureWorldToBoardLocal(end, board: item)
            hits.formUnion(view.eraseKeys(from: localStart, to: localEnd))
        }
        if case .erasing(let boardID, let already) = interaction {
            let fresh = hits.subtracting(already)
            guard !fresh.isEmpty else { return }
            callbacks.onDelete(fresh)
            interaction = .erasing(boardID: boardID ?? fresh.first?.boardID, erased: already.union(fresh))
        }
    }

    private func previewSelectionMove(_ delta: CGPoint) {
        let grouped = Dictionary(grouping: selectedKeys, by: \.boardID)
        for (boardID, keys) in grouped {
            boardViews[boardID]?.previewMove(keys: Set(keys), delta: delta)
        }
        updateSelectionOverlay()
    }

    private func clearSelectionMovePreview() {
        let grouped = Dictionary(grouping: selectedKeys, by: \.boardID)
        for (boardID, keys) in grouped { boardViews[boardID]?.clearMovePreview(keys: Set(keys)) }
    }

    private func retainSelectionMovePreview(_ delta: CGPoint) {
        let grouped = Dictionary(grouping: selectedKeys, by: \.boardID)
        for (boardID, keys) in grouped {
            boardViews[boardID]?.retainMovePreview(keys: Set(keys), delta: delta)
        }
    }

    private func previewSelectionResize(session: SelectionResizeSession, scale: CGFloat) {
        let grouped = Dictionary(grouping: session.keys, by: \.boardID)
        for (boardID, keys) in grouped {
            guard let item = workspace.items.first(where: { $0.boardID == boardID }) else { continue }
            let localAnchor = LectureCoordinateTransform.lectureWorldToBoardLocal(session.anchor, board: item)
            boardViews[boardID]?.previewResize(keys: Set(keys), anchor: localAnchor, scale: scale)
        }
    }

    private func clearSelectionResizePreview(keys: Set<SelectionKey>) {
        let grouped = Dictionary(grouping: keys, by: \.boardID)
        for (boardID, boardKeys) in grouped {
            boardViews[boardID]?.clearResizePreview(keys: Set(boardKeys))
        }
    }

    private func retainSelectionResizePreview(session: SelectionResizeSession, scale: CGFloat) {
        let grouped = Dictionary(grouping: session.keys, by: \.boardID)
        for (boardID, keys) in grouped {
            guard let item = workspace.items.first(where: { $0.boardID == boardID }) else { continue }
            let localAnchor = LectureCoordinateTransform.lectureWorldToBoardLocal(session.anchor, board: item)
            boardViews[boardID]?.retainResizePreview(keys: Set(keys), anchor: localAnchor, scale: scale)
        }
    }

    private func updateInteractionOverlay() {
        guard !lassoPoints.isEmpty else { updateSelectionOverlay(); return }
        configureInteractionStrokeForCurrentZoom()
        let path = UIBezierPath()
        for (index, point) in lassoPoints.enumerated() {
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        interactionLayer.path = path.cgPath
        interactionLayer.isHidden = false
    }

    private func updateSelectionOverlay() {
        if !lassoPoints.isEmpty { updateInteractionOverlay(); return }
        guard var union = resizePreviewBounds ?? selectionWorldBounds() else {
            interactionLayer.isHidden = true
            interactionLayer.path = nil
            callbacks.onSelectionScreenBoundsChanged(nil)
            return
        }
        configureInteractionStrokeForCurrentZoom()
        if case .movingSelection = interaction { union = union.offsetBy(dx: movePreviewDelta.x, dy: movePreviewDelta.y) }
        let screenSpaceInset = 10 / max(worldTransform.scale, 0.001)
        let path = UIBezierPath(rect: union.insetBy(dx: -screenSpaceInset,
                                                    dy: -screenSpaceInset))
        let radius = 6 / max(worldTransform.scale, 0.001)
        for handle in SelectionResizeHandle.allCases {
            let center = handle.point(in: union)
            path.append(UIBezierPath(ovalIn: CGRect(x: center.x - radius,
                                                    y: center.y - radius,
                                                    width: radius * 2,
                                                    height: radius * 2)))
        }
        interactionLayer.path = path.cgPath
        interactionLayer.isHidden = false
        let topLeft = worldTransform.screenPoint(for: CGPoint(x: union.minX, y: union.minY))
        let bottomRight = worldTransform.screenPoint(for: CGPoint(x: union.maxX, y: union.maxY))
        callbacks.onSelectionScreenBoundsChanged(CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        ))
    }

    /// The overlay lives in world space with the board layers, but its chrome
    /// should remain legible at every camera zoom. Compensating only the
    /// stroke presentation keeps the canonical lasso/selection geometry in
    /// world coordinates while maintaining a stable two-point outline.
    private func configureInteractionStrokeForCurrentZoom() {
        let inverseScale = 1 / max(worldTransform.scale, 0.001)
        interactionLayer.lineWidth = 2 * inverseScale
        interactionLayer.lineDashPattern = [NSNumber(value: 8 * inverseScale),
                                            NSNumber(value: 5 * inverseScale)]
    }

    private func resizeHandle(at world: CGPoint, bounds: CGRect) -> SelectionResizeHandle? {
        let tolerance = 16 / max(worldTransform.scale, 0.001)
        return SelectionResizeHandle.allCases.first {
            let point = $0.point(in: bounds)
            return hypot(world.x - point.x, world.y - point.y) <= tolerance
        }
    }

    private func selectionWorldBounds() -> CGRect? {
        var union = CGRect.null
        let grouped = Dictionary(grouping: selectedKeys, by: \.boardID)
        for (boardID, keys) in grouped {
            guard let item = workspace.items.first(where: { $0.boardID == boardID }),
                  let local = boardViews[boardID]?.selectionBounds(keys: Set(keys)) else { continue }
            let world = LectureCoordinateTransform.boardLocalToLectureWorld(local, board: item)
            #if DEBUG
            let labels = keys.map { "\($0.kind.rawValue):\($0.objectID)" }.sorted()
            print("[VBoard] LECTURE SELECTION BOUNDS board=\(boardID) keys=\(labels) local=\(local) placement=(\(item.canvasX),\(item.canvasY)) world=\(world)")
            #endif
            union = union.union(world)
        }
        return union.isNull ? nil : union
    }

    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        if touch.type == .pencil { return true }
        #if targetEnvironment(simulator)
        return touch.type == .indirectPointer || touch.type == .direct
        #else
        return false
        #endif
    }

    private func sample(_ local: CGPoint, touch: UITouch, updatesPressure: Bool = true) -> StrokePoint {
        let pressure: Double
        #if targetEnvironment(simulator)
        pressure = 1
        #else
        let normalized = touch.force / max(touch.maximumPossibleForce, 1)
        let filtered = updatesPressure
            ? PencilPressureResponse.smoothed(previous: lastPencilPressure, sample: normalized)
            : PencilPressureResponse.curved(normalized)
        if updatesPressure { lastPencilPressure = filtered }
        pressure = Double(filtered)
        #endif
        return StrokePoint(x: local.x, y: local.y, pressure: pressure)
    }

    private var activeStrokeStyle: CanvasStrokeStyle { activeTool == .highlighter ? markerStyle : penStyle }
    private var strokeColor: String { activeStrokeStyle.colorHex }
    private var strokeWidth: Double { activeStrokeStyle.width }
    private var strokeOpacity: Double { activeStrokeStyle.opacity }

    // MARK: - Keyboard development controls

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "+", modifierFlags: .command, action: #selector(zoomIn)),
            UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(zoomIn)),
            UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(zoomOut)),
            UIKeyCommand(input: "0", modifierFlags: .command, action: #selector(fitActiveBoard)),
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoCommand)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoCommand))
        ]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            isSpacePressed = true
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            isSpacePressed = false
        }
        super.pressesEnded(presses, with: event)
    }

    @objc private func zoomIn() { zoom(by: 1.25) }
    @objc private func zoomOut() { zoom(by: 0.8) }
    @objc private func fitActiveBoard() { if let boardID = workspace.activeBoardID { focus(boardID: boardID) } }
    @objc private func undoCommand() { callbacks.onUndo() }
    @objc private func redoCommand() { callbacks.onRedo() }

    private func zoom(by magnification: CGFloat) {
        controller.zoom(by: magnification,
                        anchoredAt: CGPoint(x: bounds.midX, y: bounds.midY),
                        viewport: bounds.size)
        applyCamera(interacting: false)
        refineRepresentations(force: true)
        callbacks.onCameraChanged(controller.camera)
    }
}

private final class LectureBoardRenderView: UIView {
    private static let thumbnailCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private let paperLayer = CAShapeLayer()
    private let professor = ProfessorSVGView()
    private let pdfSource = PDFPageRenderView()
    private let thumbnail = UIImageView()
    private let header = UILabel()
    private let vectorIndicator = BoardVectorLoadingIndicator()
    private let userLayer = CALayer()
    private var objectLayers: [String: CALayer] = [:]
    private var resizePreviewPositions: [String: CGPoint] = [:]
    private var item: WorkspaceBoardItem?
    private var scene: WorkspaceBoardScene?
    private var representedThumbnailURL: URL?
    private var thumbnailTask: Task<Void, Never>?
    private var liveStrokeLayer: CAShapeLayer?
    private var vectorProgress: Double = 1

    var hasFullScene: Bool { scene != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isUserInteractionEnabled = false
        paperLayer.fillColor = UIColor(red: 0.985, green: 0.982, blue: 0.965, alpha: 1).cgColor
        paperLayer.strokeColor = UIColor.separator.withAlphaComponent(0.4).cgColor
        paperLayer.lineWidth = 2
        layer.addSublayer(paperLayer)
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        addSubview(thumbnail)
        addSubview(pdfSource)
        addSubview(professor)
        professor.onProgress = { [weak self] progress in
            guard let self else { return }
            self.vectorProgress = progress
            let incomplete = progress < 0.999
            let previewOpacity: CGFloat
            if self.item?.sourceKind == .image {
                // A generic image is canonical source content, not a temporary
                // physical-whiteboard processing preview. It remains visible.
                previewOpacity = 1
            } else {
                let hasStableVectorProxy = self.professor.hasVisiblePresentation
                previewOpacity = VectorProgressivePresentationPolicy.previewOpacity(
                    progress: progress,
                    hasStableVectorPresentation: hasStableVectorProxy
                )
            }
            self.thumbnail.isHidden = previewOpacity == 0
            self.thumbnail.alpha = previewOpacity
            self.vectorIndicator.transition(to: incomplete
                                            ? (progress > 0 ? .vectorPartial : .vectorLoading)
                                            : .vectorReady)
        }
        userLayer.anchorPoint = .zero
        userLayer.position = .zero
        layer.addSublayer(userLayer)
        header.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        header.textColor = .label
        header.font = .systemFont(ofSize: 17, weight: .semibold)
        header.numberOfLines = 1
        header.layer.cornerRadius = 8
        header.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        header.layer.masksToBounds = true
        addSubview(header)
        addSubview(vectorIndicator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperLayer.frame = bounds
        paperLayer.path = UIBezierPath(rect: bounds).cgPath
        thumbnail.frame = bounds
        pdfSource.bounds = CGRect(origin: .zero, size: bounds.size)
        pdfSource.layer.position = .zero
        professor.frame = bounds
        userLayer.bounds = bounds
        userLayer.position = .zero
        header.frame = CGRect(x: 0, y: -40, width: bounds.width, height: 40)
        let indicatorSize = vectorIndicator.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        vectorIndicator.frame = CGRect(
            x: bounds.midX - indicatorSize.width / 2,
            y: max(12, bounds.maxY - indicatorSize.height - 18),
            width: indicatorSize.width,
            height: indicatorSize.height
        )
    }

    func configure(item: WorkspaceBoardItem,
                   scene: WorkspaceBoardScene?,
                   representation: BoardRepresentation,
                   physicalBoardShowsPaper: Bool,
                   thumbnailURL: URL?,
                   loadAsset: @escaping (String) async throws -> Data) {
        let sceneChanged = self.scene != scene
        self.item = item
        self.scene = scene
        header.text = "  \(item.title)   ·   \(dateLabel(item.createdAt))   ·   \(item.unitLabel)"
        let showPaper = item.sourceKind.isPDF || physicalBoardShowsPaper
        paperLayer.fillColor = showPaper
            ? UIColor.systemBackground.withAlphaComponent(item.sourceKind.isPDF ? 1 : 0.9).cgColor
            : UIColor.clear.cgColor
        paperLayer.strokeColor = UIColor.separator.withAlphaComponent(showPaper ? 0.32 : 0.16).cgColor
        if representation == .fullVector, let scene {
            if sceneChanged { vectorIndicator.transition(to: .vectorLoading) }
            professor.isHidden = false
            if let pdfData = scene.pdfData {
                pdfSource.display(data: pdfData)
                pdfSource.isHidden = false
                PDFBoardSource.apply(
                    transform: scene.editor.importedTransforms[PDFBoardSource.logicalID],
                    to: pdfSource
                )
            } else {
                pdfSource.clear()
                pdfSource.isHidden = true
            }
            if sceneChanged {
                thumbnail.isHidden = false
                thumbnail.alpha = 1
                loadThumbnail(thumbnailURL, loadAsset: loadAsset)
                professor.display(scene.document,
                                  transform: WorldScreenTransform(
                                    camera: CameraRect(x: 0, y: 0, width: item.boardWidth, height: item.boardHeight),
                                    viewport: bounds.size),
                                  importedTransforms: scene.editor.importedTransforms,
                                  composition: scene.composition)
                rebuildUserLayers(scene.editor.objects)
            }
            if vectorProgress >= 0.999 {
                thumbnail.isHidden = item.sourceKind != .image
                thumbnail.alpha = 1
                vectorIndicator.transition(to: .vectorReady)
            }
        } else {
            professor.isHidden = true
            pdfSource.isHidden = true
            userLayer.isHidden = true
            thumbnail.isHidden = false
            thumbnail.alpha = item.sourceKind.isPDF || physicalBoardShowsPaper ? 1 : 0.24
            vectorIndicator.transition(to: representation == .fullVector
                                         ? .vectorLoading : .previewReady)
            loadThumbnail(thumbnailURL, loadAsset: loadAsset)
        }
        if scene != nil { userLayer.isHidden = false }
        setNeedsLayout()
    }

    func updateVisibility(localCamera: CGRect, viewport: CGSize, interacting: Bool) {
        guard item != nil, scene != nil else { return }
        let camera = CameraRect(x: localCamera.minX, y: localCamera.minY,
                                width: max(localCamera.width, 1), height: max(localCamera.height, 1))
        professor.updateCamera(WorldScreenTransform(camera: camera, viewport: viewport), interacting: interacting)
    }

    func beginNavigation() { professor.beginNavigation() }
    func endNavigation() {
        professor.endNavigationUsingCurrentCamera()
    }

    func hitTestKeys(at point: CGPoint) -> Set<SelectionKey> {
        guard let item, let scene else { return [] }
        // User-created objects are the topmost editable layer. Returning the
        // professor path underneath a user stroke as well made a single click
        // look as if the old professor selection chrome had remained active,
        // and a subsequent move mutated two different logical objects.
        if let objectID = BoardHitTestPolicy.topmostEditorObjectID(
            at: point,
            objects: scene.editor.objects,
            tolerance: 12
        ) {
            return [SelectionKey(boardID: item.boardID,
                                 objectID: objectID,
                                 kind: .editorObject,
                                 objectType: scene.editor.objects.first(where: { $0.id == objectID })?.type)]
        }
        if let id = professor.hitTest(point) {
            return [SelectionKey(boardID: item.boardID,
                                 objectID: id,
                                 kind: .professorPath,
                                 objectType: "professorPath")]
        }
        return []
    }

    func selectionKeys(containedBy polygon: [CGPoint]) -> Set<SelectionKey> {
        guard let item, let scene else { return [] }
        var result = Set<SelectionKey>()
        for object in scene.editor.objects {
            let samples = objectSamples(object)
            guard !samples.isEmpty else { continue }
            let contained = samples.filter { polygonContains($0, polygon: polygon) }.count
            if Double(contained) / Double(samples.count) >= 0.65 {
                result.insert(SelectionKey(boardID: item.boardID, objectID: object.id,
                                           kind: .editorObject, objectType: object.type))
            }
        }
        for id in professor.ids(containedBy: polygon) {
            result.insert(SelectionKey(boardID: item.boardID, objectID: id,
                                       kind: .professorPath, objectType: "professorPath"))
        }
        return result
    }

    func eraseKeys(from start: CGPoint, to end: CGPoint) -> Set<SelectionKey> {
        guard let item, let scene else { return [] }
        let segment = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -14, dy: -14)
        var result = Set(scene.editor.objects.compactMap { object -> SelectionKey? in
            objectBounds(object).intersects(segment)
                ? SelectionKey(boardID: item.boardID, objectID: object.id,
                               kind: .editorObject, objectType: object.type)
                : nil
        })
        for id in professor.ids(intersecting: segment) {
            result.insert(SelectionKey(boardID: item.boardID, objectID: id,
                                       kind: .professorPath, objectType: "professorPath"))
        }
        return result
    }

    func selectionBounds(keys: Set<SelectionKey>) -> CGRect? {
        guard let scene else { return nil }
        var result = CGRect.null
        for key in keys {
            if key.kind == .professorPath { result = result.union(professor.bounds(for: key.objectID)) }
            if let object = scene.editor.objects.first(where: { $0.id == key.objectID }) {
                result = result.union(objectBounds(object))
            }
        }
        return result.isNull ? nil : result
    }

    func previewMove(keys: Set<SelectionKey>, delta: CGPoint) {
        let professorIDs = Set(keys.filter { $0.kind == .professorPath }.map(\.objectID))
        professor.previewTranslation(ids: professorIDs, delta: delta)
        for key in keys where key.kind == .editorObject {
            objectLayers[key.objectID]?.setAffineTransform(CGAffineTransform(translationX: delta.x, y: delta.y))
        }
    }

    func clearMovePreview(keys: Set<SelectionKey>) {
        professor.clearPreviewTranslation(ids: Set(keys.filter { $0.kind == .professorPath }.map(\.objectID)))
        for key in keys where key.kind == .editorObject { objectLayers[key.objectID]?.setAffineTransform(.identity) }
    }

    func retainMovePreview(keys: Set<SelectionKey>, delta: CGPoint) {
        professor.retainPreviewTranslation(
            ids: Set(keys.filter { $0.kind == .professorPath }.map(\.objectID)),
            delta: delta
        )
        // Editor-object layers intentionally keep their cheap presentation
        // transform until the synchronously updated scene rebuilds them.
    }

    func previewResize(keys: Set<SelectionKey>, anchor: CGPoint, scale: CGFloat) {
        professor.previewScale(ids: Set(keys.filter { $0.kind == .professorPath }.map(\.objectID)),
                               anchor: anchor, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in keys where key.kind == .editorObject {
            guard let layer = objectLayers[key.objectID] else { continue }
            let original = resizePreviewPositions[key.objectID] ?? layer.position
            resizePreviewPositions[key.objectID] = original
            layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            layer.position = CGPoint(x: anchor.x + (original.x - anchor.x) * scale,
                                     y: anchor.y + (original.y - anchor.y) * scale)
        }
        CATransaction.commit()
    }

    func clearResizePreview(keys: Set<SelectionKey>) {
        professor.clearPreviewScale(ids: Set(keys.filter { $0.kind == .professorPath }.map(\.objectID)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in keys where key.kind == .editorObject {
            guard let layer = objectLayers[key.objectID] else { continue }
            layer.setAffineTransform(.identity)
            if let original = resizePreviewPositions.removeValue(forKey: key.objectID) {
                layer.position = original
            }
        }
        CATransaction.commit()
    }

    func retainResizePreview(keys: Set<SelectionKey>, anchor: CGPoint, scale: CGFloat) {
        professor.retainPreviewScale(
            ids: Set(keys.filter { $0.kind == .professorPath }.map(\.objectID)),
            anchor: anchor,
            scale: scale
        )
        // As with move, exact editor layers replace the transient transform
        // when the canonical mutation reaches this view.
    }

    func showLiveStroke(points: [StrokePoint], color: String, width: Double,
                        pressure: CGFloat?) {
        let layer = liveStrokeLayer ?? {
            let layer = CAShapeLayer()
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            layer.lineJoin = .round
            userLayer.addSublayer(layer)
            liveStrokeLayer = layer
            return layer
        }()
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: point.x, y: point.y)
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        layer.path = path.cgPath
        layer.strokeColor = UIColor(svgHex: color).cgColor
        layer.lineWidth = width * Double(PencilPressureResponse.widthMultiplier(for: pressure ?? 1))
    }

    func clearLiveStroke() {
        liveStrokeLayer?.removeFromSuperlayer()
        liveStrokeLayer = nil
    }

    private func rebuildUserLayers(_ objects: [CanvasObject]) {
        resizePreviewPositions.removeAll(keepingCapacity: true)
        objectLayers.values.forEach { $0.removeFromSuperlayer() }
        objectLayers.removeAll(keepingCapacity: true)
        for object in SceneComposition.canonicalEditorObjects(objects) {
            let layer: CALayer
            if object.type == "text", object.text != nil || object.sourceMarkdown != nil {
                layer = CompactStudyPresentation.layer(
                    for: object,
                    frame: objectBounds(object),
                    contentsScale: window?.screen.scale ?? UIScreen.main.scale
                )
            } else if object.type == "path", let definition = object.d,
                      let parsed = try? SVGPathParser.cachedPath(from: definition) {
                let shape = CAShapeLayer()
                var transform = CGAffineTransform.identity
                    .translatedBy(x: CGFloat(object.translation?.x ?? 0),
                                  y: CGFloat(object.translation?.y ?? 0))
                    .scaledBy(x: CGFloat(object.scaleX ?? 1),
                              y: CGFloat(object.scaleY ?? 1))
                shape.path = parsed.copy(using: &transform)
                shape.fillColor = UIColor(svgHex: object.fill ?? object.color ?? "#183153")
                    .withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor
                shape.fillRule = .evenOdd
                layer = shape
            } else {
                let shape = CAShapeLayer()
                let path = UIBezierPath()
                let translation = object.translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
                let scaleX = object.scaleX ?? 1
                let scaleY = object.scaleY ?? 1
                for (index, point) in (object.points ?? []).enumerated() {
                    let p = CGPoint(x: point.x * scaleX + translation.x,
                                    y: point.y * scaleY + translation.y)
                    index == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                shape.path = path.cgPath
                shape.fillColor = UIColor.clear.cgColor
                shape.strokeColor = UIColor(svgHex: object.color ?? "#183153")
                    .withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor
                shape.lineWidth = (object.width ?? 4) * sqrt(abs(scaleX * scaleY))
                shape.lineCap = .round
                shape.lineJoin = .round
                layer = shape
            }
            objectLayers[object.id] = layer
            userLayer.addSublayer(layer)
        }
    }

    private func objectBounds(_ object: CanvasObject) -> CGRect {
        BoardHitTestPolicy.bounds(of: object)
    }

    private func objectSamples(_ object: CanvasObject) -> [CGPoint] {
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
        let bounds = objectBounds(object)
        guard !bounds.isNull else { return [] }
        return [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.midX, y: bounds.midY)]
    }

    private func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let previous = index == polygon.startIndex ? polygon.index(before: polygon.endIndex) : polygon.index(before: index)
            let a = polygon[index], b = polygon[previous]
            let denominator = b.y - a.y
            if abs(denominator) > .ulpOfOne,
               (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / denominator + a.x { inside.toggle() }
        }
        return inside
    }

    private func loadThumbnail(_ url: URL?,
                               loadAsset: @escaping (String) async throws -> Data) {
        guard representedThumbnailURL != url else { return }
        thumbnailTask?.cancel()
        representedThumbnailURL = url
        thumbnail.image = nil
        guard let url else { return }
        if let cached = Self.thumbnailCache.object(forKey: url as NSURL) {
            thumbnail.image = cached
            return
        }
        thumbnailTask = Task { [weak self] in
            guard let data = try? await loadAsset(url.absoluteString),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            Self.thumbnailCache.setObject(image, forKey: url as NSURL, cost: data.count)
            guard self?.representedThumbnailURL == url else { return }
            self?.thumbnail.image = image
        }
    }

    private func dateLabel(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
