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

        init(identifier: String = "stub", isAvailable: Bool = true,
             viewport: GraphViewport? = nil) {
            self.identifier = identifier
            self.isAvailable = isAvailable
            self.viewport = viewport
        }

        func mount(graph: GraphObject, in frame: CGRect) async throws {
            mountCount += 1
            view.frame = frame
            if viewport == nil { viewport = graph.viewport }
        }

        func update(graph: GraphObject) async throws {
            updateCount += 1
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

        XCTAssertEqual(committed, finalViewport)
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

    func testResetViewUpdatesCanonicalDisplayAndActiveProvider() async {
        let provider = ProviderStub()
        let session = GraphInteractiveSession(
            graph: graph(viewport: GraphViewport(xMin: 40, xMax: 80,
                                                 yMin: -2, yMax: 18)),
            coordinator: GraphProviderCoordinator()
        ) { provider }
        let host = host()
        await session.promoteNow(in: host)

        session.resetView()
        await Task.yield()

        XCTAssertEqual(session.displayGraph.viewport, .conventional)
        XCTAssertEqual(provider.viewport, .conventional)
        XCTAssertEqual(provider.updateCount, 1)
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
