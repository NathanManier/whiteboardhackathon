import CoreGraphics
import Foundation
import UIKit

enum GraphRepresentationState: String, Equatable, Sendable {
    case unloaded
    case proxy
    case promoting
    case interactive
    case demoting
    case failed
}

enum GraphRendererError: LocalizedError, Equatable {
    case unavailable
    case invalidExpression(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Interactive graph isn’t available right now."
        case .invalidExpression:
            return "This equation could not be graphed."
        case .provider:
            return "Interactive graph isn’t available right now."
        }
    }
}

/// Provider implementations are presentation details. Canonical expressions,
/// viewport, settings, frame, and provenance always remain in `GraphObject`.
@MainActor
protocol GraphRendererProvider: AnyObject {
    var identifier: String { get }
    var isAvailable: Bool { get }
    var view: UIView { get }

    func mount(graph: GraphObject, in frame: CGRect) async throws
    func update(graph: GraphObject) async throws
    func setInteractive(_ interactive: Bool) async throws
    func readViewport() async -> GraphViewport?
    func captureSnapshot() async throws -> UIImage
    func unmount()
}

/// Owns the deliberately tiny expensive-provider budget. Activating a second
/// graph first demotes and releases the previous provider.
@MainActor
final class GraphProviderCoordinator {
    private(set) var activeGraphID: String?
    private(set) var activeProvider: GraphRendererProvider?

    var activeProviderCount: Int { activeProvider == nil ? 0 : 1 }

    func promote(graph: GraphObject, provider: GraphRendererProvider,
                 frame: CGRect) async throws {
        if activeGraphID != graph.id || activeProvider !== provider {
            activeProvider?.unmount()
            activeProvider = nil
            activeGraphID = nil
        }
        guard provider.isAvailable else { throw GraphRendererError.unavailable }
        try await provider.mount(graph: graph, in: frame)
        try await provider.setInteractive(true)
        activeProvider = provider
        activeGraphID = graph.id
    }

    func demote() async -> GraphViewport? {
        guard let provider = activeProvider else { return nil }
        let viewport = await provider.readViewport()
        try? await provider.setInteractive(false)
        provider.unmount()
        activeProvider = nil
        activeGraphID = nil
        return viewport
    }

    func handleMemoryWarning() {
        activeProvider?.unmount()
        activeProvider = nil
        activeGraphID = nil
        GraphProxyCache.shared.removeAll()
    }
}

enum GraphFallbackPalette {
    static let colors = [
        UIColor(red: 0.11, green: 0.36, blue: 0.82, alpha: 1),
        UIColor(red: 0.84, green: 0.20, blue: 0.24, alpha: 1),
        UIColor(red: 0.12, green: 0.58, blue: 0.37, alpha: 1),
        UIColor(red: 0.56, green: 0.28, blue: 0.76, alpha: 1),
        UIColor(red: 0.91, green: 0.48, blue: 0.10, alpha: 1),
        UIColor(red: 0.10, green: 0.58, blue: 0.64, alpha: 1),
    ]
}

/// Cheap provider-independent graph presentation used for passive canvas
/// objects, offline display, far zoom, provider failure, and export snapshots.
enum GraphFallbackRenderer {
    static let minimumSize = CGSize(width: 180, height: 140)

    /// Reusable raster proxy for high-frequency canvas scene refreshes. The
    /// canonical graph remains vector/semantic data; this is derived display
    /// state keyed by account, board, graph semantics, viewport, and size.
    @MainActor
    static func cachedProxyLayer(for graph: GraphObject, contentsScale: CGFloat,
                                 appearance: UIUserInterfaceStyle) -> CALayer {
        let frame = graph.frame.cgRect
        let image = GraphProxyCache.shared.nativeImage(
            for: graph, size: frame.size, scale: contentsScale, appearance: appearance
        )
        let layer = CALayer()
        layer.frame = frame
        layer.name = "graph:\(graph.id):cached-proxy"
        layer.contents = image.cgImage
        layer.contentsScale = image.scale
        layer.contentsGravity = .resize
        layer.masksToBounds = true
        layer.cornerRadius = 10
        return layer
    }

