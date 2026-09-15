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
    case switchLasso
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
        // V-Board owns double tap as a direct, predictable selection gesture.
        // Keep the legacy preference arguments decodable so older settings do
        // not break launch, but do not let them change the product contract.
        _ = setting
        _ = system
        return .switchLasso
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
    private(set) var highlightedIndex = 0
    private var lastRoll: CGFloat?
    private var accumulatedRoll: CGFloat = 0
    private var itemOffset = 0
    private var itemCount = 4
    private var initialSectorIndex = 0

    enum Effect: Equatable, Sendable {
        case none
        case present(CGPoint?, highlightedIndex: Int)
        case update(CGPoint?, highlightedIndex: Int, selectionChanged: Bool)
        case commit(highlightedIndex: Int)
        case dismiss
    }

    /// A completed squeeze toggles the palette. The second squeeze commits the
    /// currently highlighted tool and closes it, so roll-only navigation has a
    /// complete, discoverable interaction without requiring a sustained hold.
    /// Roll is already in VBoard screen-angle space: positive is clockwise.
    mutating func toggle(anchor: CGPoint?, roll: CGFloat?, initialIndex: Int,
                         itemCount requestedItemCount: Int = 4) -> Effect {
        if isPresented {
            let committed = highlightedIndex
            clear()
            return .commit(highlightedIndex: committed)
        }
        isPresented = true
        self.anchor = anchor
        itemCount = max(1, requestedItemCount)
        initialSectorIndex = Self.wrapped(initialIndex, count: itemCount)
        highlightedIndex = initialSectorIndex
        lastRoll = roll
        accumulatedRoll = 0
        itemOffset = 0
        return .present(anchor, highlightedIndex: highlightedIndex)
    }

    /// The menu is an arc, not a four-way 360-degree wheel. Consequently each
    /// relative roll step is intentionally much smaller than a quadrant.
    mutating func update(anchor: CGPoint?, roll: CGFloat?,
                         stepAngle: CGFloat = 22 * .pi / 180,
                         hysteresis: CGFloat = 5 * .pi / 180) -> Effect {
        guard isPresented else { return .none }
        if let anchor { self.anchor = anchor }
        var changed = false
        if let roll {
            if let lastRoll {
                accumulatedRoll += PencilAngleMath.shortestDelta(from: lastRoll, to: roll)
            }
            self.lastRoll = roll
            let step = max(1 * .pi / 180, stepAngle)
            let threshold = step / 2 + max(0, hysteresis)
            while accumulatedRoll - CGFloat(itemOffset) * step > threshold {
                itemOffset += 1
                changed = true
            }
            while accumulatedRoll - CGFloat(itemOffset) * step < -threshold {
                itemOffset -= 1
                changed = true
            }
            highlightedIndex = Self.wrapped(initialSectorIndex + itemOffset,
                                            count: itemCount)
        }
        return .update(self.anchor, highlightedIndex: highlightedIndex,
                       selectionChanged: changed)
    }

    mutating func dismiss() -> Effect {
        guard isPresented else { return .none }
        clear()
        return .dismiss
    }

    private mutating func clear() {
        isPresented = false
        anchor = nil
        lastRoll = nil
        accumulatedRoll = 0
        itemOffset = 0
        initialSectorIndex = 0
    }

    private static func wrapped(_ index: Int, count: Int) -> Int {
        let remainder = index % count
        return remainder < 0 ? remainder + count : remainder
    }
}

enum PencilRadialPaletteModel {
    static let tools: [CanvasTool] = [.pen, .highlighter, .objectEraser, .lasso]

    static func index(for tool: CanvasTool) -> Int {
        tools.firstIndex(of: tool) ?? 0
    }

    static func tool(at index: Int) -> CanvasTool {
        let count = tools.count
        let wrapped = ((index % count) + count) % count
        return tools[wrapped]
    }
}

enum PencilArcPaletteLayout {
    /// An upper offset arc keeps the center and Pencil-tip area empty while
    /// moving primary tools away from the writing hand.
    static let startAngle = CGFloat(200) * .pi / 180
    static let sweepAngle = CGFloat(140) * .pi / 180

