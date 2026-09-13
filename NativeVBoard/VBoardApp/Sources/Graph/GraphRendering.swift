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

enum GraphPromotionStage: String, Equatable, Sendable {
    case idle
    case checkingConfiguration = "checking_configuration"
    case providerCreated = "provider_created"
    case webViewCreated = "webview_created"
    case pageLoadStarted = "page_load_started"
    case pageLoadCommitted = "page_load_committed"
    case pageLoadFinished = "page_load_finished"
    case javaScriptBootStarted = "javascript_boot_started"
    case desmosScriptReady = "desmos_script_ready"
    case calculatorCreated = "calculator_created"
    case providerReady = "provider_ready"
    case expressionsApplied = "expressions_applied"
    case viewportApplied = "viewport_applied"
    case activating
    case ready
    case failed

    var diagnosticEventName: String {
        switch self {
        case .idle: return "GRAPH PROMOTION IDLE"
        case .checkingConfiguration: return "GRAPH CONFIGURATION CHECK"
        case .providerCreated: return "GRAPH PROVIDER CREATE"
        case .webViewCreated: return "GRAPH WEBVIEW CREATED"
        case .pageLoadStarted: return "GRAPH PAGE LOAD START"
        case .pageLoadCommitted: return "GRAPH PAGE LOAD COMMITTED"
        case .pageLoadFinished: return "GRAPH PAGE LOAD FINISHED"
        case .javaScriptBootStarted: return "GRAPH JS BOOT START"
        case .desmosScriptReady: return "GRAPH DESMOS SCRIPT READY"
        case .calculatorCreated: return "GRAPH CALCULATOR CREATED"
        case .providerReady: return "GRAPH PROVIDER READY CALLBACK"
        case .expressionsApplied: return "GRAPH EXPRESSIONS APPLIED"
        case .viewportApplied: return "GRAPH VIEWPORT APPLIED"
        case .activating: return "GRAPH ACTIVATION START"
        case .ready: return "GRAPH PROMOTION READY"
        case .failed: return "GRAPH PROMOTION FAILED"
        }
    }
}

/// Optional lifecycle reporting implemented by expensive providers. It keeps
/// provider-specific WebKit/JavaScript stages out of the canonical GraphObject
/// and gives the single session owner enough evidence to diagnose a bounded
/// failure without logging equations or credentials.
@MainActor
protocol GraphProviderLifecycleReporting: AnyObject {
    var lifecycleEventHandler: ((GraphPromotionStage) -> Void)? { get set }
}

struct GraphProviderDeadlines: Equatable, Sendable {
    let transitionNanoseconds: UInt64
    let preemptionNanoseconds: UInt64
    let mountNanoseconds: UInt64
    let updateNanoseconds: UInt64
    let activationNanoseconds: UInt64

    static let standard = GraphProviderDeadlines(
        transitionNanoseconds: 2_000_000_000,
        preemptionNanoseconds: 1_500_000_000,
        mountNanoseconds: 8_000_000_000,
        updateNanoseconds: 3_000_000_000,
        activationNanoseconds: 3_000_000_000
    )
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

/// Third-party provider calls are never allowed to own V-Board lifecycle
/// progress indefinitely. The operation itself is unstructured deliberately:
/// cancellation or the deadline resumes the caller immediately even if a web
/// provider ignores Task cancellation. A late completion is discarded by the
/// single-resolution gate.
@MainActor
enum GraphProviderOperationDeadline {
    static func run(
        before timeoutNanoseconds: UInt64,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let outcome: Result<Void, Error>? = await value(
            before: timeoutNanoseconds
        ) {
            do {
                try await operation()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        guard let outcome else {
            if Task.isCancelled { throw CancellationError() }
            throw GraphRendererError.provider("provider_timeout")
        }
        try outcome.get()
    }

    static func value<Value>(
        before timeoutNanoseconds: UInt64,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value? {
        let race = GraphProviderDeadlineRace<Value>()
        return await withTaskCancellationHandler {
            await race.run(before: timeoutNanoseconds, operation: operation)
        } onCancel: {
            Task { @MainActor in race.cancel() }
        }
    }
}

@MainActor
private final class GraphProviderDeadlineRace<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(
        before timeoutNanoseconds: UInt64,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            operationTask = Task { @MainActor [weak self] in
                let value = await operation()
                self?.resolve(value)
            }
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: max(timeoutNanoseconds, 1))
                guard !Task.isCancelled else { return }
                self?.resolve(nil)
            }
        }
    }

    func cancel() { resolve(nil) }

    private func resolve(_ value: Value?) {
        guard let continuation else { return }
        self.continuation = nil
        if value == nil {
            operationTask?.cancel()
        } else {
            timeoutTask?.cancel()
        }
        operationTask = nil
        timeoutTask = nil
        continuation.resume(returning: value)
    }
}

/// Owns the deliberately tiny expensive-provider budget. Activating a second
/// graph first demotes and releases the previous provider.
@MainActor
final class GraphProviderCoordinator {
    typealias PreemptionHandler = @MainActor () async -> Void