    static func layer(for graph: GraphObject, contentsScale: CGFloat) -> CALayer {
        let frame = CGRect(x: graph.frame.x, y: graph.frame.y,
                           width: graph.frame.width, height: graph.frame.height)
        let container = CALayer()
        container.frame = frame
        container.name = "graph:\(graph.id):proxy"
        container.backgroundColor = UIColor.secondarySystemBackground.cgColor
        container.borderColor = UIColor.separator.withAlphaComponent(0.42).cgColor
        container.borderWidth = 1 / max(contentsScale, 1)
        container.cornerRadius = 10
        container.masksToBounds = true
        container.contentsScale = contentsScale

        let plotFrame = CGRect(origin: .zero, size: frame.size)
        appendGridAndAxes(to: container, graph: graph, frame: plotFrame,
                          contentsScale: contentsScale)
        appendExpressions(to: container, graph: graph, frame: plotFrame,
                          contentsScale: contentsScale)
        return container
    }

    static func image(for graph: GraphObject, scale: CGFloat = UIScreen.main.scale) -> UIImage {
        let size = CGSize(width: max(graph.frame.width, minimumSize.width),
                          height: max(graph.frame.height, minimumSize.height))
        let proxyGraph = graph.replacing(
            frame: GraphFrame(x: 0, y: 0,
                              width: Double(size.width), height: Double(size.height))
        )
        let layer = layer(for: proxyGraph, contentsScale: scale)
        layer.frame = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            layer.render(in: context.cgContext)
        }
    }

    private static func appendGridAndAxes(to container: CALayer, graph: GraphObject,
                                          frame: CGRect, contentsScale: CGFloat) {
        let viewport = graph.viewport
        guard viewport.isValid else { return }
        let gridPath = UIBezierPath()
        if graph.settings.showGrid {
            let xStep = GraphTickPolicy.step(for: viewport.xMax - viewport.xMin)
            let yStep = GraphTickPolicy.step(for: viewport.yMax - viewport.yMin)
            GraphTickPolicy.values(min: viewport.xMin, max: viewport.xMax, step: xStep)
                .forEach { x in
                    let p = map(x: x, y: viewport.yMin, viewport: viewport, frame: frame)
                    gridPath.move(to: CGPoint(x: p.x, y: frame.minY))
                    gridPath.addLine(to: CGPoint(x: p.x, y: frame.maxY))
                }
            GraphTickPolicy.values(min: viewport.yMin, max: viewport.yMax, step: yStep)
                .forEach { y in
                    let p = map(x: viewport.xMin, y: y, viewport: viewport, frame: frame)
                    gridPath.move(to: CGPoint(x: frame.minX, y: p.y))
                    gridPath.addLine(to: CGPoint(x: frame.maxX, y: p.y))
                }
        }
        let grid = CAShapeLayer()
        grid.frame = frame
        grid.path = gridPath.cgPath
        grid.fillColor = UIColor.clear.cgColor
        grid.strokeColor = UIColor.separator.withAlphaComponent(0.22).cgColor
        grid.lineWidth = 1 / max(contentsScale, 1)
        grid.contentsScale = contentsScale
        container.addSublayer(grid)

        let axesPath = UIBezierPath()
        if graph.settings.showYAxis, viewport.xMin <= 0, viewport.xMax >= 0 {
            let x = map(x: 0, y: viewport.yMin, viewport: viewport, frame: frame).x
            axesPath.move(to: CGPoint(x: x, y: frame.minY))
            axesPath.addLine(to: CGPoint(x: x, y: frame.maxY))
        }
        if graph.settings.showXAxis, viewport.yMin <= 0, viewport.yMax >= 0 {
            let y = map(x: viewport.xMin, y: 0, viewport: viewport, frame: frame).y
            axesPath.move(to: CGPoint(x: frame.minX, y: y))
            axesPath.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        let axes = CAShapeLayer()
        axes.frame = frame
        axes.path = axesPath.cgPath
        axes.fillColor = UIColor.clear.cgColor
        axes.strokeColor = UIColor.label.withAlphaComponent(0.64).cgColor
        axes.lineWidth = 1.25 / max(contentsScale, 1)
        axes.contentsScale = contentsScale
        container.addSublayer(axes)
    }

    private static func appendExpressions(to container: CALayer, graph: GraphObject,
                                          frame: CGRect, contentsScale: CGFloat) {
        var unsupported: [String] = []
        for (index, expression) in graph.expressions.filter(\.visible).enumerated() {
            let color = expression.displayStyle?.color.map { UIColor(svgHex: $0) }
                ?? GraphFallbackPalette.colors[index % GraphFallbackPalette.colors.count]
            let opacity = CGFloat(expression.displayStyle?.opacity ?? 1)
            let lineWidth = CGFloat(expression.displayStyle?.lineWidth ?? 2.25)
            if let fillPath = GraphFallbackSampler.inequalityFillPath(
                for: expression, viewport: graph.viewport, frame: frame,
                angleMode: graph.settings.angleMode
            ), !fillPath.isEmpty {
                let fill = CAShapeLayer()
                fill.frame = frame
                fill.path = fillPath.cgPath
                fill.fillColor = color.withAlphaComponent(0.13 * opacity).cgColor
                fill.strokeColor = UIColor.clear.cgColor
                fill.contentsScale = contentsScale
                container.addSublayer(fill)
            }
            let shape = CAShapeLayer()
            shape.frame = frame
            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = color.withAlphaComponent(opacity).cgColor
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.contentsScale = contentsScale
            let path = GraphFallbackSampler.path(for: expression, viewport: graph.viewport,
                                                 frame: frame, angleMode: graph.settings.angleMode)
            shape.path = path.cgPath
            if GraphEquationClassifier.isStrictInequality(expression.latex) {
                shape.lineDashPattern = [6, 4]
            }
            container.addSublayer(shape)
            if path.isEmpty { unsupported.append(expression.latex) }
        }
        if !unsupported.isEmpty {
            let label = CATextLayer()
            label.frame = frame.insetBy(dx: 10, dy: 10)
            label.alignmentMode = .left
            label.foregroundColor = UIColor.secondaryLabel.cgColor
            label.fontSize = 11
            label.contentsScale = contentsScale
            label.isWrapped = true
            label.string = "Equation preview requires interactive graphing\n"
                + unsupported.prefix(2).joined(separator: "\n")
            container.addSublayer(label)
        }
    }

    private static func map(x: Double, y: Double, viewport: GraphViewport,
                            frame: CGRect) -> CGPoint {
        GraphFallbackSampler.map(x: x, y: y, viewport: viewport, frame: frame)
    }
}

