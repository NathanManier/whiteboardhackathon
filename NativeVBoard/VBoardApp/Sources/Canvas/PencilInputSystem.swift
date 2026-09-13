import Foundation
import CoreGraphics
import UIKit
import SwiftUI

/// Product-level Pencil families used by contract tests and settings. Runtime
/// behavior never guesses a family from a device-name string; it is gated by
/// API availability and by signals that UIKit actually delivers.
enum PencilGenerationProfile: String, CaseIterable, Sendable {
    case firstGeneration
    case secondGeneration
    case usbC
    case pro

    var capabilities: PencilCapabilities {
        switch self {
        case .firstGeneration:
            return PencilCapabilities(pressure: true, tilt: true, azimuth: true,
                                      hover: false, doubleTap: false, squeeze: false,
                                      barrelRoll: false, pencilHaptics: false)
        case .secondGeneration:
            return PencilCapabilities(pressure: true, tilt: true, azimuth: true,
                                      hover: true, doubleTap: true, squeeze: false,
                                      barrelRoll: false, pencilHaptics: false)
        case .usbC:
            return PencilCapabilities(pressure: false, tilt: true, azimuth: true,
                                      hover: true, doubleTap: false, squeeze: false,
                                      barrelRoll: false, pencilHaptics: false)
        case .pro:
            return PencilCapabilities(pressure: true, tilt: true, azimuth: true,
                                      hover: true, doubleTap: true, squeeze: true,
                                      barrelRoll: true, pencilHaptics: true)
        }
    }
}

struct PencilCapabilities: Equatable, Sendable {
    var pressure: Bool
    var tilt: Bool
    var azimuth: Bool
    var hover: Bool
    var doubleTap: Bool
    var squeeze: Bool
    var barrelRoll: Bool
    var pencilHaptics: Bool

    /// APIs that this build can safely attach. Actual optional hardware
    /// support is learned from callbacks and sample properties at runtime.
    static var sdkAvailable: PencilCapabilities {
        if #available(iOS 17.5, *) {
            return PencilCapabilities(pressure: true, tilt: true, azimuth: true,
                                      hover: true, doubleTap: true, squeeze: true,
                                      barrelRoll: true, pencilHaptics: true)
        }
        return PencilCapabilities(pressure: true, tilt: true, azimuth: true,
                                  hover: true, doubleTap: true, squeeze: false,
                                  barrelRoll: false, pencilHaptics: false)
    }
}

enum PencilStrokeTool: String, Codable, Equatable, Sendable {
    case pen
    case marker
}

enum PencilDoubleTapSetting: String, CaseIterable, Codable, Sendable {
    case followSystem
    case previousTool
    case eraser
    case palette
    case off
}

enum PencilSqueezeSetting: String, CaseIterable, Codable, Sendable {
    case followSystem
    case toolPalette
    case inkAttributes
    case off
}

enum PencilHoverSetting: String, CaseIterable, Codable, Sendable {
    case followSystem
    case on
    case off
}

struct PencilPreferences: Equatable, Sendable {
    var doubleTap: PencilDoubleTapSetting = .followSystem
    var squeeze: PencilSqueezeSetting = .followSystem
    var hover: PencilHoverSetting = .followSystem

    static let defaults = PencilPreferences()
}

enum PencilPreferredAction: Equatable, Sendable {
    case ignore
    case switchEraser
    case switchPrevious
    case showColorPalette
    case showInkAttributes
    case showContextualPalette
    case runSystemShortcut
    case unknown

    init(_ action: UIPencilPreferredAction) {
        switch action {
        case .ignore: self = .ignore
        case .switchEraser: self = .switchEraser
        case .switchPrevious: self = .switchPrevious
        case .showColorPalette: self = .showColorPalette
        case .showInkAttributes: self = .showInkAttributes
        case .showContextualPalette: self = .showContextualPalette
        case .runSystemShortcut: self = .runSystemShortcut
        @unknown default: self = .unknown
        }
    }
}

enum PencilLogicalAction: Equatable, Sendable {
    case none
    case switchEraser
    case switchPrevious
    case showColorPalette
    case showInkAttributes
    case showToolPalette
    case runSystemShortcut
}

