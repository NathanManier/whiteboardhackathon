import SwiftUI
import UIKit
import OSLog

/// The single application-wide budget for an expensive graph provider. Passive
/// graph objects never reach this coordinator and therefore never allocate a
/// web view.
@MainActor
enum GraphProviderEnvironment {
    static let sharedCoordinator = GraphProviderCoordinator()

    static func makeConfiguredProvider() -> GraphRendererProvider? {
        let configuration = DesmosConfiguration()
        guard configuration.isConfigured else { return nil }
        return DesmosGraphRenderer(configuration: configuration)
    }
}

enum GraphPromotionDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vboard.ipad",
        category: "GraphPromotion"
    )

    static func record(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .public)")
        print(message)
        #endif
    }
}

@MainActor
protocol GraphResizableRendererProvider: GraphRendererProvider {
    func resize(to frame: CGRect) async throws
}

extension DesmosGraphRenderer: GraphResizableRendererProvider { }

enum GraphProviderDemotionReason: String, Equatable, Sendable {
    case done
    case edit
    case disappeared
    case background
    case memoryPressure
    case replaced
}

struct GraphDemotionResult: Equatable, Sendable {
    let boardID: String
    let graphID: String
    let viewport: GraphViewport
}

enum GraphPencilInteractionPolicy {
    /// Interactive graphs keep finger/trackpad gestures for the provider, but
    /// Pencil annotation must still honor the canonical V-Board tool. A
    /// selection, navigation, lasso, or eraser tool must never silently become
    /// a pen merely because a WKWebView is active.
    static func allowsAnnotation(for tool: CanvasTool) -> Bool {
        tool == .pen || tool == .highlighter
    }
}

enum GraphAnnotationOverlayPolicy {
    /// The interactive provider is an opaque peer above the native canvas.
    /// Re-present only canonical strokes that are ordered after the graph, so
    /// annotations keep the same z-order they have in the editor document.
    static func strokeObjectsAbove(graphID: String,
                                   in objects: [CanvasObject]) -> [CanvasObject] {
        let canonical = SceneComposition.canonicalEditorObjects(objects)
        guard let graphIndex = canonical.firstIndex(where: { $0.id == graphID }),
              graphIndex < canonical.index(before: canonical.endIndex) else { return [] }
        return canonical[canonical.index(after: graphIndex)...].filter {
            $0.type == "stroke"
        }
    }

    static func strokeIntersectsGraph(_ object: CanvasObject,
                                      graphFrame: CGRect) -> Bool {
        guard !(object.points ?? []).isEmpty else { return false }
        let rawScaleX = object.scaleX ?? 1
        let rawScaleY = object.scaleY ?? 1
        let scaleX = rawScaleX.isFinite ? rawScaleX : 1
        let scaleY = rawScaleY.isFinite ? rawScaleY : 1
        let rawWidth = object.width ?? 4
        let width = rawWidth.isFinite ? rawWidth : 4
        let renderedWidth = width * sqrt(abs(scaleX * scaleY))
        let hitBounds = BoardHitTestPolicy.bounds(of: object).insetBy(
            dx: -max(renderedWidth / 2, 0.5),
            dy: -max(renderedWidth / 2, 0.5)
        )
        return hitBounds.intersects(graphFrame)
    }
}

enum GraphAccessibility {
    static func label(for graph: GraphObject) -> String {
        let expressions = graph.expressions.filter(\.visible).prefix(2)
            .map { spoken($0.latex) }
            .filter { !$0.isEmpty }
        guard !expressions.isEmpty else { return "Graph" }
        return "Graph, " + expressions.joined(separator: ", ")
    }

    static func spoken(_ latex: String) -> String {
        var result = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacements: [(String, String)] = [
            ("\\theta", " theta "), ("\\pi", " pi "),
            ("\\cdot", " times "), ("\\times", " times "),
            ("^2", " squared "), ("^3", " cubed "),
            (">=", " greater than or equal to "),
            ("<=", " less than or equal to "),
            ("=", " equals "), ("+", " plus "), ("-", " minus "),
            ("*", " times "), ("/", " divided by "),
            ("{", ""), ("}", ""), ("^", " to the power of ")
        ]
        for (source, replacement) in replacements {
            result = result.replacingOccurrences(of: source, with: replacement)
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A passive GraphObject is rendered by CALayer for canvas performance. This
/// transparent, non-hit-testing SwiftUI peer gives VoiceOver one stable graph
/// element and routes every action back through the canonical editor paths.
struct GraphAccessibilityProxy: View {
    let graph: GraphObject
    let onInteract: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GraphAccessibility.label(for: graph))
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Interact", onInteract)
            .accessibilityAction(named: "Edit Equation", onEdit)
            .accessibilityAction(named: "Delete", onDelete)
    }
}

/// Owns the non-Pencil area outside an active graph. The first finger, mouse,
/// or trackpad contact exits graph interaction and is deliberately consumed,
/// so one pointer stream cannot pan the graph while another pans the canvas.
/// Pencil remains routed to the native annotation surface.
@MainActor
struct GraphOutsideInteractionShield: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> GraphOutsideInteractionShieldView {
        GraphOutsideInteractionShieldView(onDismiss: onDismiss)
    }

    func updateUIView(_ uiView: GraphOutsideInteractionShieldView, context: Context) {
        uiView.onDismiss = onDismiss
    }
}

enum GraphOutsideInteractionPolicy {
    struct Contact {
        let point: CGPoint
        let type: UITouch.TouchType
        let phase: UITouch.Phase
    }

    /// UIKit asks for a hit-tested view once per newly beginning contact, but
    /// `UIEvent.allTouches` also contains already-owned fingers. Match the
    /// contact nearest the queried point instead of treating the entire event
    /// as one input type, so a Pencil beginning while a finger is held outside
    /// the graph can still reach the canonical canvas input surface.
    static func shouldPassThrough(contactAt point: CGPoint,
                                  contacts: [Contact]) -> Bool {
        let beginnings = contacts.filter { $0.phase == .began }
        let candidates = beginnings.isEmpty ? contacts : beginnings
        guard let contact = candidates.min(by: {
            squaredDistance($0.point, point) < squaredDistance($1.point, point)
        }) else { return false }
        return contact.type == .pencil
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

@MainActor
final class GraphOutsideInteractionShieldView: UIView {
    var onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let touches = event?.allTouches, !touches.isEmpty else {
            return super.hitTest(point, with: event)
        }
        let contacts = touches.map {
            GraphOutsideInteractionPolicy.Contact(
                point: $0.location(in: self), type: $0.type, phase: $0.phase
            )
        }
        if GraphOutsideInteractionPolicy.shouldPassThrough(
            contactAt: point, contacts: contacts
        ) { return nil }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let activePencil = event?.allTouches?.contains(where: {
            $0.type == .pencil && $0.phase != .ended && $0.phase != .cancelled
        }) ?? false
        // A second finger must not tear down the provider out from underneath
        // a valid Pencil annotation. Consume that finger sequence and let the
        // Pencil owner finish normally.
        guard !activePencil else { return }
        onDismiss()
        super.touchesBegan(touches, with: event)
    }
}

/// Owns one interactive presentation session. The provider factory is lazy on
/// purpose: constructing a passive graph or an unconfigured surface must not
/// construct a WKWebView.
@MainActor
final class GraphInteractiveSession: ObservableObject {
    typealias ProviderFactory = @MainActor () -> GraphRendererProvider?

    @Published private(set) var displayGraph: GraphObject
    @Published private(set) var representationState: GraphRepresentationState = .proxy
    @Published private(set) var providerError: String?
    @Published private(set) var promotionStage: GraphPromotionStage = .idle
    @Published private(set) var promotionGeneration = 0
    @Published private(set) var promotionStartedAt: CFTimeInterval?
    @Published private(set) var providerIdentifier = "none"

    private let coordinator: GraphProviderCoordinator
    private let providerFactory: ProviderFactory
    private let onForcedViewportCommit: @MainActor (String, String, GraphViewport) -> Void
    private weak var hostView: GraphProviderContainerView?
    private var provider: GraphRendererProvider?
    private var lastProviderAppliedGraph: GraphObject?
    private var promotionTask: Task<Void, Never>?
    private var replacementTask: Task<Void, Never>?
    private var pendingReplacement: GraphObject?
    private var providerUpdateTask: Task<Void, Never>?
    private var pendingProviderUpdate: GraphObject?
    private var providerEpoch = 0
    private var demotionTask: Task<GraphDemotionResult?, Never>?
    private var activeDemotionID: UUID?
    private var activeDemotionAllowsSnapshot = true
    private var generation = 0
    private var wantsInteractivePresentation = false
    private var lifecycleSuspendsInteractivePresentation = false
    private var lastLayoutSize = CGSize.zero
    private let snapshotTimeoutNanoseconds: UInt64

