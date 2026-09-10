import XCTest
@preconcurrency import WebKit
@testable import VBoardApp

@MainActor
private final class WebViewNavigationWaiter: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation

    init(finished: XCTestExpectation) {
        self.finished = finished
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }
}

final class WorldScreenTransformTests: XCTestCase {
    func testCanvasCoordinateMapperConvertsFromOffsetSourceView() {
        let canvas = UIView(frame: CGRect(x: 40, y: 30, width: 800, height: 400))
        let source = UIView(frame: CGRect(x: 100, y: 80, width: 200, height: 100))
        canvas.addSubview(source)
        let camera = CameraRect(x: -100, y: -50, width: 400, height: 200)
        let raw = CGPoint(x: 25, y: 15)
        let canvasPoint = source.convert(raw, to: canvas)
        let world = CanvasCoordinateMapper.viewPointToWorld(raw, from: source, in: canvas, camera: camera)
        let roundTrip = CanvasCoordinateMapper.worldToViewPoint(world, in: canvas, camera: camera)
        XCTAssertEqual(roundTrip.x, canvasPoint.x, accuracy: 0.0001)
        XCTAssertEqual(roundTrip.y, canvasPoint.y, accuracy: 0.0001)
    }

    func testWorldScreenRoundTripWithNegativeCoordinates() {
        let transform = WorldScreenTransform(camera: CameraRect(x: -200, y: -100, width: 800, height: 400), viewport: CGSize(width: 1200, height: 600))
        let world = CGPoint(x: -50.25, y: 22.75)
        let screen = transform.screenPoint(for: world)
        XCTAssertEqual(transform.worldPoint(for: screen).x, world.x, accuracy: 0.0001)
        XCTAssertEqual(transform.worldPoint(for: screen).y, world.y, accuracy: 0.0001)
    }

    func testRootCanvasRoundTripAcrossViewportShapesAndZoomLevels() {
        let cases: [(CameraRect, CGSize, CGPoint)] = [
            (CameraRect(x: 0, y: 0, width: 100, height: 100), CGSize(width: 1024, height: 768), CGPoint(x: 17, y: 23)),
            (CameraRect(x: 240, y: -180, width: 400, height: 200), CGSize(width: 1366, height: 820), CGPoint(x: 901, y: 117)),
            (CameraRect(x: -1600, y: -900, width: 80, height: 45), CGSize(width: 834, height: 1194), CGPoint(x: 412, y: 733)),
            (CameraRect(x: -8, y: 12, width: 2400, height: 1350), CGSize(width: 1194, height: 834), CGPoint(x: 101, y: 702))
        ]
        for (camera, viewport, screen) in cases {
            let transform = WorldScreenTransform(camera: camera, viewport: viewport)
            let world = transform.worldPoint(for: screen)
            let roundTrip = transform.screenPoint(for: world)
            XCTAssertEqual(roundTrip.x, screen.x, accuracy: 0.000001)
            XCTAssertEqual(roundTrip.y, screen.y, accuracy: 0.000001)
        }
    }