enum PencilActionResolver {
    static func doubleTap(setting: PencilDoubleTapSetting,
                          system: PencilPreferredAction,
                          supported: Bool = true) -> PencilLogicalAction {
        guard supported else { return .none }
        switch setting {
        case .off: return .none
        case .previousTool: return .switchPrevious
        case .eraser: return .switchEraser
        case .palette: return .showToolPalette
        case .followSystem: return map(system)
        }
    }

    static func squeeze(setting: PencilSqueezeSetting,
                        system: PencilPreferredAction,
                        supported: Bool = true) -> PencilLogicalAction {
        guard supported else { return .none }
        switch setting {
        case .off: return .none
        case .toolPalette: return .showToolPalette
        case .inkAttributes: return .showInkAttributes
        case .followSystem: return map(system)
        }
    }

    private static func map(_ preferred: PencilPreferredAction) -> PencilLogicalAction {
        switch preferred {
        case .ignore, .unknown: return .none
        case .switchEraser: return .switchEraser
        case .switchPrevious: return .switchPrevious
        case .showColorPalette: return .showColorPalette
        case .showInkAttributes: return .showInkAttributes
        case .showContextualPalette: return .showToolPalette
        case .runSystemShortcut: return .runSystemShortcut
        }
    }
}

enum PencilSqueezePhase: Sendable { case began, changed, ended, cancelled }

struct PencilPaletteStateMachine: Equatable, Sendable {
    private(set) var isPresented = false
    private(set) var anchor: CGPoint?

    enum Effect: Equatable, Sendable {
        case none
        case present(CGPoint?)
        case update(CGPoint?)
        case dismiss
    }

    mutating func receive(_ phase: PencilSqueezePhase, anchor: CGPoint?) -> Effect {
        switch phase {
        case .began:
            guard !isPresented else { return .none }
            isPresented = true
            self.anchor = anchor
            return .present(anchor)
        case .changed:
            guard isPresented else { return .none }
            if let anchor { self.anchor = anchor }
            return .update(self.anchor)
        case .ended:
            // Ending a squeeze must not create a second presentation. The
            // palette remains until the user chooses an action or dismisses it.
            return .none
        case .cancelled:
            guard isPresented else { return .none }
            isPresented = false
            self.anchor = nil
            return .dismiss
        }
    }

    mutating func dismiss() -> Effect {
        guard isPresented else { return .none }
        isPresented = false
        anchor = nil
        return .dismiss
    }
}

enum PencilPalettePlacement {
    static func origin(anchor: CGPoint?, paletteSize: CGSize, safeBounds: CGRect,
                       spacing: CGFloat = 16) -> CGPoint {
        let fallback = CGPoint(x: safeBounds.midX, y: safeBounds.midY)
        let point = anchor ?? fallback
        var x = point.x + spacing
        var y = point.y - paletteSize.height / 2
        if x + paletteSize.width > safeBounds.maxX { x = point.x - spacing - paletteSize.width }
        if y + paletteSize.height > safeBounds.maxY { y = safeBounds.maxY - paletteSize.height }
        x = min(max(x, safeBounds.minX), max(safeBounds.minX, safeBounds.maxX - paletteSize.width))
        y = min(max(y, safeBounds.minY), max(safeBounds.minY, safeBounds.maxY - paletteSize.height))
        return CGPoint(x: x, y: y)
    }
}

enum PencilHitTarget {
    /// Invisible 36-point diameter around each visually small resize handle.
    static let resizeHandleRadius: CGFloat = 18
}

enum PencilPressureResponse {
    static func normalized(force: CGFloat, maximum: CGFloat, supported: Bool = true) -> CGFloat? {
        guard supported, maximum > 0, force.isFinite, maximum.isFinite else { return nil }
        return min(max(force / maximum, 0), 1)
    }

    static func curved(_ raw: CGFloat) -> CGFloat {
        pow(min(max(raw.isFinite ? raw : 0, 0), 1), 0.72)
    }

    static func smoothed(previous: CGFloat?, sample: CGFloat) -> CGFloat {
        let next = curved(sample)
        guard let previous, previous.isFinite else { return next }
        return previous * 0.68 + next * 0.32
    }

    static func widthMultiplier(forDisplayPressure pressure: CGFloat?) -> CGFloat {
        guard let pressure else { return 1 }
        return 0.68 + curved(pressure) * 0.52
    }

