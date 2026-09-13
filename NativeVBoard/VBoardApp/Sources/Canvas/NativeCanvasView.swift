import SwiftUI
import UIKit

enum CanvasTool: String, CaseIterable, Sendable {
    case navigation, pen, highlighter, select, lasso, objectEraser
}

enum PassiveGraphOpenPolicy {
    /// Finger taps promote a passive graph immediately. Trackpad/mouse keeps
    /// the familiar double-click gesture, and Pencil is never intercepted so
    /// it continues through the active drawing/editing tool.
    static func tapCount(for touchType: UITouch.TouchType) -> Int? {
        switch touchType {
        case .direct: return 1
        case .indirectPointer: return 2
        case .pencil, .indirect: return nil
        @unknown default: return nil
        }
    }
}

struct CanvasStrokeStyle: Equatable, Sendable {
    var colorHex: String
    var width: Double
    var opacity: Double

    static let pen = CanvasStrokeStyle(colorHex: "#183153", width: 4, opacity: 1)
    static let marker = CanvasStrokeStyle(colorHex: "#FFD60A", width: 22, opacity: 0.32)
}

/// Whiteboard content uses a stable light-surface palette even when the app's
/// surrounding chrome follows system Dark Mode. This prevents source ink,
/// labels, dots, and transient controls from inheriting low-contrast semantic
/// colors intended for a dark application background.
enum CanvasDesignTokens {
    static let canvasBackground = UIColor(red: 0.955, green: 0.96, blue: 0.965, alpha: 1)
    static let boardSurface = UIColor(red: 0.992, green: 0.992, blue: 0.985, alpha: 1)
    static let boardBorder = UIColor(red: 0.20, green: 0.25, blue: 0.30, alpha: 0.40)
    static let canvasPrimaryText = UIColor(red: 0.075, green: 0.10, blue: 0.14, alpha: 1)
    static let canvasSecondaryText = UIColor(red: 0.28, green: 0.33, blue: 0.38, alpha: 1)
    static let toolbarSurface = UIColor(white: 1, alpha: 0.96)
    static let toolbarPrimaryText = canvasPrimaryText
    static let selectionAccent = UIColor(red: 0.04, green: 0.43, blue: 0.91, alpha: 1)
    static let dotColor = UIColor(red: 0.18, green: 0.25, blue: 0.32, alpha: 1)
}

/// Canvas content has an intentional appearance independent of app chrome.
/// Graphs, paper, ink controls, and selection chrome all follow this value;
/// system Dark Mode remains free to style the library and navigation UI.
enum VBoardCanvasTheme {
    static let interfaceStyle: UIUserInterfaceStyle = .light
    static let colorScheme: ColorScheme = .light
}

private enum InputSource: String { case pencil, touch, indirectPointer, mouse, trackpad }
private enum InteractionState: String { case idle = "IDLE", drawing = "DRAWING", panning = "PANNING", pinching = "PINCHING", lassoing = "LASSOING", erasing = "ERASING", selecting = "SELECTING", movingSelection = "MOVING_SELECTION", resizingSelection = "RESIZING_SELECTION" }

#if DEBUG
/// Read-only instrumentation for proving which Apple Pencil signals UIKit is
/// delivering to the live canvas. It deliberately owns no drawing state and
/// never writes to the board document.
@MainActor
final class PencilRawEventMonitor: NSObject {
    let label = UILabel()

    private var owner: String
    private var tool = "unknown"
    private var interactionState = "IDLE"
    private var eventLine = "event: waiting for Pencil"
    private var poseLine = "pose: pressure/tilt/azimuth/roll waiting"
    private var deliveryLine = "delivery: coalesced=0 predicted=0 estimated=none"
    private var hoverLine = "hover: waiting"
    private var gestureLine = "gestures: doubleTap=0 squeeze=0"
    private var doubleTapCount = 0
    private var squeezeCount = 0
    private var estimatedUpdateCount = 0
    private var lastConsoleMoveTimestamp: TimeInterval = -1