    func testPanMovesVisibleWorldOppositeFinger() {
        var camera = CameraController(camera: CameraRect(x: 0, y: 0, width: 100, height: 100))
        camera.pan(screenTranslation: CGPoint(x: 100, y: 0), viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(camera.camera.x, -100, accuracy: 0.0001)
    }

    func testPanUsesTotalDeltaWithoutCumulativeDrift() {
        let start = CameraRect(x: -320, y: 140, width: 800, height: 400)
        let viewport = CGSize(width: 1200, height: 600)
        var camera = CameraController(camera: start)
        camera.pan(screenTranslation: CGPoint(x: 160, y: -40), viewport: viewport)
        let once = camera.camera
        camera.setCamera(start)
        camera.pan(screenTranslation: CGPoint(x: 80, y: -20), viewport: viewport)
        camera.setCamera(start)
        camera.pan(screenTranslation: CGPoint(x: 160, y: -40), viewport: viewport)
        XCTAssertEqual(camera.camera, once)
        XCTAssertEqual(camera.camera.x, start.x - 160.0 / 1.5, accuracy: 0.000001)
        XCTAssertEqual(camera.camera.y, start.y + 40.0 / 1.5, accuracy: 0.000001)
    }

    func testPinchRetainsWorldAnchorAndClampsZoom() {
        var camera = CameraController(camera: CameraRect(x: 0, y: 0, width: 100, height: 100))
        let viewport = CGSize(width: 100, height: 100)
        camera.zoom(by: 2, anchoredAt: CGPoint(x: 50, y: 50), viewport: viewport)
        XCTAssertEqual(camera.camera.center.x, 50, accuracy: 0.0001)
        XCTAssertEqual(camera.camera.width, 50, accuracy: 0.0001)
    }

    func testPinchKeepsWorldPointUnderMovingMidpoint() {
        let viewport = CGSize(width: 1_000, height: 600)
        let start = CameraRect(x: -200, y: -100, width: 1_000, height: 600)
        let startMidpoint = CGPoint(x: 420, y: 260)
        let currentMidpoint = CGPoint(x: 560, y: 330)
        let anchor = WorldScreenTransform(camera: start, viewport: viewport).worldPoint(for: startMidpoint)

        var controller = CameraController(camera: start)
        controller.pinch(startCamera: start,
                         startMidpoint: startMidpoint,
                         currentMidpoint: currentMidpoint,
                         magnification: 1.75,
                         viewport: viewport)

        let transformed = WorldScreenTransform(camera: controller.camera, viewport: viewport)
        let finalScreen = transformed.screenPoint(for: anchor)
        XCTAssertEqual(finalScreen.x, currentMidpoint.x, accuracy: 0.0001)
        XCTAssertEqual(finalScreen.y, currentMidpoint.y, accuracy: 0.0001)
        XCTAssertLessThan(controller.camera.width, start.width)
    }

    func testCameraTransformMovesWorldPixelsWhenCameraPans() {
        let viewport = CGSize(width: 800, height: 400)
        let start = CameraRect(x: 0, y: 0, width: 800, height: 400)
        let startTransform = WorldScreenTransform(camera: start, viewport: viewport)
        var controller = CameraController(camera: start)
        controller.pan(screenTranslation: CGPoint(x: 200, y: 75), viewport: viewport)
        let endTransform = WorldScreenTransform(camera: controller.camera, viewport: viewport)
        let worldPoint = CGPoint(x: 300, y: 150)
        let startScreen = startTransform.screenPoint(for: worldPoint)
        let endScreen = endTransform.screenPoint(for: worldPoint)
        XCTAssertEqual(endScreen.x - startScreen.x, 200, accuracy: 0.0001)
        XCTAssertEqual(endScreen.y - startScreen.y, 75, accuracy: 0.0001)
        XCTAssertNotEqual(startTransform.affineTransform, endTransform.affineTransform)
    }

    func testFitBoardCentersTheFullNonZeroViewBox() {
        let board = CGRect(x: 120, y: -40, width: 1_600, height: 800)
        let viewport = CGSize(width: 820, height: 1_106)
        let camera = CameraResolver.fitBoard(boardRect: board, viewport: viewport)
        let transform = WorldScreenTransform(camera: camera, viewport: viewport)
        let boardOnScreen = CGRect(origin: transform.screenPoint(for: board.origin),
                                   size: CGSize(width: board.width * transform.scale,
                                                height: board.height * transform.scale))
        XCTAssertTrue(boardOnScreen.minX >= -0.5)
        XCTAssertTrue(boardOnScreen.maxX <= viewport.width + 0.5)
        XCTAssertTrue(boardOnScreen.minY >= -0.5)
        XCTAssertTrue(boardOnScreen.maxY <= viewport.height + 0.5)
        XCTAssertEqual(camera.center.x, board.midX, accuracy: 0.0001)
        XCTAssertEqual(camera.center.y, board.midY, accuracy: 0.0001)
    }

    func testResolverFitsInvalidOrHistoricalCamera() {
        let board = CGRect(x: 0, y: 0, width: 1_711, height: 455)
        let viewport = CGSize(width: 820, height: 1_106)
        let invalid = CameraRect(x: .nan, y: .infinity, width: 0, height: -2)
        let result = CameraResolver.resolve(persisted: invalid, boardRect: board,
                                             contentBounds: board, viewport: viewport)
        XCTAssertEqual(result.reason, .boardInitialFit)
        XCTAssertEqual(result.camera, CameraResolver.fitBoard(boardRect: board, viewport: viewport))

        // This was a valid landscape viewport, but it is now completely
        // outside the board and must not teleport the portrait editor to an
        // old off-board location.
        let stale = CameraRect(x: 10_000, y: 10_000, width: 1_200, height: 700)
        let staleResult = CameraResolver.resolve(persisted: stale, boardRect: board,
                                                 contentBounds: board, viewport: viewport)
        XCTAssertEqual(staleResult.reason, .boardInitialFit)
    }

    func testResolverPreservesIntentionalZoomWithViewportAspect() {
        let board = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let viewport = CGSize(width: 820, height: 1_106)
        let fitted = CameraResolver.fitBoard(boardRect: board, viewport: viewport)
        let zoomed = CameraRect(x: fitted.x + fitted.width * 0.22,
                                y: fitted.y + fitted.height * 0.22,
                                width: fitted.width * 0.35,
                                height: fitted.height * 0.35)
        let result = CameraResolver.resolve(persisted: zoomed, boardRect: board,
                                            contentBounds: board, viewport: viewport)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.camera, zoomed)
    }

