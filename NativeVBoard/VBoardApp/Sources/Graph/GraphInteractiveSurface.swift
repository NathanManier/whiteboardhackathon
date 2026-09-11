import SwiftUI
import UIKit

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
        wantsInteractivePresentation = true
        generation += 1
        await promote(generation: generation)
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
        representationState = .demoting
        let demotionID = UUID()
        activeDemotionID = demotionID
        activeDemotionAllowsSnapshot = reason != .memoryPressure && reason != .background
        let task: Task<GraphDemotionResult?, Never> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            if let promotionToJoin { await promotionToJoin.value }
            guard self.activeDemotionID == demotionID else { return nil }
            guard let provider = self.provider else {
                if self.generation == demotionGeneration {
                    self.representationState = .proxy
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
            representationState = .proxy
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
        Task { @MainActor in try? await resizable.resize(to: bounds) }
    }

    private func schedulePromotionIfReady() {
        guard wantsInteractivePresentation,
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

        if let provider,
           coordinator.activeProvider === provider,
           coordinator.activeGraphID == displayGraph.id {
            hostView.install(provider.view)
            representationState = .interactive
            return
        }

        guard let nextProvider = providerFactory() else {
            representationState = .failed
            providerError = GraphRendererError.unavailable.localizedDescription
            return
        }

        invalidateProviderUpdates()
        provider = nextProvider
        representationState = .promoting
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
            representationState = .interactive
            #if DEBUG
            let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            print("GRAPH PROVIDER PROMOTED graph=\(displayGraph.id) provider=\(nextProvider.identifier) elapsedMs=\(String(format: "%.1f", elapsedMilliseconds)) activeProviders=\(coordinator.activeProviderCount)")
            #endif
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
            if coordinator.activeProvider === expectedProvider {
                _ = await coordinator.demote()
            } else {
                expectedProvider.unmount()
            }
            hostView?.removeProviderView(expectedProvider.view)
            return
        }
        invalidateProviderUpdates()
        let failedProvider = provider
        if let failedProvider, coordinator.activeProvider === failedProvider {
            _ = await coordinator.demote()
        } else {
            failedProvider?.unmount()
        }
        if let failedProvider { hostView?.removeProviderView(failedProvider.view) }
        provider = nil
        lastProviderAppliedGraph = nil
        representationState = .failed
        providerError = (error as? LocalizedError)?.errorDescription
            ?? GraphRendererError.unavailable.localizedDescription
        #if DEBUG
        print("GRAPH PROVIDER FAILED graph=\(displayGraph.id) error=\(error.localizedDescription)")
        #endif
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
                    Label(providerError, systemImage: "chart.xyaxis.line")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 58)
                }
                .allowsHitTesting(false)
            }

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

@MainActor
final class GraphProviderContainerView: UIView {
    weak var session: GraphInteractiveSession?
    private lazy var pencilRecognizer = GraphPencilStrokeRecognizer(
        target: self, action: #selector(handlePencilStroke(_:))
    )
    private var graph: GraphObject?
    private var pencilAnnotationEnabled = true
    private var pencilStyle: CanvasStrokeStyle = .pen
    private var onPencilStroke: ((UserStroke) -> Void)?
    private var onPencilRequestsPassiveMode: (() -> Void)?
    private var activePencilPoints: [StrokePoint] = []
    private var activePencilStyle: CanvasStrokeStyle?
    private var activePencilLayer: CAShapeLayer?
    private var completedPencilLayers: [String: CAShapeLayer] = [:]
    private var completedPencilStrokes: [String: UserStroke] = [:]
    private var completedPencilOrder: [String] = []
    private var canonicalPencilLayers: [String: CAShapeLayer] = [:]
    private var canonicalStrokeObjects: [String: CanvasObject] = [:]
    private var canonicalStrokeOrder: [String] = []
    private var configuredGraphID: String?
    private var rejectsCurrentPencilSequence = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        pencilRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilRecognizer.cancelsTouchesInView = true
        pencilRecognizer.delaysTouchesBegan = false
        pencilRecognizer.requiresExclusiveTouchType = true
        addGestureRecognizer(pencilRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
        renderPencilLayers()
        session?.hostDidLayout(bounds)
    }

    func configure(graph: GraphObject, pencilAnnotationEnabled: Bool,
                   pencilStyle: CanvasStrokeStyle,
                   canonicalStrokeObjects: [CanvasObject],
                   onPencilStroke: @escaping (UserStroke) -> Void,
                   onPencilRequestsPassiveMode: @escaping () -> Void) {
        if configuredGraphID != graph.id {
            cancelPencilStroke()
            completedPencilLayers.values.forEach { $0.removeFromSuperlayer() }
            completedPencilLayers.removeAll(keepingCapacity: false)
            completedPencilStrokes.removeAll(keepingCapacity: false)
            completedPencilOrder.removeAll(keepingCapacity: false)
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
        self.onPencilStroke = onPencilStroke
        self.onPencilRequestsPassiveMode = onPencilRequestsPassiveMode
        renderPencilLayers()
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
            activePencilPoints.removeAll(keepingCapacity: true)
            activePencilStyle = pencilStyle
            let strokeLayer = CAShapeLayer()
            strokeLayer.frame = bounds
            strokeLayer.fillColor = UIColor.clear.cgColor
            strokeLayer.strokeColor = UIColor(svgHex: pencilStyle.colorHex)
                .withAlphaComponent(pencilStyle.opacity).cgColor
            let xScale = bounds.width / CGFloat(max(graph.frame.width, 0.001))
            let yScale = bounds.height / CGFloat(max(graph.frame.height, 0.001))
            strokeLayer.lineWidth = CGFloat(pencilStyle.width) * min(xScale, yScale)
            strokeLayer.lineCap = .round
            strokeLayer.lineJoin = .round
            strokeLayer.zPosition = 10_000
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.addSublayer(strokeLayer)
            CATransaction.commit()
            activePencilLayer = strokeLayer
            appendPencilSamples(recognizer.samples, graph: graph)
        case .changed:
            appendPencilSamples(recognizer.samples, graph: graph)
        case .ended:
            appendPencilSamples(recognizer.samples, graph: graph)
            finalizeActivePencilStroke()
        case .cancelled, .failed:
            cancelPencilStroke()
        default:
            break
        }
    }

