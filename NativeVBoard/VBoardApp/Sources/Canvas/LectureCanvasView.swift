import SwiftUI
import UIKit

private enum LectureInteraction {
    case idle
    case panning(startScreen: CGPoint, startCamera: CameraRect)
    case drawing(boardID: String, strokeID: String)
    case lassoing
    case erasing(boardID: String?, erased: Set<SelectionKey>)
    case movingSelection(startWorld: CGPoint, clickSelection: Set<SelectionKey>?)
    case resizingText(key: SelectionKey, startWorld: CGPoint, startBounds: CGRect)
    case movingBoard(boardID: String, startWorld: CGPoint)
}

struct LectureCanvasView: UIViewRepresentable {
    let workspace: LectureWorkspace
    let scenes: [String: WorkspaceBoardScene]
    let selectedKeys: Set<SelectionKey>
    let tool: CanvasTool
    let thumbnailURLs: [String: URL]
    let focusRequest: WorkspaceFocusRequest?
    var onCameraChanged: (CameraRect) -> Void
    var onActiveBoardChanged: (String) -> Void
    var onDetailDemand: (Set<String>) -> Void
    var onSelectionChanged: (Set<SelectionKey>) -> Void
    var onStroke: (UserStroke, String) -> Void
    var onMoveSelection: (Set<SelectionKey>, CGPoint) -> Void
    var onResizeTextObject: (SelectionKey, CGSize) -> Void
    var onDelete: (Set<SelectionKey>) -> Void
    var onMoveBoard: (String, CGPoint) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void

    func makeUIView(context: Context) -> LectureCanvasUIView {
        LectureCanvasUIView(
            workspace: workspace,
            scenes: scenes,
            selectedKeys: selectedKeys,
            tool: tool,
            thumbnailURLs: thumbnailURLs,
            callbacks: callbacks
        )
    }

    func updateUIView(_ view: LectureCanvasUIView, context: Context) {
        view.update(workspace: workspace, scenes: scenes, selectedKeys: selectedKeys,
                    tool: tool, thumbnailURLs: thumbnailURLs,
                    focusRequest: focusRequest, callbacks: callbacks)
    }

    private var callbacks: LectureCanvasCallbacks {
        LectureCanvasCallbacks(onCameraChanged: onCameraChanged,
                               onActiveBoardChanged: onActiveBoardChanged,
                               onDetailDemand: onDetailDemand,
                               onSelectionChanged: onSelectionChanged,
                               onStroke: onStroke,
                               onMoveSelection: onMoveSelection,
                               onResizeTextObject: onResizeTextObject,
                               onDelete: onDelete,
                               onMoveBoard: onMoveBoard,
                               onUndo: onUndo,
                               onRedo: onRedo)
    }
}

struct LectureCanvasCallbacks {
    var onCameraChanged: (CameraRect) -> Void
    var onActiveBoardChanged: (String) -> Void
    var onDetailDemand: (Set<String>) -> Void
    var onSelectionChanged: (Set<SelectionKey>) -> Void
    var onStroke: (UserStroke, String) -> Void
    var onMoveSelection: (Set<SelectionKey>, CGPoint) -> Void
    var onResizeTextObject: (SelectionKey, CGSize) -> Void
    var onDelete: (Set<SelectionKey>) -> Void
    var onMoveBoard: (String, CGPoint) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
}

final class LectureCanvasUIView: UIView, UIGestureRecognizerDelegate {
    private let worldContainer = UIView()
    private let interactionLayer = CAShapeLayer()
    private var boardViews: [String: LectureBoardRenderView] = [:]
    private var workspace: LectureWorkspace
    private var scenes: [String: WorkspaceBoardScene]
    private var selectedKeys: Set<SelectionKey>
    private var activeTool: CanvasTool
    private var thumbnailURLs: [String: URL]
    private var callbacks: LectureCanvasCallbacks
    private var controller: CameraController
    private var spatialIndex: WorkspaceSpatialIndex
    private var representations: [String: BoardRepresentation] = [:]
    private var lastDetailDemand = Set<String>()
    private var interaction: LectureInteraction = .idle
    private var lassoPoints: [CGPoint] = []
    private var liveStrokePoints: [StrokePoint] = []
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