    init(graph: GraphObject,
         coordinator: GraphProviderCoordinator,
         onForcedViewportCommit: @escaping @MainActor (String, String, GraphViewport) -> Void = { _, _, _ in },
         snapshotTimeoutNanoseconds: UInt64 = 1_500_000_000,
         providerFactory: @escaping ProviderFactory) {
        displayGraph = graph
        self.coordinator = coordinator
        self.providerFactory = providerFactory
        self.onForcedViewportCommit = onForcedViewportCommit
        self.snapshotTimeoutNanoseconds = snapshotTimeoutNanoseconds
    }

    var hasLiveProviderView: Bool {
        guard let provider else { return false }
        return provider.view.superview === hostView
    }

    var promotionElapsedSeconds: Double {
        guard let promotionStartedAt else { return 0 }
        return max(CACurrentMediaTime() - promotionStartedAt, 0)
    }

    private func transition(to newState: GraphRepresentationState) {
        #if DEBUG
        let allowed: Set<GraphRepresentationState>
        switch representationState {
        case .unloaded: allowed = [.proxy, .failed]
        case .proxy: allowed = [.promoting, .interactive, .demoting, .failed, .proxy]
        case .promoting: allowed = [.interactive, .demoting, .failed, .proxy]
        case .interactive: allowed = [.demoting, .failed, .interactive]
        case .demoting: allowed = [.proxy, .failed, .demoting]
        case .failed: allowed = [.proxy, .demoting, .failed]
        }
        assert(allowed.contains(newState),
               "Invalid graph state transition \(representationState.rawValue) -> \(newState.rawValue)")
        #endif
        representationState = newState
    }

    private func recordPromotionStage(_ stage: GraphPromotionStage,
                                      generation expectedGeneration: Int,
                                      providerID expectedProviderID: ObjectIdentifier? = nil) {
        guard expectedGeneration == generation else { return }
        if let expectedProviderID {
            guard let provider, ObjectIdentifier(provider) == expectedProviderID else { return }
        }
        promotionStage = stage
        let elapsedMilliseconds = promotionElapsedSeconds * 1_000
        GraphPromotionDiagnostics.record(
            "\(stage.diagnosticEventName) graphID=\(displayGraph.id) provider=\(providerIdentifier) "
            + "sessionGeneration=\(expectedGeneration) stage=\(stage.rawValue) "
            + "elapsedMs=\(String(format: "%.1f", elapsedMilliseconds))"
        )
    }

    private func stopLifecycleReporting(for provider: GraphRendererProvider?) {
        (provider as? GraphProviderLifecycleReporting)?.lifecycleEventHandler = nil
    }

    private func promotionFailureCategory(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let rendererError = error as? GraphRendererError else {
            return "provider_error"
        }
        switch rendererError {
        case .unavailable:
            return "provider_unavailable"
        case .invalidExpression:
            return "invalid_expression"
        case .provider(let category):
            let safe = category.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                    ? Character(String(scalar)) : "_"
            }
            return String(safe.prefix(96))
        }
    }

    func attach(to hostView: GraphProviderContainerView) {
        self.hostView = hostView
        if let provider { hostView.install(provider.view) }
        schedulePromotionIfReady()
    }

    func detach(from hostView: GraphProviderContainerView) {
        guard self.hostView === hostView else { return }
        self.hostView = nil
    }

    func update(graph: GraphObject) {
        let replacesActiveGraph = graph.id != displayGraph.id
        providerError = nil

        if replacementTask != nil {
            // Even a request that returns to the currently displayed identity
            // supersedes the pending replacement. An A -> B -> A sequence can
            // arrive while A's snapshot/readback is suspended; retaining B
            // here would mount stale content with no later SwiftUI update.
            pendingReplacement = graph
            return
        }

        guard replacesActiveGraph else {
            displayGraph = graph
            guard let provider,
                  representationState == .interactive,
                  coordinator.activeGraphID == graph.id,
                  coordinator.activeProvider === provider else { return }
            enqueueProviderUpdate(graph, provider: provider)
            return
        }

        pendingReplacement = graph
        replacementTask = Task { @MainActor [weak self] in
            await self?.replaceActiveGraphAfterDemotion()
        }
    }

    func requestInteractivePresentation() {
        guard representationState == .proxy else { return }
        lifecycleSuspendsInteractivePresentation = false
        wantsInteractivePresentation = true
        schedulePromotionIfReady()
    }

    func retryInteractivePresentation() {
        guard representationState == .failed else { return }
        providerError = nil
        promotionStage = .idle
        transition(to: .proxy)
        lifecycleSuspendsInteractivePresentation = false
        wantsInteractivePresentation = true
        schedulePromotionIfReady()
    }

    /// Foregrounding may race the bounded background teardown. Join that
    /// physical unmount first, then restore the still-visible interactive
    /// surface without requiring the user to close and reopen it.
    func resumeInteractivePresentationAfterLifecycleDemotion() async {
        if let replacementTask { await replacementTask.value }
        if let demotionTask { _ = await demotionTask.value }
        guard hostView != nil else { return }
        lifecycleSuspendsInteractivePresentation = false
        wantsInteractivePresentation = true
        schedulePromotionIfReady()
    }