    private func appendPencilSamples(_ samples: [GraphPencilSample], graph: GraphObject) {
        for sample in samples {
            guard sample.point.x.isFinite, sample.point.y.isFinite else { continue }
            activePencilPoints.append(GraphPencilCoordinateMapper.strokePoint(
                localPoint: sample.point, in: bounds, graphFrame: graph.frame,
                pressure: sample.pressure
            ))
        }
        renderActivePencilLayer()
    }

    private func cancelPencilStroke() {
        activePencilLayer?.removeFromSuperlayer()
        activePencilLayer = nil
        activePencilPoints.removeAll(keepingCapacity: true)
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
        activePencilStyle = nil
        let finalized = UserStroke(
            id: "stroke-" + UUID().uuidString.lowercased(),
            color: style.colorHex, width: style.width, opacity: style.opacity,
            points: points
        )
        if let strokeLayer {
            strokeLayer.name = "graph-pencil:\(finalized.id)"
            completedPencilLayers[finalized.id] = strokeLayer
            completedPencilStrokes[finalized.id] = finalized
            completedPencilOrder.append(finalized.id)
        }
        onPencilStroke?(finalized)
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
            opacity: style.opacity, points: activePencilPoints
        )
        configure(activePencilLayer, for: stroke, graph: graph)
    }

    private func configure(_ strokeLayer: CAShapeLayer, for stroke: UserStroke,
                           graph: GraphObject) {
        strokeLayer.frame = bounds
        strokeLayer.strokeColor = UIColor(svgHex: stroke.color)
            .withAlphaComponent(stroke.opacity).cgColor
        let xScale = bounds.width / CGFloat(max(graph.frame.width, 0.001))
        let yScale = bounds.height / CGFloat(max(graph.frame.height, 0.001))
        strokeLayer.lineWidth = CGFloat(stroke.width) * min(xScale, yScale)
        let path = UIBezierPath()
        let localPoints = stroke.points.map {
            GraphPencilCoordinateMapper.localPoint(
                strokePoint: $0, in: bounds, graphFrame: graph.frame
            )
        }
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
        strokeLayer.path = path.cgPath
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
                pressure: $0.pressure
            )
        }
        configure(
            strokeLayer,
            for: UserStroke(
                id: object.id, color: object.color ?? "#183153",
                width: (object.width ?? 4) * sqrt(abs(scaleX * scaleY)),
                opacity: object.opacity ?? 1, points: points
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
}

enum GraphPencilCoordinateMapper {
    static func strokePoint(localPoint: CGPoint, in bounds: CGRect,
                            graphFrame: GraphFrame, pressure: Double) -> StrokePoint {
        let width = max(bounds.width, 0.001)
        let height = max(bounds.height, 0.001)
        return StrokePoint(
            x: graphFrame.x + Double((localPoint.x - bounds.minX) / width) * graphFrame.width,
            y: graphFrame.y + Double((localPoint.y - bounds.minY) / height) * graphFrame.height,
            pressure: min(1, max(0, pressure.isFinite ? pressure : 1))
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
    let pressure: Double
}

/// An ancestor recognizer sees Pencil events whose hit-tested descendant is
/// WKContentView. Restricting the recognizer itself to `.pencil` lets fingers
/// and trackpads continue to interact with the provider while Pencil samples
/// stay in V-Board's canonical `UserStroke` pipeline.
private final class GraphPencilStrokeRecognizer: UIGestureRecognizer {
    private(set) var samples: [GraphPencilSample] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else {
            state = .failed
            return
        }
        samples = mappedSamples(for: touch, event: event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        samples = mappedSamples(for: touch, event: event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else {
            state = .cancelled
            return
        }
        samples = mappedSamples(for: touch, event: event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        samples = []
        state = .cancelled
    }

    override func reset() {
        super.reset()
        samples = []
    }

    private func mappedSamples(for touch: UITouch, event: UIEvent) -> [GraphPencilSample] {
        let source = event.coalescedTouches(for: touch) ?? [touch]
        return source.map { sample in
            let pressure: Double
            if sample.maximumPossibleForce > 0 {
                pressure = Double(min(1, max(0, sample.force / sample.maximumPossibleForce)))
            } else {
                pressure = 1
            }
            return GraphPencilSample(point: sample.location(in: view), pressure: pressure)
        }
    }
}

@MainActor
private struct GraphProviderHost: UIViewRepresentable {
    @ObservedObject var session: GraphInteractiveSession
    let graph: GraphObject
    let canonicalStrokeObjects: [CanvasObject]
    let pencilAnnotationEnabled: Bool
    let pencilStyle: CanvasStrokeStyle
    let onPencilStroke: (UserStroke) -> Void
    let onPencilRequestsPassiveMode: () -> Void

    func makeUIView(context: Context) -> GraphProviderContainerView {
        let view = GraphProviderContainerView()
        view.session = session
        view.configure(graph: graph, pencilAnnotationEnabled: pencilAnnotationEnabled,
                       pencilStyle: pencilStyle,
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