    static func widthMultiplier(for pressure: CGFloat) -> CGFloat {
        widthMultiplier(forDisplayPressure: pressure)
    }
}

enum PencilAngleMath {
    static let fullTurn = CGFloat.pi * 2

    static func normalized(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 0 }
        let value = angle.truncatingRemainder(dividingBy: fullTurn)
        return value < 0 ? value + fullTurn : value
    }

    static func shortestDelta(from start: CGFloat, to end: CGFloat) -> CGFloat {
        var delta = normalized(end) - normalized(start)
        if delta > .pi { delta -= fullTurn }
        if delta < -.pi { delta += fullTurn }
        return delta
    }

    static func interpolated(from start: CGFloat, to end: CGFloat, fraction: CGFloat) -> CGFloat {
        normalized(start + shortestDelta(from: start, to: end) * min(max(fraction, 0), 1))
    }
}

struct PencilNibGeometry: Equatable, Sendable {
    let majorAxis: CGFloat
    let minorAxis: CGFloat
    let orientation: CGFloat

    static func marker(baseWidth: CGFloat, pressure: CGFloat?, altitude: CGFloat?,
                       azimuth: CGFloat?, roll: CGFloat?) -> PencilNibGeometry {
        let pressureScale = PencilPressureResponse.widthMultiplier(forDisplayPressure: pressure)
        let altitude = min(max(altitude ?? (.pi / 2), 0.12), .pi / 2)
        let tilt = 1 - altitude / (.pi / 2)
        let major = max(1, baseWidth * pressureScale * (1 + tilt * 0.22))
        let minor = max(1, baseWidth * 0.34 * (1 - tilt * 0.12))
        return PencilNibGeometry(majorAxis: major, minorAxis: minor,
                                 orientation: PencilAngleMath.normalized(roll ?? azimuth ?? 0))
    }
}

enum PencilStrokeGeometry {
    /// Builds a filled, deterministic path from canonical raw samples. Pressure
    /// smoothing happens here and is intentionally never written back to data.
    static func path(points: [StrokePoint], tool: PencilStrokeTool?, baseWidth: CGFloat) -> CGPath {
        let path = UIBezierPath()
        guard !points.isEmpty else { return path.cgPath }
        var displayPressure: CGFloat?
        var previousPoint: CGPoint?
        var previousRadius: CGFloat = baseWidth / 2
        var previousMarkerNib: PencilNibGeometry?

        func appendMarkerStamp(at point: CGPoint, nib: PencilNibGeometry) {
            let stamp = UIBezierPath(ovalIn: CGRect(
                x: -nib.majorAxis / 2, y: -nib.minorAxis / 2,
                width: nib.majorAxis, height: nib.minorAxis
            ))
            var transform = CGAffineTransform(rotationAngle: nib.orientation)
            transform = transform.concatenating(
                CGAffineTransform(translationX: point.x, y: point.y)
            )
            stamp.apply(transform)
            path.append(stamp)
        }

        for sample in points {
            let point = CGPoint(x: sample.x, y: sample.y)
            if let raw = sample.pressure.map({ CGFloat($0) }) {
                displayPressure = PencilPressureResponse.smoothed(previous: displayPressure, sample: raw)
            } else {
                displayPressure = nil
            }

            if tool == .marker {
                let nib = PencilNibGeometry.marker(
                    baseWidth: baseWidth,
                    pressure: displayPressure,
                    altitude: sample.altitude.map { CGFloat($0) },
                    azimuth: sample.azimuth.map { CGFloat($0) },
                    roll: sample.roll.map { CGFloat($0) }
                )
                if let previousPoint, let previousMarkerNib {
                    let distance = hypot(point.x - previousPoint.x, point.y - previousPoint.y)
                    let spacing = max(1, min(previousMarkerNib.minorAxis, nib.minorAxis) * 0.45)
                    let steps = max(1, Int(ceil(distance / spacing)))
                    for index in 1...steps {
                        let fraction = CGFloat(index) / CGFloat(steps)
                        appendMarkerStamp(
                            at: CGPoint(x: previousPoint.x + (point.x - previousPoint.x) * fraction,
                                        y: previousPoint.y + (point.y - previousPoint.y) * fraction),
                            nib: PencilNibGeometry(
                                majorAxis: previousMarkerNib.majorAxis
                                    + (nib.majorAxis - previousMarkerNib.majorAxis) * fraction,
                                minorAxis: previousMarkerNib.minorAxis
                                    + (nib.minorAxis - previousMarkerNib.minorAxis) * fraction,
                                orientation: PencilAngleMath.interpolated(
                                    from: previousMarkerNib.orientation,
                                    to: nib.orientation, fraction: fraction
                                )
                            )
                        )
                    }
                } else {
                    appendMarkerStamp(at: point, nib: nib)
                }
                previousMarkerNib = nib
            } else {
                let radius = max(0.5, baseWidth * PencilPressureResponse.widthMultiplier(
                    forDisplayPressure: displayPressure
                ) / 2)
                path.append(UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                        width: radius * 2, height: radius * 2)))
                if let previousPoint, previousPoint != point {
                    let dx = point.x - previousPoint.x
                    let dy = point.y - previousPoint.y
                    let length = max(0.0001, hypot(dx, dy))
                    let nx = -dy / length
                    let ny = dx / length
                    let connector = UIBezierPath()
                    connector.move(to: CGPoint(x: previousPoint.x + nx * previousRadius,
                                               y: previousPoint.y + ny * previousRadius))
                    connector.addLine(to: CGPoint(x: point.x + nx * radius, y: point.y + ny * radius))
                    connector.addLine(to: CGPoint(x: point.x - nx * radius, y: point.y - ny * radius))
                    connector.addLine(to: CGPoint(x: previousPoint.x - nx * previousRadius,
                                                   y: previousPoint.y - ny * previousRadius))
                    connector.close()
                    path.append(connector)
                }
                previousRadius = radius
            }
            previousPoint = point
        }
        return path.cgPath
    }
}