    /// Test seam and deterministic activation path used by the representable.
    func promoteNow(in hostView: GraphProviderContainerView) async {
        attach(to: hostView)
        if representationState == .failed { transition(to: .proxy) }
        wantsInteractivePresentation = true
        generation += 1
        let requestedGeneration = generation
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.promote(generation: requestedGeneration)
        }
        promotionTask = task
        await task.value
        if generation == requestedGeneration {
            promotionTask = nil
        }
    }

    func resetView() {
        displayGraph = displayGraph.replacing(
            viewport: displayGraph.viewport.resettingToConventionalBounds()
        )
        guard let provider,
              representationState == .interactive,
              coordinator.activeGraphID == displayGraph.id,
              coordinator.activeProvider === provider else { return }
        enqueueProviderUpdate(displayGraph, provider: provider)
    }

    /// Returns the provider's final viewport exactly once when it is available.
    /// The caller remains responsible for writing that viewport through the
    /// canonical BoardDocumentStore mutation path.
    func demote(reason: GraphProviderDemotionReason) async -> GraphDemotionResult? {
        wantsInteractivePresentation = false
        if reason == .background || reason == .memoryPressure {
            lifecycleSuspendsInteractivePresentation = true
        }
        if let demotionTask {
            if reason == .background || reason == .memoryPressure {
                activeDemotionAllowsSnapshot = false
            }
            // Join the physical teardown, but leave its one canonical viewport
            // result to the caller that started it. This prevents duplicate
            // history/autosave commits from overlapping lifecycle callbacks.
            _ = await demotionTask.value
            return nil
        }

        let startedAt = CACurrentMediaTime()
        let proxyAccountNamespace = LocalAccountNamespace.value
        let proxyCacheGeneration = GraphProxyCache.shared.generation
        generation += 1
        let demotionGeneration = generation
        // Cancellation is only a request: a provider mount can ignore it and
        // finish after the coordinator has installed the provider. Keep the
        // promotion task and join it inside the single demotion task before
        // claiming/finalizing the provider. Otherwise the stale-promotion
        // cleanup and this path can concurrently unmount/read the same web
        // view, losing the provider's last viewport.
        let promotionToJoin = promotionTask
        promotionToJoin?.cancel()
        promotionTask = nil
        invalidateProviderUpdates()
        transition(to: .demoting)
        let demotionID = UUID()
        activeDemotionID = demotionID
        activeDemotionAllowsSnapshot = reason != .memoryPressure && reason != .background
        let task: Task<GraphDemotionResult?, Never> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            if let promotionToJoin {
                _ = await GraphProviderOperationDeadline.value(
                    before: 500_000_000
                ) {
                    await promotionToJoin.value
                    return true
                }
            }
            guard self.activeDemotionID == demotionID else { return nil }
            guard let provider = self.provider else {
                if self.generation == demotionGeneration {
                    self.promotionStage = .idle
                    self.providerIdentifier = "none"
                    self.transition(to: .proxy)
                }
                return nil
            }
            let demotingGraph = self.displayGraph
            self.provider = nil
            return await self.performDemotion(
                provider: provider, graph: demotingGraph,
                generation: demotionGeneration, demotionID: demotionID,
                startedAt: startedAt,
                proxyAccountNamespace: proxyAccountNamespace,
                proxyCacheGeneration: proxyCacheGeneration
            )
        }
        demotionTask = task
        let result = await task.value
        if activeDemotionID == demotionID {
            demotionTask = nil
            activeDemotionID = nil
            activeDemotionAllowsSnapshot = true
        }
        return result
    }

    private func performDemotion(
        provider: GraphRendererProvider,
        graph demotingGraph: GraphObject,
        generation demotionGeneration: Int,
        demotionID: UUID,
        startedAt: CFTimeInterval,
        proxyAccountNamespace: String,
        proxyCacheGeneration: Int
    ) async -> GraphDemotionResult? {
        var viewport: GraphViewport?
        var snapshot: UIImage?
        stopLifecycleReporting(for: provider)
        let didFreezeInteraction = await GraphProviderFinalizer.freezeInteraction(
            provider,
            timeoutNanoseconds: max(
                min(snapshotTimeoutNanoseconds / 4, 250_000_000), 1
            )
        )
        if didFreezeInteraction,
           activeDemotionID == demotionID, activeDemotionAllowsSnapshot {
            snapshot = await captureSnapshot(from: provider)
        }
        let appliedGraphAtSnapshot = lastProviderAppliedGraph ?? demotingGraph
        let finalization = await GraphProviderFinalizer.finishWithProvenance(
            provider, fallbackViewport: demotingGraph.viewport,
            providerAlreadyNonInteractive: didFreezeInteraction
        )
        viewport = finalization.viewport.map {
            demotingGraph.viewport.replacingBounds(with: $0)
        }
        let providerReadbackViewport = finalization.providerViewport.map {
            demotingGraph.viewport.replacingBounds(with: $0)
        }
        coordinator.completeExternalDemotion(of: provider)
        if displayGraph.id == demotingGraph.id,
           lastProviderAppliedGraph?.viewport != displayGraph.viewport {
            // Reset View or a canonical viewport edit can arrive immediately
            // before Done. If its provider update was pending/cancelled, a
            // stale readback must not overwrite the newer canonical intent.
            viewport = displayGraph.viewport
        }
        var finalizedGraph = demotingGraph
        if let viewport, viewport.isValid {
            finalizedGraph = demotingGraph.replacing(viewport: viewport)
            if displayGraph.id == demotingGraph.id {
                // Preserve any same-ID semantic edit received while provider
                // readback was suspended; only its viewport is replaced.
                displayGraph = displayGraph.replacing(viewport: viewport)
                finalizedGraph = displayGraph
            }
        }
        let snapshotAspect = snapshot.flatMap { image -> Double? in
            guard image.size.width > 0, image.size.height > 0 else { return nil }
            return Double(image.size.width / image.size.height)
        }
        let finalAspect = finalizedGraph.frame.width / finalizedGraph.frame.height
        let snapshotMatchesFinalState =
            appliedGraphAtSnapshot.id == finalizedGraph.id
            && appliedGraphAtSnapshot.expressions == finalizedGraph.expressions
            && appliedGraphAtSnapshot.settings == finalizedGraph.settings
            && appliedGraphAtSnapshot.providerMetadata?.renderVersion
                == finalizedGraph.providerMetadata?.renderVersion
            && providerReadbackViewport == finalizedGraph.viewport
            && snapshotAspect.map { abs($0 - finalAspect) <= 0.001 } != false
        lastProviderAppliedGraph = nil
        if activeDemotionID == demotionID,
           activeDemotionAllowsSnapshot,
           snapshotMatchesFinalState,
           let snapshot, let hostView {
            GraphProxyCache.shared.storeProviderSnapshot(
                snapshot, for: finalizedGraph,
                appearance: hostView.traitCollection.userInterfaceStyle,
                accountNamespace: proxyAccountNamespace,
                expectedGeneration: proxyCacheGeneration
            )
        }
        hostView?.removeProviderView(provider.view)
        if generation == demotionGeneration, self.provider == nil {
            promotionStage = .idle
            providerIdentifier = "none"
            transition(to: .proxy)
        }
        #if DEBUG
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        print("GRAPH PROVIDER DEMOTED graph=\(demotingGraph.id) elapsedMs=\(String(format: "%.1f", elapsedMilliseconds)) proxy=\(snapshot != nil)")
        #endif
        guard let viewport, viewport.isValid else { return nil }
        return GraphDemotionResult(
            boardID: demotingGraph.owningBoardID,
            graphID: demotingGraph.id,
            viewport: viewport
        )
    }

    private func replaceActiveGraphAfterDemotion() async {
        if let result = await demote(reason: .replaced) {
            onForcedViewportCommit(result.boardID, result.graphID, result.viewport)
        }
        guard let replacement = pendingReplacement else {
            replacementTask = nil
            return
        }
        pendingReplacement = nil
        displayGraph = replacement
        wantsInteractivePresentation = hostView != nil
            && !lifecycleSuspendsInteractivePresentation
        replacementTask = nil
        schedulePromotionIfReady()
    }

    private func captureSnapshot(from provider: GraphRendererProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let race = GraphSnapshotRace(continuation: continuation)
            race.snapshotTask = Task { @MainActor in
                let image = try? await provider.captureSnapshot()
                race.resolve(image)
            }
            race.timeoutTask = Task { @MainActor [snapshotTimeoutNanoseconds] in
                try? await Task.sleep(nanoseconds: snapshotTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                race.resolve(nil)
            }
        }
    }

    private func handleCoordinatorPreemption() async {
        if let result = await demote(reason: .replaced) {
            onForcedViewportCommit(result.boardID, result.graphID, result.viewport)
        }
    }

    func hostDidLayout(_ bounds: CGRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        schedulePromotionIfReady()
        guard let provider else { return }
        provider.view.frame = bounds
        guard lastLayoutSize != bounds.size else { return }
        lastLayoutSize = bounds.size
        guard let resizable = provider as? GraphResizableRendererProvider else { return }
        Task { @MainActor in
            try? await GraphProviderOperationDeadline.run(before: 2_000_000_000) {
                try await resizable.resize(to: bounds)
            }
        }
    }

    private func schedulePromotionIfReady() {
        guard wantsInteractivePresentation,
              representationState == .proxy,
              promotionTask == nil,
              let hostView,
              hostView.bounds.width > 1,
              hostView.bounds.height > 1 else { return }
        generation += 1
        let requestedGeneration = generation
        promotionTask = Task { @MainActor [weak self] in
            await self?.promote(generation: requestedGeneration)
            if self?.generation == requestedGeneration {
                self?.promotionTask = nil
            }
        }
    }

    private func promote(generation requestedGeneration: Int) async {
        let startedAt = CACurrentMediaTime()
        guard requestedGeneration == generation,
              wantsInteractivePresentation,
              let hostView,
              hostView.bounds.width > 1,
              hostView.bounds.height > 1 else { return }

        promotionStartedAt = startedAt
        promotionGeneration = requestedGeneration
        providerIdentifier = "none"
        recordPromotionStage(.checkingConfiguration,
                             generation: requestedGeneration)
        GraphPromotionDiagnostics.record(
            "GRAPH PROMOTION START graphID=\(displayGraph.id) provider=checking "
            + "sessionGeneration=\(requestedGeneration)"
        )

        if let provider,
           coordinator.activeProvider === provider,
           coordinator.activeGraphID == displayGraph.id {
            hostView.install(provider.view)
            recordPromotionStage(.ready, generation: requestedGeneration,
                                 providerID: ObjectIdentifier(provider))
            transition(to: .interactive)
            return
        }

        guard let nextProvider = providerFactory() else {
            wantsInteractivePresentation = false
            promotionStage = .failed
            transition(to: .failed)
            providerError = "Interactive graph isn’t configured in this build."
            GraphPromotionDiagnostics.record(
                "GRAPH PROMOTION FAILED graphID=\(displayGraph.id) provider=none "
                + "sessionGeneration=\(requestedGeneration) stage=checking_configuration "
                + "errorCategory=missing_configuration elapsedMs="
                + String(format: "%.1f", promotionElapsedSeconds * 1_000)
            )
            return
        }

        invalidateProviderUpdates()
        provider = nextProvider
        providerIdentifier = nextProvider.identifier
        let nextProviderID = ObjectIdentifier(nextProvider)
        recordPromotionStage(.providerCreated, generation: requestedGeneration,
                             providerID: nextProviderID)
        if let reporting = nextProvider as? GraphProviderLifecycleReporting {
            reporting.lifecycleEventHandler = { [weak self] stage in
                self?.recordPromotionStage(
                    stage, generation: requestedGeneration,
                    providerID: nextProviderID
                )
            }
        }
        transition(to: .promoting)
        providerError = nil
        nextProvider.view.alpha = 0
        hostView.install(nextProvider.view)

        do {
            var appliedGraph = displayGraph
            // Record the canonical value handed to mount before entering the
            // provider. A cancellation-aware handoff may return before mount
            // or activation does; demotion still needs to distinguish that
            // input from a newer canonical Reset View.
            lastProviderAppliedGraph = appliedGraph
            try await coordinator.promote(graph: appliedGraph,
                                          provider: nextProvider,
                                          frame: hostView.bounds,
                                          onPreempt: { [weak self] in
                                              await self?.handleCoordinatorPreemption()
                                          },
                                          onStage: { [weak self] stage in
                                              self?.recordPromotionStage(
                                                  stage,
                                                  generation: requestedGeneration,
                                                  providerID: nextProviderID
                                              )
                                          })
            // The provider now owns this exact canonical input even if a
            // concurrent Done/background request made the promotion stale.
            // Demotion uses this provenance to distinguish a genuine newer
            // Reset View from the provider's final interactive viewport.
            lastProviderAppliedGraph = appliedGraph
            guard requestedGeneration == generation,
                  wantsInteractivePresentation else {
                await cleanUpOrHandOffStalePromotion(
                    nextProvider, from: hostView
                )
                return
            }
            // The provider mount can wait behind another graph's demotion.
            // Reconcile same-ID edits or Reset View changes that arrived while
            // queued before exposing the provider as interactive.
            while appliedGraph != displayGraph {
                let latestGraph = displayGraph
                try await GraphProviderOperationDeadline.run(
                    before: 3_000_000_000
                ) {
                    try await nextProvider.update(graph: latestGraph)
                }
                appliedGraph = latestGraph
                guard requestedGeneration == generation,
                      wantsInteractivePresentation,
                      provider === nextProvider else {
                    await cleanUpOrHandOffStalePromotion(
                        nextProvider, from: hostView
                    )
                    return
                }
            }
            lastProviderAppliedGraph = appliedGraph
            nextProvider.view.frame = hostView.bounds
            UIView.animate(withDuration: 0.16) { nextProvider.view.alpha = 1 }
            recordPromotionStage(.ready, generation: requestedGeneration,
                                 providerID: nextProviderID)
            transition(to: .interactive)
            let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            GraphPromotionDiagnostics.record(
                "GRAPH PROMOTION COMPLETE graphID=\(displayGraph.id) "
                + "provider=\(nextProvider.identifier) sessionGeneration=\(requestedGeneration) "
                + "totalMs=\(String(format: "%.1f", elapsedMilliseconds)) "
                + "activeProviders=\(coordinator.activeProviderCount)"
            )
        } catch {
            // A cancelled/expired provider operation can finish late, but the
            // active demotion now owns the provider lease. Let that one path
            // perform bounded viewport readback and the sole physical unmount.
            if activeDemotionID != nil, provider === nextProvider {
                return
            }
            await failProvider(error, expectedProvider: nextProvider)
        }
    }

    /// A demotion that cancelled this promotion owns final readback, proxy
    /// capture, and unmount. Leave the now-active provider installed so the
    /// joined demotion can finalize it exactly once. Other stale promotions
    /// still release themselves immediately.
    private func cleanUpOrHandOffStalePromotion(
        _ staleProvider: GraphRendererProvider,
        from hostView: GraphProviderContainerView
    ) async {
        if activeDemotionID != nil, provider === staleProvider {
            return
        }
        stopLifecycleReporting(for: staleProvider)
        if coordinator.activeProvider === staleProvider {
            _ = await coordinator.demote()
        } else {
            staleProvider.unmount()
        }
        hostView.removeProviderView(staleProvider.view)
        if provider === staleProvider { provider = nil }
    }

    private func failProvider(_ error: Error,
                              expectedProvider: GraphRendererProvider? = nil) async {
        if let expectedProvider, provider !== expectedProvider {
            stopLifecycleReporting(for: expectedProvider)
            if coordinator.activeProvider === expectedProvider {
                _ = await coordinator.demote()
            } else if expectedProvider.view.superview != nil {
                // A bounded demotion may already have physically removed this
                // cancellation-ignoring provider before its late mount task
                // returns. Do not finalize the same instance twice.
                expectedProvider.unmount()
            }
            hostView?.removeProviderView(expectedProvider.view)
            return
        }
        invalidateProviderUpdates()
        let failedProvider = provider
        let failedStage = promotionStage
        stopLifecycleReporting(for: failedProvider)
        if let failedProvider, coordinator.activeProvider === failedProvider {
            _ = await coordinator.demote()
        } else {
            failedProvider?.unmount()
        }
        if let failedProvider { hostView?.removeProviderView(failedProvider.view) }
        provider = nil
        lastProviderAppliedGraph = nil
        wantsInteractivePresentation = false
        promotionStage = .failed
        transition(to: .failed)
        providerError = "Interactive graph couldn’t open."
        GraphPromotionDiagnostics.record(
            "GRAPH PROMOTION FAILED graphID=\(displayGraph.id) "
            + "provider=\(providerIdentifier) sessionGeneration=\(promotionGeneration) "
            + "stage=\(failedStage.rawValue) "
            + "errorCategory=\(promotionFailureCategory(for: error)) elapsedMs="
            + String(format: "%.1f", promotionElapsedSeconds * 1_000)
        )
    }

    private func enqueueProviderUpdate(_ graph: GraphObject,
                                       provider expectedProvider: GraphRendererProvider) {
        pendingProviderUpdate = graph
        guard providerUpdateTask == nil else { return }
        let requestedEpoch = providerEpoch
        providerUpdateTask = Task { @MainActor [weak self] in
            await self?.drainProviderUpdates(
                expectedProvider: expectedProvider,
                requestedEpoch: requestedEpoch
            )
        }
    }

    private func drainProviderUpdates(expectedProvider: GraphRendererProvider,
                                      requestedEpoch: Int) async {
        defer {
            if providerEpoch == requestedEpoch { providerUpdateTask = nil }
        }
        while providerEpoch == requestedEpoch,
              provider === expectedProvider,
              coordinator.activeProvider === expectedProvider,
              coordinator.activeGraphID == displayGraph.id,
              representationState == .interactive,
              let graph = pendingProviderUpdate {
            pendingProviderUpdate = nil
            do {
                try await GraphProviderOperationDeadline.run(
                    before: 3_000_000_000
                ) {
                    try await expectedProvider.update(graph: graph)
                }
                if providerEpoch == requestedEpoch,
                   provider === expectedProvider {
                    lastProviderAppliedGraph = graph
                }
            } catch {
                // Ownership can change while an asynchronous provider call is
                // suspended. A late failure from the released provider must
                // never tear down its replacement.
                guard providerEpoch == requestedEpoch,
                      provider === expectedProvider else { return }
                await failProvider(error, expectedProvider: expectedProvider)
                return
            }
        }
    }

    private func invalidateProviderUpdates() {
        providerEpoch &+= 1
        pendingProviderUpdate = nil
        providerUpdateTask?.cancel()
        providerUpdateTask = nil
    }
}

