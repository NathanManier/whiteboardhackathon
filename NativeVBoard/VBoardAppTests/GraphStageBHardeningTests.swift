import XCTest
import UIKit
@testable import VBoardApp

@MainActor
final class GraphStageBHardeningTests: XCTestCase {
    private let boardID = "603f5213ab0a249716833214c5ab88da"
    private var testAccountNamespace = ""

    override func setUp() {
        super.setUp()
        LocalAccountNamespace.activate("graph-stage-b-tests-\(UUID().uuidString)")
        testAccountNamespace = LocalAccountNamespace.value
    }

    override func tearDown() {
        GraphAcceptanceURLProtocolStub.handler = nil
        if !testAccountNamespace.isEmpty {
            let accountDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent(
                "VBoard/accounts/\(testAccountNamespace)", isDirectory: true
            )
            try? FileManager.default.removeItem(at: accountDirectory)
        }
        LocalAccountNamespace.clear()
        super.tearDown()
    }

    func testExpressionDraftPreservesCanonicalFieldsWhenSavedUnchanged() throws {
        let style = GraphExpressionDisplayStyle(
            color: "#2d70b3", lineWidth: 3, lineStyle: "dashed", opacity: 0.7,
            pointStyle: "open", additionalFields: ["future_style": .bool(true)]
        )
        let source = GraphExpression(
            id: "polar-1", latex: "r=2\\sin(3\\theta)", type: .polar,
            visible: false, displayStyle: style, restrictions: ["0<theta<pi"],
            additionalFields: ["future_expression": .string("retained")]
        )

        let saved = try GraphExpressionDraft(expression: source).expression()

        XCTAssertEqual(saved, source)
        XCTAssertEqual(saved.type, .polar)
        XCTAssertFalse(saved.visible)
    }