/// Stable identity for a sample whose estimated properties may be corrected.
struct PencilSampleIdentity: Hashable, Sendable {
    let estimationUpdateIndex: Int?
    let timestampMicros: Int64

    init(estimationUpdateIndex: Int?, timestamp: TimeInterval) {
        self.estimationUpdateIndex = estimationUpdateIndex
        timestampMicros = Int64((timestamp * 1_000_000).rounded())
    }
}

struct PencilStrokeAccumulator: Sendable {
    private(set) var confirmed: [StrokePoint] = []
    private(set) var predicted: [StrokePoint] = []
    private var confirmedIndices: [PencilSampleIdentity: Int] = [:]

    mutating func appendConfirmed(_ samples: [StrokePoint]) {
        predicted.removeAll(keepingCapacity: true)
        for sample in samples {
            let identity = sample.sampleIdentity
            if let index = confirmedIndices[identity] {
                confirmed[index] = sample
            } else {
                confirmedIndices[identity] = confirmed.count
                confirmed.append(sample)
            }
        }
    }

    mutating func replaceEstimated(_ samples: [StrokePoint]) {
        for sample in samples {
            guard let updateIndex = sample.estimationUpdateIndex else { continue }
            if let index = confirmed.firstIndex(where: { $0.estimationUpdateIndex == updateIndex }) {
                let oldIdentity = confirmed[index].sampleIdentity
                confirmedIndices.removeValue(forKey: oldIdentity)
                confirmed[index] = sample
                confirmedIndices[sample.sampleIdentity] = index
            }
        }
    }

    mutating func setPredicted(_ samples: [StrokePoint]) { predicted = samples }

    var livePoints: [StrokePoint] { confirmed + predicted }
    var canonicalPoints: [StrokePoint] { confirmed }

    mutating func reset() {
        confirmed.removeAll(keepingCapacity: true)
        predicted.removeAll(keepingCapacity: true)
        confirmedIndices.removeAll(keepingCapacity: true)
    }
}

/// Applies UIKit's late estimated-property callbacks to an already committed
/// stroke without creating a second canonical point or a second stroke ID.
/// Callers persist the returned value as an in-place correction.
enum PencilStrokeCorrection {
    static func applying(_ corrections: [StrokePoint], to stroke: UserStroke) -> UserStroke? {
        guard !corrections.isEmpty else { return nil }
        var accumulator = PencilStrokeAccumulator()
        accumulator.appendConfirmed(stroke.points)
        accumulator.replaceEstimated(corrections)
        guard accumulator.canonicalPoints != stroke.points else { return nil }
        var corrected = stroke
        corrected.points = accumulator.canonicalPoints
        return corrected
    }
}