/// An unstructured race is deliberate here. Structured task groups wait for a
/// cancelled child before returning, which means a wedged third-party web
/// snapshot could still block Done/Edit forever. Both completions are confined
/// to MainActor and this gate resumes its caller exactly once.
@MainActor
private final class GraphSnapshotRace {
    private var continuation: CheckedContinuation<UIImage?, Never>?
    var snapshotTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func resolve(_ image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        let taskToCancel = image == nil ? snapshotTask : timeoutTask
        snapshotTask = nil
        timeoutTask = nil
        taskToCancel?.cancel()
        continuation.resume(returning: image)
    }
}

/// Interactive graph presentation used by board/lecture containers. It is
/// intentionally provider-independent at its boundary: Done commits only a
/// canonical viewport, while Edit delegates semantic expression changes to the
/// owning feature.
@MainActor
struct GraphInteractiveSurface: View {
    let graph: GraphObject
    let canonicalStrokeObjects: [CanvasObject]
    let pencilAnnotationEnabled: Bool
    let pencilStyle: CanvasStrokeStyle
    let pencilPreferences: PencilPreferences
    let onPencilStroke: (UserStroke) -> Void
    let onPencilRequestsPassiveMode: () -> Void
    let onCommitViewport: (String, String, GraphViewport) -> Void
    let onEdit: () -> Void
    let onDone: () -> Void