    static func angle(for index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return startAngle + sweepAngle / 2 }
        return startAngle + sweepAngle * CGFloat(index) / CGFloat(count - 1)
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

    static func center(anchor: CGPoint?, radius: CGFloat, safeBounds: CGRect,
                       spacing: CGFloat = 8) -> CGPoint {
        let point = anchor ?? CGPoint(x: safeBounds.midX, y: safeBounds.midY)
        let inset = radius + spacing
        let minimumX = safeBounds.minX + inset
        let maximumX = safeBounds.maxX - inset
        let minimumY = safeBounds.minY + inset
        let maximumY = safeBounds.maxY - inset
        return CGPoint(
            x: minimumX <= maximumX ? min(max(point.x, minimumX), maximumX) : safeBounds.midX,
            y: minimumY <= maximumY ? min(max(point.y, minimumY), maximumY) : safeBounds.midY
        )
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
        pow(min(max(raw.isFinite ? raw : 0, 0), 1), 0.85)
    }

    static func smoothed(previous: CGFloat?, sample: CGFloat) -> CGFloat {
        let next = min(max(sample.isFinite ? sample : 0, 0), 1)
        guard let previous, previous.isFinite else { return next }
        // Favor the current hardware sample so a light-to-firm transition is
        // visible immediately. This remains derived display state; the raw
        // normalized force stays unchanged in StrokePoint.
        return previous * 0.45 + next * 0.55
    }

    static func widthMultiplier(forDisplayPressure pressure: CGFloat?) -> CGFloat {
        guard let pressure else { return 1 }
        // Physical Pencil Pro samples clustered around 0.10 for a light hand
        // and reached roughly 0.87 when firm. This range keeps normal writing
        // controlled while making those endpoints visibly distinct.
        return 0.45 + curved(pressure) * 1.40
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

/// V-Board's one visual-angle convention: zero points right and positive angles
/// rotate clockwise on the physical display. UIKit view coordinates are Y-down,
/// so a positive CGAffineTransform rotation already follows that convention.
///
/// Physical Pencil Pro measurements on the target iPad show UITouch/hover
/// `rollAngle` decreasing for a clockwise barrel rotation. Convert that relative
/// raw value exactly once before any visual consumer uses it.
enum PencilScreenAngle {
    static func roll(fromAppleRaw raw: CGFloat) -> CGFloat {
        PencilAngleMath.normalized(-raw)
    }

    /// Apple documents Pencil Pro roll as relative to the angle at wake. The
    /// view-relative azimuth supplies the absolute nib heading; converted roll
    /// adds the barrel delta. Unsupported Pencils report roll == 0, naturally
    /// leaving azimuth as the fallback.
    static func markerOrientation(azimuth: CGFloat?, appleRoll: CGFloat?) -> CGFloat {
        PencilAngleMath.normalized((azimuth ?? 0) + roll(fromAppleRaw: appleRoll ?? 0))
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
                                 orientation: PencilScreenAngle.markerOrientation(
                                    azimuth: azimuth, appleRoll: roll
                                 ))
    }
}

enum PencilStrokeGeometry {
    private struct DisplaySample {
        let point: CGPoint
        let penRadius: CGFloat
        let markerNib: PencilNibGeometry?
    }

    private struct RibbonSection {
        let point: CGPoint
        let tangent: CGVector
        let left: CGPoint
        let right: CGPoint
        let capExtent: CGFloat
    }