    func testPanDeltaHasNoMutationForZeroMovement() {
        let start = CameraRect(x: -12, y: 24, width: 600, height: 400)
        var camera = CameraController(camera: start)
        camera.pan(screenTranslation: .zero, viewport: CGSize(width: 820, height: 1_106))
        XCTAssertEqual(camera.camera, start)
    }
}

final class SpatialIndexTests: XCTestCase {
    func testViewportQueryHandlesNegativeCoordinatesAndExactIntersection() {
        var index = SpatialIndex(cellSize: 100)
        index.insert(id: "negative", bounds: CGRect(x: -180, y: -40, width: 30, height: 30))
        index.insert(id: "visible", bounds: CGRect(x: 110, y: 110, width: 20, height: 20))
        index.insert(id: "far", bounds: CGRect(x: 1000, y: 1000, width: 20, height: 20))
        XCTAssertEqual(index.query(CGRect(x: -200, y: -50, width: 80, height: 80)), ["negative"])
        XCTAssertEqual(index.query(CGRect(x: 100, y: 100, width: 50, height: 50)), ["visible"])
        XCTAssertTrue(index.query(CGRect(x: 0, y: 0, width: 50, height: 50)).isEmpty)
    }

    func testLargeViewportDoesNotReturnObjectsOutsideBounds() {
        var index = SpatialIndex(cellSize: 64)
        for i in 0..<500 { index.insert(id: "p\(i)", bounds: CGRect(x: CGFloat(i * 100), y: 0, width: 10, height: 10)) }
        let result = index.query(CGRect(x: 1000, y: -20, width: 100, height: 50))
        XCTAssertEqual(result, ["p10"])
    }
}

final class SVGDocumentTests: XCTestCase {
    func testParserPreservesCanonicalPathAndEvenOddHoles() throws {
        let d = "M 0 0 L 40 0 L 40 40 L 0 40 Z M 10 10 L 30 10 L 30 30 L 10 30 Z"
        let svg = "<svg viewBox='-10 -20 100 80'><path id='prof-1' d='\(d)' fill='#183153' fill-rule='evenodd' data-ink='professor'/></svg>"
        let document = try SVGDocument.parse(svg)
        XCTAssertEqual(document.viewBox.origin.x, -10)
        XCTAssertEqual(document.viewBox.origin.y, -20)
        XCTAssertEqual(document.paths.first?.d, d)
        XCTAssertEqual(document.paths.first?.fillRule, .evenOdd)
        XCTAssertNotNil(try SVGPathParser.path(from: d))
    }

    func testMalformedPathFailsRatherThanChangingSource() {
        XCTAssertThrowsError(try SVGPathParser.path(from: "M 0 nope"))
    }
}

final class StrokeSerializationTests: XCTestCase {
    func testStrokeKeepsWorldCoordinatesAndPressure() throws {
        let stroke = UserStroke(id: "pencil-1", points: [StrokePoint(x: -4.5, y: 12.25, pressure: 0.6)])
        let data = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(UserStroke.self, from: data)
        XCTAssertEqual(decoded, stroke)
        XCTAssertEqual(decoded.points[0].pressure ?? -1, 0.6, accuracy: 0.0001)
    }