    @StateObject private var session: GraphInteractiveSession
    @State private var isClosing = false
    @State private var shouldResumeAfterBackground = false

    init(graph: GraphObject,
         canonicalStrokeObjects: [CanvasObject] = [],
         pencilAnnotationEnabled: Bool,
         pencilStyle: CanvasStrokeStyle = .pen,
         pencilPreferences: PencilPreferences = .defaults,
         onPencilStroke: @escaping (UserStroke) -> Void = { _ in },
         onPencilRequestsPassiveMode: @escaping () -> Void,
         onCommitViewport: @escaping (String, String, GraphViewport) -> Void,
         onEdit: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.init(
            graph: graph,
            coordinator: GraphProviderEnvironment.sharedCoordinator,
            providerFactory: { GraphProviderEnvironment.makeConfiguredProvider() },
            canonicalStrokeObjects: canonicalStrokeObjects,
            pencilAnnotationEnabled: pencilAnnotationEnabled,
            pencilStyle: pencilStyle,
            pencilPreferences: pencilPreferences,
            onPencilStroke: onPencilStroke,
            onPencilRequestsPassiveMode: onPencilRequestsPassiveMode,
            onCommitViewport: onCommitViewport,
            onEdit: onEdit,
            onDone: onDone
        )
    }

    init(graph: GraphObject,
         coordinator: GraphProviderCoordinator,
         providerFactory: @escaping GraphInteractiveSession.ProviderFactory,
         canonicalStrokeObjects: [CanvasObject] = [],
         pencilAnnotationEnabled: Bool,
         pencilStyle: CanvasStrokeStyle = .pen,
         pencilPreferences: PencilPreferences = .defaults,
         onPencilStroke: @escaping (UserStroke) -> Void = { _ in },
         onPencilRequestsPassiveMode: @escaping () -> Void,
         onCommitViewport: @escaping (String, String, GraphViewport) -> Void,
         onEdit: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        _session = StateObject(wrappedValue: GraphInteractiveSession(
            graph: graph, coordinator: coordinator,
            onForcedViewportCommit: onCommitViewport,
            providerFactory: providerFactory
        ))
        self.graph = graph
        self.canonicalStrokeObjects = canonicalStrokeObjects
        self.pencilAnnotationEnabled = pencilAnnotationEnabled
        self.pencilStyle = pencilStyle
        self.pencilPreferences = pencilPreferences
        self.onPencilStroke = onPencilStroke
        self.onPencilRequestsPassiveMode = onPencilRequestsPassiveMode
        self.onCommitViewport = onCommitViewport
        self.onEdit = onEdit
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            GraphNativeFallbackSurface(graph: session.displayGraph)
                .opacity(session.representationState == .interactive ? 0 : 1)

            GraphProviderHost(session: session, graph: session.displayGraph,
                              canonicalStrokeObjects: canonicalStrokeObjects,
                              pencilAnnotationEnabled: pencilAnnotationEnabled,
                              pencilStyle: pencilStyle,
                              pencilPreferences: pencilPreferences,
                              onPencilStroke: onPencilStroke,
                              onPencilRequestsPassiveMode: onPencilRequestsPassiveMode)
                .opacity(session.representationState == .interactive ? 1 : 0)
                .allowsHitTesting(session.representationState == .interactive)

            if session.representationState == .promoting {
                ProgressView("Opening interactive graph…")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
            }

            if session.representationState == .failed,
               let providerError = session.providerError {
                VStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Label(providerError, systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.semibold))
                        Text("Your graph is still saved and usable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Retry") {
                                session.retryInteractivePresentation()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("graph-interactive-retry")

                            Button("Dismiss") {
                                finish(editing: false)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("graph-interactive-dismiss")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 14,
                                                     style: .continuous))
                        .padding(.bottom, 58)
                }
            }

            #if DEBUG
            if session.representationState == .promoting
                || session.representationState == .failed {
                VStack {
                    Spacer()
                    HStack {
                        GraphPromotionDebugStatus(session: session)
                        Spacer()
                    }
                    .padding(10)
                }
                .allowsHitTesting(false)
            }
            #endif

            VStack {
                HStack(spacing: 10) {
                    Button("Edit", systemImage: "pencil") {
                        finish(editing: true)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Reset View", systemImage: "scope") {
                        session.resetView()
                    }
                    .buttonStyle(.bordered)

                    Button("Done") {
                        finish(editing: false)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.ultraThinMaterial)

                Spacer()
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.16), value: session.representationState)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(GraphAccessibility.label(for: session.displayGraph))
        .onAppear { session.requestInteractivePresentation() }
        .onChange(of: graph) { _, updatedGraph in
            session.update(graph: updatedGraph)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )) { _ in
            shouldResumeAfterBackground = true
            lifecycleDemote(reason: .background)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            guard shouldResumeAfterBackground, !isClosing else { return }
            shouldResumeAfterBackground = false
            Task { @MainActor in
                await session.resumeInteractivePresentationAfterLifecycleDemotion()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in lifecycleDemote(reason: .memoryPressure) }
        .onDisappear { lifecycleDemote(reason: .disappeared) }
    }

    private func finish(editing: Bool) {
        guard !isClosing else { return }
        isClosing = true
        Task { @MainActor in
            if let result = await session.demote(reason: editing ? .edit : .done) {
                onCommitViewport(result.boardID, result.graphID, result.viewport)
            } else {
                onCommitViewport(session.displayGraph.owningBoardID,
                                 session.displayGraph.id, session.displayGraph.viewport)
            }
            if editing { onEdit() } else { onDone() }
        }
    }

    private func lifecycleDemote(reason: GraphProviderDemotionReason) {
        Task { @MainActor in
            if let result = await session.demote(reason: reason) {
                onCommitViewport(result.boardID, result.graphID, result.viewport)
            }
            if reason == .memoryPressure {
                GraphProxyCache.shared.removeAll()
            }
        }
    }
}

#if DEBUG
private struct GraphPromotionDebugStatus: View {
    @ObservedObject var session: GraphInteractiveSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                Text("State: \(session.representationState.rawValue.uppercased())")
                Text("Stage: \(session.promotionStage.rawValue)")
                Text("Elapsed: \(session.promotionElapsedSeconds, format: .number.precision(.fractionLength(1)))s")
                Text("Generation: \(session.promotionGeneration)")
                Text("Provider: \(session.providerIdentifier)")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(7)
            .background(.thinMaterial,
                        in: RoundedRectangle(cornerRadius: 8,
                                             style: .continuous))
        }
    }
}
#endif

@MainActor
final class GraphProviderContainerView: UIView {
    weak var session: GraphInteractiveSession?
    private lazy var pencilRecognizer = GraphPencilStrokeRecognizer(
        target: self, action: #selector(handlePencilStroke(_:))
    )
    private var graph: GraphObject?
    private var pencilAnnotationEnabled = true
    private var pencilStyle: CanvasStrokeStyle = .pen
    private var pencilPreferences: PencilPreferences = .defaults
    private let pencilHoverLayer = CAShapeLayer()
    private var onPencilStroke: ((UserStroke) -> Void)?
    private var onPencilRequestsPassiveMode: (() -> Void)?
    private var activePencilPoints: [StrokePoint] = []
    private var pencilAccumulator = PencilStrokeAccumulator()
    private var activePencilStyle: CanvasStrokeStyle?
    private var activePencilLayer: CAShapeLayer?
    private var completedPencilLayers: [String: CAShapeLayer] = [:]
    private var completedPencilStrokes: [String: UserStroke] = [:]
    private var completedPencilOrder: [String] = []
    private var recentlyCommittedPencilStroke: UserStroke?
    private var canonicalPencilLayers: [String: CAShapeLayer] = [:]
    private var canonicalStrokeObjects: [String: CanvasObject] = [:]
    private var canonicalStrokeOrder: [String] = []
    private var configuredGraphID: String?
    private var rejectsCurrentPencilSequence = false
    #if DEBUG
    private let pencilRawMonitor = PencilRawEventMonitor(owner: "GraphProviderContainerView")
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        pencilRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilRecognizer.cancelsTouchesInView = true
        pencilRecognizer.delaysTouchesBegan = false
        pencilRecognizer.requiresExclusiveTouchType = true
        pencilRecognizer.estimatedCorrectionHandler = { [weak self] corrections in
            self?.applyLateEstimatedCorrections(corrections)
        }
        addGestureRecognizer(pencilRecognizer)
        pencilHoverLayer.fillColor = UIColor.clear.cgColor
        pencilHoverLayer.strokeColor = UIColor.label.withAlphaComponent(0.62).cgColor
        pencilHoverLayer.lineWidth = 1
        pencilHoverLayer.zPosition = 11_000
        pencilHoverLayer.isHidden = true
        layer.addSublayer(pencilHoverLayer)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePencilHover(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        addGestureRecognizer(hover)
        #if DEBUG
        pencilRecognizer.rawMonitor = pencilRawMonitor
        // Graph lifecycle tests intentionally require the provider container
        // to have no extra subviews. Keep this canvas-like responder visible
        // in the shared PENCIL_RAW console stream without adding an overlay.
        pencilRawMonitor.setContext(tool: "graph-annotation", state: "IDLE")
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
        pencilHoverLayer.frame = bounds
        renderPencilLayers()
        session?.hostDidLayout(bounds)
    }