/// The single policy used by both the isolated-board canvas and the class
/// workspace canvas. UIKit adapters classify a contact once, then route the
/// complete sequence to exactly one owner from begin through end/cancel.
enum CanvasInputContact: String, CaseIterable, Sendable {
    case pencil
    case finger
    case primaryPointer
    case navigationPointer
    case palm
}

enum CanvasInputOwner: String, Equatable, Sendable {
    case none
    case navigation
    case stroke
    case eraser
    case lasso
    case selection
}

enum CanvasInputArbitrationPolicy {
    static func owner(tool: CanvasTool,
                      contact: CanvasInputContact,
                      contactCount: Int = 1,
                      drawsWithFinger: Bool) -> CanvasInputOwner {
        if contact == .palm { return .none }
        if contact == .navigationPointer { return .navigation }
        if contact == .finger, contactCount >= 2 { return .navigation }

        switch tool {
        case .navigation:
            return .navigation
        case .pen, .highlighter:
            if contact == .finger, !drawsWithFinger { return .none }
            return contact == .pencil || contact == .finger || contact == .primaryPointer
                ? .stroke : .none
        case .objectEraser:
            return contact == .pencil || contact == .finger || contact == .primaryPointer
                ? .eraser : .none
        case .lasso:
            return contact == .pencil || contact == .finger || contact == .primaryPointer
                ? .lasso : .none
        case .select:
            return contact == .pencil || contact == .finger || contact == .primaryPointer
                ? .selection : .none
        }
    }

    /// A one-finger pan exists only while Hand is selected. Every editing
    /// tool reserves the first direct contact for editing (or an intentional
    /// no-op when Draw with Finger is disabled); navigation requires two.
    static func minimumDirectNavigationTouches(tool: CanvasTool) -> Int {
        tool == .navigation ? 1 : 2
    }
}

enum CanvasGestureHitTestPolicy {
    /// Canvas recognizers must not steal taps from visible controls embedded
    /// above the drawing surface. Stop at the canvas root so unrelated
    /// controls elsewhere in the hierarchy do not influence routing.
    static func allowsCanvasGesture(from hitView: UIView?, canvasRoot: UIView) -> Bool {
        var candidate = hitView
        while let view = candidate {
            if view is UIControl { return false }
            if view === canvasRoot { break }
            candidate = view.superview
        }
        return true
    }
}

enum PencilFeedbackRequest: Equatable, Sendable {
    case paletteActivation(CGPoint)
    case toolSelection(CGPoint?)
    case alignment(CGPoint)
    case action(CGPoint?)
}

@MainActor
protocol PencilFeedbackProviding: AnyObject {
    func request(_ feedback: PencilFeedbackRequest)
}

@MainActor
final class UIKitPencilFeedbackProvider: PencilFeedbackProviding {
    private weak var view: UIView?
    private var selection: UISelectionFeedbackGenerator?
    private var impact: UIImpactFeedbackGenerator?
    private var canvas: AnyObject?

    init(view: UIView) {
        self.view = view
        if #available(iOS 17.5, *) {
            selection = UISelectionFeedbackGenerator(view: view)
            impact = UIImpactFeedbackGenerator(style: .light, view: view)
            canvas = UICanvasFeedbackGenerator(view: view)
        }
    }

    func request(_ feedback: PencilFeedbackRequest) {
        guard #available(iOS 17.5, *), let view else { return }
        #if DEBUG
        PencilHardwareValidationStore.shared.detect(.haptics)
        #endif
        switch feedback {
        case .paletteActivation(let point):
            impact?.prepare(); impact?.impactOccurred(at: point)
        case .toolSelection(let point), .action(let point):
            selection?.prepare()
            if let point { selection?.selectionChanged(at: point) }
            else { selection?.selectionChanged() }
        case .alignment(let point):
            let generator = canvas as? UICanvasFeedbackGenerator
            generator?.prepare(); generator?.alignmentOccurred(at: point)
        }
        _ = view // Keep the feedback engine scoped to the live canvas view.
    }
}