    /// Builds one filled, deterministic outline from canonical raw samples.
    /// Pressure smoothing and nib-angle conversion are presentation-only and
    /// are intentionally never written back to the canonical points.
    static func path(points: [StrokePoint], tool: PencilStrokeTool?, baseWidth: CGFloat) -> CGPath {
        guard !points.isEmpty else { return UIBezierPath().cgPath }
        var displayPressure: CGFloat?
        var displaySamples: [DisplaySample] = []
        displaySamples.reserveCapacity(points.count)
        for sample in points {
            let point = CGPoint(x: sample.x, y: sample.y)
            if let raw = sample.pressure.map({ CGFloat($0) }) {
                displayPressure = PencilPressureResponse.smoothed(previous: displayPressure, sample: raw)
            } else {
                displayPressure = nil
            }

            let penRadius = max(0.5, baseWidth * PencilPressureResponse.widthMultiplier(
                forDisplayPressure: displayPressure
            ) / 2)
            let markerNib = tool == .marker ? PencilNibGeometry.marker(
                baseWidth: baseWidth,
                pressure: displayPressure,
                altitude: sample.altitude.map { CGFloat($0) },
                azimuth: sample.azimuth.map { CGFloat($0) },
                roll: sample.roll.map { CGFloat($0) }
            ) : nil
            let rendered = DisplaySample(point: point, penRadius: penRadius,
                                         markerNib: markerNib)
            if let last = displaySamples.last,
               hypot(last.point.x - point.x, last.point.y - point.y) < 0.001 {
                // Keep the newest pressure/pose at a stationary coordinate
                // without creating a zero-length ribbon section.
                displaySamples[displaySamples.count - 1] = rendered
            } else {
                displaySamples.append(rendered)
            }
        }

        guard displaySamples.count > 1 else {
            let sample = displaySamples[0]
            if let nib = sample.markerNib {
                let footprint = UIBezierPath(ovalIn: CGRect(
                    x: -nib.majorAxis / 2, y: -nib.minorAxis / 2,
                    width: nib.majorAxis, height: nib.minorAxis
                ))
                var transform = CGAffineTransform(rotationAngle: nib.orientation)
                transform = transform.concatenating(
                    CGAffineTransform(translationX: sample.point.x, y: sample.point.y)
                )
                footprint.apply(transform)
                return footprint.cgPath
            }
            let radius = sample.penRadius
            return UIBezierPath(ovalIn: CGRect(x: sample.point.x - radius,
                                               y: sample.point.y - radius,
                                               width: radius * 2,
                                               height: radius * 2)).cgPath
        }

        let tangents = displaySamples.indices.map { index -> CGVector in
            if index == 0 {
                return unitVector(from: displaySamples[0].point,
                                  to: displaySamples[1].point)
            }
            if index == displaySamples.count - 1 {
                return unitVector(from: displaySamples[index - 1].point,
                                  to: displaySamples[index].point)
            }
            let incoming = unitVector(from: displaySamples[index - 1].point,
                                      to: displaySamples[index].point)
            let outgoing = unitVector(from: displaySamples[index].point,
                                      to: displaySamples[index + 1].point)
            let sum = CGVector(dx: incoming.dx + outgoing.dx,
                               dy: incoming.dy + outgoing.dy)
            let length = hypot(sum.dx, sum.dy)
            // A reversal has no stable miter direction. Use the outgoing
            // segment instead, which bounds the join and cannot create a spike.
            return length > 0.2
                ? CGVector(dx: sum.dx / length, dy: sum.dy / length)
                : outgoing
        }

        let sections = zip(displaySamples, tangents).map { sample, tangent -> RibbonSection in
            let normal = CGVector(dx: -tangent.dy, dy: tangent.dx)
            let sideExtent: CGFloat
            let capExtent: CGFloat
            if let nib = sample.markerNib {
                sideExtent = ellipseExtent(nib: nib, direction: normal)
                capExtent = ellipseExtent(nib: nib, direction: tangent)
            } else {
                sideExtent = sample.penRadius
                capExtent = sample.penRadius
            }
            return RibbonSection(
                point: sample.point,
                tangent: tangent,
                left: CGPoint(x: sample.point.x + normal.dx * sideExtent,
                              y: sample.point.y + normal.dy * sideExtent),
                right: CGPoint(x: sample.point.x - normal.dx * sideExtent,
                               y: sample.point.y - normal.dy * sideExtent),
                capExtent: capExtent
            )
        }

        let outline = UIBezierPath()
        outline.move(to: sections[0].left)
        for section in sections.dropFirst() { outline.addLine(to: section.left) }

        let end = sections[sections.count - 1]
        let endControl = end.capExtent * 4 / 3
        outline.addCurve(
            to: end.right,
            controlPoint1: CGPoint(x: end.left.x + end.tangent.dx * endControl,
                                   y: end.left.y + end.tangent.dy * endControl),
            controlPoint2: CGPoint(x: end.right.x + end.tangent.dx * endControl,
                                   y: end.right.y + end.tangent.dy * endControl)
        )
        for section in sections.dropLast().reversed() { outline.addLine(to: section.right) }

        let start = sections[0]
        let startControl = start.capExtent * 4 / 3
        outline.addCurve(
            to: start.left,
            controlPoint1: CGPoint(x: start.right.x - start.tangent.dx * startControl,
                                   y: start.right.y - start.tangent.dy * startControl),
            controlPoint2: CGPoint(x: start.left.x - start.tangent.dx * startControl,
                                   y: start.left.y - start.tangent.dy * startControl)
        )
        outline.close()

        // A narrow, non-zero-winding spine lies wholly inside the intended
        // ribbon and guarantees that every canonical centerline sample is
        // inked even if an extreme reversal makes the variable-width outline
        // self-intersect. It does not affect the visible outside edge.
        let centerline = UIBezierPath()
        centerline.move(to: displaySamples[0].point)
        for sample in displaySamples.dropFirst() { centerline.addLine(to: sample.point) }
        let minimumDiameter = displaySamples.reduce(CGFloat.greatestFiniteMagnitude) {
            partial, sample in
            let diameter = sample.markerNib?.minorAxis ?? sample.penRadius * 2
            return min(partial, diameter)
        }
        let spine = centerline.cgPath.copy(
            strokingWithWidth: max(1, minimumDiameter * 0.62),
            lineCap: .round, lineJoin: .round, miterLimit: 2
        )
        outline.append(UIBezierPath(cgPath: spine))
        outline.usesEvenOddFillRule = false
        return outline.cgPath
    }