    func configure(graph: GraphObject, pencilAnnotationEnabled: Bool,
                   pencilStyle: CanvasStrokeStyle,
                   pencilPreferences: PencilPreferences = .defaults,
                   canonicalStrokeObjects: [CanvasObject],
                   onPencilStroke: @escaping (UserStroke) -> Void,
                   onPencilRequestsPassiveMode: @escaping () -> Void) {
        if configuredGraphID != graph.id {
            cancelPencilStroke()
            completedPencilLayers.values.forEach { $0.removeFromSuperlayer() }
            completedPencilLayers.removeAll(keepingCapacity: false)
            completedPencilStrokes.removeAll(keepingCapacity: false)
            completedPencilOrder.removeAll(keepingCapacity: false)
            recentlyCommittedPencilStroke = nil
            canonicalPencilLayers.values.forEach { $0.removeFromSuperlayer() }
            canonicalPencilLayers.removeAll(keepingCapacity: false)
            self.canonicalStrokeObjects.removeAll(keepingCapacity: false)
            canonicalStrokeOrder.removeAll(keepingCapacity: false)
            configuredGraphID = graph.id
        }
        var visibleCanonical: [String: CanvasObject] = [:]
        var visibleOrder: [String] = []
        for object in canonicalStrokeObjects
            where !(object.points ?? []).isEmpty
                && GraphAnnotationOverlayPolicy.strokeIntersectsGraph(
                    object, graphFrame: graph.frame.cgRect
                ) {
            // The editor contract requires stable, unique object IDs. Keep the
            // first instance defensively so malformed future state cannot turn
            // an interactive graph presentation into a dictionary trap.
            if visibleCanonical[object.id] == nil {
                visibleCanonical[object.id] = object
                visibleOrder.append(object.id)
            }
        }
        for id in Array(completedPencilStrokes.keys) where visibleCanonical[id] != nil {
            completedPencilLayers.removeValue(forKey: id)?.removeFromSuperlayer()
            completedPencilStrokes.removeValue(forKey: id)
            completedPencilOrder.removeAll(where: { $0 == id })
        }
        for id in Array(self.canonicalStrokeObjects.keys) where visibleCanonical[id] == nil {
            canonicalPencilLayers.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        for (id, object) in visibleCanonical where self.canonicalStrokeObjects[id] != object {
            canonicalPencilLayers.removeValue(forKey: id)?.removeFromSuperlayer()
            let strokeLayer = makePencilLayer(name: "graph-canonical-pencil:\(id)",
                                              zPosition: 9_000)
            canonicalPencilLayers[id] = strokeLayer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.addSublayer(strokeLayer)
            CATransaction.commit()
        }
        self.canonicalStrokeObjects = visibleCanonical
        canonicalStrokeOrder = visibleOrder
        self.graph = graph
        self.pencilAnnotationEnabled = pencilAnnotationEnabled
        self.pencilStyle = pencilStyle
        self.pencilPreferences = pencilPreferences
        self.onPencilStroke = onPencilStroke
        self.onPencilRequestsPassiveMode = onPencilRequestsPassiveMode
        #if DEBUG
        pencilRawMonitor.setContext(
            tool: pencilAnnotationEnabled ? "graph-annotation" : "graph-passive-request",
            state: activePencilPoints.isEmpty ? "IDLE" : "DRAWING"
        )
        #endif
        renderPencilLayers()
    }

    @objc private func handlePencilHover(_ recognizer: UIHoverGestureRecognizer) {
        #if DEBUG
        pencilRawMonitor.recordHover(recognizer, in: self)
        #endif
        let showsPreview: Bool
        switch pencilPreferences.hover {
        case .off: showsPreview = false
        case .on: showsPreview = true
        case .followSystem:
            if #available(iOS 17.5, *) { showsPreview = UIPencilInteraction.prefersHoverToolPreview }
            else { showsPreview = true }
        }
        guard showsPreview, recognizer.state == .began || recognizer.state == .changed else {
            pencilHoverLayer.path = nil
            pencilHoverLayer.isHidden = true
            return
        }
        let point = recognizer.location(in: self)
        let path = UIBezierPath()
        if pencilTool(for: pencilStyle) == .marker {
            let roll: CGFloat?
            if #available(iOS 17.5, *) { roll = recognizer.rollAngle } else { roll = nil }
            let nib = PencilNibGeometry.marker(baseWidth: CGFloat(pencilStyle.width),
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
        } else {
            let radius = max(2.5, CGFloat(pencilStyle.width) / 2)
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)))
        }
        pencilHoverLayer.path = path.cgPath
        pencilHoverLayer.isHidden = false
    }

    func install(_ providerView: UIView) {
        guard providerView.superview !== self else {
            providerView.frame = bounds
            return
        }
        subviews.forEach { $0.removeFromSuperview() }
        providerView.frame = bounds
        providerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(providerView)
    }

    func removeProviderView(_ providerView: UIView) {
        guard providerView.superview === self else { return }
        providerView.removeFromSuperview()
    }

    @objc private func handlePencilStroke(_ recognizer: GraphPencilStrokeRecognizer) {
        let hasAcceptedSequence = activePencilStyle != nil
            || activePencilLayer != nil || !activePencilPoints.isEmpty
        if !pencilAnnotationEnabled && !hasAcceptedSequence {
            if recognizer.state == .began {
                rejectsCurrentPencilSequence = true
                onPencilRequestsPassiveMode?()
            } else if recognizer.state == .ended || recognizer.state == .cancelled
                        || recognizer.state == .failed {
                rejectsCurrentPencilSequence = false
            }
            cancelPencilStroke()
            return
        }
        if rejectsCurrentPencilSequence {
            if recognizer.state == .ended || recognizer.state == .cancelled
                || recognizer.state == .failed {
                rejectsCurrentPencilSequence = false
            }
            return
        }
        guard let graph, bounds.width > 0, bounds.height > 0 else {
            cancelPencilStroke()
            return
        }
        switch recognizer.state {
        case .began:
            recentlyCommittedPencilStroke = nil
            activePencilPoints.removeAll(keepingCapacity: true)
            pencilAccumulator.reset()
            activePencilStyle = pencilStyle
            let strokeLayer = CAShapeLayer()
            strokeLayer.frame = bounds
            strokeLayer.fillColor = UIColor(svgHex: pencilStyle.colorHex)
                .withAlphaComponent(pencilStyle.opacity).cgColor
            strokeLayer.zPosition = 10_000
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.addSublayer(strokeLayer)
            CATransaction.commit()
            activePencilLayer = strokeLayer
            consumePencilSamples(recognizer, graph: graph)
        case .changed:
            consumePencilSamples(recognizer, graph: graph)
        case .ended:
            consumePencilSamples(recognizer, graph: graph)
            finalizeActivePencilStroke()
        case .cancelled, .failed:
            cancelPencilStroke()
        default:
            break
        }
    }

    private func consumePencilSamples(_ recognizer: GraphPencilStrokeRecognizer,
                                      graph: GraphObject) {
        let confirmed = recognizer.samples.compactMap { sample -> StrokePoint? in
            guard sample.point.x.isFinite, sample.point.y.isFinite else { return nil }
            return GraphPencilCoordinateMapper.strokePoint(
                localPoint: sample.point, in: bounds, graphFrame: graph.frame,
                pressure: sample.pressure, altitude: sample.altitude,
                azimuth: sample.azimuth, roll: sample.roll,
                timestamp: sample.timestamp,
                estimationUpdateIndex: sample.estimationUpdateIndex
            )
        }
        pencilAccumulator.appendConfirmed(confirmed)
        let corrections = recognizer.estimatedCorrections.compactMap { sample -> StrokePoint? in
            guard sample.point.x.isFinite, sample.point.y.isFinite else { return nil }
            return GraphPencilCoordinateMapper.strokePoint(
                localPoint: sample.point, in: bounds, graphFrame: graph.frame,
                pressure: sample.pressure, altitude: sample.altitude,
                azimuth: sample.azimuth, roll: sample.roll,
                timestamp: sample.timestamp,
                estimationUpdateIndex: sample.estimationUpdateIndex
            )
        }
        pencilAccumulator.replaceEstimated(corrections)
        let predicted = recognizer.predictedSamples.compactMap { sample -> StrokePoint? in
            guard sample.point.x.isFinite, sample.point.y.isFinite else { return nil }
            return GraphPencilCoordinateMapper.strokePoint(
                localPoint: sample.point, in: bounds, graphFrame: graph.frame,
                pressure: sample.pressure, altitude: sample.altitude,
                azimuth: sample.azimuth, roll: sample.roll,
                timestamp: sample.timestamp,
                estimationUpdateIndex: sample.estimationUpdateIndex
            )
        }
        pencilAccumulator.setPredicted(predicted)
        activePencilPoints = pencilAccumulator.canonicalPoints
        renderActivePencilLayer()
    }

    private func cancelPencilStroke() {
        activePencilLayer?.removeFromSuperlayer()
        activePencilLayer = nil
        activePencilPoints.removeAll(keepingCapacity: true)
        pencilAccumulator.reset()
        activePencilStyle = nil
    }

    /// Preserve an in-flight valid annotation if SwiftUI removes the provider
    /// surface (Done, tool change, outside dismissal) before UIKit delivers the
    /// final Pencil-up callback.
    func finalizeActivePencilStroke() {
        guard !rejectsCurrentPencilSequence, !activePencilPoints.isEmpty else {
            cancelPencilStroke()
            return
        }
        let points = activePencilPoints
        let style = activePencilStyle ?? pencilStyle
        let strokeLayer = activePencilLayer
        activePencilLayer = nil
        activePencilPoints.removeAll(keepingCapacity: true)
        pencilAccumulator.reset()
        activePencilStyle = nil
        let finalized = UserStroke(
            id: "stroke-" + UUID().uuidString.lowercased(),
            color: style.colorHex, width: style.width, opacity: style.opacity,
            points: points, pencilTool: pencilTool(for: style)
        )
        recentlyCommittedPencilStroke = finalized
        if let strokeLayer {
            strokeLayer.name = "graph-pencil:\(finalized.id)"
            completedPencilLayers[finalized.id] = strokeLayer
            completedPencilStrokes[finalized.id] = finalized
            completedPencilOrder.append(finalized.id)
        }
        onPencilStroke?(finalized)
    }

    private func applyLateEstimatedCorrections(_ samples: [GraphPencilSample]) {
        guard let graph, let recent = recentlyCommittedPencilStroke else { return }
        let corrections = samples.compactMap { sample -> StrokePoint? in
            guard sample.point.x.isFinite, sample.point.y.isFinite else { return nil }
            return GraphPencilCoordinateMapper.strokePoint(
                localPoint: sample.point, in: bounds, graphFrame: graph.frame,
                pressure: sample.pressure, altitude: sample.altitude,
                azimuth: sample.azimuth, roll: sample.roll,
                timestamp: sample.timestamp,
                estimationUpdateIndex: sample.estimationUpdateIndex
            )
        }
        guard let corrected = PencilStrokeCorrection.applying(corrections, to: recent) else {
            return
        }
        recentlyCommittedPencilStroke = corrected
        if completedPencilStrokes[corrected.id] != nil {
            completedPencilStrokes[corrected.id] = corrected
            renderPencilLayers()
        }
        onPencilStroke?(corrected)
    }

    private func renderPencilLayers() {
        guard let graph, bounds.width > 0, bounds.height > 0 else { return }
        renderActivePencilLayer()
        let canonicalStep = 500 / CGFloat(max(canonicalStrokeOrder.count, 1))
        for (index, id) in canonicalStrokeOrder.enumerated() {
            guard let object = canonicalStrokeObjects[id],
                  let strokeLayer = canonicalPencilLayers[id] else { continue }
            strokeLayer.zPosition = 9_000 + CGFloat(index) * canonicalStep
            configure(strokeLayer, for: object, graph: graph)
        }
        let completedStep = 400 / CGFloat(max(completedPencilOrder.count, 1))
        for (index, id) in completedPencilOrder.enumerated() {
            guard let stroke = completedPencilStrokes[id],
                  let strokeLayer = completedPencilLayers[id] else { continue }
            strokeLayer.zPosition = 9_500 + CGFloat(index) * completedStep
            configure(strokeLayer, for: stroke, graph: graph)
        }
    }

    private func renderActivePencilLayer() {
        guard let graph, let activePencilLayer else { return }
        let style = activePencilStyle ?? pencilStyle
        let stroke = UserStroke(
            id: "live", color: style.colorHex, width: style.width,
            opacity: style.opacity, points: pencilAccumulator.livePoints,
            pencilTool: pencilTool(for: style)
        )
        configure(activePencilLayer, for: stroke, graph: graph)
    }

    private func configure(_ strokeLayer: CAShapeLayer, for stroke: UserStroke,
                           graph: GraphObject) {
        strokeLayer.frame = bounds
        let color = UIColor(svgHex: stroke.color).withAlphaComponent(stroke.opacity).cgColor
        let xScale = bounds.width / CGFloat(max(graph.frame.width, 0.001))
        let yScale = bounds.height / CGFloat(max(graph.frame.height, 0.001))
        let renderScale = min(xScale, yScale)
        let path = UIBezierPath()
        let localSamples = stroke.points.map { sample -> StrokePoint in
            let point = GraphPencilCoordinateMapper.localPoint(
                strokePoint: sample, in: bounds, graphFrame: graph.frame
            )
            return StrokePoint(x: point.x, y: point.y, pressure: sample.pressure,
                               altitude: sample.altitude, azimuth: sample.azimuth,
                               roll: sample.roll, timestamp: sample.timestamp,
                               estimationUpdateIndex: sample.estimationUpdateIndex)
        }
        let localPoints = localSamples.map { CGPoint(x: $0.x, y: $0.y) }
        if let first = localPoints.first {
            path.move(to: first)
            if localPoints.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y + 0.01))
            } else {
                for point in localPoints.dropFirst() { path.addLine(to: point) }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let pencilTool = stroke.pencilTool {
            strokeLayer.path = PencilStrokeGeometry.path(points: localSamples,
                                                         tool: pencilTool,
                                                         baseWidth: CGFloat(stroke.width) * renderScale)
            strokeLayer.fillColor = color
            strokeLayer.strokeColor = nil
        } else {
            strokeLayer.path = path.cgPath
            strokeLayer.fillColor = UIColor.clear.cgColor
            strokeLayer.strokeColor = color
            strokeLayer.lineWidth = CGFloat(stroke.width) * renderScale
            strokeLayer.lineCap = .round
            strokeLayer.lineJoin = .round
        }
        CATransaction.commit()
    }

    private func configure(_ strokeLayer: CAShapeLayer, for object: CanvasObject,
                           graph: GraphObject) {
        let translation = object.translation ?? WorldPoint(x: 0, y: 0, pressure: nil)
        let scaleX = object.scaleX ?? 1
        let scaleY = object.scaleY ?? 1
        let points = (object.points ?? []).map {
            StrokePoint(
                x: $0.x * scaleX + translation.x,
                y: $0.y * scaleY + translation.y,
                pressure: $0.pressure, altitude: $0.altitude, azimuth: $0.azimuth,
                roll: $0.roll, timestamp: $0.timestamp,
                estimationUpdateIndex: $0.estimationUpdateIndex
            )
        }
        configure(
            strokeLayer,
            for: UserStroke(
                id: object.id, color: object.color ?? "#183153",
                width: (object.width ?? 4) * sqrt(abs(scaleX * scaleY)),
                opacity: object.opacity ?? 1, points: points,
                pencilTool: object.pencilTool
            ),
            graph: graph
        )
    }

    private func makePencilLayer(name: String, zPosition: CGFloat) -> CAShapeLayer {
        let strokeLayer = CAShapeLayer()
        strokeLayer.name = name
        strokeLayer.frame = bounds
        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        strokeLayer.zPosition = zPosition
        return strokeLayer
    }

    private func pencilTool(for style: CanvasStrokeStyle) -> PencilStrokeTool {
        style.opacity < 0.95 ? .marker : .pen
    }
}