enum GraphTickPolicy {
    static func step(for range: Double) -> Double {
        guard range.isFinite, range > 0 else { return 1 }
        let raw = range / 10
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let nice: Double
        if normalized <= 1 { nice = 1 }
        else if normalized <= 2 { nice = 2 }
        else if normalized <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * magnitude
    }

    static func values(min: Double, max: Double, step: Double) -> [Double] {
        guard min.isFinite, max.isFinite, step.isFinite, step > 0, max > min else { return [] }
        var value = ceil(min / step) * step
        var result: [Double] = []
        while value <= max, result.count < 100 {
            result.append(value)
            value += step
        }
        return result
    }
}

enum GraphFallbackSampler {
    static func path(for expression: GraphExpression, viewport: GraphViewport,
                     frame: CGRect, angleMode: String? = "radians") -> UIBezierPath {
        let path = UIBezierPath()
        guard viewport.isValid, frame.width > 0, frame.height > 0 else { return path }

        switch expression.type.rawValue {
        case GraphExpressionType.verticalLine.rawValue:
            guard let x = GraphEquationClassifier.constant(after: "x", in: expression.latex),
                  x >= viewport.xMin, x <= viewport.xMax else { return path }
            let a = map(x: x, y: viewport.yMin, viewport: viewport, frame: frame)
            let b = map(x: x, y: viewport.yMax, viewport: viewport, frame: frame)
            path.move(to: a); path.addLine(to: b)
        case GraphExpressionType.point.rawValue:
            guard let point = GraphEquationClassifier.point(in: expression.latex) else { return path }
            let center = map(x: point.x, y: point.y, viewport: viewport, frame: frame)
            path.append(UIBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4,
                                                    width: 8, height: 8)))
        case GraphExpressionType.implicitEquation.rawValue:
            appendSimpleImplicit(expression.latex, to: path, viewport: viewport, frame: frame)
        case GraphExpressionType.inequality.rawValue:
            if let relation = GraphEquationClassifier.relation(in: expression.latex),
               relation.left == "x",
               let x = GraphEquationClassifier.constantExpression(relation.right),
               x >= viewport.xMin, x <= viewport.xMax {
                let a = map(x: x, y: viewport.yMin, viewport: viewport, frame: frame)
                let b = map(x: x, y: viewport.yMax, viewport: viewport, frame: frame)
                path.move(to: a); path.addLine(to: b)
            } else {
                appendExplicitSegments(expression.latex, to: path, viewport: viewport,
                                       frame: frame, angleMode: angleMode)
            }
        default:
            appendExplicitSegments(expression.latex, to: path, viewport: viewport,
                                   frame: frame, angleMode: angleMode)
        }
        return path
    }

    static func inequalityFillPath(for expression: GraphExpression,
                                   viewport: GraphViewport, frame: CGRect,
                                   angleMode: String? = "radians") -> UIBezierPath? {
        guard expression.type == .inequality,
              let relation = GraphEquationClassifier.relation(in: expression.latex) else {
            return nil
        }
        let path = UIBezierPath()
        if relation.left == "x",
           let x = GraphEquationClassifier.constantExpression(relation.right) {
            let boundary = map(x: x, y: 0, viewport: viewport, frame: frame).x
            let fillsGreater = relation.operation == ">" || relation.operation == ">="
            let minX = fillsGreater ? boundary : frame.minX
            let maxX = fillsGreater ? frame.maxX : boundary
            guard maxX > minX else { return nil }
            path.append(UIBezierPath(rect: CGRect(x: minX, y: frame.minY,
                                                  width: maxX - minX, height: frame.height)))
            return path
        }
        guard relation.left == "y" else { return nil }
        let segments = segments(for: expression.latex, viewport: viewport,
                                sampleCount: max(128, min(1_024, Int(frame.width * 1.5))),
                                angleMode: angleMode)
        guard segments.count == 1, let segment = segments.first,
              let first = segment.first, let last = segment.last else { return nil }
        let fillsGreater = relation.operation == ">" || relation.operation == ">="
        path.move(to: map(x: first.x, y: first.y, viewport: viewport, frame: frame))
        for point in segment.dropFirst() {
            path.addLine(to: map(x: point.x, y: point.y, viewport: viewport, frame: frame))
        }
        path.addLine(to: CGPoint(x: map(x: last.x, y: last.y, viewport: viewport,
                                       frame: frame).x,
                                y: fillsGreater ? frame.minY : frame.maxY))
        path.addLine(to: CGPoint(x: map(x: first.x, y: first.y, viewport: viewport,
                                       frame: frame).x,
                                y: fillsGreater ? frame.minY : frame.maxY))
        path.close()
        return path
    }

    /// Returns math-space segments. Discontinuities are separate arrays so
    /// `1/x` and tangent asymptotes can never acquire a connecting stroke.
    static func segments(for latex: String, viewport: GraphViewport,
                         sampleCount: Int = 512,
                         angleMode: String? = "radians") -> [[CGPoint]] {
        guard viewport.isValid,
              let source = GraphEquationClassifier.explicitRightHandSide(latex),
              let expression = try? SafeGraphExpression(source: source,
                                                        angleMode: angleMode) else { return [] }
        let count = max(16, min(sampleCount, 4_096))
        let dx = (viewport.xMax - viewport.xMin) / Double(count - 1)
        let discontinuity = max((viewport.yMax - viewport.yMin) * 1.5, 1)
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var previousY: Double?
        for index in 0..<count {
            let x = viewport.xMin + Double(index) * dx
            let y = expression.evaluate(x: x)
            let visibleMargin = (viewport.yMax - viewport.yMin) * 4
            let valid = y.isFinite
                && y >= viewport.yMin - visibleMargin
                && y <= viewport.yMax + visibleMargin
                && (previousY == nil || abs(y - previousY!) <= discontinuity)
            if valid {
                current.append(CGPoint(x: x, y: y))
            } else if !current.isEmpty {
                if current.count > 1 { result.append(current) }
                current = []
            }
            previousY = y.isFinite ? y : nil
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    private static func appendExplicitSegments(_ latex: String, to path: UIBezierPath,
                                               viewport: GraphViewport, frame: CGRect,
                                               angleMode: String?) {
        for segment in segments(for: latex, viewport: viewport,
                                sampleCount: max(128, min(1_024, Int(frame.width * 1.5))),
                                angleMode: angleMode) {
            guard let first = segment.first else { continue }
            path.move(to: map(x: first.x, y: first.y, viewport: viewport, frame: frame))
            for point in segment.dropFirst() {
                path.addLine(to: map(x: point.x, y: point.y,
                                     viewport: viewport, frame: frame))
            }
        }
    }

    static func map(x: Double, y: Double, viewport: GraphViewport,
                    frame: CGRect) -> CGPoint {
        let nx = (x - viewport.xMin) / (viewport.xMax - viewport.xMin)
        let ny = (y - viewport.yMin) / (viewport.yMax - viewport.yMin)
        return CGPoint(x: frame.minX + CGFloat(nx) * frame.width,
                       y: frame.maxY - CGFloat(ny) * frame.height)
    }

    private static func appendSimpleImplicit(_ latex: String, to path: UIBezierPath,
                                             viewport: GraphViewport, frame: CGRect) {
        // Useful offline support for the common classroom circle form. More
        // general implicit relations remain available through the provider.
        guard let radius = GraphEquationClassifier.originCircleRadius(in: latex), radius > 0 else {
            return
        }
        let rect = CGRect(
            x: map(x: -radius, y: 0, viewport: viewport, frame: frame).x,
            y: map(x: 0, y: radius, viewport: viewport, frame: frame).y,
            width: abs(map(x: radius, y: 0, viewport: viewport, frame: frame).x
                       - map(x: -radius, y: 0, viewport: viewport, frame: frame).x),
            height: abs(map(x: 0, y: -radius, viewport: viewport, frame: frame).y
                        - map(x: 0, y: radius, viewport: viewport, frame: frame).y)
        )
        path.append(UIBezierPath(ovalIn: rect))
    }
}

enum GraphEquationClassifier {
    struct Relation: Equatable {
        let left: String
        let operation: String
        let right: String
    }

    static func relation(in latex: String) -> Relation? {
        let normalized = GraphLatexNormalizer.normalize(latex)
        for operation in [">=", "<=", "=", ">", "<"] {
            guard let range = normalized.range(of: operation) else { continue }
            let left = String(normalized[..<range.lowerBound])
            let right = String(normalized[range.upperBound...])
            guard !left.isEmpty, !right.isEmpty else { return nil }
            return Relation(left: left, operation: operation, right: right)
        }
        return nil
    }

    static func isStrictInequality(_ latex: String) -> Bool {
        guard let relation = relation(in: latex) else { return false }
        return relation.operation == ">" || relation.operation == "<"
    }

    static func constantExpression(_ source: String) -> Double? {
        guard let expression = try? SafeGraphExpression(source: source),
              !expression.usesVariable else { return nil }
        let value = expression.evaluate(x: 0)
        return value.isFinite ? value : nil
    }

    static func explicitRightHandSide(_ latex: String) -> String? {
        guard let relation = relation(in: latex),
              relation.left == "y" || relation.left == "f(x)"
                || relation.left == "g(x)" || relation.left == "h(x)" else { return nil }
        return relation.right
    }

    static func constant(after variable: String, in latex: String) -> Double? {
        let normalized = GraphLatexNormalizer.normalize(latex)
        guard let equal = normalized.firstIndex(of: "=") else { return nil }
        let left = String(normalized[..<equal])
        let right = String(normalized[normalized.index(after: equal)...])
        guard left == variable,
              let expression = try? SafeGraphExpression(source: right),
              !expression.usesVariable else { return nil }
        let result = expression.evaluate(x: 0)
        return result.isFinite ? result : nil
    }

    static func point(in latex: String) -> CGPoint? {
        let normalized = GraphLatexNormalizer.normalize(latex)
        guard normalized.first == "(", normalized.last == ")" else { return nil }
        let body = normalized.dropFirst().dropLast()
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let xExpression = try? SafeGraphExpression(source: String(parts[0])),
              let yExpression = try? SafeGraphExpression(source: String(parts[1])),
              !xExpression.usesVariable, !yExpression.usesVariable else { return nil }
        let x = xExpression.evaluate(x: 0), y = yExpression.evaluate(x: 0)
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    static func originCircleRadius(in latex: String) -> Double? {
        let value = GraphLatexNormalizer.normalize(latex)
        let prefixes = ["x^2+y^2=", "y^2+x^2="]
        guard let prefix = prefixes.first(where: value.hasPrefix) else { return nil }
        let rhs = String(value.dropFirst(prefix.count))
        guard let expression = try? SafeGraphExpression(source: rhs),
              !expression.usesVariable else { return nil }
        let squared = expression.evaluate(x: 0)
        guard squared.isFinite, squared > 0 else { return nil }
        return sqrt(squared)
    }
}

enum GraphLatexNormalizer {
    static func normalize(_ input: String) -> String {
        var value = rewriteFractionsAndRoots(input)
        let replacements: [(String, String)] = [
            ("$", ""), ("\\left", ""), ("\\right", ""),
            ("\\cdot", "*"), ("\\times", "*"), ("×", "*"),
            ("−", "-"), ("–", "-"), ("≥", ">="), ("≤", "<="),
            ("\\geq", ">="), ("\\ge", ">="), ("\\leq", "<="), ("\\le", "<="),
            ("\\pi", "pi"), ("π", "pi"), ("²", "^2"), ("³", "^3"),
            ("\\sin", "sin"), ("\\cos", "cos"), ("\\tan", "tan"),
            ("\\log", "log"), ("\\ln", "ln"), ("\\exp", "exp"),
            ("\\abs", "abs")
        ]
        for replacement in replacements {
            value = value.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
        return value
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .filter { !$0.isWhitespace }
            .lowercased()
    }

    private static func rewriteFractionsAndRoots(_ input: String) -> String {
        let characters = Array(input)
        var index = 0
        var output = ""

        func group(at start: Int) -> (String, Int)? {
            guard start < characters.count, characters[start] == "{" else { return nil }
            var depth = 0
            for cursor in start..<characters.count {
                if characters[cursor] == "{" { depth += 1 }
                if characters[cursor] == "}" {
                    depth -= 1
                    if depth == 0 {
                        return (String(characters[(start + 1)..<cursor]), cursor + 1)
                    }
                }
            }
            return nil
        }

        while index < characters.count {
            let remainder = String(characters[index...])
            if remainder.hasPrefix("\\frac"),
               let numerator = group(at: index + 5),
               let denominator = group(at: numerator.1) {
                output += "(" + rewriteFractionsAndRoots(numerator.0) + ")/("
                    + rewriteFractionsAndRoots(denominator.0) + ")"
                index = denominator.1
                continue
            }
            if remainder.hasPrefix("\\sqrt"), let radicand = group(at: index + 5) {
                output += "sqrt(" + rewriteFractionsAndRoots(radicand.0) + ")"
                index = radicand.1
                continue
            }
            output.append(characters[index])
            index += 1
        }
        return output
    }
}

/// Small recursive-descent parser for the native fallback. It accepts only a
/// fixed mathematical grammar and never executes arbitrary strings.
struct SafeGraphExpression {
    private static let maximumSourceLength = 2_000
    private static let maximumTokens = 512
    private static let maximumNodes = 256
    private static let maximumDepth = 32
    private static let maximumMagnitude = 1.0e100
    private static let maximumExponentMagnitude = 128.0

    private indirect enum Node {
        case number(Double)
        case variable
        case negated(Node)
        case binary(Character, Node, Node)
        case function(String, Node)

        func evaluate(x: Double, usesDegrees: Bool) -> Double {
            switch self {
            case .number(let value): return value
            case .variable: return x
            case .negated(let value): return -value.evaluate(x: x, usesDegrees: usesDegrees)
            case .binary(let operation, let lhs, let rhs):
                let a = lhs.evaluate(x: x, usesDegrees: usesDegrees)
                let b = rhs.evaluate(x: x, usesDegrees: usesDegrees)
                switch operation {
                case "+": return a + b
                case "-": return a - b
                case "*": return a * b
                case "/": return b == 0 ? .nan : a / b
                case "^":
                    guard abs(b) <= SafeGraphExpression.maximumExponentMagnitude else {
                        return .nan
                    }
                    return Foundation.pow(a, b)
                default: return .nan
                }
            case .function(let name, let value):
                let argument = value.evaluate(x: x, usesDegrees: usesDegrees)
                let trigArgument = usesDegrees ? argument * .pi / 180 : argument
                switch name {
                case "sin": return Foundation.sin(trigArgument)
                case "cos": return Foundation.cos(trigArgument)
                case "tan": return Foundation.tan(trigArgument)
                case "sqrt": return argument < 0 ? .nan : Foundation.sqrt(argument)
                case "abs": return Swift.abs(argument)
                case "exp": return Foundation.exp(argument)
                case "log": return argument <= 0 ? .nan : Foundation.log10(argument)
                case "ln": return argument <= 0 ? .nan : Foundation.log(argument)
                default: return .nan
                }
            }
        }

        var usesVariable: Bool {
            switch self {
            case .number: return false
            case .variable: return true
            case .negated(let value), .function(_, let value): return value.usesVariable
            case .binary(_, let lhs, let rhs): return lhs.usesVariable || rhs.usesVariable
            }
        }
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(Character)
        case end
    }

    private let root: Node
    private let usesDegrees: Bool

    var usesVariable: Bool { root.usesVariable }

    init(source: String, angleMode: String? = "radians") throws {
        let normalized = GraphLatexNormalizer.normalize(source)
        guard normalized.count <= Self.maximumSourceLength else {
            throw GraphRendererError.invalidExpression("expression too long")
        }
        var parser = try Parser(source: normalized)
        root = try parser.parse()
        usesDegrees = angleMode == "degrees"
    }

    func evaluate(x: Double) -> Double {
        guard x.isFinite, abs(x) <= 10_000_000 else { return .nan }
        let result = root.evaluate(x: x, usesDegrees: usesDegrees)
        guard result.isFinite, abs(result) <= Self.maximumMagnitude else { return .nan }
        return result
    }

    private struct Parser {
        private static let functions = Set(["sin", "cos", "tan", "sqrt", "abs", "exp", "log", "ln"])
        private var tokens: [Token]
        private var index = 0
        private var nodeCount = 0

        init(source: String) throws {
            tokens = try Self.tokenize(source)
        }

        mutating func parse() throws -> Node {
            let result = try expression(depth: 0)
            guard current == .end else { throw GraphRendererError.invalidExpression("trailing token") }
            return result
        }

        private var current: Token { tokens[min(index, tokens.count - 1)] }

        private mutating func consume() { index = min(index + 1, tokens.count - 1) }

        private mutating func expression(depth: Int) throws -> Node {
            try validate(depth: depth)
            var result = try term(depth: depth + 1)
            while case .symbol(let symbol) = current, symbol == "+" || symbol == "-" {
                consume()
                result = try make(.binary(symbol, result, try term(depth: depth + 1)))
            }
            return result
        }

        private mutating func term(depth: Int) throws -> Node {
            try validate(depth: depth)
            var result = try unary(depth: depth + 1)
            while true {
                if case .symbol(let symbol) = current, symbol == "*" || symbol == "/" {
                    consume()
                    result = try make(.binary(symbol, result, try unary(depth: depth + 1)))
                } else if startsPrimary(current) {
                    // Conventional implicit multiplication: 2x, 3sin(x),
                    // and (x+1)(x-1).
                    result = try make(.binary("*", result, try unary(depth: depth + 1)))
                } else {
                    return result
                }
            }
        }

        private mutating func power(depth: Int) throws -> Node {
            try validate(depth: depth)
            var result = try primary(depth: depth + 1)
            if current == .symbol("^") {
                consume()
                result = try make(.binary("^", result, try unary(depth: depth + 1)))
            }
            return result
        }

        private mutating func unary(depth: Int) throws -> Node {
            try validate(depth: depth)
            if current == .symbol("+") {
                consume()
                return try unary(depth: depth + 1)
            }
            if current == .symbol("-") {
                consume()
                return try make(.negated(try unary(depth: depth + 1)))
            }
            return try power(depth: depth + 1)
        }

        private mutating func primary(depth: Int) throws -> Node {
            try validate(depth: depth)
            switch current {
            case .number(let value): consume(); return try make(.number(value))
            case .identifier(let name):
                consume()
                if name == "x" { return try make(.variable) }
                if name == "pi" { return try make(.number(.pi)) }
                if name == "e" { return try make(.number(M_E)) }
                guard Self.functions.contains(name) else {
                    throw GraphRendererError.invalidExpression("identifier")
                }
                let argument: Node
                if current == .symbol("(") {
                    consume(); argument = try expression(depth: depth + 1)
                    guard current == .symbol(")") else {
                        throw GraphRendererError.invalidExpression("parenthesis")
                    }
                    consume()
                } else {
                    argument = try unary(depth: depth + 1)
                }
                return try make(.function(name, argument))
            case .symbol("("):
                consume()
                let result = try expression(depth: depth + 1)
                guard current == .symbol(")") else {
                    throw GraphRendererError.invalidExpression("parenthesis")
                }
                consume()
                return result
            default:
                throw GraphRendererError.invalidExpression("operand")
            }
        }

        private func validate(depth: Int) throws {
            guard depth <= SafeGraphExpression.maximumDepth else {
                throw GraphRendererError.invalidExpression("expression nesting")
            }
        }

        private mutating func make(_ node: Node) throws -> Node {
            nodeCount += 1
            guard nodeCount <= SafeGraphExpression.maximumNodes else {
                throw GraphRendererError.invalidExpression("expression complexity")
            }
            return node
        }

        private func startsPrimary(_ token: Token) -> Bool {
            switch token {
            case .number, .identifier, .symbol("("): return true
            default: return false
            }
        }

        private static func tokenize(_ source: String) throws -> [Token] {
            let characters = Array(source)
            var index = 0
            var result: [Token] = []
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace { index += 1; continue }
                if character.isNumber || character == "." {
                    let start = index
                    var decimalCount = 0
                    while index < characters.count,
                          characters[index].isNumber || characters[index] == "." {
                        if characters[index] == "." { decimalCount += 1 }
                        index += 1
                    }
                    guard decimalCount <= 1,
                          let number = Double(String(characters[start..<index])), number.isFinite else {
                        throw GraphRendererError.invalidExpression("number")
                    }
                    result.append(.number(number)); continue
                }
                if character.isLetter {
                    let start = index
                    while index < characters.count, characters[index].isLetter { index += 1 }
                    result.append(.identifier(String(characters[start..<index]))); continue
                }
                if "+-*/^(),".contains(character) {
                    result.append(.symbol(character)); index += 1; continue
                }
                throw GraphRendererError.invalidExpression("unsupported token")
            }
            result.append(.end)
            guard result.count <= SafeGraphExpression.maximumTokens else {
                throw GraphRendererError.invalidExpression("too many tokens")
            }
            return result
        }
    }
}
