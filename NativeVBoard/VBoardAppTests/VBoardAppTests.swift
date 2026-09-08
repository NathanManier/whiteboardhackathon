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
