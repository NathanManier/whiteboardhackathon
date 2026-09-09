import XCTest
@testable import VBoardApp

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
}

final class ServerContractDecodingTests: XCTestCase {
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
