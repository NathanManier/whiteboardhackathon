import XCTest
@testable import VBoardApp

final class WorldScreenTransformTests: XCTestCase {
    func testWorldScreenRoundTripWithNegativeCoordinates() {
        let transform = WorldScreenTransform(camera: CameraRect(x: -200, y: -100, width: 800, height: 400), viewport: CGSize(width: 1200, height: 600))
        let world = CGPoint(x: -50.25, y: 22.75)
        let screen = transform.screenPoint(for: world)
        XCTAssertEqual(transform.worldPoint(for: screen).x, world.x, accuracy: 0.0001)
        XCTAssertEqual(transform.worldPoint(for: screen).y, world.y, accuracy: 0.0001)
    }

    func testPanMovesVisibleWorldOppositeFinger() {
        var camera = CameraController(camera: CameraRect(x: 0, y: 0, width: 100, height: 100))
        camera.pan(screenTranslation: CGPoint(x: 100, y: 0), viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(camera.camera.x, -100, accuracy: 0.0001)
    }

    func testPinchRetainsWorldAnchorAndClampsZoom() {
        var camera = CameraController(camera: CameraRect(x: 0, y: 0, width: 100, height: 100))
        let viewport = CGSize(width: 100, height: 100)
        camera.zoom(by: 2, anchoredAt: CGPoint(x: 50, y: 50), viewport: viewport)
        XCTAssertEqual(camera.camera.center.x, 50, accuracy: 0.0001)
        XCTAssertEqual(camera.camera.width, 50, accuracy: 0.0001)
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
}