    func testSelectedUserObjectMovePreservesSourcePointsAndAddsWorldTranslation() {
        let object = CanvasObject(id: "stroke-1", type: "stroke", color: "#183153", width: 4, opacity: 1,
                                  points: [WorldPoint(x: -12, y: 8, pressure: 1)], translation: nil,
                                  sourceMarkdown: nil, text: nil, x: nil, y: nil, height: nil, fontSize: nil)
        let moved = object.translated(by: CGPoint(x: -30, y: 14))
        XCTAssertEqual(moved.points, object.points)
        XCTAssertEqual(moved.translation?.x, -30)
        XCTAssertEqual(moved.translation?.y, 14)
        XCTAssertEqual(moved.id, object.id)
    }

    func testImportedProfessorMoveUsesTransformWithoutChangingSourceGeometry() throws {
        let svg = try SVGDocument.parse("<svg viewBox='0 0 100 100'><path id='prof-1' d='M 2 3 L 8 3 Z'/></svg>")
        let originalPath = svg.paths[0].d
        let transform = ObjectTransform(x: -40, y: 22, scaleX: 1, scaleY: 1, deleted: false)
        let moved = ObjectTransform(x: transform.x - 15, y: transform.y + 9, scaleX: transform.scaleX, scaleY: transform.scaleY, deleted: transform.deleted)
        XCTAssertEqual(svg.paths[0].d, originalPath)
        XCTAssertEqual(moved.x, -55, accuracy: 0.000001)
        XCTAssertEqual(moved.y, 31, accuracy: 0.000001)
    }

    func testMultiSelectionWorldDeltaPreservesRelativeSpacing() {
        let first = CGPoint(x: -20, y: 10)
        let second = CGPoint(x: 45, y: -30)
        let delta = CGPoint(x: -70, y: 18)
        let movedFirst = CGPoint(x: first.x + delta.x, y: first.y + delta.y)
        let movedSecond = CGPoint(x: second.x + delta.x, y: second.y + delta.y)
        XCTAssertEqual(movedSecond.x - movedFirst.x, second.x - first.x, accuracy: 0.000001)
        XCTAssertEqual(movedSecond.y - movedFirst.y, second.y - first.y, accuracy: 0.000001)
    }
}