    private static func unitVector(from start: CGPoint, to end: CGPoint) -> CGVector {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.000_001)
        return CGVector(dx: dx / length, dy: dy / length)
    }

    /// Support radius of a rotated ellipse in `direction`. This lets a chisel
    /// footprint become a continuous swept ribbon instead of overlapping
    /// translucent/stamped ovals.
    private static func ellipseExtent(nib: PencilNibGeometry,
                                      direction: CGVector) -> CGFloat {
        let major = CGVector(dx: cos(nib.orientation), dy: sin(nib.orientation))
        let minor = CGVector(dx: -major.dy, dy: major.dx)
        let majorProjection = direction.dx * major.dx + direction.dy * major.dy
        let minorProjection = direction.dx * minor.dx + direction.dy * minor.dy
        let a = nib.majorAxis / 2
        let b = nib.minorAxis / 2
        return max(0.5, sqrt(pow(a * majorProjection, 2)
                             + pow(b * minorProjection, 2)))
    }
}

enum PencilEraserFootprint {
    /// The eraser preview is intentionally screen-stable. Hit testing converts
    /// this radius back into world units through the authoritative camera.
    static let screenRadius: CGFloat = 14

    static func worldRadius(cameraScale: CGFloat) -> CGFloat {
        screenRadius / max(cameraScale, 0.001)
    }
}

/// Exact/near-exact geometry used after spatial-index broad phase. It tests a
/// swept circular eraser so fast motion cannot tunnel across thin visible ink.
enum SweptEraserGeometry {
    struct LineSegment: Equatable, Sendable { let start: CGPoint; let end: CGPoint }