extension StrokePoint {
    var sampleIdentity: PencilSampleIdentity {
        PencilSampleIdentity(estimationUpdateIndex: estimationUpdateIndex, timestamp: timestamp ?? 0)
    }
}

struct PencilSettingsControls: View {
    @Binding var doubleTapRaw: String
    @Binding var squeezeRaw: String
    @Binding var hoverRaw: String

    var body: some View {
        Section("Apple Pencil") {
            Picker("Double Tap", selection: $doubleTapRaw) {
                Text("Follow System").tag(PencilDoubleTapSetting.followSystem.rawValue)
                Text("Previous Tool").tag(PencilDoubleTapSetting.previousTool.rawValue)
                Text("Eraser").tag(PencilDoubleTapSetting.eraser.rawValue)
                Text("Palette").tag(PencilDoubleTapSetting.palette.rawValue)
                Text("Off").tag(PencilDoubleTapSetting.off.rawValue)
            }
            if #available(iOS 17.5, *) {
                Picker("Squeeze", selection: $squeezeRaw) {
                    Text("Follow System").tag(PencilSqueezeSetting.followSystem.rawValue)
                    Text("Tool Palette").tag(PencilSqueezeSetting.toolPalette.rawValue)
                    Text("Ink Attributes").tag(PencilSqueezeSetting.inkAttributes.rawValue)
                    Text("Off").tag(PencilSqueezeSetting.off.rawValue)
                }
            }
            Picker("Hover", selection: $hoverRaw) {
                Text("Follow System").tag(PencilHoverSetting.followSystem.rawValue)
                Text("On").tag(PencilHoverSetting.on.rawValue)
                Text("Off").tag(PencilHoverSetting.off.rawValue)
            }
        }
    }
}

#if DEBUG
enum PencilHardwareFeature: String, CaseIterable, Identifiable, Sendable {
    case draw = "DRAW"
    case pressure = "PRESSURE"
    case tilt = "TILT"
    case hover = "HOVER"
    case doubleTap = "DOUBLE TAP"
    case squeeze = "SQUEEZE"
    case barrelRoll = "BARREL ROLL"
    case haptics = "HAPTICS"
    case palm = "PALM"
    case fingerCoexistence = "FINGER COEXISTENCE"
    var id: String { rawValue }
}

enum PencilHardwareStatus: String, CaseIterable, Sendable {
    case notTested = "NOT TESTED"
    case detected = "DETECTED"
    case pass = "PASS"
    case fail = "FAIL"
}

@MainActor
final class PencilHardwareValidationStore: ObservableObject {
    static let shared = PencilHardwareValidationStore()
    @Published private(set) var statuses: [PencilHardwareFeature: PencilHardwareStatus] = [:]

    private init() {}

    func status(for feature: PencilHardwareFeature) -> PencilHardwareStatus {
        statuses[feature] ?? .notTested
    }

    func detect(_ feature: PencilHardwareFeature) {
        guard status(for: feature) == .notTested else { return }
        statuses[feature] = .detected
    }

    func set(_ status: PencilHardwareStatus, for feature: PencilHardwareFeature) {
        statuses[feature] = status
    }

    func reset() { statuses.removeAll() }
}

struct PencilHardwareValidationView: View {
    @ObservedObject private var store = PencilHardwareValidationStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Run these checks on the target iPad with Apple Pencil Pro. DETECTED means UIKit delivered a relevant signal; only a human should mark PASS after observing the complete behavior.")
                        .font(.callout)
                }
                ForEach(PencilHardwareFeature.allCases) { feature in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.rawValue).font(.body.monospaced().weight(.semibold))
                            Text(store.status(for: feature).rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(color(store.status(for: feature)))
                        }
                        Spacer()
                        Button("Pass") { store.set(.pass, for: feature) }
                            .buttonStyle(.bordered).tint(.green)
                        Button("Fail") { store.set(.fail, for: feature) }
                            .buttonStyle(.bordered).tint(.red)
                    }
                }
            }
            .navigationTitle("Apple Pencil Validation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Reset") { store.reset() } }
            }
        }
    }

    private func color(_ status: PencilHardwareStatus) -> Color {
        switch status {
        case .notTested: return .secondary
        case .detected: return .orange
        case .pass: return .green
        case .fail: return .red
        }
    }
}
#endif
