import XCTest
@preconcurrency import WebKit
import UIKit
@testable import VBoardApp

@MainActor
final class GraphInteractiveSurfaceTests: XCTestCase {
    private final class ProviderStub: GraphResizableRendererProvider {
        let identifier: String
        let isAvailable: Bool
        let view = UIView()
        var viewport: GraphViewport?
        private(set) var mountCount = 0
        private(set) var updateCount = 0
        private(set) var interactionValues: [Bool] = []
        private(set) var resizeFrames: [CGRect] = []
        private(set) var unmountCount = 0
        let mountDelayNanoseconds: UInt64
        let updateDelayNanoseconds: UInt64
        private(set) var updatedGraphs: [GraphObject] = []
        private(set) var maximumConcurrentUpdates = 0
        private var concurrentUpdates = 0

        init(identifier: String = "stub", isAvailable: Bool = true,
             viewport: GraphViewport? = nil,
             mountDelayNanoseconds: UInt64 = 0,
             updateDelayNanoseconds: UInt64 = 0) {
            self.identifier = identifier
            self.isAvailable = isAvailable
            self.viewport = viewport
            self.mountDelayNanoseconds = mountDelayNanoseconds
            self.updateDelayNanoseconds = updateDelayNanoseconds
        }

        func mount(graph: GraphObject, in frame: CGRect) async throws {
            if mountDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: mountDelayNanoseconds)
            }
            mountCount += 1
            view.frame = frame
            if viewport == nil { viewport = graph.viewport }
        }

        func update(graph: GraphObject) async throws {
            concurrentUpdates += 1
            maximumConcurrentUpdates = max(maximumConcurrentUpdates, concurrentUpdates)
            defer { concurrentUpdates -= 1 }
            if updateDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: updateDelayNanoseconds)
            }
            updateCount += 1
            updatedGraphs.append(graph)
            viewport = graph.viewport
        }

        func setInteractive(_ interactive: Bool) async throws {
            interactionValues.append(interactive)
        }

        func readViewport() async -> GraphViewport? { viewport }

        func captureSnapshot() async throws -> UIImage { UIImage() }

        func resize(to frame: CGRect) async throws {
            resizeFrames.append(frame)
            view.frame = frame
        }

        func unmount() {
            unmountCount += 1
            view.removeFromSuperview()
        }
    }

    private func graph(id: String = "graph-lifecycle-1",
                       viewport: GraphViewport = .conventional) -> GraphObject {
        GraphObject(
            id: id,
            owningBoardID: "603f5213ab0a249716833214c5ab88da",
            frame: GraphFrame(x: -40, y: 25, width: 480, height: 300),
            expressions: [
                GraphExpression(id: "expression-1", latex: "y=x^2",
                                type: .explicitFunction)
            ],
            viewport: viewport,
            settings: GraphSettings(),
            createdAt: 1,
            updatedAt: 2
        )
    }

    private func host() -> GraphProviderContainerView {
        let host = GraphProviderContainerView(frame: CGRect(x: 0, y: 0,
                                                             width: 640, height: 420))
        host.layoutIfNeeded()
        return host
    }

    func testPassiveSessionDoesNotConstructProviderOrWebView() {
        var factoryCount = 0
        let session = GraphInteractiveSession(
            graph: graph(), coordinator: GraphProviderCoordinator()
        ) {
            factoryCount += 1
            return ProviderStub()
        }

        XCTAssertEqual(factoryCount, 0)
        XCTAssertEqual(session.representationState, .proxy)
        XCTAssertFalse(session.hasLiveProviderView)

        let fallback = GraphFallbackHostView(graph: graph())
        fallback.frame = CGRect(x: 0, y: 0, width: 640, height: 420)
        fallback.layoutIfNeeded()
        XCTAssertFalse(containsWebView(fallback))
    }

    func testMissingConfigurationStaysOnNativeFallbackWithoutProviderView() async {
        var factoryCount = 0
        let session = GraphInteractiveSession(
            graph: graph(), coordinator: GraphProviderCoordinator()
        ) {
            factoryCount += 1
            return nil
        }
        let host = host()

        await session.promoteNow(in: host)

        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(session.representationState, .failed)
        XCTAssertFalse(session.hasLiveProviderView)
        XCTAssertTrue(host.subviews.isEmpty)
        XCTAssertNotNil(session.providerError)
    }

    func testPromotionAndDoneDemotionReturnCanonicalViewportAndTearDown() async {
        let finalViewport = GraphViewport(xMin: -3.5, xMax: 14.25,
                                          yMin: -8, yMax: 5.75)
        let provider = ProviderStub(viewport: finalViewport)
        let coordinator = GraphProviderCoordinator()
        let session = GraphInteractiveSession(graph: graph(), coordinator: coordinator) {
            provider
        }
        let host = host()

        await session.promoteNow(in: host)
        XCTAssertEqual(session.representationState, .interactive)
        XCTAssertEqual(coordinator.activeProviderCount, 1)
        XCTAssertEqual(provider.mountCount, 1)
        XCTAssertEqual(provider.interactionValues, [true])
        XCTAssertTrue(session.hasLiveProviderView)

        let committed = await session.demote(reason: .done)

        XCTAssertEqual(committed?.graphID, "graph-lifecycle-1")
        XCTAssertEqual(committed?.viewport, finalViewport)
        XCTAssertEqual(session.displayGraph.viewport, finalViewport)
        XCTAssertEqual(session.representationState, .proxy)
        XCTAssertEqual(coordinator.activeProviderCount, 0)
        XCTAssertEqual(provider.interactionValues, [true, false])
        XCTAssertEqual(provider.unmountCount, 1)
        XCTAssertFalse(session.hasLiveProviderView)
    }

    func testCoordinatorNeverKeepsTwoActiveProviders() async throws {
        let coordinator = GraphProviderCoordinator()
        let first = ProviderStub(identifier: "first")
        let second = ProviderStub(identifier: "second")
        let frame = CGRect(x: 0, y: 0, width: 500, height: 320)

        try await coordinator.promote(graph: graph(id: "graph-one"),
                                      provider: first, frame: frame)
        try await coordinator.promote(graph: graph(id: "graph-two"),
                                      provider: second, frame: frame)

        XCTAssertEqual(coordinator.activeProviderCount, 1)
        XCTAssertEqual(coordinator.activeGraphID, "graph-two")
        XCTAssertTrue(coordinator.activeProvider === second)
        XCTAssertEqual(first.unmountCount, 1)
        XCTAssertEqual(second.unmountCount, 0)
    }

    func testConcurrentPromotionsAreSerializedAndNewestProviderOwnsBudget() async throws {
        let coordinator = GraphProviderCoordinator()
        let slowFirst = ProviderStub(identifier: "slow-first",
                                     mountDelayNanoseconds: 100_000_000)
        let fastSecond = ProviderStub(identifier: "fast-second")
        let frame = CGRect(x: 0, y: 0, width: 500, height: 320)

        let firstTask = Task { @MainActor in
            try await coordinator.promote(
                graph: graph(id: "graph-one"), provider: slowFirst, frame: frame
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        let secondTask = Task { @MainActor in
            try await coordinator.promote(
                graph: graph(id: "graph-two"), provider: fastSecond, frame: frame
            )
        }

        try await firstTask.value
        try await secondTask.value

        XCTAssertEqual(coordinator.activeProviderCount, 1)
        XCTAssertEqual(coordinator.activeGraphID, "graph-two")
        XCTAssertTrue(coordinator.activeProvider === fastSecond)
        XCTAssertEqual(slowFirst.unmountCount, 1)
        XCTAssertEqual(fastSecond.unmountCount, 0)
    }

    func testSameIdentityUpdateQueuedDuringMountReconcilesBeforeInteractive() async throws {
        let provider = ProviderStub(mountDelayNanoseconds: 100_000_000)
        let session = GraphInteractiveSession(
            graph: graph(), coordinator: GraphProviderCoordinator()
        ) { provider }
        let host = host()
        let finalViewport = GraphViewport(xMin: -4, xMax: 9, yMin: -12, yMax: 7)
        let updated = graph(viewport: finalViewport)

        let promotion = Task { @MainActor in await session.promoteNow(in: host) }
        try await Task.sleep(nanoseconds: 5_000_000)
        session.update(graph: updated)
        await promotion.value

        XCTAssertEqual(session.representationState, .interactive)
        XCTAssertEqual(session.displayGraph, updated)
        XCTAssertEqual(provider.viewport, finalViewport)
        XCTAssertEqual(provider.updateCount, 1)
    }

    func testActivatingSecondSessionDemotesFirstAndCommitsItsViewport() async {
        let coordinator = GraphProviderCoordinator()
        let firstViewport = GraphViewport(xMin: -18, xMax: 7, yMin: -4, yMax: 12)
        let firstProvider = ProviderStub(identifier: "first", viewport: firstViewport)
        let secondProvider = ProviderStub(identifier: "second")
        var forcedViewport: GraphViewport?
        let firstSession = GraphInteractiveSession(
            graph: graph(id: "graph-one"), coordinator: coordinator,
            onForcedViewportCommit: { _, _, viewport in forcedViewport = viewport },
            providerFactory: { firstProvider }
        )
        let secondSession = GraphInteractiveSession(
            graph: graph(id: "graph-two"), coordinator: coordinator
        ) { secondProvider }

        await firstSession.promoteNow(in: host())
        await secondSession.promoteNow(in: host())

        XCTAssertEqual(firstSession.representationState, .proxy)
        XCTAssertEqual(firstSession.displayGraph.viewport, firstViewport)
        XCTAssertEqual(forcedViewport, firstViewport)
        XCTAssertEqual(firstProvider.interactionValues, [true, false])
        XCTAssertEqual(firstProvider.unmountCount, 1)
        XCTAssertEqual(secondSession.representationState, .interactive)
        XCTAssertEqual(coordinator.activeGraphID, "graph-two")
        XCTAssertEqual(coordinator.activeProviderCount, 1)
    }

    func testResetViewUpdatesCanonicalDisplayAndActiveProvider() async {
        let provider = ProviderStub()
        let originalViewport = GraphViewport(
            xMin: 40, xMax: 80, yMin: -2, yMax: 18,
            additionalFields: ["future_viewport": .string("preserve-me")]
        )
        let session = GraphInteractiveSession(
            graph: graph(viewport: originalViewport),
            coordinator: GraphProviderCoordinator()
        ) { provider }
        let host = host()
        await session.promoteNow(in: host)

        session.resetView()
        let expected = originalViewport.resettingToConventionalBounds()
        for _ in 0..<20 where provider.viewport != expected {
            await Task.yield()
        }

        XCTAssertEqual(session.displayGraph.viewport, expected)
        XCTAssertEqual(provider.viewport, expected)
        XCTAssertEqual(provider.updateCount, 1)
    }

    func testRapidSameIdentityUpdatesAreSerializedAndLatestStateWins() async throws {
        let provider = ProviderStub(updateDelayNanoseconds: 40_000_000)
        let session = GraphInteractiveSession(
            graph: graph(), coordinator: GraphProviderCoordinator()
        ) { provider }
        await session.promoteNow(in: host())
        let first = graph(viewport: GraphViewport(xMin: -1, xMax: 1,
                                                  yMin: -2, yMax: 2))
        let middle = graph(viewport: GraphViewport(xMin: -3, xMax: 3,
                                                   yMin: -4, yMax: 4))
        let latest = graph(viewport: GraphViewport(xMin: -8, xMax: 12,
                                                   yMin: -6, yMax: 9))

        session.update(graph: first)
        try await Task.sleep(nanoseconds: 5_000_000)
        session.update(graph: middle)
        session.update(graph: latest)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(session.displayGraph, latest)
        XCTAssertEqual(provider.updatedGraphs.last, latest)
        XCTAssertEqual(provider.viewport, latest.viewport)
        XCTAssertEqual(provider.maximumConcurrentUpdates, 1)
        XCTAssertLessThanOrEqual(provider.updateCount, 2)
    }

    func testResetViewImmediatelyFollowedByDoneKeepsCanonicalResetViewport() async {
        GraphProxyCache.shared.removeAll()
        let original = GraphViewport(xMin: 40, xMax: 80, yMin: -2, yMax: 18)
        let provider = ProviderStub(viewport: original,
                                    updateDelayNanoseconds: 500_000_000)
        let session = GraphInteractiveSession(
            graph: graph(viewport: original), coordinator: GraphProviderCoordinator()
        ) { provider }
        await session.promoteNow(in: host())

        session.resetView()
        let result = await session.demote(reason: .done)

        XCTAssertEqual(result?.viewport, .conventional)
        XCTAssertEqual(session.displayGraph.viewport, .conventional)
        XCTAssertEqual(session.representationState, .proxy)
        XCTAssertNil(GraphProxyCache.shared.image(
            for: session.displayGraph, size: CGSize(width: 640, height: 420),
            scale: 2, appearance: .light
        ))
    }

    func testConfigurationPinsVersionAndRejectsSecretsThatAreNotConfigured() throws {
        XCTAssertNil(DesmosConfiguration(apiKey: nil).apiKey)
        XCTAssertNil(DesmosConfiguration(apiKey: "placeholder-key").apiKey)
        XCTAssertNil(DesmosConfiguration(apiKey: "$(VBOARD_DESMOS_API_KEY)").apiKey)

        let configured = DesmosConfiguration(apiKey: "issued-key-123")
        XCTAssertEqual(configured.scriptURL?.path, "/api/v1.12/calculator.js")
        let components = try XCTUnwrap(configured.scriptURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })
        XCTAssertEqual(components.queryItems,
                       [URLQueryItem(name: "apiKey", value: "issued-key-123")])
        XCTAssertEqual(DesmosConfiguration.stableAPIVersion, "v1.12")
    }

    func testBridgeAcceptsOnlyExpectedGraphNonceAndFiniteViewport() {
        let valid: [String: Any] = [
            "version": 1,
            "event": "viewportChanged",
            "graphID": "graph-1",
            "nonce": "nonce-1",
            "viewport": ["xMin": -10, "xMax": 10, "yMin": -6, "yMax": 6]
        ]
        let decoded = DesmosBridgeMessage.decode(
            valid, expectedGraphID: "graph-1", expectedNonce: "nonce-1"
        )
        XCTAssertEqual(decoded?.viewport, GraphViewport(xMin: -10, xMax: 10,
                                                         yMin: -6, yMax: 6))
        XCTAssertNil(DesmosBridgeMessage.decode(
            valid, expectedGraphID: "graph-2", expectedNonce: "nonce-1"
        ))
        XCTAssertNil(DesmosBridgeMessage.decode(
            valid, expectedGraphID: "graph-1", expectedNonce: "nonce-2"
        ))

        var invalid = valid
        invalid["viewport"] = ["xMin": Double.nan, "xMax": 10,
                               "yMin": -6, "yMax": 6]
        XCTAssertNil(DesmosBridgeMessage.decode(
            invalid, expectedGraphID: "graph-1", expectedNonce: "nonce-1"
        ))
    }

    private func containsWebView(_ root: UIView) -> Bool {
        if root is WKWebView { return true }
        return root.subviews.contains(where: containsWebView)
    }
}