    static func bounds(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -radius, dy: -radius)
    }

    static func intersects(polyline: [CGPoint], renderedWidth: CGFloat,
                           from start: CGPoint, to end: CGPoint,
                           eraserRadius: CGFloat) -> Bool {
        guard let first = polyline.first else { return false }
        let radius = max(0, eraserRadius) + max(0, renderedWidth) / 2
        if polyline.count == 1 { return pointSegmentDistance(first, start, end) <= radius }
        return zip(polyline, polyline.dropFirst()).contains {
            segmentDistance(start, end, $0.0, $0.1) <= radius
        }
    }

    static func intersects(rect: CGRect, from start: CGPoint, to end: CGPoint,
                           eraserRadius: CGFloat) -> Bool {
        guard !rect.isNull, !rect.isEmpty else { return false }
        let expanded = rect.insetBy(dx: -eraserRadius, dy: -eraserRadius)
        if expanded.contains(start) || expanded.contains(end) { return true }
        let corners = [CGPoint(x: expanded.minX, y: expanded.minY),
                       CGPoint(x: expanded.maxX, y: expanded.minY),
                       CGPoint(x: expanded.maxX, y: expanded.maxY),
                       CGPoint(x: expanded.minX, y: expanded.maxY)]
        return zip(corners, Array(corners.dropFirst()) + [corners[0]]).contains {
            segmentsIntersect(start, end, $0.0, $0.1)
        }
    }

    static func intersects(path: CGPath, fillRule: CAShapeLayerFillRule = .nonZero,
                           from start: CGPoint, to end: CGPoint,
                           eraserRadius: CGFloat) -> Bool {
        let rule: CGPathFillRule = fillRule == .evenOdd ? .evenOdd : .winding
        if path.contains(start, using: rule) || path.contains(end, using: rule) { return true }
        return flattenedSegments(path).contains {
            segmentDistance(start, end, $0.start, $0.end) <= eraserRadius
        }
    }

    static func flattenedSegments(_ path: CGPath, curveSteps: Int = 12) -> [LineSegment] {
        var result: [LineSegment] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        func append(_ point: CGPoint) {
            if point != current { result.append(LineSegment(start: current, end: point)) }
            current = point
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]; subpathStart = current
            case .addLineToPoint:
                append(element.points[0])
            case .addQuadCurveToPoint:
                let origin = current, control = element.points[0], end = element.points[1]
                for step in 1...max(2, curveSteps) {
                    let t = CGFloat(step) / CGFloat(max(2, curveSteps)), u = 1 - t
                    append(CGPoint(x: u * u * origin.x + 2 * u * t * control.x + t * t * end.x,
                                   y: u * u * origin.y + 2 * u * t * control.y + t * t * end.y))
                }
            case .addCurveToPoint:
                let origin = current, c1 = element.points[0], c2 = element.points[1]
                let end = element.points[2]
                for step in 1...max(3, curveSteps) {
                    let t = CGFloat(step) / CGFloat(max(3, curveSteps)), u = 1 - t
                    append(CGPoint(
                        x: u * u * u * origin.x + 3 * u * u * t * c1.x
                            + 3 * u * t * t * c2.x + t * t * t * end.x,
                        y: u * u * u * origin.y + 3 * u * u * t * c1.y
                            + 3 * u * t * t * c2.y + t * t * t * end.y
                    ))
                }
            case .closeSubpath:
                append(subpathStart)
            @unknown default:
                break
            }
        }
        return result
    }

    static func pointSegmentDistance(_ point: CGPoint, _ start: CGPoint,
                                     _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.000_001 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy)
                             / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    static func segmentDistance(_ a: CGPoint, _ b: CGPoint,
                                _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(pointSegmentDistance(a, c, d), pointSegmentDistance(b, c, d),
                   pointSegmentDistance(c, a, b), pointSegmentDistance(d, a, b))
    }

    private static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint,
                                          _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d)
        let cdA = cross(c, d, a), cdB = cross(c, d, b)
        let epsilon: CGFloat = 0.000_01
        if abs(abC) <= epsilon && pointSegmentDistance(c, a, b) <= epsilon { return true }
        if abs(abD) <= epsilon && pointSegmentDistance(d, a, b) <= epsilon { return true }
        if abs(cdA) <= epsilon && pointSegmentDistance(a, c, d) <= epsilon { return true }
        if abs(cdB) <= epsilon && pointSegmentDistance(b, c, d) <= epsilon { return true }
        return (abC > 0) != (abD > 0) && (cdA > 0) != (cdB > 0)
    }
}