    init(workspace: LectureWorkspace,
         scenes: [String: WorkspaceBoardScene],
         selectedKeys: Set<SelectionKey>,
         tool: CanvasTool,
         thumbnailURLs: [String: URL],
         callbacks: LectureCanvasCallbacks) {
        self.workspace = workspace
        self.scenes = scenes
        self.selectedKeys = selectedKeys
        self.activeTool = tool
        self.thumbnailURLs = thumbnailURLs
        self.callbacks = callbacks
        controller = CameraController(camera: workspace.camera)
        spatialIndex = WorkspaceSpatialIndex(items: workspace.items)
        super.init(frame: .zero)

        backgroundColor = UIColor.systemGray6
        clipsToBounds = true
        isMultipleTouchEnabled = true
        worldContainer.backgroundColor = .clear
        worldContainer.clipsToBounds = false
        worldContainer.isUserInteractionEnabled = false
        worldContainer.layer.anchorPoint = .zero
        worldContainer.layer.position = .zero
        addSubview(worldContainer)

        interactionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        interactionLayer.strokeColor = UIColor.systemBlue.cgColor
        interactionLayer.lineWidth = 2
        interactionLayer.lineDashPattern = [8, 5]
        interactionLayer.isHidden = true
        WorldOverlayLayerLayout.pin(interactionLayer, to: worldContainer.bounds)
        worldContainer.layer.addSublayer(interactionLayer)

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

        becomeFirstResponder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        worldContainer.bounds = CGRect(origin: .zero, size: bounds.size)
        worldContainer.layer.position = .zero
        WorldOverlayLayerLayout.pin(interactionLayer, to: worldContainer.bounds)
        applyCamera(interacting: false)
        refineRepresentations()
    }