enum GraphPencilCoordinateMapper {
    static func strokePoint(localPoint: CGPoint, in bounds: CGRect,
                            graphFrame: GraphFrame, pressure: Double?,
                            altitude: Double? = nil, azimuth: Double? = nil,
                            roll: Double? = nil, timestamp: Double? = nil,
                            estimationUpdateIndex: Int? = nil) -> StrokePoint {
        let width = max(bounds.width, 0.001)
        let height = max(bounds.height, 0.001)
        return StrokePoint(
            x: graphFrame.x + Double((localPoint.x - bounds.minX) / width) * graphFrame.width,
            y: graphFrame.y + Double((localPoint.y - bounds.minY) / height) * graphFrame.height,
            pressure: pressure.map { min(1, max(0, $0.isFinite ? $0 : 0)) },
            altitude: altitude, azimuth: azimuth, roll: roll, timestamp: timestamp,
            estimationUpdateIndex: estimationUpdateIndex
        )
    }

    static func localPoint(strokePoint: StrokePoint, in bounds: CGRect,
                           graphFrame: GraphFrame) -> CGPoint {
        CGPoint(
            x: bounds.minX + CGFloat((strokePoint.x - graphFrame.x) / graphFrame.width) * bounds.width,
            y: bounds.minY + CGFloat((strokePoint.y - graphFrame.y) / graphFrame.height) * bounds.height
        )
    }
}