enum CanvasObjectEraserHitTest {
    static func intersects(_ object: CanvasObject, from start: CGPoint, to end: CGPoint,
                           eraserRadius: CGFloat) -> Bool {
        let translation = object.translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
        let scaleX = object.scaleX ?? 1, scaleY = object.scaleY ?? 1
        let transformed = (object.points ?? []).map {
            StrokePoint(x: $0.x * scaleX + translation.x,
                        y: $0.y * scaleY + translation.y,
                        pressure: $0.pressure, altitude: $0.altitude,
                        azimuth: $0.azimuth, roll: $0.roll,
                        timestamp: $0.timestamp,
                        estimationUpdateIndex: $0.estimationUpdateIndex)
        }
        if !transformed.isEmpty {
            if let tool = object.pencilTool {
                let ink = PencilStrokeGeometry.path(
                    points: transformed, tool: tool,
                    baseWidth: CGFloat((object.width ?? 4) * sqrt(abs(scaleX * scaleY)))
                )
                return SweptEraserGeometry.intersects(path: ink, from: start, to: end,
                                                      eraserRadius: eraserRadius)
            }
            return SweptEraserGeometry.intersects(
                polyline: transformed.map { CGPoint(x: $0.x, y: $0.y) },
                renderedWidth: CGFloat((object.width ?? 4) * sqrt(abs(scaleX * scaleY))),
                from: start, to: end, eraserRadius: eraserRadius
            )
        }
        if object.type == "path", let definition = object.d,
           let parsed = try? SVGPathParser.cachedPath(from: definition) {
            var transform = CGAffineTransform.identity
                .translatedBy(x: CGFloat(translation.x), y: CGFloat(translation.y))
                .scaledBy(x: CGFloat(scaleX), y: CGFloat(scaleY))
            if let path = parsed.copy(using: &transform) {
                return SweptEraserGeometry.intersects(
                    path: path, fillRule: .evenOdd, from: start, to: end,
                    eraserRadius: eraserRadius
                )
            }
        }
        return SweptEraserGeometry.intersects(
            rect: BoardHitTestPolicy.bounds(of: object), from: start, to: end,
            eraserRadius: eraserRadius
        )
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
        // A direct finger is always canvas navigation. Tool choice never
        // changes that ownership, and a finger never creates or erases ink.
        if contact == .finger { return .navigation }
        // Mouse/trackpad uses conventional object-or-canvas behavior. The
        // canvas resolves this owner against a world-space object hit: click
        // selects an object, while an empty drag pans.
        if contact == .primaryPointer { return .selection }

        switch tool.migratedForCurrentInputModel {
        case .navigation, .select:
            assertionFailure("Legacy tools must be migrated before arbitration")
            return .none
        case .pen, .highlighter:
            return contact == .pencil ? .stroke : .none
        case .objectEraser:
            return contact == .pencil ? .eraser : .none
        case .lasso:
            return contact == .pencil ? .lasso : .none
        }
    }

    /// One direct finger always pans, independent of the selected Pencil tool.
    static func minimumDirectNavigationTouches(tool: CanvasTool) -> Int {
        1
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

/// Presentation-only object-erasure bookkeeping. Hits are exposed as a fresh
/// set for immediate hiding, while commit returns the complete gesture as one
/// canonical mutation/undo unit. Cancellation returns that same complete set
/// so callers can restore every transiently hidden representation.
struct ContinuousEraseTransaction<ID: Hashable> {
    private(set) var erasedIDs = Set<ID>()
    private(set) var isActive = false

    mutating func begin() {
        erasedIDs.removeAll(keepingCapacity: true)
        isActive = true
    }

    @discardableResult
    mutating func register(_ hits: Set<ID>) -> Set<ID> {
        guard isActive else { return [] }
        let fresh = hits.subtracting(erasedIDs)
        erasedIDs.formUnion(fresh)
        return fresh
    }

    mutating func commit() -> Set<ID> {
        let committed = erasedIDs
        erasedIDs.removeAll(keepingCapacity: true)
        isActive = false
        return committed
    }

    mutating func cancel() -> Set<ID> {
        let restored = erasedIDs
        erasedIDs.removeAll(keepingCapacity: true)
        isActive = false
        return restored
    }
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
            LabeledContent("Double Tap", value: "Lasso")
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