final class ServerContractDecodingTests: XCTestCase {
    func testStudyContentDocumentUsesBundledSanitizedRendererWithoutEmbeddingRawSource() {
        let source = #"## Reaction\n$\frac{1}{2}$ and $\ce{H2O}$ </script>"#
        let html = StudyContentDocument.html(source: source)
        XCTAssertTrue(html.contains("katex/katex.min.js"))
        XCTAssertTrue(html.contains("katex/mhchem.min.js"))
        XCTAssertTrue(html.contains("dompurify/purify.min.js"))
        XCTAssertTrue(html.contains("study-render.js"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertFalse(html.contains(source))
        XCTAssertTrue(html.contains(Data(source.utf8).base64EncodedString()))
    }

    @MainActor
    func testBundledStudyRendererExecutesMathAndChemistryWithoutNetwork() async throws {
        let completed = expectation(description: "local study renderer loaded")
        let delegate = WebViewNavigationWaiter(finished: completed)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        webView.navigationDelegate = delegate
        let source = #"## Energy\n\nUse $E=\frac{1}{2}mv^2$ and $\ce{H2O}$."#
        webView.loadHTMLString(StudyContentDocument.html(source: source),
                               baseURL: Bundle.main.resourceURL)
        await fulfillment(of: [completed], timeout: 4)
        let count = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.katex').length"
        ) as? NSNumber
        let visibleText = try await webView.evaluateJavaScript(
            "document.getElementById('content').innerText"
        ) as? String
        XCTAssertGreaterThanOrEqual(count?.intValue ?? 0, 2)
        XCTAssertFalse(visibleText?.contains("$\\frac") == true)
        XCTAssertFalse(visibleText?.contains("$\\ce") == true)
    }

    func testStudyFollowUpDecodesPracticeProblemsFromCanonicalServerShape() throws {
        let response = try JSONDecoder().decode(StudyInteractionResponse.self, from: Data(#"""
        {
          "interaction": {
            "id": "0123456789abcdef",
            "title": "Limits",
            "answer": "Start with the definition.",
            "followUps": [{
              "id": "fedcba9876543210",
              "kind": "practice_problems",
              "question": "Create practice",
              "answer": "",
              "problems": [
                {"id": "p1", "problem": "Evaluate the first limit."},
                {"id": "p2", "problem": "Evaluate the second limit."}
              ]
            }]
          },
          "problems": [
            {"id": "p1", "problem": "Evaluate the first limit."},
            {"id": "p2", "problem": "Evaluate the second limit."}
          ]
        }
        """#.utf8))
        XCTAssertEqual(response.interaction?.followUps?.last?.kind, "practice_problems")
        XCTAssertEqual(response.problems?.map(\.id), ["p1", "p2"])
    }

    func testLectureNoteMetadataRoundTripsWithCanonicalMarkdown() throws {
        let note = CanvasObject(
            id: "note-1", type: "text", color: "#183153", width: 520, opacity: 1,
            points: nil, translation: nil,
            sourceMarkdown: "Keep $x^2$ exactly.", text: "Keep $x^2$ exactly.",
            x: 900, y: -40, height: 260, fontSize: 28,
            createdAt: 1_789_000_000, unitLabel: "Unit 3", origin: "study"
        )
        let decoded = try JSONDecoder().decode(CanvasObject.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(decoded.sourceMarkdown, "Keep $x^2$ exactly.")
        XCTAssertEqual(decoded.createdAt, 1_789_000_000)
        XCTAssertEqual(decoded.unitLabel, "Unit 3")
        XCTAssertEqual(decoded.origin, "study")
    }

    func testLectureNoteResizePreservesCanonicalSourceAndOwnershipMetadata() {
        let note = CanvasObject(
            id: "note-1", type: "text", color: "#183153", width: 520, opacity: 1,
            points: nil, translation: nil, sourceMarkdown: "Keep $x^2$ exactly.",
            text: "Keep $x^2$ exactly.", x: 900, y: -40, height: 260, fontSize: 28,
            createdAt: 1_789_000_000, unitLabel: "Unit 3", origin: "study"
        )
        let resized = note.resized(to: CGSize(width: 680, height: 340))
        XCTAssertEqual(resized.width, 680)
        XCTAssertEqual(resized.height, 340)
        XCTAssertEqual(resized.sourceMarkdown, note.sourceMarkdown)
        XCTAssertEqual(resized.unitLabel, note.unitLabel)
        XCTAssertEqual(resized.origin, note.origin)
        XCTAssertEqual(resized.x, note.x)
        XCTAssertEqual(resized.y, note.y)
    }

    func testEditorEnvelopeAndOmittedCollectionsUseServerDefaults() throws {
        let json = """
        {"editor":{"schema_version":4,"revision":7,"viewport":{"x":-20,"y":-10,"width":800,"height":600},"objects":[],"imported_transforms":null,"source_boards":null,"merged_board_ids":null}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorEnvelope.self, from: json).editor
        XCTAssertEqual(decoded.revision, 7)
        XCTAssertEqual(decoded.viewport.x, -20)
        XCTAssertEqual(decoded.groups.count, 0)
        XCTAssertEqual(decoded.importedTransforms.count, 0)
        XCTAssertEqual(decoded.sourceBoards.count, 0)
        XCTAssertEqual(decoded.mergedBoardIDs.count, 0)
    }

    func testUnknownObjectTypeAndUnknownFieldsDoNotDropObject() throws {
        let json = """
        {"editor":{"schema_version":4,"revision":1,"viewport":{"x":0,"y":0,"width":100,"height":100},"objects":[{"id":"future-1","type":"ai_practice_problem","color":"#183153","points":[],"future_field":{"answer":42}}]}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorEnvelope.self, from: json).editor
        XCTAssertEqual(decoded.objects.count, 1)
        XCTAssertEqual(decoded.objects[0].type, "ai_practice_problem")
    }

    func testPracticeProblemAcceptsServerProblemKeyAndCanvasMetadataRoundTrips() throws {
        let problem = try JSONDecoder().decode(PracticeProblem.self, from: Data("{\"id\":\"p1\",\"problem\":\"Solve x^2=4\"}".utf8))
        XCTAssertEqual(problem.id, "p1")
        XCTAssertEqual(problem.text, "Solve x^2=4")
        let object = CanvasObject(id: "p1", type: "text", color: "#183153", width: 200,
                                  opacity: 1, points: nil, translation: nil,
                                  sourceMarkdown: problem.text, text: problem.text,
                                  x: -10, y: 5, height: 100, fontSize: 20,
                                  role: "ai_practice_problem", sourceStudyInteractionID: "study-1")
        let decoded = try JSONDecoder().decode(CanvasObject.self, from: JSONEncoder().encode(object))
        XCTAssertEqual(decoded.role, "ai_practice_problem")
        XCTAssertEqual(decoded.sourceStudyInteractionID, "study-1")
        XCTAssertEqual(decoded.x, -10)
    }
}

final class SceneCompositionTests: XCTestCase {
    private func editor(objects: [CanvasObject] = [], transforms: [String: ObjectTransform] = [:]) -> EditorState {
        EditorState(schemaVersion: 4, revision: 0, updatedAt: nil, viewport: CameraRect(x: 0, y: 0, width: 100, height: 100), objects: objects, groups: [], importedTransforms: transforms, sourceBoards: [], mergedBoardIDs: [])
    }

    func testCombinedExportIDsCannotCreateDuplicateWithImmutableProfessorSource() throws {
        let svg = try SVGDocument.parse("<svg viewBox='0 0 100 100'><path id='prof-1' d='M 0 0 L 10 0 Z' fill='#183153'/></svg>")
        let object = CanvasObject(id: "stroke-1", type: "stroke", color: "#183153", width: 4, opacity: 1, points: [WorldPoint(x: 0, y: 0, pressure: nil)], translation: nil, sourceMarkdown: nil, text: nil, x: nil, y: nil, height: nil, fontSize: nil)
        let composition = SceneComposition.build(boardID: "board-a", document: svg, editor: editor(objects: [object]))
        XCTAssertEqual(composition.nodes.count, 2)
        XCTAssertTrue(composition.duplicateLogicalIDs.isEmpty)
        XCTAssertEqual(composition, SceneComposition.build(boardID: "board-a", document: svg, editor: editor(objects: [object])))
    }

    func testDeletedImportedPathIsSuppressedAndTransformStillProducesOneNode() throws {
        let svg = try SVGDocument.parse("<svg viewBox='0 0 100 100'><path id='prof-1' d='M 0 0 L 10 0 Z' fill='#183153'/><path id='prof-2' d='M 20 0 L 30 0 Z' fill='#183153'/></svg>")
        let transforms = ["prof-1": ObjectTransform(x: 5, y: 6, scaleX: 2, scaleY: 2, deleted: false), "prof-2": ObjectTransform(x: 0, y: 0, scaleX: 1, scaleY: 1, deleted: true)]
        let composition = SceneComposition.build(boardID: "board-a", document: svg, editor: editor(transforms: transforms))
        XCTAssertEqual(composition.nodes.map(\.logicalID), ["prof-1"])
    }

    func testRepeatedStableEditorIDHasOneRenderableOwner() {
        let object = CanvasObject(id: "stroke-1", type: "stroke", color: "#183153", width: 4, opacity: 1, points: [WorldPoint(x: 0, y: 0, pressure: nil)], translation: nil, sourceMarkdown: nil, text: nil, x: nil, y: nil, height: nil, fontSize: nil)
        let renderable = SceneComposition.canonicalEditorObjects([object, object])
        XCTAssertEqual(renderable.count, 1)
        XCTAssertEqual(renderable.first?.id, "stroke-1")
    }

    func testRepeatedStableProfessorPathIDHasOneRenderableOwner() throws {
        let document = try SVGDocument.parse("<svg viewBox='0 0 10 10'><path id='prof-1' d='M0 0L1 1Z'/><path id='prof-1' d='M2 2L3 3Z'/></svg>")
        XCTAssertEqual(SceneComposition.canonicalProfessorPaths(document.paths).count, 1)
    }
}

final class LectureWorkspaceModelTests: XCTestCase {
    func testEffectiveBoundsIncludesBoardOwnedContentOutsidePaper() throws {
        let editor = try JSONDecoder().decode(EditorState.self, from: Data(#"""
        {
          "schema_version":4,"revision":2,"viewport":{"x":0,"y":0,"width":100,"height":80},
          "objects":[{"id":"note","type":"text","x":150,"y":-40,"width":90,"height":50,"text":"Study"}],
          "groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]
        }
        """#.utf8))
        let bounds = WorkspaceEffectiveBounds.boardLocal(editor: editor, boardSize: CGSize(width: 100, height: 80))
        XCTAssertEqual(bounds, CGRect(x: 0, y: -40, width: 240, height: 120))
    }

    private func item(_ index: Int, x: Double, y: Double = 0,
                      width: Double = 800, height: Double = 600,
                      effectiveWidth: Double? = nil) -> WorkspaceBoardItem {
        let boardID = String(format: "%032x", index + 1)
        return WorkspaceBoardItem(
            id: "board:\(boardID)", kind: "board", boardID: boardID,
            canvasX: x, canvasY: y, boardWidth: width, boardHeight: height,
            effectiveContentBounds: CameraRect(x: x, y: y, width: effectiveWidth ?? width, height: height),
            createdAt: Double(index + 1), capturedAt: nil, detectedBoardDate: nil,
            unitLabel: "No Unit", unitNumber: nil, unitConfidence: 0,
            unitSource: .none, title: "Board \(index + 1)", thumbnailURL: nil, zIndex: index
        )
    }

    func testBoardLocalLectureWorldRoundTripWithNegativePlacement() {
        let board = item(0, x: -4_200, y: 900)
        let local = CGPoint(x: 312.5, y: -44)
        let lecture = LectureCoordinateTransform.boardLocalToLectureWorld(local, board: board)
        XCTAssertEqual(lecture.x, -3_887.5, accuracy: 0.000001)
        XCTAssertEqual(lecture.y, 856, accuracy: 0.000001)
        let roundTrip = LectureCoordinateTransform.lectureWorldToBoardLocal(lecture, board: board)
        XCTAssertEqual(roundTrip.x, local.x, accuracy: 0.000001)
        XCTAssertEqual(roundTrip.y, local.y, accuracy: 0.000001)
    }

    func testAutoPlacementUsesEffectiveContentRightEdge() {
        let first = item(0, x: 0, effectiveWidth: 1_600)
        let second = item(1, x: 2_000, width: 700, effectiveWidth: 900)
        let placement = WorkspaceLayout.placement(for: CGSize(width: 640, height: 480), after: [first, second])
        XCTAssertEqual(placement.x, 2_996, accuracy: 0.000001)
        XCTAssertEqual(placement.y, 0, accuracy: 0.000001)
    }

    func testWorkspaceSpatialIndexOnlyReturnsCandidateBoards() {
        let items = [item(0, x: -1_000), item(1, x: 0), item(2, x: 5_000)]
        let index = WorkspaceSpatialIndex(items: items)
        XCTAssertEqual(index.query(CGRect(x: -50, y: -50, width: 900, height: 700)).map(\.boardID), [items[1].boardID])
    }

    func testFullDetailBudgetNeverPromotesMoreThanThreeBoards() {
        let items = (0..<12).map { item($0, x: Double($0 * 240), width: 220, height: 160) }
        let camera = CameraRect(x: 0, y: -100, width: 3_000, height: 800)
        let representations = BoardDetailPolicy.representations(
            items: items, camera: camera, viewport: CGSize(width: 1_200, height: 800),
            activeBoardID: items[8].boardID
        )
        XCTAssertLessThanOrEqual(representations.values.filter { $0 == .fullVector }.count, 3)
        XCTAssertEqual(representations[items[8].boardID], .fullVector)
        XCTAssertGreaterThan(representations.values.filter { $0 == .thumbnail }.count, 0)
    }

    func testCompositeSelectionKeysKeepCollidingSVGIDsIndependent() {
        let first = SelectionKey(boardID: "a", objectID: "path-1", kind: .professorPath)
        let second = SelectionKey(boardID: "b", objectID: "path-1", kind: .professorPath)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func testHundredBoardManifestDecodesWithoutScenePayloads() throws {
        let itemsJSON = (0..<100).map { index -> String in
            let boardID = String(format: "%032x", index + 1)
            return """
            {"id":"board:\(boardID)","kind":"board","board_id":"\(boardID)","canvas_x":\(index * 900),"canvas_y":0,"board_width":800,"board_height":600,"effective_content_bounds":{"x":\(index * 900),"y":0,"width":800,"height":600},"created_at":\(index + 1),"unit_label":"No Unit","unit_confidence":0,"unit_source":"none","title":"Board \(index + 1)","z_index":\(index)}
            """
        }.joined(separator: ",")
        let data = Data("""
        {"workspace":{"schema_version":1,"revision":4,"camera":{"x":0,"y":0,"width":1200,"height":800},"items":[\(itemsJSON)],"active_board_id":null,"last_viewed_at":1}}
        """.utf8)
        let workspace = try JSONDecoder().decode(LectureWorkspaceEnvelope.self, from: data).workspace
        XCTAssertEqual(workspace.items.count, 100)
        XCTAssertEqual(workspace.revision, 4)
    }

    func testExplicitUnitNormalizerRequiresLiteralUnitMarker() {
        XCTAssertEqual(ExplicitUnitNormalizer.normalized("UNIT 2")?.label, "Unit 2")
        XCTAssertEqual(ExplicitUnitNormalizer.normalized("Unit III")?.number, 3)
        XCTAssertNil(ExplicitUnitNormalizer.normalized("Chapter 2"))
        XCTAssertNil(ExplicitUnitNormalizer.normalized("Find the unit vector"))
    }

    func testHostedLectureBoardDecodesNestedDimensionsAssetsAndDate() throws {
        let data = Data(#"""
        {
          "id":"63cb8b57e8ad25b3c71008d323d78326",
          "board_id":"63cb8b57e8ad25b3c71008d323d78326",
          "name":"Whiteboard 1",
          "folder_id":"98b1a86028cc3282",
          "dimensions":{"width":3000,"height":2266},
          "assets":{"thumbnail":"thumbnail.png","master":"master.png"},
          "pipeline":{"status":"ready"},
          "lecture_boards":[
            {"boardId":"63cb8b57e8ad25b3c71008d323d78326","createdAt":1788746697.9258761}
          ]
        }
        """#.utf8)
        let board = try JSONDecoder().decode(LibraryBoard.self, from: data)
        XCTAssertEqual(board.width, 3000)
        XCTAssertEqual(board.height, 2266)
        XCTAssertEqual(board.status, "ready")
        XCTAssertEqual(board.thumbnailURL, "/boards/63cb8b57e8ad25b3c71008d323d78326/thumbnail.png")
        XCTAssertEqual(board.createdAt ?? 0, 1788746697.9258761, accuracy: 0.0001)
    }

    func testLegacyWorkspaceUsesRealHostedBoardGeometry() throws {
        let folder = LectureFolder(id: "lecture", name: "Chemistry", workspaceBoardID: nil,
                                   boardOrder: ["board-a", "board-b"])
        let first = LibraryBoard(id: "board-a", name: "One", folderID: "lecture", status: "ready",
                                 width: 3000, height: 2266, thumbnailURL: "/boards/board-a/thumbnail.png",
                                 url: nil, createdAt: 100, updatedAt: nil)
        let second = LibraryBoard(id: "board-b", name: "Two", folderID: "lecture", status: "ready",
                                  width: 2292, height: 2164, thumbnailURL: "/boards/board-b/thumbnail.png",
                                  url: nil, createdAt: 200, updatedAt: nil)
        let workspace = LectureWorkspace.legacy(
            lecture: LectureResponse(folder: folder, boards: [first, second], studyGuide: nil, studyGuideStale: nil)
        )
        XCTAssertEqual(workspace.items[0].boardWidth, 3000)
        XCTAssertEqual(workspace.items[0].boardHeight, 2266)
        XCTAssertEqual(workspace.items[1].canvasX, 3096)
        XCTAssertEqual(workspace.camera.width, 3128)
        XCTAssertEqual(workspace.items[1].createdAt, 200)
    }
}
