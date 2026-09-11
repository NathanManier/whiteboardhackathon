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
    private weak var hostView: GraphProviderContainerView?
    private var provider: GraphRendererProvider?
    private var promotionTask: Task<Void, Never>?
    private var generation = 0
    private var wantsInteractivePresentation = false
    private var lastLayoutSize = CGSize.zero

    init(graph: GraphObject,
         coordinator: GraphProviderCoordinator,
         providerFactory: @escaping ProviderFactory) {
        displayGraph = graph
        self.coordinator = coordinator
        self.providerFactory = providerFactory
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
        displayGraph = graph
        providerError = nil

        guard !replacesActiveGraph else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.demote(reason: .replaced)
                self.wantsInteractivePresentation = true
                self.schedulePromotionIfReady()
            }
            return
        }

        guard let provider,
              coordinator.activeGraphID == graph.id,
              coordinator.activeProvider === provider else { return }
        Task { @MainActor [weak self] in
            do {
                try await provider.update(graph: graph)
            } catch {
                await self?.failProvider(error)
            }
        }
    }

    func requestInteractivePresentation() {
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
        displayGraph = displayGraph.replacing(viewport: .conventional)
        guard let provider,
              coordinator.activeGraphID == displayGraph.id,
              coordinator.activeProvider === provider else { return }
        let graph = displayGraph
        Task { @MainActor [weak self] in
            do {
                try await provider.update(graph: graph)
            } catch {
                await self?.failProvider(error)
            }
        }
    }

    /// Returns the provider's final viewport exactly once when it is available.
    /// The caller remains responsible for writing that viewport through the
    /// canonical BoardDocumentStore mutation path.
    func demote(reason: GraphProviderDemotionReason) async -> GraphViewport? {
        generation += 1
        wantsInteractivePresentation = false
        promotionTask?.cancel()
        promotionTask = nil

        guard let provider else {
            representationState = .proxy
            return nil
        }

        // Clear ownership before the first suspension point so overlapping
        // onDisappear/background/dismantle callbacks cannot demote or commit
        // the same provider twice.
        self.provider = nil
        representationState = .demoting
        let viewport: GraphViewport?
        if coordinator.activeProvider === provider,
           coordinator.activeGraphID == displayGraph.id {
            viewport = await coordinator.demote()
        } else {
            viewport = await provider.readViewport()
            try? await provider.setInteractive(false)
            provider.unmount()
        }

        if let viewport, viewport.isValid {
            displayGraph = displayGraph.replacing(viewport: viewport)
        }
        hostView?.removeProviderView(provider.view)
        representationState = .proxy
        #if DEBUG
        print("GRAPH PROVIDER DEMOTED graph=\(displayGraph.id) reason=\(reason.rawValue)")
        #endif
        return viewport?.isValid == true ? viewport : nil
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
            self?.promotionTask = nil
        }
    }

    private func promote(generation requestedGeneration: Int) async {
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

        provider = nextProvider
        representationState = .promoting
        providerError = nil
        nextProvider.view.alpha = 0
        hostView.install(nextProvider.view)

        do {
            try await coordinator.promote(graph: displayGraph,
                                          provider: nextProvider,
                                          frame: hostView.bounds)
            guard requestedGeneration == generation,
                  wantsInteractivePresentation else {
                if coordinator.activeProvider === nextProvider {
                    _ = await coordinator.demote()
                } else {
                    nextProvider.unmount()
                }
                hostView.removeProviderView(nextProvider.view)
                if provider === nextProvider { provider = nil }
                return
            }
            nextProvider.view.frame = hostView.bounds
            UIView.animate(withDuration: 0.16) { nextProvider.view.alpha = 1 }
            representationState = .interactive
            #if DEBUG
            print("GRAPH PROVIDER PROMOTED graph=\(displayGraph.id) provider=\(nextProvider.identifier)")
            #endif
        } catch {
            await failProvider(error)
        }
    }

    private func failProvider(_ error: Error) async {
        let failedProvider = provider
        if let failedProvider, coordinator.activeProvider === failedProvider {
            _ = await coordinator.demote()
        } else {
            failedProvider?.unmount()
        }
        if let failedProvider { hostView?.removeProviderView(failedProvider.view) }
        provider = nil
        representationState = .failed
        providerError = (error as? LocalizedError)?.errorDescription
            ?? GraphRendererError.unavailable.localizedDescription
        #if DEBUG
        print("GRAPH PROVIDER FAILED graph=\(displayGraph.id) error=\(error.localizedDescription)")
        #endif
    }
}