    func update(workspace: LectureWorkspace,
                scenes: [String: WorkspaceBoardScene],
                selectedKeys: Set<SelectionKey>,
                tool: CanvasTool,
                thumbnailURLs: [String: URL],
                focusRequest: WorkspaceFocusRequest?,
                callbacks: LectureCanvasCallbacks) {
        let placementsChanged = self.workspace.items != workspace.items
        let scenesChanged = self.scenes != scenes
        self.workspace = workspace
        self.scenes = scenes
        self.selectedKeys = selectedKeys
        self.activeTool = tool
        self.thumbnailURLs = thumbnailURLs
        self.callbacks = callbacks
        if controller.camera != workspace.camera, !isInteracting {
            controller.setCamera(workspace.camera)
        }
        if placementsChanged { spatialIndex = WorkspaceSpatialIndex(items: workspace.items) }
        if placementsChanged || scenesChanged { refineRepresentations(force: true) }
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
        case .resizingText: return "RESIZING_TEXT"
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
        for (boardID, view) in boardViews {
            guard let item = workspace.items.first(where: { $0.boardID == boardID }) else { continue }
            let localCamera = LectureCoordinateTransform.lectureWorldToBoardLocal(controller.camera.cgRect, board: item)
            view.updateVisibility(localCamera: localCamera, viewport: bounds.size, interacting: interacting)
        }
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
                                thumbnailURL: thumbnailURLs[item.boardID])
        }
        if let activeBoardID = workspace.activeBoardID, let activeView = boardViews[activeBoardID] {
            worldContainer.bringSubviewToFront(activeView)
        }
        interactionLayer.removeFromSuperlayer()
        worldContainer.layer.addSublayer(interactionLayer)
        updateSelectionOverlay()
        applyCamera(interacting: false)
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
        let headerAndPaper = item.frame.insetBy(dx: -32, dy: -32).union(
            CGRect(x: item.frame.minX, y: item.frame.minY - 52, width: item.frame.width, height: 52)
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
                ? item.frame.union(CGRect(x: item.frame.minX, y: item.frame.minY - 52, width: item.frame.width, height: 52))
                : item.effectiveFrame.union(item.frame)
            return rect.contains(lecturePoint)
        }
    }

    private func isHeader(_ point: CGPoint, item: WorkspaceBoardItem) -> Bool {
        CGRect(x: item.frame.minX, y: item.frame.minY - 52, width: item.frame.width, height: 52).contains(point)
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
        if activeTool == .select,
           let resize = resizableTextSelection(),
           resizeHandleContains(world, bounds: resize.bounds) {
            resizePreviewBounds = resize.bounds
            interaction = .resizingText(key: resize.key, startWorld: world,
                                        startBounds: resize.bounds)
            callbacks.onActiveBoardChanged(resize.key.boardID)
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
            callbacks.onSelectionChanged(selectedKeys)
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
        liveStrokeBoardID = item.boardID
        liveStrokePoints = [sample(local, touch: touch)]
        boardViews[item.boardID]?.showLiveStroke(points: liveStrokePoints,
                                                color: strokeColor,
                                                width: strokeWidth)
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
            boardViews[boardID]?.showLiveStroke(points: liveStrokePoints,
                                                color: strokeColor,
                                                width: strokeWidth)
        case .lassoing:
            lassoPoints.append(world)
            updateInteractionOverlay()
        case .erasing:
            erase(from: lastEraseWorld ?? world, to: world)
            lastEraseWorld = world
        case .movingSelection(let startWorld, _):
            movePreviewDelta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
            previewSelectionMove(movePreviewDelta)
        case .resizingText(let key, let startWorld, let startBounds):
            let size = CGSize(width: max(120, startBounds.width + world.x - startWorld.x),
                              height: max(80, startBounds.height + world.y - startWorld.y))
            resizePreviewBounds = CGRect(origin: startBounds.origin, size: size)
            boardViews[key.boardID]?.previewResize(key: key, size: size)
            updateSelectionOverlay()
        case .movingBoard(let boardID, let startWorld):
            let delta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
            if let item = workspace.items.first(where: { $0.boardID == boardID }) {
                boardViews[boardID]?.frame = item.frame.offsetBy(dx: delta.x, dy: delta.y)
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
            liveStrokeBoardID = nil
        case .lassoing:
            finishLasso(endpoint: world)
        case .erasing:
            erase(from: lastEraseWorld ?? world, to: world)
            if case .erasing(_, let erased) = interaction, !erased.isEmpty {
                selectedKeys.subtract(erased)
                callbacks.onSelectionChanged(selectedKeys)
            }
            lastEraseWorld = nil
        case .movingSelection(let startWorld, let clickSelection):
            let delta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
            clearSelectionMovePreview()
            let screenDistance = hypot(delta.x, delta.y) * worldTransform.scale
            if screenDistance >= 3 {
                callbacks.onMoveSelection(selectedKeys, delta)
            } else if let clickSelection {
                selectedKeys = clickSelection
                callbacks.onSelectionChanged(clickSelection)
            }
        case .resizingText(let key, let startWorld, let startBounds):
            let size = CGSize(width: max(120, startBounds.width + world.x - startWorld.x),
                              height: max(80, startBounds.height + world.y - startWorld.y))
            boardViews[key.boardID]?.clearResizePreview(key: key)
            callbacks.onResizeTextObject(key, size)
        case .movingBoard(let boardID, let startWorld):
            let delta = CGPoint(x: world.x - startWorld.x, y: world.y - startWorld.y)
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
        if case .resizingText(let key, _, _) = interaction {
            boardViews[key.boardID]?.clearResizePreview(key: key)
        }
        if case .movingBoard(let boardID, _) = interaction,
           let item = workspace.items.first(where: { $0.boardID == boardID }) {
            boardViews[boardID]?.frame = item.frame
        }
        lassoPoints.removeAll()
        liveStrokePoints.removeAll()
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
        for item in spatialIndex.query(bounds) {
            guard let boardView = boardViews[item.boardID], boardView.hasFullScene else {
                callbacks.onDetailDemand([item.boardID])
                continue
            }
            let localPolygon = polygon.map { LectureCoordinateTransform.lectureWorldToBoardLocal($0, board: item) }
            selected.formUnion(boardView.selectionKeys(containedBy: localPolygon))
        }
        selectedKeys = selected
        lassoPoints.removeAll()
        #if DEBUG
        print("[VBoard] LECTURE LASSO boardsQueried=\(spatialIndex.query(bounds).count) selected=\(selected.count) ids=\(selected.map { "\($0.boardID):\($0.objectID)" }.sorted())")
        #endif
        callbacks.onSelectionChanged(selected)
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
            return
        }
        configureInteractionStrokeForCurrentZoom()
        if case .movingSelection = interaction { union = union.offsetBy(dx: movePreviewDelta.x, dy: movePreviewDelta.y) }
        let screenSpaceInset = 10 / max(worldTransform.scale, 0.001)
        let path = UIBezierPath(rect: union.insetBy(dx: -screenSpaceInset,
                                                    dy: -screenSpaceInset))
        if resizableTextSelection() != nil {
            let radius = max(5, 11 / max(worldTransform.scale, 0.001))
            path.append(UIBezierPath(ovalIn: CGRect(x: union.maxX - radius,
                                                    y: union.maxY - radius,
                                                    width: radius * 2,
                                                    height: radius * 2)))
        }
        interactionLayer.path = path.cgPath
        interactionLayer.isHidden = false
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

    private func resizableTextSelection() -> (key: SelectionKey, bounds: CGRect)? {
        guard selectedKeys.count == 1, let key = selectedKeys.first,
              key.kind == .editorObject,
              let item = workspace.items.first(where: { $0.boardID == key.boardID }),
              let boardView = boardViews[key.boardID],
              boardView.isResizableTextObject(id: key.objectID),
              let local = boardView.selectionBounds(keys: Set([key])) else { return nil }
        return (key, LectureCoordinateTransform.boardLocalToLectureWorld(local, board: item))
    }

    private func resizeHandleContains(_ world: CGPoint, bounds: CGRect) -> Bool {
        let tolerance = max(8, 20 / max(worldTransform.scale, 0.001))
        return hypot(world.x - bounds.maxX, world.y - bounds.maxY) <= tolerance
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

    private func sample(_ local: CGPoint, touch: UITouch) -> StrokePoint {
        let pressure: Double
        #if targetEnvironment(simulator)
        pressure = 1
        #else
        pressure = Double(touch.force / max(touch.maximumPossibleForce, 1))
        #endif
        return StrokePoint(x: local.x, y: local.y, pressure: pressure)
    }

    private var strokeColor: String { activeTool == .highlighter ? "#FFD60A" : "#183153" }
    private var strokeWidth: Double { activeTool == .highlighter ? 22 : 4 }
    private var strokeOpacity: Double { activeTool == .highlighter ? 0.32 : 1 }

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
    private let thumbnail = UIImageView()
    private let header = UILabel()
    private let loading = UIActivityIndicatorView(style: .medium)
    private let userLayer = CALayer()
    private var objectLayers: [String: CALayer] = [:]
    private var item: WorkspaceBoardItem?
    private var scene: WorkspaceBoardScene?
    private var representedThumbnailURL: URL?
    private var liveStrokeLayer: CAShapeLayer?

    var hasFullScene: Bool { scene != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isUserInteractionEnabled = false
        paperLayer.fillColor = UIColor(red: 0.985, green: 0.982, blue: 0.965, alpha: 1).cgColor
        paperLayer.strokeColor = UIColor.separator.withAlphaComponent(0.4).cgColor
        paperLayer.lineWidth = 2
        layer.addSublayer(paperLayer)
        thumbnail.contentMode = .scaleAspectFit
        thumbnail.clipsToBounds = true
        addSubview(thumbnail)
        addSubview(professor)
        userLayer.anchorPoint = .zero
        userLayer.position = .zero
        layer.addSublayer(userLayer)
        header.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        header.textColor = .label
        header.font = .systemFont(ofSize: 22, weight: .semibold)
        header.numberOfLines = 2
        header.layer.cornerRadius = 10
        header.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        header.layer.masksToBounds = true
        addSubview(header)
        addSubview(loading)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperLayer.frame = bounds
        paperLayer.path = UIBezierPath(rect: bounds).cgPath
        thumbnail.frame = bounds
        professor.frame = bounds
        userLayer.bounds = bounds
        userLayer.position = .zero
        header.frame = CGRect(x: 0, y: -52, width: bounds.width, height: 52)
        loading.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func configure(item: WorkspaceBoardItem,
                   scene: WorkspaceBoardScene?,
                   representation: BoardRepresentation,
                   thumbnailURL: URL?) {
        let sceneChanged = self.scene != scene
        self.item = item
        self.scene = scene
        header.text = "  \(item.title)\n  \(dateLabel(item.createdAt)) • \(item.unitLabel)"
        if representation == .fullVector, let scene {
            thumbnail.isHidden = true
            professor.isHidden = false
            loading.stopAnimating()
            if sceneChanged {
                professor.display(scene.document,
                                  transform: WorldScreenTransform(
                                    camera: CameraRect(x: 0, y: 0, width: item.boardWidth, height: item.boardHeight),
                                    viewport: bounds.size),
                                  importedTransforms: scene.editor.importedTransforms,
                                  composition: scene.composition)
                rebuildUserLayers(scene.editor.objects)
            }
        } else {
            professor.isHidden = true
            userLayer.isHidden = true
            thumbnail.isHidden = false
            if representation == .fullVector { loading.startAnimating() } else { loading.stopAnimating() }
            loadThumbnail(thumbnailURL)
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
        guard let item else { return }
        professor.endNavigation(WorldScreenTransform(camera: CameraRect(x: 0, y: 0, width: item.boardWidth, height: item.boardHeight), viewport: bounds.size))
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
                                 kind: .editorObject)]
        }
        if let id = professor.hitTest(point) {
            return [SelectionKey(boardID: item.boardID,
                                 objectID: id,
                                 kind: .professorPath)]
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
                result.insert(SelectionKey(boardID: item.boardID, objectID: object.id, kind: .editorObject))
            }
        }
        for id in professor.ids(containedBy: polygon) {
            result.insert(SelectionKey(boardID: item.boardID, objectID: id, kind: .professorPath))
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
                ? SelectionKey(boardID: item.boardID, objectID: object.id, kind: .editorObject)
                : nil
        })
        for id in professor.ids(intersecting: segment) {
            result.insert(SelectionKey(boardID: item.boardID, objectID: id, kind: .professorPath))
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

    func isResizableTextObject(id: String) -> Bool {
        scene?.editor.objects.contains(where: { $0.id == id && $0.type == "text" }) == true
    }

    func previewResize(key: SelectionKey, size: CGSize) {
        guard key.kind == .editorObject,
              let object = scene?.editor.objects.first(where: { $0.id == key.objectID }),
              let layer = objectLayers[key.objectID] else { return }
        var frame = objectBounds(object)
        frame.size = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        CATransaction.commit()
    }

    func clearResizePreview(key: SelectionKey) {
        guard let object = scene?.editor.objects.first(where: { $0.id == key.objectID }),
              let layer = objectLayers[key.objectID] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = objectBounds(object)
        CATransaction.commit()
    }

    func showLiveStroke(points: [StrokePoint], color: String, width: Double) {
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
        layer.lineWidth = width
    }

    func clearLiveStroke() {
        liveStrokeLayer?.removeFromSuperlayer()
        liveStrokeLayer = nil
    }

    private func rebuildUserLayers(_ objects: [CanvasObject]) {
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
            } else {
                let shape = CAShapeLayer()
                let path = UIBezierPath()
                let translation = object.translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
                for (index, point) in (object.points ?? []).enumerated() {
                    let p = CGPoint(x: point.x + translation.x, y: point.y + translation.y)
                    index == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                shape.path = path.cgPath
                shape.fillColor = UIColor.clear.cgColor
                shape.strokeColor = UIColor(svgHex: object.color ?? "#183153")
                    .withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor
                shape.lineWidth = object.width ?? 4
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
            let stride = max(1, points.count / 40)
            return points.enumerated().compactMap { index, point in
                guard index % stride == 0 || index == points.count - 1 else { return nil }
                return CGPoint(x: point.x + translation.x, y: point.y + translation.y)
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

    private func loadThumbnail(_ url: URL?) {
        guard representedThumbnailURL != url else { return }
        representedThumbnailURL = url
        thumbnail.image = nil
        guard let url else { return }
        if let cached = Self.thumbnailCache.object(forKey: url as NSURL) {
            thumbnail.image = cached
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Self.thumbnailCache.setObject(image, forKey: url as NSURL, cost: data.count)
            DispatchQueue.main.async {
                guard self?.representedThumbnailURL == url else { return }
                self?.thumbnail.image = image
            }
        }.resume()
    }

    private func dateLabel(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
