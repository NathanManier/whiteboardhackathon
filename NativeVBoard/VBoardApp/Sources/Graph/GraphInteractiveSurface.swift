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

/// The expanded graph owns its own live raster. Hide that one object from the
/// underlying board canvas so per-character canonical source updates do not
/// rebuild unrelated stroke, text, image, or passive-graph layers.
enum GraphEditingCanvasIsolation {
    static func objectsForCanvas(_ objects: [CanvasObject],
                                 hidingGraphID graphID: String?) -> [CanvasObject] {
        guard let graphID else { return objects }
        return objects.filter { !($0.id == graphID && $0.type == "graph") }
    }

    static func editorForCanvas(_ editor: EditorState,
                                hidingGraphID graphID: String?) -> EditorState {
        guard graphID != nil else { return editor }
        var result = editor
        result.objects = objectsForCanvas(editor.objects, hidingGraphID: graphID)
        return result
    }

    static func scenesForCanvas(_ scenes: [String: WorkspaceBoardScene],
                                hiding graph: GraphObject?)
        -> [String: WorkspaceBoardScene] {
        guard let graph, var scene = scenes[graph.owningBoardID] else { return scenes }
        var editor = editorForCanvas(scene.editor, hidingGraphID: graph.id)
        // A save acknowledgement can advance the revision while the visible
        // canvas payload is otherwise identical. Revisions coordinate storage,
        // not rendering, so normalize it in this presentation-only snapshot.
        editor.revision = 0
        scene.editor = editor
        scene.composition = SceneComposition.build(
            boardID: scene.boardID, document: scene.document, editor: editor
        )
        var result = scenes
        result[graph.owningBoardID] = scene
        return result
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
           let snapshot {
            GraphProxyCache.shared.storeProviderSnapshot(
                snapshot, for: finalizedGraph,
                appearance: VBoardCanvasTheme.interfaceStyle,
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
    let onCommitGraph: (GraphObject) -> Void
    let onBeginGraphEditing: (String, String) -> Void
    let onEndGraphEditing: (String, String) -> Void
    let onExplain: () -> Void
    let onPractice: () -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onDone: () -> Void
    private let usesLightweightRenderer: Bool

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
         onCommitGraph: @escaping (GraphObject) -> Void = { _ in },
         onBeginGraphEditing: @escaping (String, String) -> Void = { _, _ in },
         onEndGraphEditing: @escaping (String, String) -> Void = { _, _ in },
         onExplain: @escaping () -> Void = {},
         onPractice: @escaping () -> Void = {},
         onDelete: @escaping () -> Void = {},
         onEdit: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.init(
            graph: graph,
            coordinator: GraphProviderEnvironment.sharedCoordinator,
            providerFactory: { GraphProviderEnvironment.makeConfiguredProvider() },
            usesLightweightRenderer: true,
            canonicalStrokeObjects: canonicalStrokeObjects,
            pencilAnnotationEnabled: pencilAnnotationEnabled,
            pencilStyle: pencilStyle,
            pencilPreferences: pencilPreferences,
            onPencilStroke: onPencilStroke,
            onPencilRequestsPassiveMode: onPencilRequestsPassiveMode,
            onCommitViewport: onCommitViewport,
            onCommitGraph: onCommitGraph,
            onBeginGraphEditing: onBeginGraphEditing,
            onEndGraphEditing: onEndGraphEditing,
            onExplain: onExplain,
            onPractice: onPractice,
            onDelete: onDelete,
            onEdit: onEdit,
            onDone: onDone
        )
    }

    init(graph: GraphObject,
         coordinator: GraphProviderCoordinator,
         providerFactory: @escaping GraphInteractiveSession.ProviderFactory,
         usesLightweightRenderer: Bool = false,
         canonicalStrokeObjects: [CanvasObject] = [],
         pencilAnnotationEnabled: Bool,
         pencilStyle: CanvasStrokeStyle = .pen,
         pencilPreferences: PencilPreferences = .defaults,
         onPencilStroke: @escaping (UserStroke) -> Void = { _ in },
         onPencilRequestsPassiveMode: @escaping () -> Void,
         onCommitViewport: @escaping (String, String, GraphViewport) -> Void,
         onCommitGraph: @escaping (GraphObject) -> Void = { _ in },
         onBeginGraphEditing: @escaping (String, String) -> Void = { _, _ in },
         onEndGraphEditing: @escaping (String, String) -> Void = { _, _ in },
         onExplain: @escaping () -> Void = {},
         onPractice: @escaping () -> Void = {},
         onDelete: @escaping () -> Void = {},
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
        self.onCommitGraph = onCommitGraph
        self.onBeginGraphEditing = onBeginGraphEditing
        self.onEndGraphEditing = onEndGraphEditing
        self.onExplain = onExplain
        self.onPractice = onPractice
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.onDone = onDone
        self.usesLightweightRenderer = usesLightweightRenderer
    }

    @ViewBuilder
    var body: some View {
        if usesLightweightRenderer {
            LightweightGraphSurface(
                graph: graph,
                onCommitViewport: { viewport in
                    onCommitViewport(graph.owningBoardID, graph.id, viewport)
                },
                onCommitGraph: onCommitGraph,
                onBeginEditing: {
                    onBeginGraphEditing(graph.owningBoardID, graph.id)
                },
                onEndEditing: {
                    onEndGraphEditing(graph.owningBoardID, graph.id)
                },
                onExplain: onExplain,
                onPractice: onPractice,
                onDelete: onDelete,
                onEdit: onEdit,
                onDone: onDone
            )
        } else {
            providerSurface
        }
    }

    private var providerSurface: some View {
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
        .background(Color(uiColor: CanvasDesignTokens.boardSurface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, VBoardCanvasTheme.colorScheme)
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

/// Provider-free graph navigation for the primary classroom workflow. The
/// graph remains a normal persisted GraphObject; this surface only edits its
/// canonical viewport and never creates a WKWebView or an AI explanation.
private struct LightweightGraphSurface: View {
    let graph: GraphObject
    let onCommitViewport: (GraphViewport) -> Void
    let onCommitGraph: (GraphObject) -> Void
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void
    let onExplain: () -> Void
    let onPractice: () -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onDone: () -> Void

    @StateObject private var model: GraphWorkspaceModel
    @State private var keypadInsertion: GraphMathKeyCommand?
    @State private var dragStart: GraphViewport?
    @State private var magnificationStart: GraphViewport?
    @State private var compactShowsGraph = true

    init(graph: GraphObject, onCommitViewport: @escaping (GraphViewport) -> Void,
         onCommitGraph: @escaping (GraphObject) -> Void,
         onBeginEditing: @escaping () -> Void,
         onEndEditing: @escaping () -> Void,
         onExplain: @escaping () -> Void, onPractice: @escaping () -> Void,
         onDelete: @escaping () -> Void,
         onEdit: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.graph = graph
        self.onCommitViewport = onCommitViewport
        self.onCommitGraph = onCommitGraph
        self.onBeginEditing = onBeginEditing
        self.onEndEditing = onEndEditing
        self.onExplain = onExplain
        self.onPractice = onPractice
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.onDone = onDone
        _model = StateObject(wrappedValue: GraphWorkspaceModel(
            graph: graph, onExpressionMutation: onCommitGraph
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                toolbar
                Divider()
                if proxy.size.width >= 700 {
                    HStack(spacing: 0) {
                        expressionPanel
                            .frame(width: max(280, min(proxy.size.width * 0.34, 420)))
                        Divider()
                        plot
                    }
                } else {
                    compactPaneSwitch
                    Divider()
                    if compactShowsGraph { plot } else { expressionPanel }
                }
                if model.isEditing {
                    Divider()
                    mathInputTray
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color(uiColor: CanvasDesignTokens.boardSurface))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .environment(\.colorScheme, VBoardCanvasTheme.colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(GraphAccessibility.label(for: model.workingGraph))
        .onAppear(perform: onBeginEditing)
        .onDisappear {
            model.finishEditing()
            onEndEditing()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )) { _ in
            commitViewport()
            onEndEditing()
        }
        .animation(.easeOut(duration: 0.14), value: model.isEditing)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Text("Graph")
                .font(.headline)
            Spacer()
            Menu {
                Button("Explain this graph", systemImage: "text.magnifyingglass",
                       action: onExplain)
                Button("Practice from this graph", systemImage: "list.bullet.clipboard",
                       action: onPractice)
                Divider()
                Button("Graph settings", systemImage: "slider.horizontal.3",
                       action: onEdit)
                Button("Delete graph", systemImage: "trash", role: .destructive) {
                    onEndEditing()
                    onDelete()
                    onDone()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More graph actions")
            .help("More graph actions")

            Button("Reset View") {
                model.resetViewport()
                commitViewport()
            }
            .frame(minHeight: 44)
            .accessibilityHint("Restores the standard x and y range without changing expressions")
            .help("Reset only the graph viewport")

            Button("Done") {
                commitViewport()
                onEndEditing()
                onDone()
            }
            .frame(minHeight: 44)
            .buttonStyle(.borderedProminent)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(uiColor: CanvasDesignTokens.toolbarSurface))
    }

    private var compactPaneSwitch: some View {
        HStack(spacing: 20) {
            compactPaneButton("Expressions", showsGraph: false)
            compactPaneButton("Graph", showsGraph: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(uiColor: CanvasDesignTokens.toolbarSurface))
    }

    private func compactPaneButton(_ title: String, showsGraph: Bool) -> some View {
        Button {
            compactShowsGraph = showsGraph
        } label: {
            VStack(spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Rectangle()
                    .fill(compactShowsGraph == showsGraph ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private var expressionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EXPRESSIONS")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.expressions.count)/\(GraphRecognitionController.maximumExpressions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.expressions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Add an expression")
                                .font(.body.weight(.medium))
                            Button("Expression", systemImage: "plus") {
                                _ = model.addExpression()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    } else {
                        ForEach(Array(model.expressions.enumerated()), id: \.element.id) {
                            index, expression in
                            expressionRow(expression, index: index)
                            if index < model.expressions.count - 1 { Divider() }
                        }
                    }

                    if !model.expressions.isEmpty {
                        Button {
                            _ = model.addExpression()
                        } label: {
                            Label("Expression", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: 48)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.expressions.count
                                  >= GraphRecognitionController.maximumExpressions)
                        .accessibilityLabel("Add Expression")
                    }
                }
            }
        }
        .background(Color(uiColor: CanvasDesignTokens.toolbarSurface).opacity(0.34))
    }

    private func expressionRow(_ expression: GraphExpression, index: Int) -> some View {
        let feedback = model.feedback(for: expression)
        let slider = model.slider(for: expression)
        let isEditing = model.editingExpressionID == expression.id
        return HStack(alignment: .top, spacing: 10) {
            Button {
                model.toggleVisibility(id: expression.id)
            } label: {
                Circle()
                    .fill(curveColor(expression, index: index)
                        .opacity(expression.visible ? 1 : 0.18))
                    .overlay {
                        if !expression.visible {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                expression.visible ? "Hide expression \(index + 1)" : "Show expression \(index + 1)"
            )

            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    GraphMathEditorField(
                        text: expression.latex,
                        insertion: keypadInsertion,
                        isFocused: true,
                        onChange: { model.updateSource(id: expression.id, source: $0) },
                        onSubmit: { model.finishEditing() }
                    )
                    .frame(height: 44)
                    .accessibilityLabel("Expression \(index + 1) source")
                } else if let slider {
                    parameterSlider(slider, expressionID: expression.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.beginEditing(expression.id) }
                } else {
                    Button {
                        model.beginEditing(expression.id)
                    } label: {
                        Group {
                            if feedback?.isError == true {
                                Text(expression.latex.isEmpty ? "Empty expression" : expression.latex)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.primary)
                            } else {
                                StudyContentView(
                                    source: "\\(\(expression.latex)\\)",
                                    maximumWidth: 310
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if let feedback, slider == nil {
                    HStack(spacing: 8) {
                        if feedback.isError {
                            Image(systemName: "exclamationmark.circle")
                                .accessibilityHidden(true)
                        }
                        Text(feedback.message)
                            .font(feedback.isError ? .caption : .callout.monospacedDigit())
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(feedback.isError ? Color.red : Color.secondary)
                }

                if feedback?.isError == true,
                   let parameter = model.undefinedParameters(for: expression).first {
                    Button("Add slider for \(parameter)") {
                        _ = model.addParameter(named: parameter)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 10)

            expressionMenu(expression, index: index)
                .padding(.top, 12)
        }
        .padding(.horizontal, 10)
        .background(
            model.selectedExpressionID == expression.id
                ? Color.accentColor.opacity(0.055) : Color.clear
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Expression \(index + 1), \(CompactStudyPresentation.readableText(from: expression.latex)), \(expression.visible ? "visible" : "hidden")"
        )
    }

    private func parameterSlider(_ slider: GraphParameterSlider,
                                 expressionID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(slider.name)
                    .font(.body.monospaced().weight(.semibold))
                Spacer()
                Text(GraphWorkspaceModel.format(slider.value))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { model.slider(for: model.expression(id: expressionID)
                        ?? GraphExpression(id: expressionID, latex: "", type: .unknown))?.value
                        ?? slider.value },
                    set: { model.updateSlider(id: expressionID, value: $0) }
                ),
                in: slider.minimum...slider.maximum,
                step: slider.step
            )
            .accessibilityLabel("Parameter \(slider.name)")
            .accessibilityValue(GraphWorkspaceModel.format(slider.value))
            HStack {
                Text(GraphWorkspaceModel.format(slider.minimum))
                Spacer()
                Text(GraphWorkspaceModel.format(slider.maximum))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private func expressionMenu(_ expression: GraphExpression, index: Int) -> some View {
        Menu {
            Button("Edit", systemImage: "pencil") { model.beginEditing(expression.id) }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                _ = model.duplicateExpression(id: expression.id)
            }
            Menu("Curve color") {
                ForEach(Array(Self.curveColors.enumerated()), id: \.offset) { colorIndex, hex in
                    Button("Color \(colorIndex + 1)") { model.setColor(hex, id: expression.id) }
                }
            }
            if let function = GraphMathEnvironment.functionDefinition(in: expression.latex) {
                Divider()
                Button("Add derivative") { _ = model.addExpression(source: "\(function.name)'()") }
                Button("Add definite integral") {
                    _ = model.addExpression(source: "integral(\(function.name)(x),,)")
                }
            }
            Divider()
            Button("Delete expression", systemImage: "trash", role: .destructive) {
                model.deleteExpression(id: expression.id)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions for expression \(index + 1)")
    }

    private var plot: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                GraphNativeFallbackSurface(graph: model.workingGraph, showsMetadata: false)
                    .contentShape(Rectangle())
                    .gesture(panGesture(size: proxy.size))
                    .simultaneousGesture(zoomGesture)

                GraphIndirectNavigationCapture(
                    onPan: { state, translation in
                        switch state {
                        case .began: dragStart = model.viewport
                        case .changed: updatePan(translation: translation, size: proxy.size)
                        case .ended:
                            dragStart = nil
                            commitViewport()
                        case .cancelled, .failed:
                            if let dragStart { model.updateViewport(dragStart) }
                            dragStart = nil
                        default: break
                        }
                    },
                    onWheel: { factor, anchor, finished in
                        if factor != 1 {
                            model.updateViewport(scaled(
                                model.viewport, by: factor,
                                anchoredAt: anchor, size: proxy.size
                            ))
                        }
                        if finished { commitViewport() }
                    }
                )

                VStack(spacing: 0) {
                    Button { zoom(by: 0.74) } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                    }
                    Divider().frame(width: 44)
                    Button { zoom(by: 1.35) } label: {
                        Image(systemName: "minus")
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.plain)
                .background(Color(uiColor: CanvasDesignTokens.toolbarSurface))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                    Color(uiColor: CanvasDesignTokens.boardBorder).opacity(0.55), lineWidth: 1
                ))
                .padding(12)
                .accessibilityElement(children: .contain)
            }
        }
        .background(Color(uiColor: CanvasDesignTokens.boardSurface))
    }

    private var mathInputTray: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                ForEach(GraphMathKeyboardCategory.allCases) { category in
                    Button {
                        model.keyboardCategory = category
                    } label: {
                        VStack(spacing: 5) {
                            Text(category.rawValue)
                                .font(.subheadline.weight(.semibold))
                            Rectangle()
                                .fill(model.keyboardCategory == category
                                      ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                }
                Spacer()
                Button {
                    model.finishEditing()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide math keyboard")
            }

            let keys = keys(for: model.keyboardCategory)
            let columns = columnCount(for: model.keyboardCategory)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
                spacing: 6
            ) {
                ForEach(keys) { key in
                    Button {
                        keypadInsertion = GraphMathKeyCommand(action: key.action)
                    } label: {
                        Text(key.label)
                            .font(.callout.weight(key.emphasized ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                key.emphasized
                                    ? Color.accentColor.opacity(0.10)
                                    : Color(uiColor: CanvasDesignTokens.boardSurface),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                                Color(uiColor: CanvasDesignTokens.boardBorder).opacity(0.45),
                                lineWidth: 1
                            ))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key.accessibilityLabel)
                }
            }
            // Keep the plot and expression list stationary when the user
            // switches between categories with different key counts.
            .frame(
                minHeight: CGFloat(5 * 44 + 4 * 6),
                alignment: .top
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: CanvasDesignTokens.toolbarSurface))
    }

    private func columnCount(for category: GraphMathKeyboardCategory) -> Int {
        switch category {
        case .basic: return 6
        case .functions: return 3
        case .calculus: return 2
        }
    }

    private func keys(for category: GraphMathKeyboardCategory) -> [GraphMathKey] {
        switch category {
        case .basic:
            return [
                .text("7"), .text("8"), .text("9"), .template("(", "(", 0),
                .template(")", ")", 0), .action("⌫", "delete backward", .backspace, true),
                .text("4"), .text("5"), .text("6"), .text("+", emphasized: true),
                .template("−", "-", 0, emphasized: true), .text("^", emphasized: true),
                .text("1"), .text("2"), .text("3"),
                .template("×", "*", 0, emphasized: true),
                .template("÷", "/", 0, emphasized: true), .text("x"),
                .text("0"), .text("."), .template("π", "pi", 0), .text("e"),
                .text("="), .action("Clear", "clear expression", .clear, false),
                .text("<"), .text(">"), .template("≤", "<=", 0),
                .template("≥", ">=", 0), .text(","), .text("y"),
            ]
        case .functions:
            return [
                .function("sin"), .function("cos"), .function("tan"),
                .function("sec"), .function("csc"), .function("cot"),
                .function("asin", spoken: "inverse sine"),
                .function("acos", spoken: "inverse cosine"),
                .function("atan", spoken: "inverse tangent"),
                .function("sqrt", label: "√", spoken: "square root"),
                .function("abs", spoken: "absolute value"), .function("ln"),
                .function("log"), .function("exp"),
                .template("x²", "^2", 0),
            ]
        case .calculus:
            return [
                .template("f′( )", "f'()", 1, spoken: "derivative at a point", emphasized: true),
                .template("d/dx", "d/dx()", 1, spoken: "derivative expression", emphasized: true),
                .template("∫ bounds", "integral(,,)", 3,
                          spoken: "definite integral with bounds", emphasized: true),
                .template("f(x)=", "f(x)=", 0, spoken: "define function f"),
                .template("g(x)=", "g(x)=", 0, spoken: "define function g"),
                .template("a=", "a=", 0, spoken: "define parameter a"),
                .template("x²", "^2", 0),
                .function("sqrt", label: "√", spoken: "square root"),
                .text("x"), .text(","),
            ]
        }
    }

    private func curveColor(_ expression: GraphExpression, index: Int) -> Color {
        if let hex = expression.displayStyle?.color {
            return Color(uiColor: UIColor(svgHex: hex))
        }
        return Color(uiColor: GraphFallbackPalette.colors[index % GraphFallbackPalette.colors.count])
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil { dragStart = model.viewport }
                updatePan(translation: value.translation, size: size)
            }
            .onEnded { _ in
                dragStart = nil
                commitViewport()
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let start = magnificationStart ?? model.viewport
                if magnificationStart == nil { magnificationStart = start }
                let scale = min(20, max(0.05, Double(value)))
                model.updateViewport(GraphViewportNavigation.zoomed(start, by: 1 / scale))
            }
            .onEnded { _ in
                magnificationStart = nil
                commitViewport()
            }
    }

    private func zoom(by factor: Double) {
        model.updateViewport(GraphViewportNavigation.zoomed(model.viewport, by: factor))
        commitViewport()
    }

    private func updatePan(translation: CGSize, size: CGSize) {
        let start = dragStart ?? model.viewport
        model.updateViewport(GraphViewportNavigation.panned(
            start, by: translation, size: size
        ))
    }

    private func scaled(_ source: GraphViewport, by factor: Double,
                        anchoredAt point: CGPoint, size: CGSize) -> GraphViewport {
        GraphViewportNavigation.zoomed(source, by: factor, anchor: point, size: size)
    }

    private func commitViewport() { onCommitViewport(model.viewport) }

    private static let curveColors = [
        "#2d70b3", "#c74440", "#388c46", "#6042a6", "#fa7e19", "#0d8f9c",
    ]
}

private struct GraphMathKey: Identifiable {
    let id = UUID()
    let label: String
    let accessibilityLabel: String
    let action: GraphMathKeyAction
    let emphasized: Bool

    static func text(_ value: String, emphasized: Bool = false) -> Self {
        Self(label: value, accessibilityLabel: value,
             action: .insert(text: value), emphasized: emphasized)
    }

    static func template(_ label: String, _ text: String, _ cursorBacktrack: Int,
                         spoken: String? = nil, emphasized: Bool = false) -> Self {
        Self(label: label, accessibilityLabel: spoken ?? label,
             action: .insert(text: text, cursorBacktrack: cursorBacktrack),
             emphasized: emphasized)
    }

    static func function(_ name: String, label: String? = nil,
                         spoken: String? = nil) -> Self {
        template(label ?? name, "\(name)()", 1, spoken: spoken ?? name)
    }

    static func action(_ label: String, _ spoken: String,
                       _ action: GraphMathKeyAction, _ emphasized: Bool) -> Self {
        Self(label: label, accessibilityLabel: spoken,
             action: action, emphasized: emphasized)
    }
}

private struct GraphMathKeyCommand: Equatable {
    let id = UUID()
    let action: GraphMathKeyAction
}

private struct GraphMathEditorField: UIViewRepresentable {
    let text: String
    let insertion: GraphMathKeyCommand?
    let isFocused: Bool
    let onChange: (String) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .none
        field.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .never
        field.placeholder = "y=x²"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)),
                        for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
        guard let insertion,
              context.coordinator.lastInsertionID != insertion.id else { return }
        context.coordinator.lastInsertionID = insertion.id
        let selected = field.selectedTextRange.map {
            NSRange(location: field.offset(from: field.beginningOfDocument, to: $0.start),
                    length: field.offset(from: $0.start, to: $0.end))
        } ?? NSRange(location: (field.text ?? "").utf16.count, length: 0)
        let result = GraphMathInsertionPlan.apply(
            insertion.action, to: field.text ?? "", selection: selected
        )
        field.text = result.source
        if let start = field.position(from: field.beginningOfDocument,
                                      offset: result.selection.location),
           let end = field.position(from: start, offset: result.selection.length) {
            field.selectedTextRange = field.textRange(from: start, to: end)
        }
        context.coordinator.parent.onChange(result.source)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: GraphMathEditorField
        var lastInsertionID: UUID?

        init(parent: GraphMathEditorField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.onChange(field.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            textField.resignFirstResponder()
            return false
        }
    }
}

/// UIKit exposes trackpad scroll and discrete mouse-wheel streams separately
/// from direct finger pans. This transparent peer handles only indirect input;
/// direct touches fall through to the SwiftUI pan/pinch gestures above.
private struct GraphIndirectNavigationCapture: UIViewRepresentable {
    let onPan: (UIGestureRecognizer.State, CGSize) -> Void
    let onWheel: (Double, CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> GraphIndirectNavigationView {
        GraphIndirectNavigationView(onPan: onPan, onWheel: onWheel)
    }

    func updateUIView(_ view: GraphIndirectNavigationView, context: Context) {
        view.onPan = onPan
        view.onWheel = onWheel
    }
}

private final class GraphIndirectNavigationView: UIView, UIGestureRecognizerDelegate {
    var onPan: (UIGestureRecognizer.State, CGSize) -> Void
    var onWheel: (Double, CGPoint, Bool) -> Void

    init(onPan: @escaping (UIGestureRecognizer.State, CGSize) -> Void,
         onWheel: @escaping (Double, CGPoint, Bool) -> Void) {
        self.onPan = onPan
        self.onWheel = onWheel
        super.init(frame: .zero)
        backgroundColor = .clear

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(trackpadPan(_:)))
        scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.allowedScrollTypesMask = .continuous
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(mouseWheel(_:)))
        wheel.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        wheel.allowedScrollTypesMask = .discrete
        wheel.cancelsTouchesInView = false
        wheel.delegate = self
        addGestureRecognizer(wheel)
    }

    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let touch = event?.allTouches?.first else { return true }
        return touch.type == .indirectPointer
    }

    @objc private func trackpadPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        onPan(gesture.state, CGSize(width: translation.x, height: translation.y))
    }

    @objc private func mouseWheel(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let delta = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            guard delta.isFinite, abs(delta) > 0.001 else { return }
            let factor = min(1.8, max(0.55, exp(Double(delta) * 0.006)))
            onWheel(factor, gesture.location(in: self), false)
        case .ended:
            onWheel(1, gesture.location(in: self), true)
        case .cancelled, .failed:
            onWheel(1, gesture.location(in: self), true)
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer)
        -> Bool { true }
}

#if DEBUG
/// Launch-only visual acceptance fixture. It is excluded from Release and
/// keeps screenshots deterministic without requiring an account or server.
struct GraphWorkspaceReviewView: View {
    @State private var graph: GraphObject
    @State private var isOpen = true

    init(state: String) {
        _graph = State(initialValue: Self.makeGraph(state: state))
    }

    var body: some View {
        Group {
            if isOpen {
                GraphInteractiveSurface(
                    graph: graph,
                    pencilAnnotationEnabled: false,
                    onPencilRequestsPassiveMode: {},
                    onCommitViewport: { owningBoardID, graphID, viewport in
                        guard owningBoardID == graph.owningBoardID,
                              graphID == graph.id else { return }
                        graph = graph.replacing(viewport: viewport)
                    },
                    onCommitGraph: { updated in
                        guard updated.id == graph.id,
                              updated.owningBoardID == graph.owningBoardID else { return }
                        graph = updated
                    },
                    onEdit: {},
                    onDone: { isOpen = false }
                )
            } else {
                Button("Reopen Graph", systemImage: "chart.xyaxis.line") {
                    isOpen = true
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 160, minHeight: 52)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: CanvasDesignTokens.canvasBackground))
    }

    private static func makeGraph(state: String) -> GraphObject {
        GraphObject(
            id: "graph-review", owningBoardID: "603f5213ab0a249716833214c5ab88da",
            frame: GraphFrame(x: 0, y: 0, width: 900, height: 620),
            expressions: expressions(for: state),
            viewport: GraphViewport(xMin: -10, xMax: 10, yMin: -8, yMax: 12),
            settings: GraphSettings(showXAxis: true, showYAxis: true, showGrid: true)
        )
    }

    private static func expressions(for state: String) -> [GraphExpression] {
        switch state {
        case "multiple":
            return [expression("f(x)=sin(x)", id: "f", color: "#2d70b3"),
                    expression("g(x)=0.5x^2-2", id: "g", color: "#c74440"),
                    expression("y=2", id: "line", color: "#388c46")]
        case "parameter":
            return [expression("f(x)=a*sin(x)", id: "curve", color: "#2d70b3"),
                    expression("a=1", id: "parameter", color: "#c74440")]
        case "derivative":
            return [expression("f(x)=x^2", id: "function", color: "#2d70b3"),
                    expression("f'(2)", id: "derivative", color: "#c74440")]
        case "integral":
            return [expression("f(x)=x^2", id: "function", color: "#2d70b3"),
                    expression("integral(f(x),0,2)", id: "integral", color: "#c74440")]
        case "error":
            return [expression("f(x)=sin(", id: "invalid", color: "#c74440")]
        default:
            return [expression("f(x)=sin(x)", id: "f", color: "#2d70b3")]
        }
    }

    private static func expression(_ source: String, id: String,
                                   color: String) -> GraphExpression {
        GraphExpression(
            id: id, latex: source, type: GraphExpressionInference.type(for: source),
            displayStyle: GraphExpressionDisplayStyle(color: color, lineWidth: 2.5)
        )
    }
}
#endif

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
        pencilHoverLayer.strokeColor = CanvasDesignTokens.canvasPrimaryText
            .withAlphaComponent(0.62).cgColor
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
    var showsMetadata = true

    func makeUIView(context: Context) -> GraphFallbackHostView {
        GraphFallbackHostView(graph: graph, showsMetadata: showsMetadata)
    }

    func updateUIView(_ uiView: GraphFallbackHostView, context: Context) {
        uiView.update(graph: graph, showsMetadata: showsMetadata)
    }
}

@MainActor
final class GraphFallbackHostView: UIView {
    private var graph: GraphObject
    private var renderedSize = CGSize.zero
    private var graphLayer: CALayer?
    private var showsMetadata: Bool

    init(graph: GraphObject, showsMetadata: Bool = true) {
        self.graph = graph
        self.showsMetadata = showsMetadata
        super.init(frame: .zero)
        overrideUserInterfaceStyle = VBoardCanvasTheme.interfaceStyle
        backgroundColor = CanvasDesignTokens.boardSurface
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1,
              renderedSize != bounds.size else { return }
        rebuild()
    }

    func update(graph: GraphObject, showsMetadata: Bool? = nil) {
        let nextShowsMetadata = showsMetadata ?? self.showsMetadata
        guard self.graph != graph || self.showsMetadata != nextShowsMetadata else { return }
        self.graph = graph
        self.showsMetadata = nextShowsMetadata
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        renderedSize = bounds.size
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let image: UIImage
        if showsMetadata {
            image = GraphProxyCache.shared.nativeImage(
                for: graph, size: bounds.size, scale: scale,
                appearance: VBoardCanvasTheme.interfaceStyle
            )
        } else {
            let localGraph = graph.replacing(frame: GraphFrame(
                x: 0, y: 0, width: Double(max(bounds.width, GraphFrame.minimumDimension)),
                height: Double(max(bounds.height, GraphFrame.minimumDimension))
            ))
            image = GraphFallbackRenderer.image(
                for: localGraph, scale: scale, showsMetadata: false
            )
        }
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