/// Interactive graph presentation used by board/lecture containers. It is
/// intentionally provider-independent at its boundary: Done commits only a
/// canonical viewport, while Edit delegates semantic expression changes to the
/// owning feature.
@MainActor
struct GraphInteractiveSurface: View {
    let graph: GraphObject
    let onCommitViewport: (GraphViewport) -> Void
    let onEdit: () -> Void
    let onDone: () -> Void

    @StateObject private var session: GraphInteractiveSession
    @State private var isClosing = false

    init(graph: GraphObject,
         onCommitViewport: @escaping (GraphViewport) -> Void,
         onEdit: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.init(
            graph: graph,
            coordinator: GraphProviderEnvironment.sharedCoordinator,
            providerFactory: { GraphProviderEnvironment.makeConfiguredProvider() },
            onCommitViewport: onCommitViewport,
            onEdit: onEdit,
            onDone: onDone
        )
    }

    init(graph: GraphObject,
         coordinator: GraphProviderCoordinator,
         providerFactory: @escaping GraphInteractiveSession.ProviderFactory,
         onCommitViewport: @escaping (GraphViewport) -> Void,
         onEdit: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        _session = StateObject(wrappedValue: GraphInteractiveSession(
            graph: graph, coordinator: coordinator, providerFactory: providerFactory
        ))
        self.graph = graph
        self.onCommitViewport = onCommitViewport
        self.onEdit = onEdit
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            GraphNativeFallbackSurface(graph: session.displayGraph)
                .opacity(session.representationState == .interactive ? 0 : 1)

            GraphProviderHost(session: session)
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
        .accessibilityElement(children: .contain)
        .onAppear { session.requestInteractivePresentation() }
        .onChange(of: graph) { _, updatedGraph in
            session.update(graph: updatedGraph)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )) { _ in lifecycleDemote(reason: .background) }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in lifecycleDemote(reason: .memoryPressure) }
        .onDisappear { lifecycleDemote(reason: .disappeared) }
    }

    private func finish(editing: Bool) {
        guard !isClosing else { return }
        isClosing = true
        Task { @MainActor in
            let viewport = await session.demote(reason: editing ? .edit : .done)
                ?? session.displayGraph.viewport
            onCommitViewport(viewport)
            if editing { onEdit() } else { onDone() }
        }
    }

    private func lifecycleDemote(reason: GraphProviderDemotionReason) {
        Task { @MainActor in
            if let viewport = await session.demote(reason: reason) {
                onCommitViewport(viewport)
            }
        }
    }
}

@MainActor
final class GraphProviderContainerView: UIView {
    weak var session: GraphInteractiveSession?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
        session?.hostDidLayout(bounds)
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
}

@MainActor
private struct GraphProviderHost: UIViewRepresentable {
    @ObservedObject var session: GraphInteractiveSession

    func makeUIView(context: Context) -> GraphProviderContainerView {
        let view = GraphProviderContainerView()
        view.session = session
        session.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: GraphProviderContainerView, context: Context) {
        uiView.session = session
        session.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: GraphProviderContainerView,
                                coordinator: ()) {
        let session = uiView.session
        session?.detach(from: uiView)
        uiView.session = nil
        Task { @MainActor in _ = await session?.demote(reason: .disappeared) }
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
    private var graphLayer: CALayer?

    init(graph: GraphObject) {
        self.graph = graph
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
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

    func update(graph: GraphObject) {
        guard self.graph != graph else { return }
        self.graph = graph
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        renderedSize = bounds.size
        let localGraph = graph.replacing(frame: GraphFrame(
            x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height)
        ))
        let replacement = GraphFallbackRenderer.layer(
            for: localGraph, contentsScale: window?.screen.scale ?? UIScreen.main.scale
        )
        replacement.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        graphLayer?.removeFromSuperlayer()
        layer.addSublayer(replacement)
        CATransaction.commit()
        graphLayer = replacement
    }
}