    func testNestedFutureFieldsSurviveGraphRoundTrip() throws {
        let data = Data(#"""
        {
          "id":"graph-future","type":"graph",
          "owning_board_id":"603f5213ab0a249716833214c5ab88da",
          "frame":{"x":0,"y":0,"width":400,"height":300},
          "expressions":[{"id":"e1","latex":"y=x","type":"explicitFunction","visible":true,
            "display_style":{"color":"#2d70b3","future_style":7}}],
          "viewport":{"x_min":-10,"x_max":10,"y_min":-10,"y_max":10,"future_viewport":"v"},
          "settings":{"show_x_axis":true,"show_y_axis":true,"show_grid":true,
            "show_expressions_panel":false,"lock_viewport":false,"angle_mode":"radians","future_setting":true},
          "source_selection":{"source_board_ids":["603f5213ab0a249716833214c5ab88da"],
            "selected_object_keys":["path-1"],"future_source":"s"},
          "provider_metadata":{"preference":"desmos","future_provider":{"n":1}},
          "created_at":1,"updated_at":2,"version":1
        }
        """#.utf8)
        let graph = try JSONDecoder().decode(GraphObject.self, from: data)

        XCTAssertEqual(graph.expressions[0].displayStyle?.additionalFields["future_style"],
                       .integer(7))
        XCTAssertEqual(graph.viewport.additionalFields["future_viewport"], .string("v"))
        XCTAssertEqual(graph.settings.additionalFields["future_setting"], .bool(true))
        XCTAssertEqual(graph.sourceSelection?.additionalFields["future_source"], .string("s"))
        XCTAssertEqual(graph.providerMetadata?.additionalFields["future_provider"],
                       .object(["n": .integer(1)]))

        let encoded = try JSONEncoder().encode(graph)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((root["settings"] as? [String: Any])?["future_setting"] as? Bool, true)
        XCTAssertEqual((root["viewport"] as? [String: Any])?["future_viewport"] as? String, "v")
    }

    func testPersistenceSanitizerRetainsSupportedNestedExtensionFields() throws {
        let graph = makeGraph(
            settings: GraphSettings(additionalFields: ["future_setting": .bool(true)]),
            source: GraphSourceSelection(
                sourceBoardIDs: [boardID], selectedObjectKeys: ["path-1"],
                additionalFields: ["future_source": .string("value")]
            ),
            provider: GraphProviderMetadata(
                preference: "desmos", additionalFields: ["future_provider": .integer(2)]
            )
        )

        let clean = try GraphPersistenceValidator.sanitized(graph, expectedBoardID: boardID)

        XCTAssertEqual(clean.settings.additionalFields["future_setting"], .bool(true))
        XCTAssertEqual(clean.sourceSelection?.additionalFields["future_source"], .string("value"))
        XCTAssertEqual(clean.providerMetadata?.additionalFields["future_provider"], .integer(2))
    }

    func testDenseGraphProvenanceIsSummarizedWithoutRejectingCreation() throws {
        let keys = (0..<GraphPersistenceValidator.maximumSelectedObjectKeyInputs).map {
            "\(boardID):professorPath:path-\($0)"
        }
        let graph = makeGraph(source: GraphSourceSelection(
            sourceBoardIDs: [boardID], selectedObjectKeys: keys
        ))

        let clean = try GraphPersistenceValidator.sanitized(graph,
                                                            expectedBoardID: boardID)
        let source = try XCTUnwrap(clean.sourceSelection)
        XCTAssertEqual(source.selectedObjectKeys, Array(keys.prefix(400)))
        XCTAssertEqual(source.additionalFields["selected_object_keys_truncated"], .bool(true))
        XCTAssertEqual(source.additionalFields["selected_object_key_count"],
                       .integer(Int64(keys.count)))
        guard case .string(let digest)? =
                source.additionalFields["selected_object_keys_sha256"] else {
            return XCTFail("Missing dense provenance digest")
        }
        XCTAssertEqual(digest.count, 64)
        XCTAssertNoThrow(try GraphPersistenceValidator.sanitized(clean,
                                                                 expectedBoardID: boardID))
    }

    func testFallbackParserUsesConventionalPrecedenceLogBaseAndDegreeMode() throws {
        XCTAssertEqual(try SafeGraphExpression(source: "-x^2").evaluate(x: 2), -4,
                       accuracy: 0.000_001)
        XCTAssertEqual(try SafeGraphExpression(source: "(-x)^2").evaluate(x: 2), 4,
                       accuracy: 0.000_001)
        XCTAssertEqual(try SafeGraphExpression(source: "log(100)").evaluate(x: 0), 2,
                       accuracy: 0.000_001)
        XCTAssertEqual(try SafeGraphExpression(source: "ln(e^2)").evaluate(x: 0), 2,
                       accuracy: 0.000_001)
        XCTAssertEqual(
            try SafeGraphExpression(source: "sin(x)", angleMode: "degrees").evaluate(x: 90),
            1, accuracy: 0.000_001
        )
    }

    func testFallbackInequalityHasBoundaryAndFillWithoutExecutingInput() {
        let expression = GraphExpression(id: "ineq-1", latex: "y>x^2",
                                         type: .inequality)
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let boundary = GraphFallbackSampler.path(for: expression,
                                                 viewport: .conventional, frame: frame)
        let fill = GraphFallbackSampler.inequalityFillPath(
            for: expression, viewport: .conventional, frame: frame
        )
        XCTAssertFalse(boundary.isEmpty)
        XCTAssertNotNil(fill)
        XCTAssertFalse(fill?.isEmpty ?? true)

        let unsafe = GraphExpression(id: "unsafe-1", latex: "y=javascript:alert(1)",
                                     type: .explicitFunction)
        XCTAssertTrue(GraphFallbackSampler.path(for: unsafe, viewport: .conventional,
                                                frame: frame).isEmpty)
    }

    func testFallbackNeverMisrepresentsUnsupportedDomainRestrictions() {
        let restricted = GraphExpression(
            id: "restricted-1", latex: "y=x^2", type: .explicitFunction,
            restrictions: ["-2<x<2"]
        )
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(GraphFallbackSampler.path(
            for: restricted, viewport: .conventional, frame: frame
        ).isEmpty)
    }

    func testProxyCacheKeyIsPrivateSemanticAndSizeSpecificAndMemoryBounded() {
        let cache = GraphProxyCache(countLimit: 2, totalCostLimit: 1_024)
        let graph = makeGraph()
        LocalAccountNamespace.activate("user-a")
        let first = cache.cacheKey(for: graph, size: CGSize(width: 400, height: 300),
                                   scale: 2, appearance: .light)
        let resized = cache.cacheKey(for: graph, size: CGSize(width: 500, height: 300),
                                     scale: 2, appearance: .light)
        let edited = cache.cacheKey(
            for: graph.replacing(expressions: [
                GraphExpression(id: "e1", latex: "y=x^3", type: .explicitFunction)
            ]), size: CGSize(width: 400, height: 300), scale: 2, appearance: .light
        )
        LocalAccountNamespace.activate("user-b")
        let otherAccount = cache.cacheKey(for: graph, size: CGSize(width: 400, height: 300),
                                          scale: 2, appearance: .light)

        XCTAssertNotEqual(first, resized)
        XCTAssertNotEqual(first, edited)
        XCTAssertNotEqual(first, otherAccount)
        XCTAssertLessThanOrEqual(
            cache.boundedRenderScale(for: CGSize(width: 10_000, height: 8_000),
                                     requestedScale: 4) * 10_000,
            GraphProxyCache.maximumPixelEdge + 0.001
        )
    }

    func testProviderSnapshotIsReusedAcrossPassiveCameraSizes() {
        let cache = GraphProxyCache(countLimit: 4, totalCostLimit: 1_024 * 1_024)
        let graph = makeGraph()
        let providerImage = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10))
            .image { context in
                UIColor.systemPurple.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            }
        cache.storeProviderSnapshot(providerImage, for: graph, appearance: .light)

        let zoomedOut = cache.nativeImage(
            for: graph, size: CGSize(width: 120, height: 90), scale: 1,
            appearance: .light
        )
        let zoomedIn = cache.nativeImage(
            for: graph, size: CGSize(width: 1_200, height: 900), scale: 3,
            appearance: .light
        )

        XCTAssertTrue(zoomedOut === providerImage)
        XCTAssertTrue(zoomedIn === providerImage)
    }

    func testProviderSnapshotReusePreservesGraphAspectRatio() {
        let cache = GraphProxyCache(countLimit: 4, totalCostLimit: 1_024 * 1_024)
        let wide = makeGraph(frame: GraphFrame(x: 0, y: 0, width: 800, height: 400))
        let proportionallyResized = wide.replacing(
            frame: GraphFrame(x: 0, y: 0, width: 400, height: 200)
        )
        let tall = wide.replacing(frame: GraphFrame(x: 0, y: 0,
                                                     width: 300, height: 600))

        XCTAssertEqual(
            cache.providerCacheKey(for: wide, appearance: .light),
            cache.providerCacheKey(for: proportionallyResized, appearance: .light)
        )
        XCTAssertNotEqual(
            cache.providerCacheKey(for: wide, appearance: .light),
            cache.providerCacheKey(for: tall, appearance: .light)
        )
    }

    func testNativeFallbackRasterPreservesExtremeCanonicalAspectRatio() {
        let graph = makeGraph(frame: GraphFrame(x: 0, y: 0, width: 32, height: 300))

        let image = GraphFallbackRenderer.image(for: graph, scale: 1)

        XCTAssertEqual(image.size.width, 32, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 300, accuracy: 0.001)
        XCTAssertEqual(image.size.width / image.size.height,
                       CGFloat(graph.frame.width / graph.frame.height),
                       accuracy: 0.000_001)
    }

    func testLateProviderSnapshotCannotRepopulatePurgedCache() {
        let cache = GraphProxyCache(countLimit: 4, totalCostLimit: 1_024 * 1_024)
        let capturedGeneration = cache.generation
        cache.removeAll()

        XCTAssertFalse(cache.storeProviderSnapshot(
            UIImage(), for: makeGraph(), appearance: .light,
            accountNamespace: LocalAccountNamespace.value,
            expectedGeneration: capturedGeneration
        ))
    }

    func testInteractiveGraphPencilPolicyHonorsEveryCanonicalTool() {
        XCTAssertTrue(GraphPencilInteractionPolicy.allowsAnnotation(for: .pen))
        XCTAssertTrue(GraphPencilInteractionPolicy.allowsAnnotation(for: .highlighter))
        XCTAssertFalse(GraphPencilInteractionPolicy.allowsAnnotation(for: .navigation))
        XCTAssertFalse(GraphPencilInteractionPolicy.allowsAnnotation(for: .select))
        XCTAssertFalse(GraphPencilInteractionPolicy.allowsAnnotation(for: .lasso))
        XCTAssertFalse(GraphPencilInteractionPolicy.allowsAnnotation(for: .objectEraser))
    }

    func testOutsideInteractionRoutesEachNewMixedContactByItsOwnType() {
        let heldFinger = GraphOutsideInteractionPolicy.Contact(
            point: CGPoint(x: 20, y: 20), type: .direct, phase: .stationary
        )
        let newPencil = GraphOutsideInteractionPolicy.Contact(
            point: CGPoint(x: 180, y: 140), type: .pencil, phase: .began
        )
        XCTAssertTrue(GraphOutsideInteractionPolicy.shouldPassThrough(
            contactAt: newPencil.point, contacts: [heldFinger, newPencil]
        ))

        let heldPencil = GraphOutsideInteractionPolicy.Contact(
            point: CGPoint(x: 180, y: 140), type: .pencil, phase: .stationary
        )
        let newFinger = GraphOutsideInteractionPolicy.Contact(
            point: CGPoint(x: 30, y: 24), type: .direct, phase: .began
        )
        XCTAssertFalse(GraphOutsideInteractionPolicy.shouldPassThrough(
            contactAt: newFinger.point, contacts: [heldPencil, newFinger]
        ))
    }

    func testGraphAnnotationOverlayUsesCanonicalOrderAndSparseStrokeBounds() {
        func stroke(_ id: String, points: [WorldPoint]) -> CanvasObject {
            CanvasObject(
                id: id, type: "stroke", color: "#183153", width: 4, opacity: 1,
                points: points, translation: nil, sourceMarkdown: nil, text: nil,
                x: nil, y: nil, height: nil, fontSize: nil
            )
        }
        let duplicateBefore = stroke("duplicate", points: [
            WorldPoint(x: 20, y: 20, pressure: 1)
        ])
        let graph = makeGraph(frame: GraphFrame(x: 10, y: 10, width: 100, height: 80))
        let horizontal = stroke("horizontal", points: [
            WorldPoint(x: 10, y: 50, pressure: 1),
            WorldPoint(x: 110, y: 50, pressure: 1)
        ])
        let vertical = stroke("vertical", points: [
            WorldPoint(x: 60, y: 10, pressure: 1),
            WorldPoint(x: 60, y: 90, pressure: 1)
        ])
        let canonicalAbove = GraphAnnotationOverlayPolicy.strokeObjectsAbove(
            graphID: graph.id,
            in: [duplicateBefore, CanvasObject(graph: graph),
                 stroke("duplicate", points: [WorldPoint(x: 40, y: 40, pressure: 1)]),
                 horizontal, vertical]
        )

        XCTAssertEqual(canonicalAbove.map(\.id), ["horizontal", "vertical"])
        XCTAssertTrue(GraphAnnotationOverlayPolicy.strokeIntersectsGraph(
            duplicateBefore, graphFrame: graph.frame.cgRect
        ))
        XCTAssertTrue(GraphAnnotationOverlayPolicy.strokeIntersectsGraph(
            horizontal, graphFrame: graph.frame.cgRect
        ))
        XCTAssertTrue(GraphAnnotationOverlayPolicy.strokeIntersectsGraph(
            vertical, graphFrame: graph.frame.cgRect
        ))
    }

    func testDemotionSnapshotDeadlineCannotBlockViewportCommitOrTeardown() async throws {
        let finalViewport = GraphViewport(xMin: -2, xMax: 3, yMin: -4, yMax: 5)
        let provider = ProviderStub(
            viewport: finalViewport, snapshotDelayNanoseconds: 2_000_000_000
        )
        let coordinator = GraphProviderCoordinator()
        let session = GraphInteractiveSession(
            graph: makeGraph(), coordinator: coordinator,
            snapshotTimeoutNanoseconds: 10_000_000
        ) { provider }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        await session.promoteNow(in: host)

        let startedAt = CACurrentMediaTime()
        let result = await session.demote(reason: .done)
        let elapsed = CACurrentMediaTime() - startedAt

        XCTAssertEqual(result?.graphID, "graph-one")
        XCTAssertEqual(result?.viewport, finalViewport)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertEqual(provider.unmountCount, 1)
        XCTAssertEqual(coordinator.activeProviderCount, 0)
        XCTAssertEqual(session.representationState, .proxy)
        let freeze = try XCTUnwrap(provider.events.firstIndex(of: "interactive:false"))
        let snapshot = try XCTUnwrap(provider.events.firstIndex(of: "snapshot"))
        let readback = try XCTUnwrap(provider.events.firstIndex(of: "read-viewport"))
        XCTAssertLessThan(freeze, snapshot)
        XCTAssertLessThan(snapshot, readback)
    }

    func testProviderViewportReadbackPreservesCanonicalExtensionFields() async {
        let originalViewport = GraphViewport(
            xMin: -10, xMax: 10, yMin: -10, yMax: 10,
            additionalFields: ["future_viewport": .string("retained")]
        )
        let providerViewport = GraphViewport(xMin: -3, xMax: 7, yMin: -8, yMax: 12)
        let provider = ProviderStub(viewport: providerViewport)
        let session = GraphInteractiveSession(
            graph: makeGraph(viewport: originalViewport),
            coordinator: GraphProviderCoordinator()
        ) { provider }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        await session.promoteNow(in: host)

        let result = await session.demote(reason: .done)

        XCTAssertEqual(result?.viewport.xMin, -3)
        XCTAssertEqual(result?.viewport.xMax, 7)
        XCTAssertEqual(result?.viewport.yMin, -8)
        XCTAssertEqual(result?.viewport.yMax, 12)
        XCTAssertEqual(result?.viewport.additionalFields["future_viewport"],
                       .string("retained"))
        XCTAssertEqual(session.displayGraph.viewport, result?.viewport)
    }

    func testViewportReadbackDeadlineFallsBackAndUnmounts() async {
        let fallback = GraphViewport(xMin: -7, xMax: 9, yMin: -4, yMax: 6)
        let provider = ProviderStub(
            viewport: GraphViewport(xMin: 50, xMax: 60, yMin: 70, yMax: 80),
            readViewportDelayNanoseconds: 2_000_000_000
        )

        let startedAt = CACurrentMediaTime()
        let viewport = await GraphProviderFinalizer.finish(
            provider, fallbackViewport: fallback, timeoutNanoseconds: 10_000_000
        )

        XCTAssertEqual(viewport, fallback)
        XCTAssertLessThan(CACurrentMediaTime() - startedAt, 0.5)
        XCTAssertEqual(provider.unmountCount, 1)
    }

    func testViewportReadbackDeadlineDoesNotClaimFallbackCameFromProvider() async {
        let fallback = GraphViewport(xMin: -7, xMax: 9, yMin: -4, yMax: 6)
        let provider = ProviderStub(
            viewport: GraphViewport(xMin: 50, xMax: 60, yMin: 70, yMax: 80),
            readViewportDelayNanoseconds: 2_000_000_000
        )

        let result = await GraphProviderFinalizer.finishWithProvenance(
            provider, fallbackViewport: fallback, timeoutNanoseconds: 10_000_000
        )

        XCTAssertEqual(result.viewport, fallback)
        XCTAssertNil(result.providerViewport)
        XCTAssertEqual(provider.unmountCount, 1)
    }

    func testConcurrentPromotionWaitsUntilPreviousProviderIsPhysicallyUnmounted() async {
        let tracker = ProviderMountTracker()
        let firstProvider = ProviderStub(
            viewport: .conventional, snapshotDelayNanoseconds: 120_000_000,
            mountTracker: tracker
        )
        let secondProvider = ProviderStub(viewport: .conventional,
                                          mountTracker: tracker)
        let coordinator = GraphProviderCoordinator()
        let first = GraphInteractiveSession(
            graph: makeGraph(id: "graph-first"), coordinator: coordinator
        ) { firstProvider }
        let second = GraphInteractiveSession(
            graph: makeGraph(id: "graph-second"), coordinator: coordinator
        ) { secondProvider }
        await first.promoteNow(in: GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        ))

        await second.promoteNow(in: GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        ))

        XCTAssertEqual(tracker.maximumMountedCount, 1)
        XCTAssertEqual(tracker.mountedCount, 1)
        XCTAssertEqual(firstProvider.unmountCount, 1)
        XCTAssertEqual(coordinator.activeGraphID, "graph-second")
        XCTAssertTrue(coordinator.activeProvider === secondProvider)
    }

    func testDemotionJoinsCancelledPromotionAndFinalizesProviderExactlyOnce() async {
        let activationGate = ProviderActivationGate()
        let finalViewport = GraphViewport(
            xMin: -23, xMax: 17, yMin: -9, yMax: 15
        )
        let provider = ProviderStub(
            viewport: finalViewport, activationGate: activationGate
        )
        let coordinator = GraphProviderCoordinator()
        let session = GraphInteractiveSession(
            graph: makeGraph(), coordinator: coordinator
        ) { provider }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        session.attach(to: host)
        session.requestInteractivePresentation()

        for _ in 0..<100 where !provider.events.contains("interactive:true") {
            await Task.yield()
        }
        XCTAssertTrue(provider.events.contains("interactive:true"))

        let demotion = Task { @MainActor in
            await session.demote(reason: .done)
        }
        for _ in 0..<100 where session.representationState != .demoting {
            await Task.yield()
        }
        XCTAssertEqual(session.representationState, .demoting)
        activationGate.open()

        let result = await demotion.value

        XCTAssertEqual(result?.viewport, finalViewport)
        XCTAssertEqual(session.displayGraph.viewport, finalViewport)
        XCTAssertEqual(provider.unmountCount, 1)
        XCTAssertEqual(provider.events.filter { $0 == "unmount" }.count, 1)
        XCTAssertEqual(coordinator.activeProviderCount, 0)
        XCTAssertEqual(session.representationState, .proxy)
    }

    func testDemotionDoesNotWaitForProviderThatIgnoresPromotionCancellation() async {
        let activationGate = ProviderActivationGate()
        let finalViewport = GraphViewport(
            xMin: -31, xMax: 11, yMin: -14, yMax: 19
        )
        let provider = ProviderStub(
            viewport: finalViewport, activationGate: activationGate
        )
        let coordinator = GraphProviderCoordinator()
        let session = GraphInteractiveSession(
            graph: makeGraph(), coordinator: coordinator
        ) { provider }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        session.attach(to: host)
        session.requestInteractivePresentation()

        for _ in 0..<100 where !provider.events.contains("interactive:true") {
            await Task.yield()
        }
        XCTAssertTrue(provider.events.contains("interactive:true"))

        var result: GraphDemotionResult?
        let completed = expectation(description: "bounded demotion")
        Task { @MainActor in
            result = await session.demote(reason: .done)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 0.75)

        XCTAssertEqual(result?.viewport, finalViewport)
        XCTAssertEqual(provider.unmountCount, 1)
        XCTAssertEqual(coordinator.activeProviderCount, 0)
        XCTAssertEqual(session.representationState, .proxy)

        // Let the deliberately non-cooperative provider call return after the
        // session has already demoted. Its late completion must be inert.
        activationGate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(provider.unmountCount, 1)
        XCTAssertEqual(coordinator.activeProviderCount, 0)
    }

    func testForegroundResumeWaitsForBackgroundDemotionThenPromotesAgain() async {
        let tracker = ProviderMountTracker()
        let firstProvider = ProviderStub(
            viewport: .conventional, snapshotDelayNanoseconds: 40_000_000,
            mountTracker: tracker
        )
        let secondProvider = ProviderStub(viewport: .conventional,
                                          mountTracker: tracker)
        var providers = [firstProvider, secondProvider]
        let coordinator = GraphProviderCoordinator()
        let session = GraphInteractiveSession(
            graph: makeGraph(), coordinator: coordinator
        ) { providers.isEmpty ? nil : providers.removeFirst() }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        await session.promoteNow(in: host)

        let demotion = Task { @MainActor in
            await session.demote(reason: .background)
        }
        for _ in 0..<20 where session.representationState != .demoting {
            await Task.yield()
        }
        XCTAssertEqual(session.representationState, .demoting)
        await session.resumeInteractivePresentationAfterLifecycleDemotion()
        _ = await demotion.value
        for _ in 0..<20 where session.representationState != .interactive {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(firstProvider.unmountCount, 1)
        XCTAssertEqual(session.representationState, .interactive)
        XCTAssertTrue(coordinator.activeProvider === secondProvider)
        XCTAssertEqual(tracker.maximumMountedCount, 1)
    }

    func testReplacingActiveGraphCannotApplyOldProviderViewportToNewGraph() async throws {
        let oldViewport = GraphViewport(xMin: -3, xMax: 4, yMin: -5, yMax: 6)
        let newViewport = GraphViewport(xMin: 40, xMax: 80, yMin: 10, yMax: 30)
        let firstProvider = ProviderStub(viewport: oldViewport)
        let secondProvider = ProviderStub(viewport: newViewport)
        var providers: [ProviderStub] = [firstProvider, secondProvider]
        let coordinator = GraphProviderCoordinator()
        let session = GraphInteractiveSession(
            graph: makeGraph(id: "graph-old", viewport: .conventional),
            coordinator: coordinator
        ) { providers.isEmpty ? nil : providers.removeFirst() }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        await session.promoteNow(in: host)

        session.update(graph: makeGraph(id: "graph-new", viewport: newViewport))
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(session.displayGraph.id, "graph-new")
        XCTAssertEqual(session.displayGraph.viewport, newViewport)
        XCTAssertNotEqual(session.displayGraph.viewport, oldViewport)
        XCTAssertEqual(firstProvider.unmountCount, 1)
        XCTAssertLessThanOrEqual(coordinator.activeProviderCount, 1)
    }

    func testRapidReplacementDuringSnapshotInstallsOnlyLatestGraphIdentity() async throws {
        let oldViewport = GraphViewport(xMin: -3, xMax: 4, yMin: -5, yMax: 6)
        let finalViewport = GraphViewport(xMin: 100, xMax: 140, yMin: 20, yMax: 50)
        let firstProvider = ProviderStub(
            viewport: oldViewport, snapshotDelayNanoseconds: 120_000_000
        )
        let finalProvider = ProviderStub(viewport: finalViewport)
        var providers = [firstProvider, finalProvider]
        let coordinator = GraphProviderCoordinator()
        var forcedIdentity: (boardID: String, graphID: String)?
        let session = GraphInteractiveSession(
            graph: makeGraph(id: "graph-old"), coordinator: coordinator,
            onForcedViewportCommit: { boardID, graphID, _ in
                forcedIdentity = (boardID, graphID)
            }
        ) { providers.isEmpty ? nil : providers.removeFirst() }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        await session.promoteNow(in: host)

        session.update(graph: makeGraph(id: "graph-intermediate"))
        await Task.yield()
        session.update(graph: makeGraph(id: "graph-final", viewport: finalViewport))
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(session.displayGraph.id, "graph-final")
        XCTAssertEqual(session.displayGraph.viewport, finalViewport)
        XCTAssertNotEqual(session.displayGraph.viewport, oldViewport)
        XCTAssertEqual(firstProvider.unmountCount, 1)
        XCTAssertLessThanOrEqual(coordinator.activeProviderCount, 1)
        XCTAssertEqual(coordinator.activeGraphID, "graph-final")
        XCTAssertEqual(forcedIdentity?.boardID, boardID)
        XCTAssertEqual(forcedIdentity?.graphID, "graph-old")

        forcedIdentity = nil
        let other = GraphInteractiveSession(
            graph: makeGraph(id: "graph-other"), coordinator: coordinator
        ) { ProviderStub(viewport: .conventional) }
        await other.promoteNow(in: GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        ))
        XCTAssertEqual(forcedIdentity?.boardID, boardID)
        XCTAssertEqual(forcedIdentity?.graphID, "graph-final")
    }

    func testReplacementSequenceReturningToOriginalIdentityKeepsNewestRequest() async throws {
        let firstProvider = ProviderStub(
            viewport: .conventional, snapshotDelayNanoseconds: 120_000_000
        )
        let returnedViewport = GraphViewport(xMin: -22, xMax: 18,
                                             yMin: -14, yMax: 11)
        let returnedProvider = ProviderStub(viewport: returnedViewport)
        var providers = [firstProvider, returnedProvider]
        let coordinator = GraphProviderCoordinator()
        let session = GraphInteractiveSession(
            graph: makeGraph(id: "graph-a"), coordinator: coordinator
        ) { providers.isEmpty ? nil : providers.removeFirst() }
        let host = GraphProviderContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 320)
        )
        host.layoutIfNeeded()
        await session.promoteNow(in: host)

        session.update(graph: makeGraph(id: "graph-b"))
        await Task.yield()
        session.update(graph: makeGraph(id: "graph-a", viewport: returnedViewport))
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(session.displayGraph.id, "graph-a")
        XCTAssertEqual(session.displayGraph.viewport, returnedViewport)
        XCTAssertEqual(coordinator.activeGraphID, "graph-a")
        XCTAssertTrue(coordinator.activeProvider === returnedProvider)
        XCTAssertEqual(firstProvider.unmountCount, 1)
        XCTAssertLessThanOrEqual(coordinator.activeProviderCount, 1)
    }

    func testRecognitionSignatureTracksSelectedVisualMutationButIgnoresCamera() throws {
        let document = SVGDocument(viewBox: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   paths: [])
        func editor(middleY: Double, cameraX: Double) -> EditorState {
            let stroke = CanvasObject(
                id: "stroke-visual", type: "stroke", color: "#183153", width: 4,
                opacity: 1,
                points: [
                    WorldPoint(x: 0, y: 0, pressure: 1),
                    WorldPoint(x: 5, y: middleY, pressure: 1),
                    WorldPoint(x: 10, y: 10, pressure: 1)
                ],
                translation: nil, sourceMarkdown: nil, text: nil,
                x: nil, y: nil, height: nil, fontSize: nil
            )
            return EditorState(
                schemaVersion: 4, revision: 7, updatedAt: nil,
                viewport: CameraRect(x: cameraX, y: -20, width: 800, height: 600),
                objects: [stroke], groups: [], importedTransforms: [:],
                sourceBoards: [], mergedBoardIDs: []
            )
        }
        let original = try XCTUnwrap(BoardStudySelection.isolated(
            boardID: boardID, selectedIDs: ["stroke-visual"], document: document,
            editor: editor(middleY: 5, cameraX: 0)
        ))
        let cameraOnly = try XCTUnwrap(BoardStudySelection.isolated(
            boardID: boardID, selectedIDs: ["stroke-visual"], document: document,
            editor: editor(middleY: 5, cameraX: 3_000)
        ))
        let mutatedInsideSameBounds = try XCTUnwrap(BoardStudySelection.isolated(
            boardID: boardID, selectedIDs: ["stroke-visual"], document: document,
            editor: editor(middleY: 8, cameraX: 0)
        ))

        XCTAssertEqual(GraphRecognitionTarget.board(original).cacheSignature,
                       GraphRecognitionTarget.board(cameraOnly).cacheSignature)
        XCTAssertNotEqual(GraphRecognitionTarget.board(original).cacheSignature,
                          GraphRecognitionTarget.board(mutatedInsideSameBounds).cacheSignature)
    }

    func testLecturePlacementUsesConvertedWorldSourceButKeepsLocalProvenance() throws {
        let localBBox = try XCTUnwrap(StudySelectionBBox(
            rect: CGRect(x: 20, y: 30, width: 180, height: 60)
        ))
        let selection = BoardStudySelection(
            boardID: boardID, canonicalObjectIDs: ["stroke-visual"],
            localBBox: localBBox, selectedTextObjects: [],
            lectureWorldBBox: CGRect(x: 2_020, y: -970, width: 180, height: 60)
        )
        let graph = GraphObjectFactory.make(
            boardID: boardID, selection: selection,
            expressions: [GraphExpression(id: "e1", latex: "y=x^2",
                                          type: .explicitFunction)],
            recognitionRequestID: "0123456789abcdef", cameraScale: 1,
            occupied: [], placementSource: CGRect(x: 2_020, y: -970,
                                                   width: 180, height: 60)
        )

        XCTAssertGreaterThan(graph.frame.x, 2_000)
        XCTAssertEqual(graph.sourceSelection?.originalSelectionBBox,
                       GraphFrame(x: 20, y: 30, width: 180, height: 60))
    }

    func testGraphTransformsRemainWithinServerPersistenceRange() {
        let graph = makeGraph(frame: GraphFrame(x: 9_999_999, y: -9_999_999,
                                                width: 400, height: 300))
        let moved = graph.translated(by: CGPoint(x: 1_000, y: -1_000))
        let resized = graph.resized(to: CGSize(width: 20_000_000, height: 1))

        XCTAssertEqual(moved.frame.x, 10_000_000)
        XCTAssertEqual(moved.frame.y, -10_000_000)
        XCTAssertEqual(resized.frame.width, 10_000_000)
        XCTAssertEqual(resized.frame.height, 32)
    }

    func testPencilOverInteractiveGraphMapsIntoOwningBoardWorldCoordinates() throws {
        let frame = GraphFrame(x: -240, y: 80, width: 800, height: 400)
        let bounds = CGRect(x: 20, y: 40, width: 400, height: 200)

        let topLeft = GraphPencilCoordinateMapper.strokePoint(
            localPoint: CGPoint(x: 20, y: 40), in: bounds,
            graphFrame: frame, pressure: 0.25
        )
        let center = GraphPencilCoordinateMapper.strokePoint(
            localPoint: CGPoint(x: 220, y: 140), in: bounds,
            graphFrame: frame, pressure: 2
        )

        XCTAssertEqual(topLeft.x, -240, accuracy: 0.000_001)
        XCTAssertEqual(topLeft.y, 80, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(topLeft.pressure), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(center.x, 160, accuracy: 0.000_001)
        XCTAssertEqual(center.y, 280, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(center.pressure), 1, accuracy: 0.000_001)
        let roundTrip = GraphPencilCoordinateMapper.localPoint(
            strokePoint: center, in: bounds, graphFrame: frame
        )
        XCTAssertEqual(roundTrip.x, 220, accuracy: 0.000_001)
        XCTAssertEqual(roundTrip.y, 140, accuracy: 0.000_001)
    }

    func testGraphFrameDrivesHitTestingAndMixedCanonicalSelectionBounds() throws {
        let professorPath = "M -200 -40 L -160 -40 L -160 0 L -200 0 Z"
        let document = try SVGDocument.parse(
            "<svg viewBox='-240 -80 900 500'><path id='prof-1' d='\(professorPath)'/></svg>"
        )
        let graph = makeGraph(
            frame: GraphFrame(x: -120, y: 40, width: 360, height: 240)
        )
        let note = CanvasObject(
            id: "note-1", type: "text", color: "#183153", width: 200,
            opacity: 1, points: nil, translation: nil,
            sourceMarkdown: "Keep source exact", text: "Keep source exact",
            x: 300, y: 100, height: 100, fontSize: 24
        )
        let graphObject = CanvasObject(graph: graph)
        let objects = [graphObject, note]

        XCTAssertEqual(BoardHitTestPolicy.bounds(of: graphObject), graph.frame.cgRect)
        XCTAssertEqual(
            BoardHitTestPolicy.topmostEditorObjectID(
                at: CGPoint(x: 0, y: 100), objects: objects, tolerance: 0
            ),
            graph.id
        )
        XCTAssertNil(BoardHitTestPolicy.topmostEditorObjectID(
            at: CGPoint(x: 280, y: 20), objects: objects, tolerance: 0
        ))

        let editor = EditorState(
            schemaVersion: 4, revision: 3, updatedAt: nil,
            viewport: CameraRect(x: -300, y: -100, width: 1_000, height: 700),
            objects: objects, groups: [], importedTransforms: [:],
            sourceBoards: [], mergedBoardIDs: []
        )
        let selection = try XCTUnwrap(BoardStudySelection.isolated(
            boardID: boardID, selectedIDs: [graph.id, note.id, "prof-1"],
            document: document, editor: editor
        ))

        XCTAssertEqual(selection.canonicalObjectIDs, [graph.id, note.id, "prof-1"])
        XCTAssertEqual(selection.localBBox.cgRect,
                       CGRect(x: -200, y: -40, width: 700, height: 320))
        XCTAssertEqual(selection.selectedTextObjects.map(\.id), [graph.id, note.id])
        XCTAssertEqual(selection.selectedTextObjects.first?.role, "graph")
        XCTAssertEqual(selection.selectedTextObjects.first?.text, "y=x^2")
        XCTAssertEqual(document.paths.first?.d, professorPath)
    }

    func testGraphCreateMoveResizeEditDeleteAreUndoableCanonicalMutations() throws {
        let mutationBoardID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let source = makeGraph(
            owningBoardID: mutationBoardID,
            source: GraphSourceSelection(
                sourceBoardIDs: [mutationBoardID],
                selectedObjectKeys: ["professorPath:equation-1"]
            )
        )
        let initial = EditorState(
            schemaVersion: 4, revision: 5, updatedAt: nil,
            viewport: CameraRect(x: -400, y: -300, width: 1_200, height: 900),
            objects: [], groups: [], importedTransforms: [:],
            sourceBoards: [], mergedBoardIDs: []
        )
        let store = BoardDocumentStore(boardID: mutationBoardID, editor: initial)
        let api = APIClient(baseURL: URL(string: "https://graph-history.invalid")!)

        store.addGraph(source, api: api)
        XCTAssertEqual(store.editor.objects.compactMap(\.graph), [source])
        store.undo(api: api)
        XCTAssertTrue(store.editor.objects.isEmpty)
        store.redo(api: api)
        XCTAssertEqual(store.editor.objects.compactMap(\.graph), [source])

        store.moveObject(id: source.id, by: CGPoint(x: 75, y: -25), api: api)
        let moved = try XCTUnwrap(store.editor.objects.first?.graph)
        XCTAssertEqual(moved.frame.x, source.frame.x + 75)
        XCTAssertEqual(moved.frame.y, source.frame.y - 25)
        XCTAssertEqual(moved.sourceSelection, source.sourceSelection)
        store.undo(api: api)
        XCTAssertEqual(store.editor.objects.first?.graph, source)
        store.redo(api: api)
        XCTAssertEqual(store.editor.objects.first?.graph, moved)

        store.scaleObjects(ids: [source.id], around: .zero, by: 0.001, api: api)
        let resized = try XCTUnwrap(store.editor.objects.first?.graph)
        XCTAssertGreaterThanOrEqual(resized.frame.width, GraphFrame.minimumDimension)
        XCTAssertGreaterThanOrEqual(resized.frame.height, GraphFrame.minimumDimension)
        XCTAssertEqual(resized.frame.height, GraphFrame.minimumDimension,
                       accuracy: 0.000_001)
        XCTAssertEqual(resized.expressions, source.expressions)
        store.undo(api: api)
        XCTAssertEqual(store.editor.objects.first?.graph, moved)
        store.redo(api: api)
        XCTAssertEqual(store.editor.objects.first?.graph, resized)

        let edited = resized
            .replacing(expressions: [
                GraphExpression(id: "e1", latex: "y=x^3", type: .explicitFunction)
            ])
            .replacing(viewport: GraphViewport(xMin: -4, xMax: 6,
                                               yMin: -8, yMax: 12))
        let canonicalEdited = try GraphPersistenceValidator.sanitized(
            edited, expectedBoardID: mutationBoardID
        )
        store.replaceGraph(edited, api: api)
        XCTAssertEqual(store.editor.objects.first?.graph?.expressions.first?.latex,
                       "y=x^3")
        store.undo(api: api)
        XCTAssertEqual(store.editor.objects.first?.graph, resized)
        store.redo(api: api)
        XCTAssertEqual(store.editor.objects.first?.graph, canonicalEdited)

        store.deleteObjects(ids: [source.id], api: api)
        XCTAssertTrue(store.editor.objects.isEmpty)
        store.undo(api: api)
        XCTAssertEqual(store.editor.objects.first?.graph, canonicalEdited)
        XCTAssertEqual(store.editor.objects.filter { $0.id == source.id }.count, 1)
        store.redo(api: api)
        XCTAssertTrue(store.editor.objects.isEmpty)
    }

    func testMixedGraphNoteAndProfessorResizeUsesOneBoundedFactor() throws {
        let mutationBoardID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let graph = makeGraph(
            owningBoardID: mutationBoardID,
            frame: GraphFrame(x: 20, y: 30, width: 80, height: 64)
        )
        let note = CanvasObject(
            id: "note-mixed", type: "text", color: "#183153", width: 200,
            opacity: 1, points: nil, translation: nil,
            sourceMarkdown: "Canonical $x^2$ source", text: "Canonical $x^2$ source",
            x: 200, y: 50, height: 100, fontSize: 24
        )
        let initial = EditorState(
            schemaVersion: 4, revision: 9, updatedAt: nil,
            viewport: CameraRect(x: 0, y: 0, width: 800, height: 600),
            objects: [CanvasObject(graph: graph), note], groups: [],
            importedTransforms: [
                "prof-1": ObjectTransform(x: 0, y: 0, scaleX: 1,
                                           scaleY: 1, deleted: false)
            ],
            sourceBoards: [], mergedBoardIDs: []
        )
        let store = BoardDocumentStore(boardID: mutationBoardID, editor: initial)
        let api = APIClient(baseURL: URL(string: "https://mixed-resize.invalid")!)

        store.scaleObjects(
            editorObjectIDs: [graph.id, note.id], professorPathIDs: ["prof-1"],
            around: .zero, by: 0.1, api: api
        )

        let resizedGraph = try XCTUnwrap(
            store.editor.objects.first(where: { $0.id == graph.id })?.graph
        )
        let resizedNote = try XCTUnwrap(
            store.editor.objects.first(where: { $0.id == note.id })
        )
        XCTAssertEqual(resizedGraph.frame,
                       GraphFrame(x: 10, y: 15, width: 40, height: 32))
        XCTAssertEqual(BoardHitTestPolicy.bounds(of: resizedNote),
                       CGRect(x: 100, y: 25, width: 100, height: 50))
        XCTAssertEqual(resizedNote.sourceMarkdown, note.sourceMarkdown)
        XCTAssertEqual(store.editor.importedTransforms["prof-1"]?.scaleX, 0.5)
        XCTAssertEqual(store.editor.importedTransforms["prof-1"]?.scaleY, 0.5)
        XCTAssertFalse(store.editor.objects.contains(where: { $0.id == "prof-1" }))

        store.undo(api: api)
        XCTAssertEqual(store.editor, initial)
        store.redo(api: api)
        XCTAssertEqual(store.editor.objects.first(where: { $0.id == graph.id })?.graph,
                       resizedGraph)
        XCTAssertEqual(store.editor.objects.first(where: { $0.id == note.id })?.sourceMarkdown,
                       note.sourceMarkdown)
    }

    func testCrossBoardMixedGraphSelectionsStayBoardLocalWithSharedObjectIDs() throws {
        let secondBoardID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let graphID = "graph-shared"
        let professorPath = "M -40 -30 L -10 -30 L -10 0 L -40 0 Z"
        let firstDocument = try SVGDocument.parse(
            "<svg viewBox='-100 -100 900 700'><path id='prof-1' d='\(professorPath)'/></svg>"
        )
        let secondDocument = try SVGDocument.parse(
            "<svg viewBox='-200 -100 800 600'></svg>"
        )
        let firstGraph = makeGraph(
            id: graphID, owningBoardID: boardID,
            frame: GraphFrame(x: 10, y: 20, width: 400, height: 300)
        )
        let secondGraph = makeGraph(
            id: graphID, owningBoardID: secondBoardID,
            frame: GraphFrame(x: -100, y: 40, width: 200, height: 120)
        ).replacing(expressions: [
            GraphExpression(id: "e1", latex: "y=sin(x)", type: .explicitFunction)
        ])
        let note = CanvasObject(
            id: "note-1", type: "text", color: "#183153", width: 200,
            opacity: 1, points: nil, translation: nil,
            sourceMarkdown: "Compare both graphs", text: "Compare both graphs",
            x: 300, y: 100, height: 100, fontSize: 24
        )
        let firstEditor = EditorState(
            schemaVersion: 4, revision: 2, updatedAt: nil,
            viewport: CameraRect(x: -100, y: -100, width: 900, height: 700),
            objects: [CanvasObject(graph: firstGraph), note], groups: [],
            importedTransforms: [:], sourceBoards: [], mergedBoardIDs: []
        )
        let secondEditor = EditorState(
            schemaVersion: 4, revision: 4, updatedAt: nil,
            viewport: CameraRect(x: -200, y: -100, width: 800, height: 600),
            objects: [CanvasObject(graph: secondGraph)], groups: [],
            importedTransforms: [:], sourceBoards: [], mergedBoardIDs: []
        )
        let firstItem = makeWorkspaceItem(boardID: boardID, x: 1_000, y: -500)
        let secondItem = makeWorkspaceItem(boardID: secondBoardID, x: -2_000, y: 800)
        let firstScene = makeScene(boardID: boardID, document: firstDocument,
                                   editor: firstEditor)
        let secondScene = makeScene(boardID: secondBoardID, document: secondDocument,
                                    editor: secondEditor)
        let keys: Set<SelectionKey> = [
            SelectionKey(boardID: boardID, objectID: graphID,
                         kind: .editorObject, objectType: "graph"),
            SelectionKey(boardID: boardID, objectID: note.id,
                         kind: .editorObject, objectType: "text"),
            SelectionKey(boardID: boardID, objectID: "prof-1",
                         kind: .professorPath, objectType: "professorPath"),
            SelectionKey(boardID: secondBoardID, objectID: graphID,
                         kind: .editorObject, objectType: "graph")
        ]

        let firstSelection = try XCTUnwrap(BoardStudySelection.lecture(
            boardID: boardID, selectionKeys: keys, item: firstItem, scene: firstScene
        ))
        let secondSelection = try XCTUnwrap(BoardStudySelection.lecture(
            boardID: secondBoardID, selectionKeys: keys,
            item: secondItem, scene: secondScene
        ))

        XCTAssertEqual(firstSelection.canonicalObjectIDs, [graphID, note.id, "prof-1"])
        XCTAssertEqual(firstSelection.localBBox.cgRect,
                       CGRect(x: -40, y: -30, width: 540, height: 350))
        XCTAssertEqual(firstSelection.lectureWorldBBox,
                       CGRect(x: 960, y: -530, width: 540, height: 350))
        XCTAssertEqual(firstSelection.selectedTextObjects.map(\.id), [graphID, note.id])
        XCTAssertEqual(secondSelection.canonicalObjectIDs, [graphID])
        XCTAssertEqual(secondSelection.localBBox.cgRect,
                       CGRect(x: -100, y: 40, width: 200, height: 120))
        XCTAssertEqual(secondSelection.lectureWorldBBox,
                       CGRect(x: -2_100, y: 840, width: 200, height: 120))
        XCTAssertEqual(secondSelection.selectedTextObjects.first?.text, "y=sin(x)")

        let target = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            selections: [firstSelection, secondSelection],
            preferredPrimaryBoardID: secondBoardID
        ))
        guard case .lecture(let lectureTarget) = target else {
            return XCTFail("A cross-board graph selection must keep both board-local selections")
        }
        XCTAssertEqual(lectureTarget.primaryBoardID, secondBoardID)
        XCTAssertEqual(Set(lectureTarget.selections.map(\.boardID)),
                       Set([boardID, secondBoardID]))
        XCTAssertEqual(lectureTarget.selections.first(where: { $0.boardID == boardID })?
            .canonicalObjectIDs, [graphID, note.id, "prof-1"])
        XCTAssertEqual(firstDocument.paths.first?.d, professorPath)
    }

    func testGraphSaveAcknowledgementReopensFinalCanonicalState() async throws {
        let persistenceBoardID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let source = makeGraph(
            owningBoardID: persistenceBoardID,
            source: GraphSourceSelection(
                interactionID: "0123456789abcdef",
                sourceBoardIDs: [persistenceBoardID],
                selectedObjectKeys: ["stroke-equation"],
                originalRecognitionRequestID: "fedcba9876543210",
                originalSelectionBBox: GraphFrame(x: -20, y: 10,
                                                  width: 160, height: 60)
            ),
            provider: GraphProviderMetadata(
                preference: "desmos", state: .object(["opaque": .bool(true)])
            )
        )
        let initial = EditorState(
            schemaVersion: 4, revision: 17, updatedAt: nil,
            viewport: CameraRect(x: -500, y: -300, width: 1_200, height: 900),
            objects: [], groups: [], importedTransforms: [:],
            sourceBoards: [], mergedBoardIDs: []
        )
        var saveRequestCount = 0
        var loadRequestCount = 0
        var serverEditor = initial
        GraphAcceptanceURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path,
                           "/api/boards/\(persistenceBoardID)/editor")
            switch request.httpMethod {
            case "PUT":
                var candidate = try JSONDecoder().decode(
                    EditorState.self, from: try graphAcceptanceRequestBody(request)
                )
                saveRequestCount += 1
                candidate.revision = 18
                serverEditor = candidate
            case "GET":
                loadRequestCount += 1
            default:
                XCTFail("Unexpected graph persistence method \(request.httpMethod ?? "nil")")
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(EditorEnvelope(editor: serverEditor))
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphAcceptanceURLProtocolStub.self]
        let api = APIClient(
            baseURL: URL(string: "https://graph-persistence.test")!,
            session: URLSession(configuration: configuration)
        )
        let store = BoardDocumentStore(boardID: persistenceBoardID, editor: initial)

        store.addGraph(source, api: api)
        store.moveObject(id: source.id, by: CGPoint(x: 85, y: -45), api: api)
        let moved = try XCTUnwrap(store.editor.objects.first?.graph)
        let finalGraph = moved
            .replacing(expressions: [
                GraphExpression(id: "e1", latex: "y=x^3-2",
                                type: .explicitFunction, visible: false),
                GraphExpression(id: "e2", latex: "y=sin(x)",
                                type: .explicitFunction)
            ])
            .replacing(viewport: GraphViewport(xMin: -6, xMax: 9,
                                               yMin: -12, yMax: 15))
            .replacing(settings: GraphSettings(
                showXAxis: true, showYAxis: true, showGrid: false,
                showExpressionsPanel: true, lockViewport: true,
                angleMode: "degrees"
            ))
        store.replaceGraph(finalGraph, api: api)
        await store.saveNow(api: api)

        XCTAssertEqual(saveRequestCount, 1)
        XCTAssertEqual(store.status, .clean)
        XCTAssertEqual(store.editor.revision, 18)
        let fetched = try await api.editor(id: persistenceBoardID)
        let reopened = BoardDocumentStore(boardID: persistenceBoardID, editor: fetched)
        reopened.restoreLocalIfPresent(server: fetched)
        let reopenedGraph = try XCTUnwrap(reopened.editor.objects.first?.graph)

        XCTAssertEqual(loadRequestCount, 1)
        XCTAssertEqual(reopened.status, .clean)
        XCTAssertEqual(reopened.editor.revision, 18)
        XCTAssertEqual(reopened.editor.objects.count, 1)
        XCTAssertEqual(reopenedGraph.id, source.id)
        XCTAssertEqual(reopenedGraph.owningBoardID, persistenceBoardID)
        XCTAssertEqual(reopenedGraph.frame, finalGraph.frame)
        XCTAssertEqual(reopenedGraph.expressions, finalGraph.expressions)
        XCTAssertEqual(reopenedGraph.viewport, finalGraph.viewport)
        XCTAssertEqual(reopenedGraph.settings, finalGraph.settings)
        XCTAssertEqual(reopenedGraph.sourceSelection, source.sourceSelection)
        XCTAssertEqual(reopenedGraph.providerMetadata, source.providerMetadata)
        XCTAssertTrue(SceneComposition.build(
            boardID: persistenceBoardID,
            document: SVGDocument(viewBox: .zero, paths: []),
            editor: reopened.editor
        ).duplicateLogicalIDs.isEmpty)
    }

    func testGraphAccessibilityUsesOneReadableSemanticLabel() {
        let graph = makeGraph().replacing(expressions: [
            GraphExpression(id: "e1", latex: "y=x^2-4", type: .explicitFunction)
        ])

        XCTAssertEqual(GraphAccessibility.label(for: graph),
                       "Graph, y equals x squared minus 4")
    }

    func testNearMaximumGraphAndMixedMemberUseOneBoundedResizeFactor() throws {
        let mutationBoardID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let graph = makeGraph(
            owningBoardID: mutationBoardID,
            frame: GraphFrame(x: 0, y: 0, width: 8_000_000, height: 2_000_000)
        )
        let note = CanvasObject(
            id: "note-near-maximum", type: "text", color: "#183153", width: 800,
            opacity: 1, points: nil, translation: nil,
            sourceMarkdown: "Preserve this source", text: "Preserve this source",
            x: 1_000, y: 2_000, height: 400, fontSize: 24
        )
        let initial = EditorState(
            schemaVersion: 4, revision: 1, updatedAt: nil,
            viewport: CameraRect(x: 0, y: 0, width: 800, height: 600),
            objects: [CanvasObject(graph: graph), note], groups: [],
            importedTransforms: [
                "prof-maximum": ObjectTransform(x: 0, y: 0, scaleX: 1,
                                                  scaleY: 1, deleted: false)
            ], sourceBoards: [], mergedBoardIDs: []
        )
        let store = BoardDocumentStore(boardID: mutationBoardID, editor: initial)
        let api = APIClient(baseURL: URL(string: "https://resize-maximum.invalid")!)

        let applied = store.scaleObjects(
            editorObjectIDs: [graph.id, note.id], professorPathIDs: ["prof-maximum"],
            around: .zero, by: 2, api: api
        )

        XCTAssertEqual(try XCTUnwrap(applied), 1.25, accuracy: 0.000_001)
        let resizedGraph = try XCTUnwrap(
            store.editor.objects.first(where: { $0.id == graph.id })?.graph
        )
        XCTAssertEqual(resizedGraph.frame.width, 10_000_000, accuracy: 0.001)
        XCTAssertEqual(resizedGraph.frame.height, 2_500_000, accuracy: 0.001)
        XCTAssertEqual(resizedGraph.frame.width / resizedGraph.frame.height,
                       graph.frame.width / graph.frame.height, accuracy: 0.000_001)
        let resizedNote = try XCTUnwrap(
            store.editor.objects.first(where: { $0.id == note.id })
        )
        XCTAssertEqual(try XCTUnwrap(resizedNote.width), 1_000, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(resizedNote.height), 500, accuracy: 0.000_001)
        let professorTransform = try XCTUnwrap(
            store.editor.importedTransforms["prof-maximum"]
        )
        XCTAssertEqual(try XCTUnwrap(professorTransform.scaleX),
                       1.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(professorTransform.scaleY),
                       1.25, accuracy: 0.000_001)
    }

    func testGraphOriginBoundConstrainsWholeSelectionBeforePerFieldClamp() throws {
        let mutationBoardID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let graph = makeGraph(
            owningBoardID: mutationBoardID,
            frame: GraphFrame(x: 9_000_000, y: -8_000_000,
                              width: 100_000, height: 80_000)
        )
        let note = CanvasObject(
            id: "origin-note", type: "text", color: "#183153", width: 900,
            opacity: 1, points: nil, translation: nil,
            sourceMarkdown: "Moves rigidly", text: "Moves rigidly",
            x: 4_500_000, y: 100, height: 450, fontSize: 24
        )
        let initial = EditorState(
            schemaVersion: 4, revision: 1, updatedAt: nil,
            viewport: CameraRect(x: 0, y: 0, width: 800, height: 600),
            objects: [CanvasObject(graph: graph), note], groups: [],
            importedTransforms: [:], sourceBoards: [], mergedBoardIDs: []
        )
        let store = BoardDocumentStore(boardID: mutationBoardID, editor: initial)
        let api = APIClient(baseURL: URL(string: "https://resize-origin.invalid")!)

        let applied = store.scaleObjects(
            editorObjectIDs: [graph.id, note.id], professorPathIDs: [],
            around: .zero, by: 2, api: api
        )

        let factor = try XCTUnwrap(applied)
        XCTAssertEqual(factor, 10.0 / 9.0, accuracy: 0.000_001)
        let resizedGraph = try XCTUnwrap(store.editor.objects.first?.graph)
        XCTAssertEqual(resizedGraph.frame.x, 10_000_000, accuracy: 0.001)
        XCTAssertEqual(resizedGraph.frame.y, graph.frame.y * Double(factor), accuracy: 0.001)
        let resizedNote = try XCTUnwrap(store.editor.objects.first(where: { $0.id == note.id }))
        XCTAssertEqual(try XCTUnwrap(resizedNote.width),
                       try XCTUnwrap(note.width) * Double(factor), accuracy: 0.001)
        XCTAssertEqual((resizedNote.translation?.x ?? 0) + (resizedNote.x ?? 0),
                       (note.x ?? 0) * Double(factor), accuracy: 0.001)
    }

    func testGraphAtMinimumShrinkIsNoOpWithoutUndoOrRetainedPreviewFactor() throws {
        let mutationBoardID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let graph = makeGraph(
            owningBoardID: mutationBoardID,
            frame: GraphFrame(x: 10, y: 20, width: 32, height: 64)
        )
        let initial = EditorState(
            schemaVersion: 4, revision: 4, updatedAt: nil,
            viewport: CameraRect(x: 0, y: 0, width: 800, height: 600),
            objects: [CanvasObject(graph: graph)], groups: [],
            importedTransforms: [:], sourceBoards: [], mergedBoardIDs: []
        )
        let store = BoardDocumentStore(boardID: mutationBoardID, editor: initial)
        let api = APIClient(baseURL: URL(string: "https://resize-noop.invalid")!)
        let bounds = try XCTUnwrap(store.selectionScaleBounds(
            editorObjectIDs: [graph.id], professorPathIDs: [], around: .zero
        ))

        XCTAssertNil(bounds.clampedFactor(0.5),
                     "The canvas uses nil to clear, rather than retain, its transient proxy")
        XCTAssertNil(store.scaleObjects(ids: [graph.id], around: .zero, by: 0.5, api: api))
        XCTAssertEqual(store.editor, initial)
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)
    }

    func testCrossBoardScaleConstraintsIntersectBeforeEitherBoardCommits() throws {
        let firstBoardID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let secondBoardID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let minimumGraph = makeGraph(
            id: "graph-minimum", owningBoardID: firstBoardID,
            frame: GraphFrame(x: 0, y: 0, width: 32, height: 64)
        )
        let maximumGraph = makeGraph(
            id: "graph-maximum", owningBoardID: secondBoardID,
            frame: GraphFrame(x: 0, y: 0, width: 8_000_000, height: 2_000_000)
        )
        var shared = try XCTUnwrap(SelectionScaleBounds.selection(
            objects: [CanvasObject(graph: minimumGraph)], importedTransforms: [:],
            editorObjectIDs: [minimumGraph.id], professorPathIDs: [], anchor: .zero
        ))
        let second = try XCTUnwrap(SelectionScaleBounds.selection(
            objects: [CanvasObject(graph: maximumGraph)], importedTransforms: [:],
            editorObjectIDs: [maximumGraph.id], professorPathIDs: [], anchor: .zero
        ))
        shared.formIntersection(second)

        XCTAssertNil(shared.clampedFactor(0.5),
                     "One board at its minimum makes the whole shrink gesture a no-op")
        XCTAssertEqual(try XCTUnwrap(shared.clampedFactor(2)), 1.25,
                       accuracy: 0.000_001)
    }

    private func makeGraph(
        id: String = "graph-one",
        owningBoardID: String? = nil,
        frame: GraphFrame = GraphFrame(x: 10, y: 20, width: 400, height: 300),
        viewport: GraphViewport = .conventional,
        settings: GraphSettings = GraphSettings(),
        source: GraphSourceSelection? = nil,
        provider: GraphProviderMetadata? = nil
    ) -> GraphObject {
        GraphObject(
            id: id, owningBoardID: owningBoardID ?? boardID, frame: frame,
            expressions: [GraphExpression(id: "e1", latex: "y=x^2",
                                          type: .explicitFunction)],
            viewport: viewport, settings: settings, sourceSelection: source,
            providerMetadata: provider, createdAt: 1, updatedAt: 2
        )
    }

    private func makeWorkspaceItem(boardID: String, x: Double,
                                   y: Double) -> WorkspaceBoardItem {
        WorkspaceBoardItem(
            id: "board:\(boardID)", kind: "board", boardID: boardID,
            canvasX: x, canvasY: y, boardWidth: 800, boardHeight: 600,
            effectiveContentBounds: CameraRect(x: x, y: y, width: 800, height: 600),
            createdAt: 1, capturedAt: nil, detectedBoardDate: nil,
            unitLabel: "Unit 1", unitNumber: 1, unitConfidence: 1,
            unitSource: .manual, title: "Board", thumbnailURL: nil, zIndex: 0
        )
    }

    private func makeScene(boardID: String, document: SVGDocument,
                           editor: EditorState) -> WorkspaceBoardScene {
        WorkspaceBoardScene(
            boardID: boardID, document: document, pdfData: nil, editor: editor,
            composition: SceneComposition.build(
                boardID: boardID, document: document, editor: editor
            )
        )
    }

    private final class ProviderMountTracker {
        private(set) var mountedCount = 0
        private(set) var maximumMountedCount = 0

        func mounted() {
            mountedCount += 1
            maximumMountedCount = max(maximumMountedCount, mountedCount)
        }

        func unmounted() { mountedCount = max(0, mountedCount - 1) }
    }

    private final class ProviderActivationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class ProviderStub: GraphResizableRendererProvider {
        let identifier = "hardening-stub"
        let isAvailable = true
        let view = UIView()
        var viewport: GraphViewport?
        var unmountCount = 0
        var events: [String] = []
        let snapshotDelayNanoseconds: UInt64
        let readViewportDelayNanoseconds: UInt64
        let mountTracker: ProviderMountTracker?
        let activationGate: ProviderActivationGate?
        private var isMounted = false

        init(viewport: GraphViewport?, snapshotDelayNanoseconds: UInt64 = 0,
             readViewportDelayNanoseconds: UInt64 = 0,
             mountTracker: ProviderMountTracker? = nil,
             activationGate: ProviderActivationGate? = nil) {
            self.viewport = viewport
            self.snapshotDelayNanoseconds = snapshotDelayNanoseconds
            self.readViewportDelayNanoseconds = readViewportDelayNanoseconds
            self.mountTracker = mountTracker
            self.activationGate = activationGate
        }
        func mount(graph: GraphObject, in frame: CGRect) async throws {
            events.append("mount")
            view.frame = frame
            if !isMounted {
                isMounted = true
                mountTracker?.mounted()
            }
        }
        func update(graph: GraphObject) async throws {
            events.append("update")
            viewport = graph.viewport
        }
        func setInteractive(_ interactive: Bool) async throws {
            events.append("interactive:\(interactive)")
            if interactive, let activationGate {
                await activationGate.wait()
            }
        }
        func readViewport() async -> GraphViewport? {
            events.append("read-viewport")
            if readViewportDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: readViewportDelayNanoseconds)
            }
            return viewport
        }
        func captureSnapshot() async throws -> UIImage {
            events.append("snapshot")
            if snapshotDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: snapshotDelayNanoseconds)
            }
            return UIImage()
        }
        func resize(to frame: CGRect) async throws { view.frame = frame }
        func unmount() {
            events.append("unmount")
            unmountCount += 1
            if isMounted {
                isMounted = false
                mountTracker?.unmounted()
            }
            view.removeFromSuperview()
        }
    }
}

private final class GraphAcceptanceURLProtocolStub: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func graphAcceptanceRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw URLError(.cannotDecodeContentData)
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 16_384
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while true {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