    private(set) var activeGraphID: String?
    private(set) var activeProvider: GraphRendererProvider?
    private var activePreemptionHandler: PreemptionHandler?
    private var transitionIsOwned = false
    private struct TransitionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }
    private var transitionWaiters: [TransitionWaiter] = []
    private let deadlines: GraphProviderDeadlines

    init(deadlines: GraphProviderDeadlines = .standard) {
        self.deadlines = deadlines
    }

    var activeProviderCount: Int { activeProvider == nil ? 0 : 1 }

    func promote(graph: GraphObject, provider: GraphRendererProvider,
                 frame: CGRect,
                 onPreempt: PreemptionHandler? = nil,
                 onStage: ((GraphPromotionStage) -> Void)? = nil) async throws {
        try await acquireTransition()
        defer { releaseTransition() }
        try Task.checkCancellation()
        if activeGraphID != graph.id || activeProvider !== provider {
            let previousProvider = activeProvider
            let previousPreemptionHandler = activePreemptionHandler
            activeProvider = nil
            activeGraphID = nil
            activePreemptionHandler = nil
            if let previousPreemptionHandler {
                let completed = await GraphProviderOperationDeadline.value(
                    before: deadlines.preemptionNanoseconds
                ) {
                    await previousPreemptionHandler()
                    return true
                } == true
                if !completed { previousProvider?.unmount() }
            } else {
                previousProvider?.unmount()
            }
        }
        try Task.checkCancellation()
        guard provider.isAvailable else { throw GraphRendererError.unavailable }
        // Reserve the single expensive-provider slot before entering any
        // third-party async mount/activation call. If that call ignores
        // cancellation, the session's preemption handler still represents the
        // physical provider until bounded demotion has unmounted it; another
        // graph cannot slip into the budget during that handoff.
        activeProvider = provider
        activeGraphID = graph.id
        activePreemptionHandler = onPreempt
        do {
            try await GraphProviderOperationDeadline.run(
                before: deadlines.mountNanoseconds
            ) {
                try await provider.mount(graph: graph, in: frame)
            }
            onStage?(.providerReady)
            try Task.checkCancellation()
            try await GraphProviderOperationDeadline.run(
                before: deadlines.updateNanoseconds
            ) {
                try await provider.update(graph: graph)
            }
            onStage?(.expressionsApplied)
            onStage?(.viewportApplied)
            try Task.checkCancellation()
            onStage?(.activating)
            try await GraphProviderOperationDeadline.run(
                before: deadlines.activationNanoseconds
            ) {
                try await provider.setInteractive(true)
            }
            try Task.checkCancellation()
        } catch {
            // Release the logical single-provider slot immediately. The owning
            // session removes/unmounts the concrete view exactly once; any
            // cancellation-ignoring operation may finish later but no longer
            // has authority to become interactive.
            if activeProvider === provider {
                activeProvider = nil
                activeGraphID = nil
                activePreemptionHandler = nil
            }
            throw error
        }
    }

    func demote(fallbackViewport: GraphViewport? = nil,
                timeoutNanoseconds: UInt64 = 750_000_000) async -> GraphViewport? {
        do {
            try await acquireTransition()
        } catch {
            let provider = activeProvider
            activeProvider = nil
            activeGraphID = nil
            activePreemptionHandler = nil
            provider?.unmount()
            return fallbackViewport
        }
        defer { releaseTransition() }
        guard let provider = activeProvider else { return nil }
        activeProvider = nil
        activeGraphID = nil
        activePreemptionHandler = nil
        return await GraphProviderFinalizer.finish(
            provider, fallbackViewport: fallbackViewport,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    /// A session keeps coordinator ownership while it captures its proxy and
    /// finalizes the provider. New promotions therefore invoke and await that
    /// session's preemption handler instead of mounting concurrently. Once the
    /// provider is physically unmounted, release the slot synchronously.
    func completeExternalDemotion(of provider: GraphRendererProvider) {
        guard activeProvider === provider else { return }
        activeProvider = nil
        activeGraphID = nil
        activePreemptionHandler = nil
    }

    private func acquireTransition() async throws {
        if !transitionIsOwned {
            transitionIsOwned = true
            return
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        nanoseconds: max(self?.deadlines.transitionNanoseconds ?? 1, 1)
                    )
                    guard !Task.isCancelled else { return }
                    self?.resolveTransitionWaiter(id: waiterID, acquired: false)
                }
                transitionWaiters.append(TransitionWaiter(
                    id: waiterID, continuation: continuation,
                    timeoutTask: timeoutTask
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveTransitionWaiter(id: waiterID, acquired: false)
            }
        }
        guard acquired else {
            if Task.isCancelled { throw CancellationError() }
            throw GraphRendererError.provider("transition_timeout")
        }
    }

    private func releaseTransition() {
        if transitionWaiters.isEmpty {
            transitionIsOwned = false
        } else {
            let waiter = transitionWaiters.removeFirst()
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    private func resolveTransitionWaiter(id: UUID, acquired: Bool) {
        guard let index = transitionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = transitionWaiters.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: acquired)
    }

    func handleMemoryWarning() {
        activeProvider?.unmount()
        activeProvider = nil
        activeGraphID = nil
        activePreemptionHandler = nil
        GraphProxyCache.shared.removeAll()
    }
}

/// Third-party providers are allowed to fail, but never to hold Done/Edit or
/// the global one-provider budget indefinitely. A timeout falls back to the
/// last canonical viewport and unmounts immediately; any late callback is
/// ignored by the single-resolution race.
@MainActor
enum GraphProviderFinalizer {
    struct Result: Equatable {
        /// The valid provider viewport, or the caller's canonical fallback when
        /// readback did not complete successfully.
        let viewport: GraphViewport?
        /// Non-nil only when the provider itself returned a valid viewport.
        /// Callers use this provenance to avoid keying a live snapshot with a
        /// fallback viewport that the snapshot does not actually depict.
        let providerViewport: GraphViewport?
    }

    private struct ViewportReadback {
        let viewport: GraphViewport?
    }

    static func finish(_ provider: GraphRendererProvider,
                       fallbackViewport: GraphViewport?,
                       timeoutNanoseconds: UInt64 = 750_000_000) async -> GraphViewport? {
        await finishWithProvenance(
            provider, fallbackViewport: fallbackViewport,
            timeoutNanoseconds: timeoutNanoseconds
        ).viewport
    }

    static func finishWithProvenance(
        _ provider: GraphRendererProvider,
        fallbackViewport: GraphViewport?,
        providerAlreadyNonInteractive: Bool = false,
        timeoutNanoseconds: UInt64 = 750_000_000
    ) async -> Result {
        let readBudget = max(timeoutNanoseconds * 2 / 3, 1)
        let disableBudget = max(timeoutNanoseconds - readBudget, 1)
        let readback: ViewportReadback? = await value(
            before: readBudget,
            operation: { ViewportReadback(viewport: await provider.readViewport()) }
        )
        guard let readback else {
            provider.unmount()
            return Result(viewport: fallbackViewport, providerViewport: nil)
        }
        if !providerAlreadyNonInteractive {
            let _: Bool? = await value(before: disableBudget) {
                try? await provider.setInteractive(false)
                return true
            }
        }
        provider.unmount()
        if let viewport = readback.viewport, viewport.isValid {
            return Result(viewport: viewport, providerViewport: viewport)
        }
        return Result(viewport: fallbackViewport, providerViewport: nil)
    }

    /// Stops provider-owned gestures before a proxy image and viewport are
    /// captured. Without this barrier, the user can pan between the snapshot
    /// and readback, producing an image whose pixels do not match its cache key.
    static func freezeInteraction(
        _ provider: GraphRendererProvider,
        timeoutNanoseconds: UInt64 = 250_000_000
    ) async -> Bool {
        let completed: Bool? = await value(before: timeoutNanoseconds) {
            do {
                try await provider.setInteractive(false)
                return true
            } catch {
                return false
            }
        }
        return completed == true
    }

    private static func value<Value>(before timeoutNanoseconds: UInt64,
                                     operation: @escaping @MainActor () async -> Value) async -> Value? {
        await GraphProviderOperationDeadline.value(
            before: timeoutNanoseconds, operation: operation
        )
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
        container.backgroundColor = CanvasDesignTokens.boardSurface.cgColor
        container.borderColor = CanvasDesignTokens.boardBorder.withAlphaComponent(0.42).cgColor
        container.borderWidth = 1 / max(contentsScale, 1)
        container.cornerRadius = 10
        container.masksToBounds = true
        container.contentsScale = contentsScale

        let plotFrame = CGRect(origin: .zero, size: frame.size)
        appendGridAndAxes(to: container, graph: graph, frame: plotFrame,
                          contentsScale: contentsScale)
        appendExpressions(to: container, graph: graph, frame: plotFrame,
                          contentsScale: contentsScale)
        appendReadableMetadata(to: container, graph: graph, frame: plotFrame,
                               contentsScale: contentsScale)
        return container
    }

    static func image(for graph: GraphObject, scale: CGFloat = UIScreen.main.scale) -> UIImage {
        // Render in the graph's real logical aspect. Independently enlarging
        // width and height to different minimums distorts valid narrow/tall or
        // short/wide graph frames when the resulting bitmap is stretched back
        // into the canonical canvas frame.
        let size = CGSize(
            width: max(graph.frame.width, GraphFrame.minimumDimension),
            height: max(graph.frame.height, GraphFrame.minimumDimension)
        )
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
        grid.strokeColor = CanvasDesignTokens.canvasSecondaryText.withAlphaComponent(0.18).cgColor
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
        axes.strokeColor = CanvasDesignTokens.canvasPrimaryText.withAlphaComponent(0.64).cgColor
        axes.lineWidth = 1.25 / max(contentsScale, 1)
        axes.contentsScale = contentsScale
        container.addSublayer(axes)
    }

    private static func appendExpressions(to container: CALayer, graph: GraphObject,
                                          frame: CGRect, contentsScale: CGFloat) {
        var unsupported: [String] = []
        let environment = GraphMathEnvironment.build(
            from: graph.expressions, angleMode: graph.settings.angleMode
        )
        for (index, expression) in graph.expressions.filter(\.visible).enumerated() {
            let color = expression.displayStyle?.color.map { UIColor(svgHex: $0) }
                ?? GraphFallbackPalette.colors[index % GraphFallbackPalette.colors.count]
            let opacity = CGFloat(expression.displayStyle?.opacity ?? 1)
            let lineWidth = CGFloat(expression.displayStyle?.lineWidth ?? 2.25)
            if let fillPath = GraphFallbackSampler.inequalityFillPath(
                for: expression, viewport: graph.viewport, frame: frame,
                angleMode: graph.settings.angleMode, environment: environment
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
                                                 frame: frame, angleMode: graph.settings.angleMode,
                                                 environment: environment)
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
            label.foregroundColor = CanvasDesignTokens.canvasSecondaryText.cgColor
            label.fontSize = 11
            label.contentsScale = contentsScale
            label.isWrapped = true
            label.string = "Equation preview requires interactive graphing\n"
                + unsupported.prefix(2).joined(separator: "\n")
            container.addSublayer(label)
        }
    }

    private static func appendReadableMetadata(to container: CALayer, graph: GraphObject,
                                                frame: CGRect, contentsScale: CGFloat) {
        let visible = graph.expressions.filter(\.visible)
        let readable = visible.prefix(2).map {
            CompactStudyPresentation.readableText(from: $0.latex)
        }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        if !readable.isEmpty {
            let background = CALayer()
            background.frame = CGRect(x: 7, y: 7, width: max(1, frame.width - 14), height: 25)
            background.backgroundColor = CanvasDesignTokens.toolbarSurface.withAlphaComponent(0.86).cgColor
            background.cornerRadius = 6
            container.addSublayer(background)

            let label = CATextLayer()
            label.frame = background.bounds.insetBy(dx: 7, dy: 4)
            label.string = readable
            label.fontSize = 11
            label.foregroundColor = CanvasDesignTokens.canvasPrimaryText.cgColor
            label.truncationMode = .end
            label.contentsScale = contentsScale
            background.addSublayer(label)
        }

        let range = String(
            format: "x %.1f…%.1f   y %.1f…%.1f",
            graph.viewport.xMin, graph.viewport.xMax,
            graph.viewport.yMin, graph.viewport.yMax
        )
        let rangeLabel = CATextLayer()
        rangeLabel.frame = CGRect(x: 9, y: max(0, frame.height - 20),
                                  width: max(1, frame.width - 18), height: 14)
        rangeLabel.string = range
        rangeLabel.fontSize = 9
        rangeLabel.foregroundColor = UIColor.secondaryLabel.cgColor
        rangeLabel.alignmentMode = .right
        rangeLabel.contentsScale = contentsScale
        container.addSublayer(rangeLabel)
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
                     frame: CGRect, angleMode: String? = "radians",
                     environment: GraphMathEnvironment = .empty) -> UIBezierPath {
        let path = UIBezierPath()
        // The provider understands arbitrary Desmos restriction syntax. The
        // safe native parser intentionally does not; rendering an unrestricted
        // curve would be confidently wrong, so use the existing readable
        // unsupported-equation fallback instead.
        guard expression.restrictions.isEmpty,
              viewport.isValid, frame.width > 0, frame.height > 0 else { return path }

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
            appendImplicit(expression.latex, to: path, viewport: viewport, frame: frame,
                           angleMode: angleMode, environment: environment)
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
                                       frame: frame, angleMode: angleMode,
                                       environment: environment)
            }
        default:
            appendExplicitSegments(expression.latex, to: path, viewport: viewport,
                                   frame: frame, angleMode: angleMode,
                                   environment: environment)
        }
        return path
    }

    static func inequalityFillPath(for expression: GraphExpression,
                                   viewport: GraphViewport, frame: CGRect,
                                   angleMode: String? = "radians",
                                   environment: GraphMathEnvironment = .empty) -> UIBezierPath? {
        guard expression.type == .inequality,
              expression.restrictions.isEmpty,
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
                                angleMode: angleMode, environment: environment)
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
                         angleMode: String? = "radians",
                         environment: GraphMathEnvironment = .empty) -> [[CGPoint]] {
        guard viewport.isValid,
              let source = GraphEquationClassifier.explicitRightHandSide(latex),
              let expression = try? SafeGraphExpression(source: source,
                                                        angleMode: angleMode,
                                                        variables: environment.variables,
                                                        functions: environment.functions) else { return [] }
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
                                               angleMode: String?,
                                               environment: GraphMathEnvironment) {
        for segment in segments(for: latex, viewport: viewport,
                                sampleCount: max(128, min(1_024, Int(frame.width * 1.5))),
                                angleMode: angleMode, environment: environment) {
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

    private static func appendImplicit(_ latex: String, to path: UIBezierPath,
                                       viewport: GraphViewport, frame: CGRect,
                                       angleMode: String?,
                                       environment: GraphMathEnvironment) {
        guard let relation = GraphEquationClassifier.relation(in: latex),
              relation.operation == "=",
              let lhs = try? SafeGraphExpression(source: relation.left,
                                                  angleMode: angleMode,
                                                  variables: environment.variables,
                                                  functions: environment.functions),
              let rhs = try? SafeGraphExpression(source: relation.right,
                                                  angleMode: angleMode,
                                                  variables: environment.variables,
                                                  functions: environment.functions) else { return }
        // Marching squares is derived display geometry. A bounded grid keeps
        // it deterministic and safe while supporting general classroom
        // relations such as x^2+y^2=1 without provider code or network access.
        let columns = max(36, min(120, Int(frame.width / 5)))
        let rows = max(36, min(120, Int(frame.height / 5)))
        let dx = (viewport.xMax - viewport.xMin) / Double(columns)
        let dy = (viewport.yMax - viewport.yMin) / Double(rows)
        func value(_ x: Double, _ y: Double) -> Double {
            lhs.evaluate(x: x, y: y) - rhs.evaluate(x: x, y: y)
        }
        func crossing(_ a: (Double, Double, Double),
                      _ b: (Double, Double, Double)) -> CGPoint? {
            guard a.2.isFinite, b.2.isFinite,
                  (a.2 == 0 || b.2 == 0 || (a.2 < 0) != (b.2 < 0)) else { return nil }
            let denominator = abs(a.2) + abs(b.2)
            let t = denominator > 1e-14 ? abs(a.2) / denominator : 0.5
            return map(x: a.0 + (b.0 - a.0) * t,
                       y: a.1 + (b.1 - a.1) * t,
                       viewport: viewport, frame: frame)
        }
        for row in 0..<rows {
            let y0 = viewport.yMin + Double(row) * dy
            let y1 = y0 + dy
            for column in 0..<columns {
                let x0 = viewport.xMin + Double(column) * dx
                let x1 = x0 + dx
                let corners = [
                    (x0, y0, value(x0, y0)), (x1, y0, value(x1, y0)),
                    (x1, y1, value(x1, y1)), (x0, y1, value(x0, y1)),
                ]
                let edgePoints = [crossing(corners[0], corners[1]),
                                  crossing(corners[1], corners[2]),
                                  crossing(corners[2], corners[3]),
                                  crossing(corners[3], corners[0])].compactMap { $0 }
                if edgePoints.count == 2 {
                    path.move(to: edgePoints[0]); path.addLine(to: edgePoints[1])
                } else if edgePoints.count == 4 {
                    // Ambiguous saddle: pair adjacent crossings. This avoids
                    // drawing a false diagonal through the cell center.
                    path.move(to: edgePoints[0]); path.addLine(to: edgePoints[1])
                    path.move(to: edgePoints[2]); path.addLine(to: edgePoints[3])
                }
            }
        }
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

/// Board-local math definitions derived from canonical expression source.
/// Nothing in this environment is persisted separately: scalar values and
/// user functions are rebuilt from rows such as `a=2` and `f(x)=sin(x)`.
struct GraphMathEnvironment: Equatable, Sendable {
    static let builtInFunctions: Set<String> = [
        "sin", "cos", "tan", "sec", "csc", "cot",
        "asin", "acos", "atan", "sqrt", "abs", "exp", "log", "ln",
    ]

    var variables: [String: Double]
    var functions: [String: String]

    static let empty = GraphMathEnvironment(variables: [:], functions: [:])

    static func build(from expressions: [GraphExpression],
                      angleMode: String? = "radians") -> GraphMathEnvironment {
        var environment = GraphMathEnvironment.empty
        let scalarSources = expressions.compactMap { scalarDefinition(in: $0.latex) }
        for expression in expressions {
            if let definition = functionDefinition(in: expression.latex) {
                environment.functions[definition.name] = definition.body
            }
        }
        // A small fixed-point pass supports definitions that reference rows
        // above or below them without allowing recursive evaluation.
        for _ in 0...scalarSources.count {
            var changed = false
            for definition in scalarSources {
                guard let parsed = try? SafeGraphExpression(
                    source: definition.source, angleMode: angleMode,
                    variables: environment.variables,
                    functions: environment.functions
                ), !parsed.usesVariable else { continue }
                let value = parsed.evaluate(x: 0, y: 0)
                guard value.isFinite,
                      environment.variables[definition.name] != value else { continue }
                environment.variables[definition.name] = value
                changed = true
            }
            if !changed { break }
        }
        return environment
    }

    static func functionDefinition(in source: String) -> (name: String, body: String)? {
        guard let relation = GraphEquationClassifier.relation(in: source),
              relation.operation == "=", relation.left.hasSuffix("(x)") else { return nil }
        let name = String(relation.left.dropLast(3))
        guard isIdentifier(name), !builtInFunctions.contains(name),
              !relation.right.isEmpty else { return nil }
        return (name, relation.right)
    }

    static func scalarDefinition(in source: String) -> (name: String, source: String)? {
        guard let relation = GraphEquationClassifier.relation(in: source),
              relation.operation == "=", isSliderIdentifier(relation.left),
              !relation.right.isEmpty else { return nil }
        return (relation.left, relation.right)
    }

    func undefinedSliderParameters(in source: String) -> [String] {
        let normalized = GraphLatexNormalizer.normalize(source)
        let rightHandSource: String
        if let relation = GraphEquationClassifier.relation(in: normalized),
           relation.left == "y" || relation.left.hasSuffix("(x)") {
            rightHandSource = relation.right
        } else {
            rightHandSource = normalized
        }
        let characters = Array(rightHandSource)
        var result = Set<String>()
        var index = 0
        while index < characters.count {
            guard characters[index].isLetter else { index += 1; continue }
            let start = index
            while index < characters.count, characters[index].isLetter { index += 1 }
            let name = String(characters[start..<index])
            let isCall = index < characters.count && characters[index] == "("
            if Self.isSliderIdentifier(name), !isCall,
               variables[name] == nil, name != "x", name != "y",
               name != "e", name != "pi" {
                result.insert(name)
            }
        }
        return result.sorted()
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isSliderIdentifier(_ value: String) -> Bool {
        value.count == 1 && value.first?.isLetter == true
            && value != "x" && value != "y" && value != "e"
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
            ("\\sec", "sec"), ("\\csc", "csc"), ("\\cot", "cot"),
            ("\\arcsin", "asin"), ("\\arccos", "acos"), ("\\arctan", "atan"),
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
            .replacingOccurrences(of: "arcsin", with: "asin")
            .replacingOccurrences(of: "arccos", with: "acos")
            .replacingOccurrences(of: "arctan", with: "atan")
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
        case variable(String)
        case negated(Node)
        case binary(Character, Node, Node)
        case function(String, Node)
        case userFunction(argument: Node, body: Node)

        func evaluate(x: Double, y: Double, usesDegrees: Bool) -> Double {
            switch self {
            case .number(let value): return value
            case .variable(let name): return name == "y" ? y : x
            case .negated(let value): return -value.evaluate(x: x, y: y, usesDegrees: usesDegrees)
            case .binary(let operation, let lhs, let rhs):
                let a = lhs.evaluate(x: x, y: y, usesDegrees: usesDegrees)
                let b = rhs.evaluate(x: x, y: y, usesDegrees: usesDegrees)
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
                let argument = value.evaluate(x: x, y: y, usesDegrees: usesDegrees)
                let trigArgument = usesDegrees ? argument * .pi / 180 : argument
                switch name {
                case "sin": return Foundation.sin(trigArgument)
                case "cos": return Foundation.cos(trigArgument)
                case "tan": return Foundation.tan(trigArgument)
                case "sec": return reciprocal(Foundation.cos(trigArgument))
                case "csc": return reciprocal(Foundation.sin(trigArgument))
                case "cot": return reciprocal(Foundation.tan(trigArgument))
                case "asin":
                    guard (-1...1).contains(argument) else { return .nan }
                    let result = Foundation.asin(argument)
                    return usesDegrees ? result * 180 / .pi : result
                case "acos":
                    guard (-1...1).contains(argument) else { return .nan }
                    let result = Foundation.acos(argument)
                    return usesDegrees ? result * 180 / .pi : result
                case "atan":
                    let result = Foundation.atan(argument)
                    return usesDegrees ? result * 180 / .pi : result
                case "sqrt": return argument < 0 ? .nan : Foundation.sqrt(argument)
                case "abs": return Swift.abs(argument)
                case "exp": return Foundation.exp(argument)
                case "log": return argument <= 0 ? .nan : Foundation.log10(argument)
                case "ln": return argument <= 0 ? .nan : Foundation.log(argument)
                default: return .nan
                }
            case .userFunction(let argument, let body):
                let value = argument.evaluate(x: x, y: y, usesDegrees: usesDegrees)
                guard value.isFinite else { return .nan }
                return body.evaluate(x: value, y: y, usesDegrees: usesDegrees)
            }
        }

        private func reciprocal(_ value: Double) -> Double {
            abs(value) <= 1e-14 ? .nan : 1 / value
        }

        func usesFreeVariable(boundX: Bool = false) -> Bool {
            switch self {
            case .number: return false
            case .variable(let name): return name == "x" ? !boundX : true
            case .negated(let value), .function(_, let value):
                return value.usesFreeVariable(boundX: boundX)
            case .binary(_, let lhs, let rhs):
                return lhs.usesFreeVariable(boundX: boundX)
                    || rhs.usesFreeVariable(boundX: boundX)
            case .userFunction(let argument, let body):
                return argument.usesFreeVariable(boundX: boundX)
                    || body.usesFreeVariable(boundX: true)
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

    var usesVariable: Bool { root.usesFreeVariable() }

    init(source: String, angleMode: String? = "radians",
         variables: [String: Double] = [:], functions: [String: String] = [:]) throws {
        let normalized = GraphLatexNormalizer.normalize(source)
        guard normalized.count <= Self.maximumSourceLength else {
            throw GraphRendererError.invalidExpression("expression too long")
        }
        var parser = try Parser(source: normalized, variables: variables,
                                functions: functions)
        root = try parser.parse()
        usesDegrees = angleMode == "degrees"
    }

    func evaluate(x: Double) -> Double {
        evaluate(x: x, y: 0)
    }

    func evaluate(x: Double, y: Double) -> Double {
        guard x.isFinite, abs(x) <= 10_000_000 else { return .nan }
        guard y.isFinite, abs(y) <= 10_000_000 else { return .nan }
        let result = root.evaluate(x: x, y: y, usesDegrees: usesDegrees)
        guard result.isFinite, abs(result) <= Self.maximumMagnitude else { return .nan }
        return result
    }

    private struct Parser {
        private static let functions = Set([
            "sin", "cos", "tan", "asin", "acos", "atan",
            "sec", "csc", "cot", "sqrt", "abs", "exp", "log", "ln"
        ])
        private var tokens: [Token]
        private var index = 0
        private var nodeCount = 0
        private let variables: [String: Double]
        private let userFunctions: [String: String]
        private let functionDepth: Int

        init(source: String, variables: [String: Double] = [:],
             functions: [String: String] = [:], functionDepth: Int = 0) throws {
            tokens = try Self.tokenize(source)
            self.variables = variables
            userFunctions = functions
            self.functionDepth = functionDepth
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
                if name == "x" || name == "y" { return try make(.variable(name)) }
                if name == "pi" { return try make(.number(.pi)) }
                if name == "e" { return try make(.number(M_E)) }
                if let value = variables[name], value.isFinite {
                    return try make(.number(value))
                }
                let isBuiltInFunction = Self.functions.contains(name)
                let userFunctionBody = userFunctions[name]
                guard isBuiltInFunction || userFunctionBody != nil else {
                    throw GraphRendererError.invalidExpression("undefined \(name)")
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
                if isBuiltInFunction {
                    return try make(.function(name, argument))
                }
                guard let bodySource = userFunctionBody, functionDepth < 8 else {
                    throw GraphRendererError.invalidExpression("undefined \(name)")
                }
                var nestedFunctions = userFunctions
                nestedFunctions.removeValue(forKey: name)
                var bodyParser = try Parser(
                    source: GraphLatexNormalizer.normalize(bodySource),
                    variables: variables, functions: nestedFunctions,
                    functionDepth: functionDepth + 1
                )
                let body = try bodyParser.parse()
                return try make(.userFunction(argument: argument, body: body))
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

enum NativeGraphSolutionKind: String, Equatable, Sendable {
    case calculation, linear, quadratic, numericalRoots, intersections,
         derivative, definiteIntegral, unsupportedIndefiniteIntegral
}

struct NativeGraphMathResult: Equatable, Sendable {
    let kind: NativeGraphSolutionKind
    let values: [Double]
    let message: String
    let isExact: Bool
}

/// Local, typed-AST-backed classroom math tools. Every operation is bounded;
/// input is parsed by SafeGraphExpression and is never passed to eval, a web
/// provider, Python, or another arbitrary-code runtime.
enum NativeGraphMath {
    static func calculate(_ source: String, angleMode: String? = "radians",
                          variables: [String: Double] = [:],
                          functions: [String: String] = [:])
        throws -> NativeGraphMathResult {
        let expression = try SafeGraphExpression(
            source: source, angleMode: angleMode,
            variables: variables, functions: functions
        )
        guard !expression.usesVariable else {
            throw GraphRendererError.invalidExpression("numeric expression contains a variable")
        }
        let value = expression.evaluate(x: 0, y: 0)
        guard value.isFinite else { throw GraphRendererError.invalidExpression("undefined result") }
        return NativeGraphMathResult(kind: .calculation, values: [value],
                                     message: format(value), isExact: false)
    }

    static func solve(_ equation: String, domain: ClosedRange<Double>,
                      angleMode: String? = "radians",
                      variables: [String: Double] = [:],
                      functions: [String: String] = [:]) throws -> NativeGraphMathResult {
        if isUnboundedIntegral(equation) {
            return NativeGraphMathResult(
                kind: .unsupportedIndefiniteIntegral, values: [],
                message: "This is an indefinite integral. Graph the integrand, enter bounds, or edit the expression.",
                isExact: false
            )
        }
        let evaluator = try equationEvaluator(
            equation, angleMode: angleMode,
            variables: variables, functions: functions
        )
        let f0 = evaluator(0), f1 = evaluator(1), fm1 = evaluator(-1), f2 = evaluator(2)
        if [f0, f1, fm1, f2].allSatisfy(\.isFinite) {
            let a = (f1 + fm1) / 2 - f0
            let b = (f1 - fm1) / 2
            let c = f0
            let predictedF2 = 4 * a + 2 * b + c
            let tolerance = 1e-8 * max(1, abs(f2), abs(predictedF2))
            let validationXs = [-2.0, 0.5, 1.5, 3.0]
            let fitsQuadratic = abs(f2 - predictedF2) <= tolerance
                && validationXs.allSatisfy { x in
                    let actual = evaluator(x)
                    let predicted = a * x * x + b * x + c
                    return actual.isFinite
                        && abs(actual - predicted)
                            <= 1e-8 * max(1, abs(actual), abs(predicted))
                }
            if fitsQuadratic {
                if abs(a) <= 1e-10, abs(b) > 1e-10 {
                    let root = -c / b
                    return NativeGraphMathResult(kind: .linear, values: [root],
                                                 message: "x = \(format(root))",
                                                 isExact: true)
                }
                if abs(a) > 1e-10 {
                    let discriminant = b * b - 4 * a * c
                    if discriminant < -tolerance {
                        return NativeGraphMathResult(kind: .quadratic, values: [],
                                                     message: "No real solutions",
                                                     isExact: true)
                    }
                    let root = sqrt(max(0, discriminant))
                    // Stable form avoids catastrophic cancellation when |b|
                    // is much larger than the discriminant contribution.
                    let q = -0.5 * (b + (b >= 0 ? root : -root))
                    let roots: [Double]
                    if abs(q) <= 1e-14 {
                        roots = [-b / (2 * a)]
                    } else {
                        roots = deduplicated([q / a, c / q])
                    }
                    return NativeGraphMathResult(kind: .quadratic, values: roots,
                                                 message: roots.map { "x = \(format($0))" }
                                                    .joined(separator: ", "),
                                                 isExact: true)
                }
            }
        }
        let roots = scanRoots(evaluator, domain: domain)
        return NativeGraphMathResult(
            kind: .numericalRoots, values: roots,
            message: roots.isEmpty ? "No roots found in \(format(domain.lowerBound))…\(format(domain.upperBound))"
                : roots.map { "x ≈ \(format($0))" }.joined(separator: ", "),
            isExact: false
        )
    }

    static func intersections(_ first: String, _ second: String,
                              domain: ClosedRange<Double>,
                              angleMode: String? = "radians",
                              variables: [String: Double] = [:],
                              functions: [String: String] = [:]) throws -> NativeGraphMathResult {
        let lhs = try explicitExpression(
            first, angleMode: angleMode, variables: variables, functions: functions
        )
        let rhs = try explicitExpression(
            second, angleMode: angleMode, variables: variables, functions: functions
        )
        let roots = scanRoots({ lhs.evaluate(x: $0) - rhs.evaluate(x: $0) }, domain: domain)
        var coordinates: [Double] = []
        for x in roots { coordinates.append(contentsOf: [x, lhs.evaluate(x: x)]) }
        let message = roots.enumerated().map { index, x in
            "(\(format(x)), \(format(coordinates[index * 2 + 1])))"
        }.joined(separator: ", ")
        return NativeGraphMathResult(kind: .intersections, values: coordinates,
                                     message: message.isEmpty ? "No intersections in the visible domain" : message,
                                     isExact: false)
    }

    static func derivative(_ source: String, at x: Double,
                           angleMode: String? = "radians",
                           variables: [String: Double] = [:],
                           functions: [String: String] = [:]) throws -> NativeGraphMathResult {
        let expression = try explicitExpression(
            source, angleMode: angleMode, variables: variables, functions: functions
        )
        let h = max(1e-6, abs(x) * 1e-5)
        let value = (expression.evaluate(x: x - 2 * h)
                     - 8 * expression.evaluate(x: x - h)
                     + 8 * expression.evaluate(x: x + h)
                     - expression.evaluate(x: x + 2 * h)) / (12 * h)
        guard value.isFinite else { throw GraphRendererError.invalidExpression("derivative undefined") }
        return NativeGraphMathResult(kind: .derivative, values: [value],
                                     message: "f′(\(format(x))) ≈ \(format(value))", isExact: false)
    }

    static func integral(_ source: String, from a: Double, to b: Double,
                         angleMode: String? = "radians",
                         variables: [String: Double] = [:],
                         functions: [String: String] = [:]) throws -> NativeGraphMathResult {
        let expression = try explicitExpression(
            source, angleMode: angleMode, variables: variables, functions: functions
        )
        let f: (Double) -> Double = { expression.evaluate(x: $0) }
        let whole = simpson(f, a, b)
        let value = adaptiveSimpson(f, a, b, epsilon: 1e-8, whole: whole, depth: 14)
        guard value.isFinite else { throw GraphRendererError.invalidExpression("integral undefined") }
        return NativeGraphMathResult(kind: .definiteIntegral, values: [value],
                                     message: "∫ ≈ \(format(value))", isExact: false)
    }

    private static func explicitExpression(_ source: String, angleMode: String?,
                                           variables: [String: Double],
                                           functions: [String: String]) throws
        -> SafeGraphExpression {
        let rhs = GraphEquationClassifier.explicitRightHandSide(source) ?? source
        return try SafeGraphExpression(
            source: rhs, angleMode: angleMode,
            variables: variables, functions: functions
        )
    }

    private static func equationEvaluator(_ source: String, angleMode: String?,
                                          variables: [String: Double],
                                          functions: [String: String]) throws
        -> (Double) -> Double {
        if let rhs = GraphEquationClassifier.explicitRightHandSide(source) {
            let expression = try SafeGraphExpression(
                source: rhs, angleMode: angleMode,
                variables: variables, functions: functions
            )
            return { expression.evaluate(x: $0) }
        }
        if let relation = GraphEquationClassifier.relation(in: source) {
            let left = try SafeGraphExpression(
                source: relation.left, angleMode: angleMode,
                variables: variables, functions: functions
            )
            let right = try SafeGraphExpression(
                source: relation.right, angleMode: angleMode,
                variables: variables, functions: functions
            )
            return { left.evaluate(x: $0) - right.evaluate(x: $0) }
        }
        let expression = try SafeGraphExpression(
            source: source, angleMode: angleMode,
            variables: variables, functions: functions
        )
        return { expression.evaluate(x: $0) }
    }

    private static func scanRoots(_ f: (Double) -> Double,
                                  domain: ClosedRange<Double>) -> [Double] {
        guard domain.lowerBound.isFinite, domain.upperBound.isFinite,
              domain.upperBound > domain.lowerBound else { return [] }
        let count = 1_024
        let step = (domain.upperBound - domain.lowerBound) / Double(count)
        var roots: [Double] = []
        var x0 = domain.lowerBound
        var y0 = f(x0)
        for index in 1...count {
            let x1 = index == count ? domain.upperBound : domain.lowerBound + Double(index) * step
            let y1 = f(x1)
            if y0.isFinite, abs(y0) < 1e-8 { roots.append(x0) }
            if y0.isFinite, y1.isFinite, (y0 < 0) != (y1 < 0) {
                var lower = x0, upper = x1, lowerValue = y0
                for _ in 0..<64 {
                    let midpoint = (lower + upper) / 2
                    let middleValue = f(midpoint)
                    guard middleValue.isFinite else { break }
                    if abs(middleValue) < 1e-12 { lower = midpoint; upper = midpoint; break }
                    if (lowerValue < 0) != (middleValue < 0) {
                        upper = midpoint
                    } else {
                        lower = midpoint; lowerValue = middleValue
                    }
                }
                roots.append((lower + upper) / 2)
            }
            x0 = x1; y0 = y1
        }
        if y0.isFinite, abs(y0) < 1e-8 { roots.append(domain.upperBound) }
        return deduplicated(roots, tolerance: max(1e-7, step * 0.2))
    }

    private static func simpson(_ f: (Double) -> Double, _ a: Double, _ b: Double) -> Double {
        let midpoint = (a + b) / 2
        return (b - a) * (f(a) + 4 * f(midpoint) + f(b)) / 6
    }

    private static func adaptiveSimpson(_ f: (Double) -> Double, _ a: Double, _ b: Double,
                                        epsilon: Double, whole: Double, depth: Int) -> Double {
        let midpoint = (a + b) / 2
        let left = simpson(f, a, midpoint)
        let right = simpson(f, midpoint, b)
        let delta = left + right - whole
        if depth <= 0 || !delta.isFinite || abs(delta) <= 15 * epsilon {
            return left + right + delta / 15
        }
        return adaptiveSimpson(f, a, midpoint, epsilon: epsilon / 2,
                               whole: left, depth: depth - 1)
            + adaptiveSimpson(f, midpoint, b, epsilon: epsilon / 2,
                              whole: right, depth: depth - 1)
    }

    private static func deduplicated(_ values: [Double], tolerance: Double = 1e-8) -> [Double] {
        values.sorted().reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > tolerance }) ?? true { result.append(value) }
        }
    }

    private static func isUnboundedIntegral(_ source: String) -> Bool {
        let compact = source.filter { !$0.isWhitespace }.lowercased()
        return (compact.contains("∫") || compact.contains("\\int"))
            && !compact.contains("_") && !compact.contains("from")
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "undefined" }
        if abs(value.rounded() - value) < 1e-10 { return String(Int(value.rounded())) }
        return value.formatted(.number.precision(.significantDigits(1...8)))
    }
}