    init(owner: String) {
        self.owner = owner
        super.init()
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .label
        label.numberOfLines = 0
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        label.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.75).cgColor
        label.layer.borderWidth = 1
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        label.accessibilityIdentifier = "pencilDebugRawEventMonitor"
        render()
    }

    func installOverlay(on view: UIView) {
        view.addSubview(label)
    }

    func setVisible(_ visible: Bool) {
        label.isHidden = !visible
    }

    func setContext(tool: String, state: String) {
        self.tool = tool
        interactionState = state
        render()
    }

    func layout(in bounds: CGRect, top: CGFloat) {
        let width = max(0, min(520, bounds.width - 16))
        label.frame = CGRect(x: 8, y: top, width: width, height: 174)
    }

    func recordTouch(_ phase: String,
                     touch: UITouch,
                     event: UIEvent?,
                     in view: UIView,
                     tool: String,
                     state: String) {
        self.tool = tool
        interactionState = state
        let location = touch.preciseLocation(in: view)
        let contactCount = event?.allTouches?.count ?? 1
        let pencilCount = event?.allTouches?.filter { $0.type == .pencil }.count
            ?? (touch.type == .pencil ? 1 : 0)
        let source = Self.touchTypeName(touch.type)
        let latencyMS = max(0, (ProcessInfo.processInfo.systemUptime - touch.timestamp) * 1_000)
        eventLine = String(
            format: "event: %@ %@ x=%.1f y=%.1f contacts=%d pencil=%d latency=%.1fms",
            phase, source, location.x, location.y, contactCount, pencilCount, latencyMS
        )

        if touch.type == .pencil {
            PencilHardwareValidationStore.shared.detect(.draw)
            let normalizedForce = touch.maximumPossibleForce > 0
                ? touch.force / touch.maximumPossibleForce : 0
            if touch.maximumPossibleForce > 0 {
                PencilHardwareValidationStore.shared.detect(.pressure)
            }
            if touch.altitudeAngle.isFinite {
                PencilHardwareValidationStore.shared.detect(.tilt)
            }
            let rawRoll: String
            let screenRoll: String
            if #available(iOS 17.5, *) {
                rawRoll = Self.degrees(touch.rollAngle)
                screenRoll = Self.degrees(PencilScreenAngle.roll(
                    fromAppleRaw: touch.rollAngle
                ))
                if abs(touch.rollAngle) > 0.0001 {
                    PencilHardwareValidationStore.shared.detect(.barrelRoll)
                }
            } else {
                rawRoll = "n/a"
                screenRoll = "n/a"
            }
            let widthMultiplier = PencilPressureResponse.widthMultiplier(
                forDisplayPressure: normalizedForce
            )
            poseLine = String(
                format: "pose: force=%.3f/%.3f norm=%.3f width=%.2fx altitude=%@ azimuth=%@ rawRoll=%@ screenRoll=%@",
                touch.force, touch.maximumPossibleForce, normalizedForce,
                widthMultiplier,
                Self.degrees(touch.altitudeAngle),
                Self.degrees(touch.azimuthAngle(in: view)), rawRoll, screenRoll
            )
        } else {
            poseLine = "pose: non-Pencil input (Pencil-only fields not sampled)"
        }

        let coalesced = event?.coalescedTouches(for: touch)?.count ?? 0
        let predicted = event?.predictedTouches(for: touch)?.count ?? 0
        deliveryLine = "delivery: coalesced=\(coalesced) predicted=\(predicted) estimated=\(Self.propertyNames(touch.estimatedProperties)) expecting=\(Self.propertyNames(touch.estimatedPropertiesExpectingUpdates)) corrections=\(estimatedUpdateCount)"
        if touch.type == .pencil,
           event?.allTouches?.contains(where: { $0.type == .direct }) == true {
            PencilHardwareValidationStore.shared.detect(.fingerCoexistence)
        }
        render()

        if phase != "MOVE" || touch.timestamp - lastConsoleMoveTimestamp >= 0.05 {
            lastConsoleMoveTimestamp = touch.timestamp
            log("touch \(eventLine) \(poseLine) \(deliveryLine)")
        }
    }

    func recordEstimatedUpdates(_ touches: Set<UITouch>, in view: UIView) {
        estimatedUpdateCount += touches.count
        guard let touch = touches.first else { return }
        deliveryLine = "delivery: estimated UPDATE index=\(touch.estimationUpdateIndex?.stringValue ?? "nil") properties=\(Self.propertyNames(touch.estimatedProperties)) expecting=\(Self.propertyNames(touch.estimatedPropertiesExpectingUpdates)) corrections=\(estimatedUpdateCount)"
        if touch.type == .pencil {
            let location = touch.preciseLocation(in: view)
            log("estimated-update x=\(Self.number(location.x)) y=\(Self.number(location.y)) \(deliveryLine)")
        }
        render()
    }

    func recordHover(_ recognizer: UIHoverGestureRecognizer, in view: UIView) {
        PencilHardwareValidationStore.shared.detect(.hover)
        let point = recognizer.location(in: view)
        let rawRoll: String
        let screenRoll: String
        if #available(iOS 17.5, *) {
            rawRoll = Self.degrees(recognizer.rollAngle)
            screenRoll = Self.degrees(PencilScreenAngle.roll(
                fromAppleRaw: recognizer.rollAngle
            ))
            if abs(recognizer.rollAngle) > 0.0001 {
                PencilHardwareValidationStore.shared.detect(.barrelRoll)
            }
        } else {
            rawRoll = "n/a"
            screenRoll = "n/a"
        }
        hoverLine = String(
            format: "hover: %@ x=%.1f y=%.1f z=%.3f altitude=%@ azimuth=%@ rawRoll=%@ screenRoll=%@",
            Self.gestureStateName(recognizer.state), point.x, point.y,
            recognizer.zOffset, Self.degrees(recognizer.altitudeAngle),
            Self.degrees(recognizer.azimuthAngle(in: view)), rawRoll, screenRoll
        )
        render()
        log(hoverLine)
    }

    func recordLegacyDoubleTap() {
        PencilHardwareValidationStore.shared.detect(.doubleTap)
        doubleTapCount += 1
        gestureLine = "gestures: doubleTap=\(doubleTapCount) squeeze=\(squeezeCount) preferredTap=\(Self.preferredActionName(UIPencilInteraction.preferredTapAction))"
        render()
        log("double-tap legacy preferred=\(Self.preferredActionName(UIPencilInteraction.preferredTapAction))")
    }

    @available(iOS 17.5, *)
    func recordDoubleTap(_ tap: UIPencilInteraction.Tap) {
        PencilHardwareValidationStore.shared.detect(.doubleTap)
        doubleTapCount += 1
        let pose = tap.hoverPose.map(Self.poseDescription) ?? "pose=nil"
        gestureLine = "gestures: doubleTap=\(doubleTapCount) squeeze=\(squeezeCount) preferredTap=\(Self.preferredActionName(UIPencilInteraction.preferredTapAction))"
        render()
        log("double-tap timestamp=\(Self.number(tap.timestamp)) \(pose)")
    }

    @available(iOS 17.5, *)
    func recordSqueeze(_ squeeze: UIPencilInteraction.Squeeze) {
        PencilHardwareValidationStore.shared.detect(.squeeze)
        if squeeze.phase == .began { squeezeCount += 1 }
        let pose = squeeze.hoverPose.map(Self.poseDescription) ?? "pose=nil"
        gestureLine = "gestures: doubleTap=\(doubleTapCount) squeeze=\(squeezeCount) phase=\(Self.squeezePhaseName(squeeze.phase)) preferredSqueeze=\(Self.preferredActionName(UIPencilInteraction.preferredSqueezeAction))"
        render()
        log("squeeze phase=\(Self.squeezePhaseName(squeeze.phase)) timestamp=\(Self.number(squeeze.timestamp)) \(pose)")
    }

    private func render() {
        label.text = "  RAW PENCIL — DEBUG ONLY\n  owner: \(owner)  tool=\(tool) state=\(interactionState)\n  \(eventLine)\n  \(poseLine)\n  \(deliveryLine)\n  \(hoverLine)\n  \(gestureLine)"
    }

    private func log(_ message: String) {
        print("[VBoard] PENCIL_RAW owner=\(owner) tool=\(tool) state=\(interactionState) \(message)")
    }

    private static func number(_ value: CGFloat) -> String { String(format: "%.3f", value) }
    private static func number(_ value: TimeInterval) -> String { String(format: "%.3f", value) }
    private static func degrees(_ radians: CGFloat) -> String {
        String(format: "%.1f°", radians * 180 / .pi)
    }

    private static func propertyNames(_ properties: UITouch.Properties) -> String {
        var names: [String] = []
        if properties.contains(.location) { names.append("location") }
        if properties.contains(.force) { names.append("force") }
        if properties.contains(.azimuth) { names.append("azimuth") }
        if properties.contains(.altitude) { names.append("altitude") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private static func touchTypeName(_ type: UITouch.TouchType) -> String {
        switch type {
        case .pencil: return "pencil"
        case .direct: return "finger"
        case .indirectPointer: return "pointer"
        case .indirect: return "indirect"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }

    private static func gestureStateName(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private static func preferredActionName(_ action: UIPencilPreferredAction) -> String {
        switch action {
        case .ignore: return "ignore"
        case .switchEraser: return "switchEraser"
        case .switchPrevious: return "switchPrevious"
        case .showColorPalette: return "showColorPalette"
        case .showInkAttributes: return "showInkAttributes"
        case .showContextualPalette: return "showContextualPalette"
        case .runSystemShortcut: return "runSystemShortcut"
        @unknown default: return "unknown(\(action.rawValue))"
        }
    }

    @available(iOS 17.5, *)
    private static func squeezePhaseName(_ phase: UIPencilInteraction.Phase) -> String {
        switch phase {
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    @available(iOS 17.5, *)
    private static func poseDescription(_ pose: UIPencilHoverPose) -> String {
        "pose=(x=\(number(pose.location.x)) y=\(number(pose.location.y)) z=\(number(pose.zOffset)) altitude=\(degrees(pose.altitudeAngle)) azimuth=\(degrees(pose.azimuthAngle)) rawRoll=\(degrees(pose.rollAngle)) screenRoll=\(degrees(PencilScreenAngle.roll(fromAppleRaw: pose.rollAngle))))"
    }
}
#endif

struct NativeCanvasView: UIViewRepresentable {
    let boardID: String
    let document: SVGDocument
    var previewImage: UIImage? = nil
    let pdfData: Data?
    var sourceKind: BoardSourceKind = .physicalWhiteboard
    let camera: CameraRect
    let objects: [CanvasObject]
    let importedTransforms: [String: ObjectTransform]
    let composition: SceneComposition
    var showsPaper = true
    var backgroundStyle = WorkspaceBackgroundStyle.dots
    var penStyle = CanvasStrokeStyle.pen
    var markerStyle = CanvasStrokeStyle.marker
    var pencilPreferences = PencilPreferences.defaults
    var isPencilPalettePresented = false
    var showsDeveloperDiagnostics = false
    var onStroke: (UserStroke) -> Void = { _ in }
    var tool: CanvasTool = .pen
    var onSelectionChanged: (Set<String>) -> Void = { _ in }
    var onSelectionRegionChanged: (CGRect?) -> Void = { _ in }
    var onMove: (Set<String>, CGPoint) -> Void = { _, _ in }
    var onResize: (Set<String>, CGPoint, CGFloat) -> Void = { _, _, _ in }
    var onResizeGraphHeight: (String, CGFloat, CGFloat) -> Void = { _, _, _ in }
    var onGraphDoubleTap: (String) -> Void = { _ in }
    var onDelete: (Set<String>) -> Void = { _ in }
    var onCameraChanged: (CameraRect) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onPencilAction: (PencilLogicalAction, CGPoint?) -> Void = { _, _ in }
    var onPencilPaletteMoved: (CGPoint) -> Void = { _ in }
    var onPencilPaletteHighlight: (Int) -> Void = { _ in }
    var onPencilPaletteCommit: (Int) -> Void = { _ in }
    var onPencilPaletteDismiss: () -> Void = {}

    func makeUIView(context: Context) -> InfiniteCanvasUIView {
        InfiniteCanvasUIView(boardID: boardID, document: document, previewImage: previewImage,
                             pdfData: pdfData, sourceKind: sourceKind, camera: camera,
                             objects: objects, importedTransforms: importedTransforms,
                             composition: composition, showsPaper: showsPaper, backgroundStyle: backgroundStyle,
                             penStyle: penStyle, markerStyle: markerStyle,
                             pencilPreferences: pencilPreferences,
                             isPencilPalettePresented: isPencilPalettePresented,
                             showsDeveloperDiagnostics: showsDeveloperDiagnostics,
                             onStroke: onStroke, tool: tool,
                             onSelectionChanged: onSelectionChanged, onSelectionRegionChanged: onSelectionRegionChanged, onMove: onMove, onResize: onResize,
                             onResizeGraphHeight: onResizeGraphHeight,
                             onGraphDoubleTap: onGraphDoubleTap,
                             onDelete: onDelete, onCameraChanged: onCameraChanged, onUndo: onUndo, onRedo: onRedo,
                             onPencilAction: onPencilAction, onPencilPaletteMoved: onPencilPaletteMoved,
                             onPencilPaletteHighlight: onPencilPaletteHighlight,
                             onPencilPaletteCommit: onPencilPaletteCommit,
                             onPencilPaletteDismiss: onPencilPaletteDismiss)
    }

    func updateUIView(_ uiView: InfiniteCanvasUIView, context: Context) {
        uiView.update(boardID: boardID, document: document, previewImage: previewImage,
                      pdfData: pdfData, sourceKind: sourceKind, camera: camera,
                      objects: objects, importedTransforms: importedTransforms,
                      composition: composition, showsPaper: showsPaper, backgroundStyle: backgroundStyle,
                      penStyle: penStyle, markerStyle: markerStyle,
                      pencilPreferences: pencilPreferences,
                      isPencilPalettePresented: isPencilPalettePresented,
                      showsDeveloperDiagnostics: showsDeveloperDiagnostics,
                      onStroke: onStroke, tool: tool,
                      onSelectionChanged: onSelectionChanged, onSelectionRegionChanged: onSelectionRegionChanged, onMove: onMove, onResize: onResize,
                      onResizeGraphHeight: onResizeGraphHeight,
                      onGraphDoubleTap: onGraphDoubleTap,
                      onDelete: onDelete, onCameraChanged: onCameraChanged, onUndo: onUndo, onRedo: onRedo,
                      onPencilAction: onPencilAction, onPencilPaletteMoved: onPencilPaletteMoved,
                      onPencilPaletteHighlight: onPencilPaletteHighlight,
                      onPencilPaletteCommit: onPencilPaletteCommit,
                      onPencilPaletteDismiss: onPencilPaletteDismiss)
    }
}

/// UIKit owns the high-frequency input and layer composition. World-space
/// content is transformed as one GPU-composited layer; expensive visibility
/// refinement only runs after a gesture ends.
final class InfiniteCanvasUIView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let gridLayer = CAShapeLayer()
    /// The root view is intentionally never camera-transformed. It owns the
    /// input stream and stays in the same coordinate space as UIKit events.
    /// Every world-space layer is a descendant of this single container so a
    /// CameraRect change moves the visible pixels, not just the culling set.
    private let worldContainer = UIView()
    private let previewSource = UIImageView()
    private let pdfSource = PDFPageRenderView()
    private let professor = ProfessorSVGView()
    private let vectorIndicator = BoardVectorLoadingIndicator()
    private let userLayer = CALayer()
    private let paperLayer = CAShapeLayer()
    private let pencilHoverLayer = CAShapeLayer()
    private var userObjectLayers: [String: CALayer] = [:]
    private var renderedObjects: [String: CanvasObject] = [:]
    private var strokeLayers: [String: CALayer] = [:]
    private var activeStrokeLayer: CAShapeLayer?
    private(set) var userStrokes: [UserStroke] = []
    private var activePoints: [StrokePoint] = []
    private var predictedPoints: [StrokePoint] = []
    private var strokeAccumulator = PencilStrokeAccumulator()
    private var activeID: String?
    private var recentlyCommittedStroke: UserStroke?
    private var onStroke: (UserStroke) -> Void
    private var activeTool: CanvasTool
    private var onSelectionChanged: (Set<String>) -> Void
    private var onSelectionRegionChanged: (CGRect?) -> Void
    private var onMove: (Set<String>, CGPoint) -> Void
    private var onResize: (Set<String>, CGPoint, CGFloat) -> Void
    private var onResizeGraphHeight: (String, CGFloat, CGFloat) -> Void
    private var onGraphDoubleTap: (String) -> Void
    private var onDelete: (Set<String>) -> Void
    private var onCameraChanged: (CameraRect) -> Void
    private var onUndo: () -> Void
    private var onRedo: () -> Void
    private var pencilPreferences: PencilPreferences
    private var onPencilAction: (PencilLogicalAction, CGPoint?) -> Void
    private var onPencilPaletteMoved: (CGPoint) -> Void
    private var onPencilPaletteHighlight: (Int) -> Void
    private var onPencilPaletteCommit: (Int) -> Void
    private var onPencilPaletteDismiss: () -> Void
    private var pencilInteraction: UIPencilInteraction!
    private var pencilHoverRecognizer: UIHoverGestureRecognizer!
    private var squeezeState = PencilPaletteStateMachine()
    private var activeSqueezeAction: PencilLogicalAction = .none
    private var isPencilPalettePresented = false
    private var pendingSqueezeAnchor: CGPoint?
    private var pendingSqueezeRoll: CGFloat?
    private var pencilFeedback: PencilFeedbackProviding!
    private var selectedIDs = Set<String>()
    private var editStart = CGPoint.zero
    private var editStartScreen = CGPoint.zero
    private var lastEditPoint = CGPoint.zero
    private var moveDelta = CGPoint.zero
    private var moveActive = false
    private var resizeSession: SelectionResizeSession?
    private var resizePreviewBounds: CGRect?
    private var resizePreviewPositions: [String: CGPoint] = [:]
    private var lassoWorldPoints: [CGPoint] = []
    private let interactionLayer = CAShapeLayer()
    private var boardID: String
    private var document: SVGDocument
    private var previewImage: UIImage?
    private var pdfData: Data?
    private var sourceKind: BoardSourceKind
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
    private var showsDeveloperDiagnostics: Bool
    private var previousViewportSize: CGSize = .zero
    private var panStart = CGPoint.zero
    private var panStartCamera = CameraRect(x: 0, y: 0, width: 1, height: 1)
    private var wheelStartCamera = CameraRect(x: 0, y: 0, width: 1, height: 1)
    private var panGesture: UIPanGestureRecognizer!
    private var scrollPanGesture: UIPanGestureRecognizer!
    private var wheelZoomGesture: UIPanGestureRecognizer!
    private var pinchGesture: UIPinchGestureRecognizer!
    private var graphFingerTapGesture: UITapGestureRecognizer!
    private var graphPointerDoubleTapGesture: UITapGestureRecognizer!
    private var isSpacePressed = false
    private var interactionState: InteractionState = .idle
    private var activeInputSource: InputSource = .touch
    private var activeInputOwner: CanvasInputOwner = .none
    private var activeInputContact: CanvasInputContact?
    private var eraseTransaction = ContinuousEraseTransaction<String>()
    private var pinchStartCamera = CameraRect(x: 0, y: 0, width: 1, height: 1)
    private var pinchStartMidpoint = CGPoint.zero
    #if DEBUG
    private let perfLabel = UILabel()
    private let pencilRawMonitor = PencilRawEventMonitor(owner: "InfiniteCanvasUIView")
    private var lastRenderStats: RenderStats?
    private let crosshairLayer = CAShapeLayer()
    private var lastCameraMutationReason: CameraMutationReason?
    #endif

    init(boardID: String, document: SVGDocument, previewImage: UIImage? = nil,
         pdfData: Data? = nil, sourceKind: BoardSourceKind = .physicalWhiteboard,
         camera: CameraRect,
         objects: [CanvasObject] = [], importedTransforms: [String: ObjectTransform] = [:],
         composition: SceneComposition, showsPaper: Bool = true,
         backgroundStyle: WorkspaceBackgroundStyle = .dots,
         penStyle: CanvasStrokeStyle = .pen, markerStyle: CanvasStrokeStyle = .marker,
         pencilPreferences: PencilPreferences = .defaults,
         isPencilPalettePresented: Bool = false,
         showsDeveloperDiagnostics: Bool = false,
         onStroke: @escaping (UserStroke) -> Void = { _ in },
         tool: CanvasTool = .pen, onSelectionChanged: @escaping (Set<String>) -> Void = { _ in },
         onSelectionRegionChanged: @escaping (CGRect?) -> Void = { _ in },
         onMove: @escaping (Set<String>, CGPoint) -> Void = { _, _ in },
         onResize: @escaping (Set<String>, CGPoint, CGFloat) -> Void = { _, _, _ in },
         onResizeGraphHeight: @escaping (String, CGFloat, CGFloat) -> Void = { _, _, _ in },
         onGraphDoubleTap: @escaping (String) -> Void = { _ in },
         onDelete: @escaping (Set<String>) -> Void = { _ in }, onCameraChanged: @escaping (CameraRect) -> Void = { _ in }, onUndo: @escaping () -> Void = {}, onRedo: @escaping () -> Void = {},
         onPencilAction: @escaping (PencilLogicalAction, CGPoint?) -> Void = { _, _ in },
         onPencilPaletteMoved: @escaping (CGPoint) -> Void = { _ in },
         onPencilPaletteHighlight: @escaping (Int) -> Void = { _ in },
         onPencilPaletteCommit: @escaping (Int) -> Void = { _ in },
         onPencilPaletteDismiss: @escaping () -> Void = {}) {
        self.boardID = boardID; self.document = document; self.previewImage = previewImage
        self.pdfData = pdfData; self.sourceKind = sourceKind; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition; self.showsPaper = showsPaper
        self.penStyle = penStyle; self.markerStyle = markerStyle
        self.pencilPreferences = pencilPreferences
        self.isPencilPalettePresented = isPencilPalettePresented
        self.showsDeveloperDiagnostics = showsDeveloperDiagnostics
        self.backgroundStyle = backgroundStyle
        self.onStroke = onStroke
        self.activeTool = tool; self.onSelectionChanged = onSelectionChanged
        self.onSelectionRegionChanged = onSelectionRegionChanged
        self.onMove = onMove; self.onResize = onResize
        self.onResizeGraphHeight = onResizeGraphHeight
        self.onGraphDoubleTap = onGraphDoubleTap
        self.onDelete = onDelete; self.onCameraChanged = onCameraChanged; self.onUndo = onUndo; self.onRedo = onRedo
        self.onPencilAction = onPencilAction
        self.onPencilPaletteMoved = onPencilPaletteMoved
        self.onPencilPaletteHighlight = onPencilPaletteHighlight
        self.onPencilPaletteCommit = onPencilPaletteCommit
        self.onPencilPaletteDismiss = onPencilPaletteDismiss
        controller = CameraController(camera: camera)
        persistedCamera = camera
        super.init(frame: .zero)
        backgroundColor = CanvasDesignTokens.canvasBackground
        isMultipleTouchEnabled = true
        clipsToBounds = true
        gridLayer.fillColor = UIColor.clear.cgColor
        gridLayer.lineWidth = 1
        gridLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(gridLayer)
        pencilHoverLayer.fillColor = UIColor.clear.cgColor
        pencilHoverLayer.strokeColor = CanvasDesignTokens.canvasPrimaryText
            .withAlphaComponent(0.62).cgColor
        pencilHoverLayer.lineWidth = 1
        pencilHoverLayer.isHidden = true
        layer.addSublayer(pencilHoverLayer)
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
        previewSource.layer.name = "VBoardPreviewSource"
        pdfSource.layer.name = "VBoardPDFSource"
        professor.layer.name = "VBoardProfessorSource"
        userLayer.name = "VBoardUserContent"
        interactionLayer.fillColor = CanvasDesignTokens.selectionAccent.withAlphaComponent(0.08).cgColor
        interactionLayer.strokeColor = CanvasDesignTokens.selectionAccent.cgColor; interactionLayer.lineWidth = 2
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
        professor.onProgress = { [weak self] progress in
            guard let self else { return }
            let ready = progress >= 0.999
            self.previewSource.isHidden = (ready && self.sourceKind != .image)
                || self.previewImage == nil || self.pdfData != nil
            self.vectorIndicator.transition(to: ready
                                            ? .vectorReady
                                            : (progress > 0 ? .vectorPartial : .vectorLoading))
            if ready {
                self.document.performanceTrace?.event(
                    "current_viewport_editable", fields: ["board": self.boardID], once: true
                )
            }
        }
        addSubview(worldContainer)
        // The paper is the bottom-most board source. Keeping it inside the
        // user layer placed an opaque rectangle above PDF/professor content,
        // which explained why reopened imported boards showed annotations but
        // not their source page.
        worldContainer.layer.addSublayer(paperLayer)
        previewSource.image = previewImage
        previewSource.contentMode = .scaleToFill
        previewSource.clipsToBounds = true
        previewSource.layer.anchorPoint = .zero
        previewSource.isHidden = previewImage == nil || pdfData != nil
        previewSource.isUserInteractionEnabled = false
        worldContainer.addSubview(previewSource)
        worldContainer.addSubview(pdfSource)
        worldContainer.addSubview(professor)
        worldContainer.layer.addSublayer(userLayer)
        worldContainer.layer.addSublayer(interactionLayer)
        addSubview(vectorIndicator)
        // ProfessorSVGView is a render-only subview. If it participates in
        // hit-testing, the parent never receives the simulator mouse/Pencil
        // stream and every editing tool appears inert.
        professor.isUserInteractionEnabled = false
        if let pdfData { pdfSource.display(data: pdfData) }
        else { pdfSource.isHidden = true }
        if pdfData != nil {
            PDFBoardSource.apply(transform: importedTransforms[PDFBoardSource.logicalID], to: pdfSource)
        }
        if sourceKind == .image {
            PDFBoardSource.apply(transform: PDFBoardSource.imageTransform(importedTransforms),
                                 to: previewSource)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        pan.minimumNumberOfTouches = CanvasInputArbitrationPolicy
            .minimumDirectNavigationTouches(tool: tool)
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.allowedScrollTypesMask = []
        // When a second finger converts a one-contact edit into navigation,
        // UIKit must cancel the edit sequence so transient state is rolled
        // back before the camera takes ownership.
        pan.cancelsTouchesInView = true
        pan.delegate = self; panGesture = pan; addGestureRecognizer(pan)
        #if targetEnvironment(simulator)
        // Simulator pointer drags are owned by the root touch overrides
        // below. Keeping the recognizer enabled at the same time lets UIKit
        // compete for the same stream and can produce a partial/teleporting
        // pan. Physical-device gesture routing remains available.
        panGesture.isEnabled = false
        #endif
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        scrollPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scrollPan.allowedScrollTypesMask = .continuous
        scrollPan.cancelsTouchesInView = false
        scrollPan.delegate = self; scrollPanGesture = scrollPan; addGestureRecognizer(scrollPan)
        let wheelZoom = UIPanGestureRecognizer(target: self, action: #selector(didWheelZoom(_:)))
        wheelZoom.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        wheelZoom.allowedScrollTypesMask = .discrete
        wheelZoom.cancelsTouchesInView = false
        wheelZoom.delegate = self; wheelZoomGesture = wheelZoom; addGestureRecognizer(wheelZoom)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:)))
        // Camera gestures must never compete with a Pencil stroke. Finger and
        // trackpad pinch share the same authoritative CameraController path.
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                   NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pinch.cancelsTouchesInView = true
        pinch.delegate = self; pinchGesture = pinch; addGestureRecognizer(pinch)
        let graphFingerTap = UITapGestureRecognizer(target: self,
                                                     action: #selector(didOpenGraph(_:)))
        graphFingerTap.numberOfTapsRequired = PassiveGraphOpenPolicy.tapCount(for: .direct) ?? 1
        graphFingerTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        graphFingerTap.cancelsTouchesInView = true
        graphFingerTap.delegate = self
        graphFingerTapGesture = graphFingerTap
        addGestureRecognizer(graphFingerTap)
        let graphDoubleTap = UITapGestureRecognizer(target: self,
                                                     action: #selector(didOpenGraph(_:)))
        graphDoubleTap.numberOfTapsRequired = PassiveGraphOpenPolicy.tapCount(
            for: .indirectPointer
        ) ?? 2
        graphDoubleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        graphDoubleTap.cancelsTouchesInView = true
        graphDoubleTap.delegate = self
        graphPointerDoubleTapGesture = graphDoubleTap
        addGestureRecognizer(graphDoubleTap)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(pencilHover(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        addGestureRecognizer(hover)
        pencilHoverRecognizer = hover
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        addInteraction(interaction)
        pencilInteraction = interaction
        pencilFeedback = UIKitPencilFeedbackProvider(view: self)
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
        perfLabel.isHidden = !showsDeveloperDiagnostics
        addSubview(perfLabel)
        pencilRawMonitor.installOverlay(on: self)
        pencilRawMonitor.setVisible(showsDeveloperDiagnostics)
        pencilRawMonitor.setContext(tool: activeTool.rawValue, state: interactionState.rawValue)
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

    var pencilInteractionCountForTesting: Int {
        interactions.filter { $0 is UIPencilInteraction }.count
    }

    var previewIsVisibleForTesting: Bool { !previewSource.isHidden }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        #if DEBUG
        pencilRawMonitor.recordLegacyDoubleTap()
        #endif
        routePencilAction(PencilActionResolver.doubleTap(
            setting: pencilPreferences.doubleTap,
            system: PencilPreferredAction(UIPencilInteraction.preferredTapAction)
        ), anchor: nil)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveTap tap: UIPencilInteraction.Tap) {
        #if DEBUG
        pencilRawMonitor.recordDoubleTap(tap)
        #endif
        routePencilAction(PencilActionResolver.doubleTap(
            setting: pencilPreferences.doubleTap,
            system: PencilPreferredAction(UIPencilInteraction.preferredTapAction)
        ), anchor: tap.hoverPose?.location)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        #if DEBUG
        pencilRawMonitor.recordSqueeze(squeeze)
        #endif
        let point = squeeze.hoverPose?.location
        let roll = squeeze.hoverPose.map {
            PencilScreenAngle.roll(fromAppleRaw: $0.rollAngle)
        }
        let phase: PencilSqueezePhase
        switch squeeze.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        @unknown default: phase = .cancelled
        }

        if phase == .began {
            activeSqueezeAction = PencilActionResolver.squeeze(
                setting: pencilPreferences.squeeze,
                system: PencilPreferredAction(UIPencilInteraction.preferredSqueezeAction)
            )
            pendingSqueezeAnchor = point
            pendingSqueezeRoll = roll
            if !isPaletteAction(activeSqueezeAction) {
                routePencilAction(activeSqueezeAction, anchor: point)
            }
            return
        }
        if phase == .changed {
            if let point { pendingSqueezeAnchor = point }
            if let roll { pendingSqueezeRoll = roll }
            if squeezeState.isPresented {
                applyPaletteEffect(squeezeState.update(anchor: point, roll: roll), point: point)
            }
            return
        }
        if phase == .ended, isPaletteAction(activeSqueezeAction) {
            applyPaletteEffect(squeezeState.toggle(
                anchor: pendingSqueezeAnchor ?? point,
                roll: pendingSqueezeRoll ?? roll,
                initialIndex: PencilRadialPaletteModel.index(for: activeTool),
                itemCount: PencilRadialPaletteModel.tools.count
            ), point: point)
        }
        activeSqueezeAction = .none
        pendingSqueezeAnchor = nil
        pendingSqueezeRoll = nil
    }

    private func isPaletteAction(_ action: PencilLogicalAction) -> Bool {
        action == .showToolPalette || action == .showInkAttributes
            || action == .showColorPalette
    }

    private func applyPaletteEffect(_ effect: PencilPaletteStateMachine.Effect,
                                    point: CGPoint?) {
        switch effect {
        case .present(let anchor, let index):
            isPencilPalettePresented = true
            routePencilAction(activeSqueezeAction, anchor: anchor)
            onPencilPaletteHighlight(index)
            pencilFeedback.request(.paletteActivation(anchor
                ?? CGPoint(x: bounds.midX, y: bounds.midY)))
        case .update(let anchor, let index, let selectionChanged):
            if let anchor { onPencilPaletteMoved(anchor) }
            onPencilPaletteHighlight(index)
            if selectionChanged { pencilFeedback.request(.toolSelection(point)) }
        case .commit(let index):
            isPencilPalettePresented = false
            onPencilPaletteCommit(index)
            onPencilPaletteDismiss()
            pencilFeedback.request(.action(point))
        case .dismiss:
            isPencilPalettePresented = false
            onPencilPaletteDismiss()
        case .none:
            break
        }
    }

    private func routePencilAction(_ action: PencilLogicalAction, anchor: CGPoint?) {
        guard action != .none else { return }
        onPencilAction(action, anchor)
    }

    private var shouldShowPencilHoverPreview: Bool {
        switch pencilPreferences.hover {
        case .off: return false
        case .on: return true
        case .followSystem:
            if #available(iOS 17.5, *) { return UIPencilInteraction.prefersHoverToolPreview }
            return true
        }
    }

    @objc private func pencilHover(_ recognizer: UIHoverGestureRecognizer) {
        #if DEBUG
        pencilRawMonitor.recordHover(recognizer, in: self)
        #endif
        let point = recognizer.location(in: self)
        if isPencilPalettePresented,
           recognizer.state == .began || recognizer.state == .changed,
           #available(iOS 17.5, *) {
            let roll = PencilScreenAngle.roll(fromAppleRaw: recognizer.rollAngle)
            applyPaletteEffect(squeezeState.update(anchor: point, roll: roll), point: point)
        }
        guard shouldShowPencilHoverPreview,
              recognizer.state == .began || recognizer.state == .changed else {
            pencilHoverLayer.path = nil
            pencilHoverLayer.isHidden = true
            return
        }
        let scale = max(worldTransform.scale, 0.001)
        let path = UIBezierPath()
        switch activeTool {
        case .pen:
            let radius = max(2.5, CGFloat(penStyle.width) * scale / 2)
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)))
        case .highlighter:
            let roll: CGFloat?
            if #available(iOS 17.5, *) { roll = recognizer.rollAngle } else { roll = nil }
            let nib = PencilNibGeometry.marker(baseWidth: CGFloat(markerStyle.width) * scale,
                                               pressure: nil,
                                               altitude: recognizer.altitudeAngle,
                                               azimuth: recognizer.azimuthAngle(in: self),
                                               roll: roll)
            let stamp = UIBezierPath(ovalIn: CGRect(x: -nib.majorAxis / 2,
                                                    y: -nib.minorAxis / 2,
                                                    width: nib.majorAxis,
                                                    height: nib.minorAxis))
            var transform = CGAffineTransform(rotationAngle: nib.orientation)
            transform = transform.concatenating(
                CGAffineTransform(translationX: point.x, y: point.y)
            )
            stamp.apply(transform); path.append(stamp)
        case .objectEraser:
            let radius = PencilEraserFootprint.screenRadius
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)))
        case .lasso, .select, .navigation:
            path.move(to: CGPoint(x: point.x - 6, y: point.y))
            path.addLine(to: CGPoint(x: point.x + 6, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - 6))
            path.addLine(to: CGPoint(x: point.x, y: point.y + 6))
        }
        pencilHoverLayer.path = path.cgPath
        pencilHoverLayer.isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newViewportSize = bounds.size
        if previousViewportSize.width > 0, previousViewportSize.height > 0,
           newViewportSize != previousViewportSize,
           cameraInitializedForBoardID == boardID {
            controller.resizeViewport(from: previousViewportSize, to: newViewportSize)
            let resizedCamera = controller.camera
            let resizedBoardID = boardID
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.boardID == resizedBoardID,
                      self.cameraInitializedForBoardID == resizedBoardID else { return }
                self.onCameraChanged(resizedCamera)
            }
        }
        previousViewportSize = newViewportSize
        gridLayer.frame = bounds
        pencilHoverLayer.frame = bounds
        // Never assign `frame` to a transformed layer. Establish the stable
        // untransformed geometry first, then apply the camera transform in
        // `applyCamera`.
        worldContainer.bounds = CGRect(origin: .zero, size: bounds.size)
        worldContainer.layer.position = .zero
        professor.frame = worldContainer.bounds
        PDFBoardSource.pinTopLeft(previewSource, size: document.viewBox.size,
                                  origin: document.viewBox.origin)
        PDFBoardSource.pinTopLeft(pdfSource, size: document.viewBox.size,
                                  origin: document.viewBox.origin)
        userLayer.bounds = worldContainer.bounds
        userLayer.position = .zero
        paperLayer.bounds = worldContainer.bounds
        paperLayer.position = .zero
        WorldOverlayLayerLayout.pin(interactionLayer, to: worldContainer.bounds)
        #if DEBUG
        perfLabel.frame = CGRect(x: 8, y: 8, width: 360, height: 112)
        pencilRawMonitor.layout(in: bounds, top: 126)
        #endif
        let indicatorSize = vectorIndicator.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        vectorIndicator.frame = CGRect(
            x: bounds.midX - indicatorSize.width / 2,
            y: max(12, bounds.maxY - indicatorSize.height - 18),
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        resolveInitialCameraIfNeeded()
        applyCamera(interacting: false)
    }

    func update(boardID: String, document: SVGDocument, previewImage: UIImage? = nil,
                pdfData: Data? = nil, sourceKind: BoardSourceKind = .physicalWhiteboard,
                camera: CameraRect,
                objects: [CanvasObject], importedTransforms: [String: ObjectTransform],
                composition: SceneComposition, showsPaper: Bool = true,
                backgroundStyle: WorkspaceBackgroundStyle = .dots,
                penStyle: CanvasStrokeStyle = .pen, markerStyle: CanvasStrokeStyle = .marker,
                pencilPreferences: PencilPreferences = .defaults,
                isPencilPalettePresented: Bool = false,
                showsDeveloperDiagnostics: Bool = false,
                onStroke: @escaping (UserStroke) -> Void = { _ in },
                tool: CanvasTool = .pen, onSelectionChanged: @escaping (Set<String>) -> Void = { _ in },
                onSelectionRegionChanged: @escaping (CGRect?) -> Void = { _ in },
                onMove: @escaping (Set<String>, CGPoint) -> Void = { _, _ in },
                onResize: @escaping (Set<String>, CGPoint, CGFloat) -> Void = { _, _, _ in },
                onResizeGraphHeight: @escaping (String, CGFloat, CGFloat) -> Void = { _, _, _ in },
                onGraphDoubleTap: @escaping (String) -> Void = { _ in },
                onDelete: @escaping (Set<String>) -> Void = { _ in }, onCameraChanged: @escaping (CameraRect) -> Void = { _ in }, onUndo: @escaping () -> Void = {}, onRedo: @escaping () -> Void = {},
                onPencilAction: @escaping (PencilLogicalAction, CGPoint?) -> Void = { _, _ in },
                onPencilPaletteMoved: @escaping (CGPoint) -> Void = { _ in },
                onPencilPaletteHighlight: @escaping (Int) -> Void = { _ in },
                onPencilPaletteCommit: @escaping (Int) -> Void = { _ in },
                onPencilPaletteDismiss: @escaping () -> Void = {}) {
        let boardChanged = self.boardID != boardID
        let documentChanged = self.document != document || self.importedTransforms != importedTransforms
        let previewChanged = self.previewImage !== previewImage
        let pdfChanged = self.pdfData != pdfData
        let objectsChanged = self.objects != objects
        self.boardID = boardID; self.document = document; self.previewImage = previewImage
        self.pdfData = pdfData; self.sourceKind = sourceKind; self.objects = objects
        self.importedTransforms = importedTransforms; self.composition = composition; self.showsPaper = showsPaper
        self.penStyle = penStyle; self.markerStyle = markerStyle
        self.pencilPreferences = pencilPreferences
        self.isPencilPalettePresented = isPencilPalettePresented
        if !isPencilPalettePresented { _ = squeezeState.dismiss() }
        self.showsDeveloperDiagnostics = showsDeveloperDiagnostics
        #if DEBUG
        perfLabel.isHidden = !showsDeveloperDiagnostics
        pencilRawMonitor.setVisible(showsDeveloperDiagnostics)
        pencilRawMonitor.setContext(tool: tool.rawValue, state: interactionState.rawValue)
        if !showsDeveloperDiagnostics { crosshairLayer.isHidden = true }
        #endif
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
            // A toolbar change is a hard ownership boundary. Discard any
            // presentation-only edit and restore an interrupted camera gesture
            // before the next tool is allowed to consume input.
            if interactionState != .idle { clearTransientInput() }
            pencilFeedback.request(.toolSelection(nil))
            #if DEBUG
            print("[VBoard] TOOL CHANGED \(self.activeTool.rawValue) -> \(tool.rawValue) board=\(boardID)")
            #endif
            if tool != .select, tool != .lasso, !selectedIDs.isEmpty {
                selectedIDs.removeAll()
                onSelectionRegionChanged(nil)
                onSelectionChanged([])
                updateSelectionOverlay()
            }
        }
        self.activeTool = tool; self.onSelectionChanged = onSelectionChanged
        self.onSelectionRegionChanged = onSelectionRegionChanged
        self.onMove = onMove; self.onResize = onResize
        self.onResizeGraphHeight = onResizeGraphHeight
        self.onGraphDoubleTap = onGraphDoubleTap
        self.onDelete = onDelete; self.onCameraChanged = onCameraChanged; self.onUndo = onUndo; self.onRedo = onRedo
        self.onPencilAction = onPencilAction
        self.onPencilPaletteMoved = onPencilPaletteMoved
        self.onPencilPaletteHighlight = onPencilPaletteHighlight
        self.onPencilPaletteCommit = onPencilPaletteCommit
        self.onPencilPaletteDismiss = onPencilPaletteDismiss
        panGesture.minimumNumberOfTouches = CanvasInputArbitrationPolicy
            .minimumDirectNavigationTouches(tool: tool)
        // Hand and simulator Space-pan own the root touch stream directly.
        // This keeps one camera owner for indirect-pointer drags; physical
        // devices retain the recognizer path below.
        #if targetEnvironment(simulator)
        panGesture.isEnabled = false
        #else
        // Direct fingers always navigate on hardware, independent of the
        // selected Pencil/content tool. Pencil touches are excluded by the
        // recognizer's allowedTouchTypes and continue through the edit path.
        panGesture.isEnabled = true
        #endif
        updateInputHUD()
        // `camera` is the store's persisted snapshot. It is consumed only
        // when a board identity changes; ordinary SwiftUI refreshes must not
        // overwrite the live camera after a pan or zoom.
        if documentChanged { professor.display(document, transform: worldTransform, importedTransforms: importedTransforms, composition: composition) }
        if previewChanged || documentChanged || pdfChanged {
            previewSource.image = previewImage
            PDFBoardSource.pinTopLeft(previewSource, size: document.viewBox.size,
                                      origin: document.viewBox.origin)
            previewSource.isHidden = (sourceKind != .image
                && !documentChanged && professor.hasVisiblePresentation)
                || previewImage == nil || pdfData != nil
        }
        if pdfChanged {
            if let pdfData { pdfSource.display(data: pdfData); pdfSource.isHidden = false }
            else { pdfSource.clear(); pdfSource.isHidden = true }
        }
        if pdfData != nil {
            PDFBoardSource.apply(transform: importedTransforms[PDFBoardSource.logicalID], to: pdfSource)
        } else {
            pdfSource.isHidden = true
        }
        if sourceKind == .image {
            PDFBoardSource.apply(transform: PDFBoardSource.imageTransform(importedTransforms),
                                 to: previewSource)
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
        let radius: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.95 : 0.9
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
        showsPaper ? CanvasDesignTokens.boardSurface : CanvasDesignTokens.canvasBackground
    }

    private func boardBoundaryColor() -> UIColor {
        CanvasDesignTokens.boardBorder
    }

    private func workspaceGridColor(alpha: CGFloat) -> UIColor {
        CanvasDesignTokens.dotColor.withAlphaComponent(alpha)
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
            if activeInputContact == .finger, activeInputOwner != .navigation {
                cancelActiveContentInteraction()
            }
            activeInputOwner = .navigation
            activeInputContact = .finger
            interactionState = .panning; debugInputOperation("PAN BEGIN")
            panStart = translation; panStartCamera = controller.camera; professor.beginNavigation(); debugPan("BEGIN", screen: translation); updateInputHUD()
        case .changed:
            guard interactionState == .panning else { return }
            setCamera(panStartCamera, reason: .handPan)
            mutateCamera(reason: .handPan) { $0.pan(screenTranslation: CGPoint(x: translation.x - panStart.x, y: translation.y - panStart.y), viewport: bounds.size) }
            applyCamera(interacting: true); debugInputOperation("PAN UPDATE"); debugPan("UPDATE", screen: translation)
        case .ended:
            guard interactionState == .panning else { return }
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; debugInputOperation("PAN END"); debugPan("END"); updateInputHUD()
            activeInputOwner = .none; activeInputContact = nil
            panStart = .zero
        case .cancelled, .failed:
            guard interactionState == .panning else { return }
            setCamera(panStartCamera, reason: .handPan)
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; debugInputOperation("PAN CANCEL"); debugPan("CANCEL"); updateInputHUD()
            activeInputOwner = .none; activeInputContact = nil
            panStart = .zero
        default: break
        }
    }

    @objc private func didWheelZoom(_ gesture: UIPanGestureRecognizer) {
        let focalPoint = gesture.location(in: self)
        switch gesture.state {
        case .began:
            wheelStartCamera = controller.camera
            professor.beginNavigation()
        case .changed:
            let delta = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            guard delta.isFinite, abs(delta) > 0.001 else { return }
            let factor = min(1.8, max(0.55, exp(-delta * 0.006)))
            mutateCamera(reason: .pinch) {
                $0.zoom(by: factor, anchoredAt: focalPoint, viewport: bounds.size)
            }
            applyCamera(interacting: true)
        case .ended:
            professor.endNavigation(worldTransform)
            applyCamera(interacting: false)
            onCameraChanged(controller.camera)
        case .cancelled, .failed:
            setCamera(wheelStartCamera, reason: .pinch)
            professor.endNavigation(worldTransform)
            applyCamera(interacting: false)
            onCameraChanged(controller.camera)
        default: break
        }
    }

    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            if activeInputContact == .finger, activeInputOwner != .navigation {
                cancelActiveContentInteraction()
            }
            activeInputOwner = .navigation
            activeInputContact = .finger
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
        case .ended:
            guard interactionState == .pinching else { return }
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; pinchStartMidpoint = .zero; debugInputOperation("PINCH END"); updateInputHUD()
            activeInputOwner = .none; activeInputContact = nil
        case .cancelled, .failed:
            guard interactionState == .pinching else { return }
            setCamera(pinchStartCamera, reason: .pinch)
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; pinchStartMidpoint = .zero; debugInputOperation("PINCH CANCEL"); updateInputHUD()
            activeInputOwner = .none; activeInputContact = nil
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let navigationPans = [panGesture, scrollPanGesture].compactMap { $0 }
        return navigationPans.contains(where: {
            (gestureRecognizer === $0 && otherGestureRecognizer === pinchGesture)
                || (otherGestureRecognizer === $0 && gestureRecognizer === pinchGesture)
        })
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard CanvasGestureHitTestPolicy.allowsCanvasGesture(
            from: touch.view, canvasRoot: self
        ) else { return false }
        if gestureRecognizer === graphFingerTapGesture
            || gestureRecognizer === graphPointerDoubleTapGesture {
            return graphObjectID(at: touch.location(in: self)) != nil
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGesture || gestureRecognizer === scrollPanGesture
            || gestureRecognizer === wheelZoomGesture { return true }
        return true
    }

    @objc private func didOpenGraph(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        guard let graphID = graphObjectID(at: recognizer.location(in: self)) else { return }
        onGraphDoubleTap(graphID)
    }

    private func graphObjectID(at screenPoint: CGPoint) -> String? {
        let world = worldPoint(screenPoint, from: self)
        return objects.reversed().first(where: {
            $0.graph != nil && BoardHitTestPolicy.bounds(of: $0).contains(world)
        })?.id
    }

    private var drawsWithFinger: Bool {
        #if targetEnvironment(simulator)
        // Simulator primary-click streams may be synthesized as `.direct`.
        return true
        #else
        // iPhone has no Pencil path, so editing tools remain usable. iPad Pen
        // and Marker reserve one-finger drawing until a visible preference is
        // introduced; Lasso/Eraser/Select still edit with one finger.
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    private func contact(for touch: UITouch) -> CanvasInputContact {
        if touch.type == .pencil { return .pencil }
        #if targetEnvironment(simulator)
        if touch.type == .direct || touch.type == .indirectPointer { return .primaryPointer }
        #else
        if touch.type == .direct { return .finger }
        if touch.type == .indirectPointer { return .primaryPointer }
        #endif
        return .navigationPointer
    }

    private func directContactCount(event: UIEvent?) -> Int {
        max(1, event?.allTouches?.filter {
            $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 1)
    }

    // Pencil, enabled finger drawing, and simulator primary-click input use
    // the same canonical Stroke model.
    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        CanvasInputArbitrationPolicy.owner(
            tool: activeTool,
            contact: contact(for: touch),
            drawsWithFinger: drawsWithFinger
        ) == .stroke
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
        if showsDeveloperDiagnostics { updateCrosshair(screen: screen, roundTrip: roundTrip) }
    }
    private func debugOwnership(_ phase: String, touch: UITouch,
                                owner: CanvasInputOwner, contactCount: Int) {
        let point = touch.location(in: self)
        let hit = hitTest(point, with: nil)
        let hitName = hit.map { String(describing: type(of: $0)) } ?? "none"
        let renderState = vectorIndicator.state
        let pop = nearestNavigationController()?.interactivePopGestureRecognizer
        let recognizers = "pan=\(Self.gestureStateName(panGesture.state)),pinch=\(Self.gestureStateName(pinchGesture.state)),scroll=\(Self.gestureStateName(scrollPanGesture.state))"
        print("[VBoard] INPUT_OWNER phase=\(phase) board=\(boardID) source=\(sourceKind.rawValue) render=\(renderState) tool=\(activeTool.rawValue) contact=\(contact(for: touch).rawValue) contacts=\(contactCount) screen=(\(point.x),\(point.y)) world=\(worldPoint(point, from: self)) hit=\(hitName) recognizers={\(recognizers)} candidate=\(owner.rawValue) owner=\(activeInputOwner.rawValue) camera=\(controller.camera) popEnabled=\(pop?.isEnabled.description ?? "missing") popState=\(pop.map { Self.gestureStateName($0.state) } ?? "missing")")
        if owner == .navigation, contactCount == 1,
           activeTool == .lasso || activeTool == .objectEraser
            || activeTool == .pen || activeTool == .highlighter {
            assertionFailure("Unexpected navigation ownership while \(activeTool.rawValue) selected")
        }
    }
    private static func gestureStateName(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }
    private func nearestNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.navigationController
            }
            responder = current.next
        }
        return nil
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
        guard showsDeveloperDiagnostics else { return }
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
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoKey)),
         UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteSelectionKey))]
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
        clearTransientInput()
        super.pressesCancelled(presses, with: event)
    }

    @objc private func clearTransientInput() {
        isSpacePressed = false
        switch interactionState {
        case .panning:
            setCamera(panStartCamera, reason: .handPan)
            professor.endNavigation(worldTransform)
            applyCamera(interacting: false)
            onCameraChanged(controller.camera)
        case .pinching:
            setCamera(pinchStartCamera, reason: .pinch)
            professor.endNavigation(worldTransform)
            applyCamera(interacting: false)
            onCameraChanged(controller.camera)
        default:
            break
        }
        cancelActiveContentInteraction()
        panStart = .zero
        pinchStartMidpoint = .zero
        _ = eraseTransaction.cancel()
        moveDelta = .zero
        moveActive = false
        resizeSession = nil
        resizePreviewBounds = nil
        updateSelectionOverlay()
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
    @objc private func deleteSelectionKey() {
        guard interactionState == .idle, !selectedIDs.isEmpty else { return }
        let deleted = selectedIDs
        selectedIDs.removeAll()
        onSelectionRegionChanged(nil)
        onSelectionChanged([])
        updateSelectionOverlay()
        onDelete(deleted)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        pencilHoverLayer.isHidden = true
        pencilHoverLayer.path = nil
        let inputContact = contact(for: touch)
        let contactCount = inputContact == .finger ? directContactCount(event: event) : 1
        let owner = CanvasInputArbitrationPolicy.owner(
            tool: isSpacePressed ? .navigation : activeTool,
            contact: inputContact,
            contactCount: contactCount,
            drawsWithFinger: drawsWithFinger
        )
        activeInputContact = inputContact
        activeInputOwner = owner
        #if DEBUG
        pencilRawMonitor.recordTouch("BEGIN", touch: touch, event: event, in: self,
                                     tool: activeTool.rawValue, state: interactionState.rawValue)
        debugOwnership("BEGIN", touch: touch, owner: owner, contactCount: contactCount)
        #endif
        debugInput("BEGIN", touch: touch)
        if owner == .none {
            super.touchesBegan(touches, with: event)
            return
        }
        let screen = touch.location(in: self)
        let point = worldPoint(screen, from: self)
        if owner == .navigation {
            // Direct-finger navigation is recognizer-owned: one finger for
            // Hand, two fingers for every editing tool. Pointer/Pencil Hand
            // input stays on the root touch path.
            if inputContact == .finger {
                super.touchesBegan(touches, with: event)
                return
            }
            panStart = screen; panStartCamera = controller.camera
            interactionState = .panning; professor.beginNavigation()
            debugInputOperation("PAN BEGIN"); debugPan("BEGIN", screen: screen); updateInputHUD(); return
        }
        if owner != .stroke { beginEditing(at: point, screen: screen); return }
        interactionState = .drawing; debugInputOperation("STROKE BEGIN"); updateInputHUD()
        recentlyCommittedStroke = nil
        strokeAccumulator.reset()
        strokeAccumulator.appendConfirmed(samples(for: touch, event: event))
        activePoints = strokeAccumulator.canonicalPoints
        predictedPoints.removeAll(keepingCapacity: true)
        activeID = UUID().uuidString
        let layer = CAShapeLayer(); layer.fillColor = strokeColor.cgColor
        layer.strokeColor = nil
        layer.fillRule = .nonZero
        // Canonical object layers retain document order. The transient trace
        // is presentation-only and must remain visible above opaque graph
        // proxies until the finalized canonical stroke replaces it.
        layer.zPosition = 1_000_000
        activeStrokeLayer = layer
        updateActiveStroke()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        #if DEBUG
        pencilRawMonitor.recordTouch("MOVE", touch: touch, event: event, in: self,
                                     tool: activeTool.rawValue, state: interactionState.rawValue)
        #endif
        debugInput("MOVE", touch: touch)
        if (interactionState == .panning || interactionState == .pinching),
           activeStrokeLayer != nil, isDrawingTouch(touch) {
            strokeAccumulator.appendConfirmed(samples(for: touch, event: event))
            strokeAccumulator.setPredicted(predictedSamples(for: touch, event: event))
            activePoints = strokeAccumulator.canonicalPoints
            predictedPoints = strokeAccumulator.predicted
            updateActiveStroke()
            return
        }
        if interactionState == .panning {
            let screen = touch.location(in: self)
            setCamera(panStartCamera, reason: .handPan)
            mutateCamera(reason: .handPan) { $0.pan(screenTranslation: CGPoint(x: screen.x - panStart.x, y: screen.y - panStart.y), viewport: bounds.size) }
            applyCamera(interacting: true); debugInputOperation("PAN UPDATE"); debugPan("UPDATE", screen: screen); return
        }
        if activeInputOwner == .lasso || activeInputOwner == .eraser
            || activeInputOwner == .selection {
            continueEditing(at: worldPoint(touch.location(in: self), from: self),
                            screen: touch.location(in: self))
            return
        }
        guard activeInputOwner == .stroke, isDrawingTouch(touch) else { return }
        strokeAccumulator.appendConfirmed(samples(for: touch, event: event))
        strokeAccumulator.setPredicted(predictedSamples(for: touch, event: event))
        activePoints = strokeAccumulator.canonicalPoints
        predictedPoints = strokeAccumulator.predicted
        updateActiveStroke(); debugInputOperation("STROKE APPEND")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        #if DEBUG
        pencilRawMonitor.recordTouch("END", touch: touch, event: event, in: self,
                                     tool: activeTool.rawValue, state: interactionState.rawValue)
        #endif
        debugInput("END", touch: touch)
        if (interactionState == .panning || interactionState == .pinching),
           activeStrokeLayer != nil, isDrawingTouch(touch) {
            strokeAccumulator.appendConfirmed(samples(for: touch, event: event))
            activePoints = strokeAccumulator.canonicalPoints
            commitActiveStroke()
            return
        }
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
            interactionState = .idle; panStart = .zero
            activeInputOwner = .none; activeInputContact = nil
            debugInputOperation("PAN END"); debugPan("END", screen: screen); updateInputHUD(); return
        }
        if activeInputOwner == .lasso || activeInputOwner == .eraser
            || activeInputOwner == .selection {
            finishEditing(at: worldPoint(touch.location(in: self), from: self))
            activeInputOwner = .none; activeInputContact = nil
            return
        }
        guard activeInputOwner == .stroke, isDrawingTouch(touch) else { return }
        strokeAccumulator.appendConfirmed(samples(for: touch, event: event))
        activePoints = strokeAccumulator.canonicalPoints
        commitActiveStroke()
        interactionState = .idle; activeInputOwner = .none; activeInputContact = nil; updateInputHUD()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        #if DEBUG
        if let touch = touches.first {
            pencilRawMonitor.recordTouch("CANCEL", touch: touch, event: event, in: self,
                                         tool: activeTool.rawValue, state: interactionState.rawValue)
        }
        #endif
        if interactionState == .panning {
            setCamera(panStartCamera, reason: .handPan)
            professor.endNavigation(worldTransform); applyCamera(interacting: false)
            onCameraChanged(controller.camera)
            interactionState = .idle; panStart = .zero
            activeInputOwner = .none; activeInputContact = nil
            updateInputHUD(); return
        }
        if activeInputOwner == .lasso || activeInputOwner == .eraser
            || activeInputOwner == .selection {
            finishEditing(at: nil)
            activeInputOwner = .none; activeInputContact = nil
            return
        }
        if activeInputOwner == .stroke, touches.contains(where: { isDrawingTouch($0) }) {
            activeStrokeLayer?.removeFromSuperlayer(); activeStrokeLayer = nil
            activePoints.removeAll(); predictedPoints.removeAll(); strokeAccumulator.reset(); activeID = nil
        }
        interactionState = .idle; activeInputOwner = .none; activeInputContact = nil
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        #if DEBUG
        pencilRawMonitor.recordEstimatedUpdates(touches, in: self)
        #endif
        let corrections = touches.filter(isDrawingTouch).map(sample(for:))
        if interactionState == .drawing {
            strokeAccumulator.replaceEstimated(corrections)
            activePoints = strokeAccumulator.canonicalPoints
            updateActiveStroke()
        } else if let stroke = recentlyCommittedStroke,
                  let corrected = PencilStrokeCorrection.applying(corrections, to: stroke) {
            recentlyCommittedStroke = corrected
            onStroke(corrected)
        }
        super.touchesEstimatedPropertiesUpdated(touches)
    }

    private func commitActiveStroke() {
        if let activeID, !activePoints.isEmpty {
            let stroke = UserStroke(id: activeID, color: strokeColorHex, width: strokeWidth,
                                    opacity: strokeOpacity, points: activePoints,
                                    pencilTool: activePencilStrokeTool)
            recentlyCommittedStroke = stroke
            onStroke(stroke)
            debugInputOperation("STROKE FINALIZE")
        }
        activeStrokeLayer?.removeFromSuperlayer()
        activeStrokeLayer = nil
        activePoints.removeAll()
        predictedPoints.removeAll()
        strokeAccumulator.reset()
        activeID = nil
    }

    private func beginEditing(at point: CGPoint, screen: CGPoint) {
        editStart = point; editStartScreen = screen; lastEditPoint = point
        moveDelta = .zero; moveActive = false; resizeSession = nil; resizePreviewBounds = nil
        if activeTool == .navigation {
            interactionState = .panning
            return
        } else if (activeTool == .lasso || activeTool == .select),
                  let bounds = selectionWorldBounds(),
                  let handle = resizeHandle(at: point, bounds: bounds) {
            let session = SelectionResizeSession(keys: [], startBounds: bounds,
                                                 handle: handle, startPointer: point,
                                                 mode: selectedGraphForVerticalResize == nil
                                                    ? .uniform : .graphVertical)
            resizeSession = session
            resizePreviewBounds = bounds
            interactionState = .resizingSelection
            return
        } else if activeTool == .lasso {
            if let bounds = selectionWorldBounds(),
               bounds.insetBy(dx: -10 / max(worldTransform.scale, 0.001),
                              dy: -10 / max(worldTransform.scale, 0.001)).contains(point) {
                interactionState = .movingSelection
                return
            }
            if !selectedIDs.isEmpty {
                selectedIDs.removeAll()
                onSelectionRegionChanged(nil)
                onSelectionChanged([])
                updateSelectionOverlay()
            }
            interactionState = .lassoing; lassoWorldPoints = [point]; debugInputOperation("LASSO BEGIN"); updateInteractionPath()
        } else if activeTool == .objectEraser {
            interactionState = .erasing; eraseTransaction.begin(); eraseSegment(from: point, to: point); debugInputOperation("ERASER BEGIN")
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
        if interactionState == .movingSelection {
            moveActive = true
            moveDelta = CGPoint(x: point.x - editStart.x, y: point.y - editStart.y)
            previewMove(moveDelta)
            debugInputOperation("MOVE UPDATE")
            lastEditPoint = point
            return
        }
        if interactionState == .resizingSelection, let session = resizeSession {
            let requested = SelectionResizeGeometry.scale(session: session, currentPointer: point)
            let scale = boundedResizeScale(session: session, requested: requested) ?? 1
            resizePreviewBounds = SelectionResizeGeometry.bounds(session: session, scale: scale)
            if session.mode == .graphVertical {
                previewGraphVerticalResize(anchorY: session.anchor.y, scale: scale)
            } else {
                previewResize(anchor: session.anchor, scale: scale)
            }
            updateSelectionOverlay()
            lastEditPoint = point
            return
        }
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
        if interactionState == .resizingSelection, let session = resizeSession {
            let requested = endpoint.map {
                SelectionResizeGeometry.scale(session: session, currentPointer: $0)
            } ?? 1
            if endpoint != nil,
               let scale = boundedResizeScale(session: session, requested: requested) {
                if session.mode == .graphVertical,
                   let graph = selectedGraphForVerticalResize {
                    onResizeGraphHeight(graph.id, session.anchor.y, scale)
                } else {
                    retainResizePreview(anchor: session.anchor, scale: scale)
                    onResize(selectedIDs, session.anchor, scale)
                }
                debugInputOperation("RESIZE COMMIT")
            } else {
                clearResizePreview()
            }
            resizeSession = nil; resizePreviewBounds = nil
            interactionState = .idle; updateSelectionOverlay(); updateInputHUD()
            return
        }
        if activeTool == .select || interactionState == .movingSelection {
            if let endpoint, !selectedIDs.isEmpty {
                let delta = CGPoint(x: endpoint.x - editStart.x, y: endpoint.y - editStart.y)
                if moveActive || hypot(delta.x, delta.y) > 0 {
                    moveDelta = delta
                    retainMovePreview(delta)
                    onMove(selectedIDs, delta)
                    debugInputOperation("MOVE COMMIT")
                } else {
                    clearMovePreview()
                }
            } else {
                clearMovePreview()
            }
            moveActive = false; moveDelta = .zero
            interactionState = .idle; updateSelectionOverlay(); updateInputHUD()
            return
        }
        if interactionState == .erasing {
            if endpoint != nil, !eraseTransaction.erasedIDs.isEmpty {
                let deleted = eraseTransaction.commit()
                selectedIDs.subtract(deleted)
                onSelectionRegionChanged(nil)
                onDelete(deleted)
                onSelectionChanged(selectedIDs)
                debugInputOperation("ERASER COMMIT")
            } else {
                setErasePreview(ids: eraseTransaction.cancel(), hidden: false)
            }
            interactionState = .idle
            updateSelectionOverlay(); updateInputHUD()
            return
        }
        if interactionState == .lassoing, let endpoint, lassoWorldPoints.count == 1 { lassoWorldPoints.append(endpoint) }
        if interactionState == .lassoing, lassoWorldPoints.count >= 2 {
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
        let started = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in selectedIDs {
            userObjectLayers[id]?.setAffineTransform(CGAffineTransform(translationX: delta.x, y: delta.y))
        }
        professor.previewTranslation(ids: selectedIDs, delta: delta)
        updateSelectionOverlay()
        CATransaction.commit()
        #if DEBUG
        print("[VBoard] SELECTION PREVIEW sameFrame=true ids=\(selectedIDs.count) apply_ms=\(String(format: "%.3f", (CACurrentMediaTime() - started) * 1_000)) delta=(\(delta.x),\(delta.y))")
        #endif
    }

    private func clearMovePreview() {
        for id in selectedIDs { userObjectLayers[id]?.setAffineTransform(.identity) }
        professor.clearPreviewTranslation(ids: selectedIDs)
        if selectedIDs.contains(PDFBoardSource.imageLogicalID) {
            PDFBoardSource.apply(transform: PDFBoardSource.imageTransform(importedTransforms),
                                 to: previewSource)
        }
    }

    private func retainMovePreview(_ delta: CGPoint) {
        professor.retainPreviewTranslation(ids: selectedIDs, delta: delta)
        if selectedIDs.contains(PDFBoardSource.imageLogicalID) {
            applyImageSourcePreview(delta: delta)
        }
        // User-object layers retain the same presentation transform until the
        // canonical object update rebuilds them on the next SwiftUI pass.
    }

    private func previewResize(anchor: CGPoint, scale: CGFloat) {
        professor.previewScale(ids: selectedIDs, anchor: anchor, scale: scale)
        if selectedIDs.contains(PDFBoardSource.imageLogicalID) {
            applyImageSourcePreview(anchor: anchor, scale: scale)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in selectedIDs {
            guard let layer = userObjectLayers[id] else { continue }
            let original = resizePreviewPositions[id] ?? layer.position
            resizePreviewPositions[id] = original
            layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            layer.position = CGPoint(x: anchor.x + (original.x - anchor.x) * scale,
                                     y: anchor.y + (original.y - anchor.y) * scale)
        }
        CATransaction.commit()
    }

    private func previewGraphVerticalResize(anchorY: CGFloat, scale: CGFloat) {
        guard let graph = selectedGraphForVerticalResize,
              let layer = userObjectLayers[graph.id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let original = resizePreviewPositions[graph.id] ?? layer.position
        resizePreviewPositions[graph.id] = original
        layer.setAffineTransform(CGAffineTransform(scaleX: 1, y: scale))
        layer.position = CGPoint(x: original.x,
                                 y: anchorY + (original.y - anchorY) * scale)
        CATransaction.commit()
    }

    private func clearResizePreview() {
        professor.clearPreviewScale(ids: selectedIDs)
        if selectedIDs.contains(PDFBoardSource.imageLogicalID) {
            PDFBoardSource.apply(transform: PDFBoardSource.imageTransform(importedTransforms),
                                 to: previewSource)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in selectedIDs {
            guard let layer = userObjectLayers[id] else { continue }
            layer.setAffineTransform(.identity)
            if let original = resizePreviewPositions.removeValue(forKey: id) {
                layer.position = original
            }
        }
        CATransaction.commit()
    }

    private func retainResizePreview(anchor: CGPoint, scale: CGFloat) {
        professor.retainPreviewScale(ids: selectedIDs, anchor: anchor, scale: scale)
        if selectedIDs.contains(PDFBoardSource.imageLogicalID) {
            applyImageSourcePreview(anchor: anchor, scale: scale)
        }
    }

    private func applyImageSourcePreview(delta: CGPoint) {
        let existing = PDFBoardSource.imageTransform(importedTransforms)
        previewSource.layer.setAffineTransform(CGAffineTransform(
            a: CGFloat(existing?.scaleX ?? 1), b: 0, c: 0,
            d: CGFloat(existing?.scaleY ?? 1),
            tx: CGFloat(existing?.x ?? 0) + delta.x,
            ty: CGFloat(existing?.y ?? 0) + delta.y
        ))
    }

    private func applyImageSourcePreview(anchor: CGPoint, scale: CGFloat) {
        let existing = PDFBoardSource.imageTransform(importedTransforms)
        let oldX = CGFloat(existing?.x ?? 0)
        let oldY = CGFloat(existing?.y ?? 0)
        previewSource.layer.setAffineTransform(CGAffineTransform(
            a: CGFloat(existing?.scaleX ?? 1) * scale, b: 0, c: 0,
            d: CGFloat(existing?.scaleY ?? 1) * scale,
            tx: anchor.x + scale * (oldX - anchor.x),
            ty: anchor.y + scale * (oldY - anchor.y)
        ))
    }

    /// The visual proxy must use the same factor as the document mutation.
    /// Otherwise a graph already at its minimum/maximum can leave a retained
    /// transform behind even though the canonical store correctly no-ops.
    private func boundedResizeScale(session: SelectionResizeSession,
                                    requested: CGFloat) -> CGFloat? {
        if session.mode == .graphVertical {
            guard let graph = selectedGraphForVerticalResize else { return nil }
            return GraphCardResizePolicy.clampedVerticalFactor(
                currentHeight: graph.frame.height, requested: requested
            )
        }
        let anchor = session.anchor
        let editorIDs = Set(objects.lazy.filter { self.selectedIDs.contains($0.id) }.map(\.id))
        return SelectionScaleBounds.selection(
            objects: objects,
            importedTransforms: importedTransforms,
            editorObjectIDs: editorIDs,
            professorPathIDs: selectedIDs.subtracting(editorIDs),
            anchor: anchor
        )?.clampedFactor(requested)
    }

    private func eraseSegment(from start: CGPoint, to end: CGPoint) {
        let radius = PencilEraserFootprint.worldRadius(cameraScale: worldTransform.scale)
        let segmentBounds = SweptEraserGeometry.bounds(from: start, to: end, radius: radius)
        var hit = Set(objects.compactMap { object -> String? in
            guard segmentBounds.intersects(BoardHitTestPolicy.bounds(of: object)) else { return nil }
            return CanvasObjectEraserHitTest.intersects(
                object, from: start, to: end, eraserRadius: radius
            ) ? object.id : nil
        })
        hit.formUnion(professor.ids(intersectingSweptSegmentFrom: start, to: end,
                                    radius: radius))
        let fresh = eraseTransaction.register(hit)
        guard !fresh.isEmpty else { return }
        // Visual feedback is immediate, while canonical deletion remains one
        // batch at gesture end. Cancellation can therefore restore the exact
        // pre-gesture presentation without touching editor state.
        setErasePreview(ids: fresh, hidden: true)
        #if DEBUG
        print("[VBoard] ERASER HITS ids=\(Array(fresh))")
        #endif
    }

    private func cancelActiveContentInteraction() {
        switch interactionState {
        case .drawing:
            activeStrokeLayer?.removeFromSuperlayer()
            activeStrokeLayer = nil
            activePoints.removeAll(); predictedPoints.removeAll()
            strokeAccumulator.reset(); activeID = nil
        case .movingSelection:
            clearMovePreview()
        case .resizingSelection:
            clearResizePreview()
        case .lassoing:
            lassoWorldPoints.removeAll()
        case .erasing:
            setErasePreview(ids: eraseTransaction.cancel(), hidden: false)
        case .idle, .panning, .pinching, .selecting:
            break
        }
        interactionState = .idle
        activeInputOwner = .none
        activeInputContact = nil
        updateInteractionPath()
        updateInputHUD()
    }

    private func setErasePreview(ids: Set<String>, hidden: Bool) {
        guard !ids.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in ids { userObjectLayers[id]?.isHidden = hidden }
        CATransaction.commit()
        professor.setTransientHidden(ids: ids, hidden: hidden)
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
        guard !lassoWorldPoints.isEmpty else { updateSelectionOverlay(); return }
        let path = UIBezierPath(); for (index, point) in lassoWorldPoints.enumerated() { if index == 0 { path.move(to: point) } else { path.addLine(to: point) } }
        interactionLayer.path = path.cgPath; interactionLayer.isHidden = false
    }

    private func updateSelectionOverlay() {
        guard !selectedIDs.isEmpty else { interactionLayer.isHidden = lassoWorldPoints.isEmpty; return }
        guard var bounds = resizePreviewBounds ?? selectionWorldBounds() else { return }
        if moveActive { bounds = bounds.offsetBy(dx: moveDelta.x, dy: moveDelta.y) }
        let inverseScale = 1 / max(worldTransform.scale, 0.001)
        let path = UIBezierPath(rect: bounds.insetBy(dx: -10 * inverseScale,
                                                     dy: -10 * inverseScale))
        let handleRadius = 6 * inverseScale
        for handle in availableResizeHandles {
            let point = handle.point(in: bounds)
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - handleRadius,
                                                    y: point.y - handleRadius,
                                                    width: handleRadius * 2,
                                                    height: handleRadius * 2)))
        }
        interactionLayer.lineWidth = 2 * inverseScale
        interactionLayer.lineDashPattern = [NSNumber(value: 8 * inverseScale),
                                            NSNumber(value: 5 * inverseScale)]
        interactionLayer.path = path.cgPath; interactionLayer.isHidden = false
    }

    private func selectionWorldBounds() -> CGRect? {
        var bounds = CGRect.null
        for object in objects where selectedIDs.contains(object.id) {
            bounds = bounds.union(BoardHitTestPolicy.bounds(of: object))
        }
        for id in selectedIDs { bounds = bounds.union(professor.bounds(for: id)) }
        return bounds.isNull ? nil : bounds
    }

    private func resizeHandle(at point: CGPoint, bounds: CGRect) -> SelectionResizeHandle? {
        let tolerance = PencilHitTarget.resizeHandleRadius / max(worldTransform.scale, 0.001)
        return availableResizeHandles.first {
            let handlePoint = $0.point(in: bounds)
            return hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= tolerance
        }
    }

    private var selectedGraphForVerticalResize: GraphObject? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return objects.first(where: { $0.id == id })?.graph
    }

    private var availableResizeHandles: [SelectionResizeHandle] {
        if selectedGraphForVerticalResize != nil { return SelectionResizeHandle.verticalHandles }
        let containsGraph = objects.contains { selectedIDs.contains($0.id) && $0.graph != nil }
        return containsGraph ? [] : SelectionResizeHandle.cornerHandles
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
        return source.map(sample(for:))
    }

    private func predictedSamples(for touch: UITouch, event: UIEvent?) -> [StrokePoint] {
        (event?.predictedTouches(for: touch) ?? []).map(sample(for:))
    }

    private func sample(for touch: UITouch) -> StrokePoint {
        let sourceView = touch.view ?? self
        let point = worldPoint(touch.preciseLocation(in: sourceView), from: sourceView)
        #if targetEnvironment(simulator)
        let pressure: CGFloat? = nil
        #else
        let pressure = touch.type == .pencil
            ? PencilPressureResponse.normalized(force: touch.force,
                                                maximum: touch.maximumPossibleForce)
            : nil
        #endif
        let isPencil = touch.type == .pencil
        let roll: CGFloat?
        if #available(iOS 17.5, *), isPencil { roll = touch.rollAngle } else { roll = nil }
        return StrokePoint(
            x: point.x, y: point.y, pressure: pressure.map(Double.init),
            altitude: isPencil ? Double(touch.altitudeAngle) : nil,
            azimuth: isPencil ? Double(touch.azimuthAngle(in: self)) : nil,
            roll: roll.map(Double.init), timestamp: touch.timestamp,
            estimationUpdateIndex: touch.estimationUpdateIndex?.intValue
        )
    }

    private func updateActiveStroke() {
        guard let layer = activeStrokeLayer else { return }
        layer.path = PencilStrokeGeometry.path(points: activePoints + predictedPoints,
                                               tool: activePencilStrokeTool,
                                               baseWidth: strokeWidth)
        layer.frame = bounds
        if layer.superlayer == nil { userLayer.addSublayer(layer) }
    }

    private var activeStrokeStyle: CanvasStrokeStyle { activeTool == .highlighter ? markerStyle : penStyle }
    private var strokeColorHex: String { activeStrokeStyle.colorHex }
    private var strokeColor: UIColor { UIColor(svgHex: strokeColorHex).withAlphaComponent(CGFloat(strokeOpacity)) }
    private var strokeWidth: CGFloat { CGFloat(activeStrokeStyle.width) }
    private var strokeOpacity: Double { activeStrokeStyle.opacity }
    private var activePencilStrokeTool: PencilStrokeTool {
        activeTool == .highlighter ? .marker : .pen
    }

    private func rebuildUserLayers() {
        let canonical = SceneComposition.canonicalEditorObjects(objects)
        let nextIDs = Set(canonical.map(\.id))
        for id in Array(userObjectLayers.keys) where !nextIDs.contains(id) {
            userObjectLayers.removeValue(forKey: id)?.removeFromSuperlayer()
            renderedObjects.removeValue(forKey: id)
        }
        for (index, object) in canonical.enumerated() {
            let layer: CALayer
            if renderedObjects[object.id] == object, let existing = userObjectLayers[object.id] {
                layer = existing
            } else {
                userObjectLayers.removeValue(forKey: object.id)?.removeFromSuperlayer()
                layer = makeObjectLayer(object)
                userObjectLayers[object.id] = layer
                userLayer.addSublayer(layer)
            }
            layer.zPosition = CGFloat(index)
            renderedObjects[object.id] = object
        }
        for stroke in userStrokes where strokeLayers[stroke.id] == nil { addStrokeLayer(stroke) }
    }

    private func makeObjectLayer(_ object: CanvasObject) -> CALayer {
        if object.type == "graph", let graph = object.graph {
            let layer = GraphFallbackRenderer.cachedProxyLayer(
                for: graph, contentsScale: window?.screen.scale ?? UIScreen.main.scale,
                appearance: VBoardCanvasTheme.interfaceStyle
            )
            applyProvenance(object.id, to: layer)
            return layer
        }
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
        let transformedPoints = (object.points ?? []).map { point in
            StrokePoint(x: point.x * scaleX + tx, y: point.y * scaleY + ty,
                        pressure: point.pressure, altitude: point.altitude,
                        azimuth: point.azimuth, roll: point.roll,
                        timestamp: point.timestamp,
                        estimationUpdateIndex: point.estimationUpdateIndex)
        }
        for (index, point) in transformedPoints.enumerated() {
            let world = CGPoint(x: point.x, y: point.y)
            if index == 0 { path.move(to: world) } else { path.addLine(to: world) }
        }
        let color = UIColor(svgHex: object.color ?? "#183153").withAlphaComponent(CGFloat(object.opacity ?? 1)).cgColor
        if let pencilTool = object.pencilTool {
            layer.path = PencilStrokeGeometry.path(points: transformedPoints, tool: pencilTool,
                                                   baseWidth: CGFloat((object.width ?? 4) * sqrt(abs(scaleX * scaleY))))
            layer.fillColor = color; layer.strokeColor = nil; layer.fillRule = .nonZero
        } else {
            layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color
            layer.lineWidth = (object.width ?? 4) * sqrt(abs(scaleX * scaleY))
            layer.lineCap = .round; layer.lineJoin = .round
        }
        applyProvenance(object.id, to: layer); return layer
    }

    private func addStrokeLayer(_ stroke: UserStroke) {
        let layer = CAShapeLayer(); let path = UIBezierPath()
        for (index, point) in stroke.points.enumerated() {
            let world = CGPoint(x: point.x + stroke.translation.x, y: point.y + stroke.translation.y)
            if index == 0 { path.move(to: world) } else { path.addLine(to: world) }
        }
        let color = UIColor(svgHex: stroke.color).withAlphaComponent(CGFloat(stroke.opacity)).cgColor
        if let pencilTool = stroke.pencilTool {
            let translated = stroke.points.map {
                StrokePoint(x: $0.x + stroke.translation.x, y: $0.y + stroke.translation.y,
                            pressure: $0.pressure, altitude: $0.altitude, azimuth: $0.azimuth,
                            roll: $0.roll, timestamp: $0.timestamp,
                            estimationUpdateIndex: $0.estimationUpdateIndex)
            }
            layer.path = PencilStrokeGeometry.path(points: translated, tool: pencilTool,
                                                   baseWidth: CGFloat(stroke.width))
            layer.fillColor = color; layer.strokeColor = nil; layer.fillRule = .nonZero
        } else {
            layer.path = path.cgPath; layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color
            layer.lineWidth = stroke.width; layer.lineCap = .round; layer.lineJoin = .round
        }
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
        guard showsDeveloperDiagnostics else { return }
        renderDebugHUD()
    }

    private func renderDebugHUD() {
        pencilRawMonitor.setContext(tool: activeTool.rawValue, state: interactionState.rawValue)
        var text = "Tool: \(activeTool.rawValue)\nInput: \(activeInputSource.rawValue)\nState: \(interactionState.rawValue)  Selected: \(selectedIDs.count) Space: \(isSpacePressed)\nCamera: x=\(Int(controller.camera.x)) y=\(Int(controller.camera.y)) w=\(Int(controller.camera.width)) h=\(Int(controller.camera.height))\nBoard: \(Int(document.viewBox.width))×\(Int(document.viewBox.height))  Paper: \(!paperLayer.isHidden)\nLast camera: \(lastCameraMutationReason?.rawValue ?? "none")"
        if let stats = lastRenderStats { text += "\n" + stats.overlayText }
        perfLabel.text = text
    }
    #endif
}