private struct GraphPencilSample {
    let point: CGPoint
    let pressure: Double?
    let altitude: Double?
    let azimuth: Double?
    let roll: Double?
    let timestamp: Double
    let estimationUpdateIndex: Int?
}

/// An ancestor recognizer sees Pencil events whose hit-tested descendant is
/// WKContentView. Restricting the recognizer itself to `.pencil` lets fingers
/// and trackpads continue to interact with the provider while Pencil samples
/// stay in V-Board's canonical `UserStroke` pipeline.
private final class GraphPencilStrokeRecognizer: UIGestureRecognizer {
    private(set) var samples: [GraphPencilSample] = []
    private(set) var predictedSamples: [GraphPencilSample] = []
    private(set) var estimatedCorrections: [GraphPencilSample] = []
    var estimatedCorrectionHandler: (([GraphPencilSample]) -> Void)?
    #if DEBUG
    weak var rawMonitor: PencilRawEventMonitor?
    #endif

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else {
            state = .failed
            return
        }
        #if DEBUG
        if let view {
            rawMonitor?.recordTouch("BEGIN", touch: touch, event: event, in: view,
                                    tool: "graph-annotation", state: "IDLE")
        }
        #endif
        samples = mappedSamples(for: touch, event: event)
        predictedSamples = []
        estimatedCorrections = []
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        #if DEBUG
        if let view {
            rawMonitor?.recordTouch("MOVE", touch: touch, event: event, in: view,
                                    tool: "graph-annotation", state: "DRAWING")
        }
        #endif
        samples = mappedSamples(for: touch, event: event)
        predictedSamples = (event.predictedTouches(for: touch) ?? []).map(mappedSample(for:))
        estimatedCorrections = []
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else {
            state = .cancelled
            return
        }
        #if DEBUG
        if let view {
            rawMonitor?.recordTouch("END", touch: touch, event: event, in: view,
                                    tool: "graph-annotation", state: "DRAWING")
        }
        #endif
        samples = mappedSamples(for: touch, event: event)
        predictedSamples = []
        estimatedCorrections = []
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        #if DEBUG
        if let touch = touches.first, let view {
            rawMonitor?.recordTouch("CANCEL", touch: touch, event: event, in: view,
                                    tool: "graph-annotation", state: "DRAWING")
        }
        #endif
        samples = []
        predictedSamples = []
        estimatedCorrections = []
        state = .cancelled
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        #if DEBUG
        if let view { rawMonitor?.recordEstimatedUpdates(touches, in: view) }
        #endif
        estimatedCorrections = touches.filter { $0.type == .pencil }.map(mappedSample(for:))
        estimatedCorrectionHandler?(estimatedCorrections)
        samples = []
        predictedSamples = []
        if state == .began || state == .changed { state = .changed }
        super.touchesEstimatedPropertiesUpdated(touches)
    }

    override func reset() {
        super.reset()
        samples = []
        predictedSamples = []
        estimatedCorrections = []
    }

    private func mappedSamples(for touch: UITouch, event: UIEvent) -> [GraphPencilSample] {
        let source = event.coalescedTouches(for: touch) ?? [touch]
        return source.map(mappedSample(for:))
    }

    private func mappedSample(for sample: UITouch) -> GraphPencilSample {
        let pressure = PencilPressureResponse.normalized(force: sample.force,
                                                         maximum: sample.maximumPossibleForce)
        let roll: CGFloat?
        if #available(iOS 17.5, *) { roll = sample.rollAngle } else { roll = nil }
        return GraphPencilSample(point: sample.preciseLocation(in: view),
                                 pressure: pressure.map { Double($0) },
                                 altitude: Double(sample.altitudeAngle),
                                 azimuth: Double(sample.azimuthAngle(in: view)),
                                 roll: roll.map { Double($0) }, timestamp: sample.timestamp,
                                 estimationUpdateIndex: sample.estimationUpdateIndex?.intValue)
    }
}

@MainActor
private struct GraphProviderHost: UIViewRepresentable {
    @ObservedObject var session: GraphInteractiveSession
    let graph: GraphObject
    let canonicalStrokeObjects: [CanvasObject]
    let pencilAnnotationEnabled: Bool
    let pencilStyle: CanvasStrokeStyle
    let pencilPreferences: PencilPreferences
    let onPencilStroke: (UserStroke) -> Void
    let onPencilRequestsPassiveMode: () -> Void

    func makeUIView(context: Context) -> GraphProviderContainerView {
        let view = GraphProviderContainerView()
        view.session = session
        view.configure(graph: graph, pencilAnnotationEnabled: pencilAnnotationEnabled,
                       pencilStyle: pencilStyle,
                       pencilPreferences: pencilPreferences,
                       canonicalStrokeObjects: canonicalStrokeObjects,
                       onPencilStroke: onPencilStroke,
                       onPencilRequestsPassiveMode: onPencilRequestsPassiveMode)
        session.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: GraphProviderContainerView, context: Context) {
        uiView.session = session
        uiView.configure(graph: graph, pencilAnnotationEnabled: pencilAnnotationEnabled,
                         pencilStyle: pencilStyle,
                         pencilPreferences: pencilPreferences,
                         canonicalStrokeObjects: canonicalStrokeObjects,
                         onPencilStroke: onPencilStroke,
                         onPencilRequestsPassiveMode: onPencilRequestsPassiveMode)
        session.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: GraphProviderContainerView,
                                coordinator: ()) {
        let session = uiView.session
        uiView.finalizeActivePencilStroke()
        session?.detach(from: uiView)
        uiView.session = nil
    }
}

@MainActor
struct GraphNativeFallbackSurface: UIViewRepresentable {
    let graph: GraphObject

    func makeUIView(context: Context) -> GraphFallbackHostView {
        GraphFallbackHostView(graph: graph)
    }

    func updateUIView(_ uiView: GraphFallbackHostView, context: Context) {
        uiView.update(graph: graph)
    }
}

@MainActor
final class GraphFallbackHostView: UIView {
    private var graph: GraphObject
    private var renderedSize = CGSize.zero
    private var renderedAppearance: UIUserInterfaceStyle = .unspecified
    private var graphLayer: CALayer?

    init(graph: GraphObject) {
        self.graph = graph
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        isUserInteractionEnabled = false
        clipsToBounds = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: GraphFallbackHostView, _: UITraitCollection) in
            view.rebuild()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1,
              renderedSize != bounds.size
                || renderedAppearance != traitCollection.userInterfaceStyle else { return }
        rebuild()
    }

    func update(graph: GraphObject) {
        guard self.graph != graph else { return }
        self.graph = graph
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        renderedSize = bounds.size
        renderedAppearance = traitCollection.userInterfaceStyle
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let image = GraphProxyCache.shared.nativeImage(
            for: graph, size: bounds.size, scale: scale,
            appearance: renderedAppearance
        )
        let replacement = CALayer()
        replacement.name = "graph:\(graph.id):cached-proxy"
        replacement.contents = image.cgImage
        replacement.contentsScale = image.scale
        replacement.contentsGravity = .resize
        replacement.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        graphLayer?.removeFromSuperlayer()
        layer.addSublayer(replacement)
        CATransaction.commit()
        graphLayer = replacement
    }
}
