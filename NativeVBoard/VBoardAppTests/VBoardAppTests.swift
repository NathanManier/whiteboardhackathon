import XCTest
@preconcurrency import WebKit
import UIKit
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

final class PDFBoardContractTests: XCTestCase {
    func testLibraryAndWorkspaceDecodePDFSourceMetadata() throws {
        let board = try JSONDecoder().decode(LibraryBoard.self, from: Data("""
        {"id":"board-pdf","name":"Freeform","folder_id":"lecture-a","status":"ready","width":612,"height":792,"source_kind":"freeform_pdf","pdf_url":"/boards/board-pdf/source.pdf"}
        """.utf8))
        XCTAssertEqual(board.sourceKind, .freeformPDF)
        XCTAssertEqual(board.pdfURL, "/boards/board-pdf/source.pdf")
        XCTAssertTrue(board.sourceKind.isPDF)
    }

    func testPDFSourceGetsExactlyOneTransparentSelectableGeometryProxy() throws {
        let source = try SVGDocument.parse("<svg viewBox='0 0 612 792'><image id='pdf-page-1' width='612' height='792'/></svg>")
        let first = PDFBoardSource.selectableDocument(source, sourceKind: .freeformPDF)
        let second = PDFBoardSource.selectableDocument(first, sourceKind: .freeformPDF)
        XCTAssertEqual(first.paths.map(\.id).compactMap { $0 }, [PDFBoardSource.logicalID])
        XCTAssertEqual(second.paths.map(\.id).compactMap { $0 }, [PDFBoardSource.logicalID])
        XCTAssertEqual(first.viewBox, CGRect(x: 0, y: 0, width: 612, height: 792))
    }

    func testPhysicalBoardDoesNotReceivePDFProxy() throws {
        let source = try SVGDocument.parse("<svg viewBox='0 0 100 80'><path id='ink' d='M 1 1 L 2 2'/></svg>")
        let result = PDFBoardSource.selectableDocument(source, sourceKind: .physicalWhiteboard)
        XCTAssertEqual(result, source)
    }

    func testPDFLassoUsesSelectedRegionInsteadOfWholePageForStudyRequest() throws {
        let source = try SVGDocument.parse("<svg viewBox='0 0 612 792'/>")
        let document = PDFBoardSource.selectableDocument(source, sourceKind: .freeformPDF)
        let editor = try JSONDecoder().decode(EditorState.self, from: Data("""
        {"schema_version":4,"revision":0,"viewport":{"x":0,"y":0,"width":612,"height":792},"objects":[],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}
        """.utf8))
        let region = CGRect(x: 120, y: 240, width: 180, height: 90)
        let selection = BoardStudySelection.isolated(
            boardID: "pdf-board", selectedIDs: [PDFBoardSource.logicalID],
            document: document, editor: editor, preferredLocalBBox: region
        )
        XCTAssertEqual(selection?.canonicalObjectIDs, [PDFBoardSource.logicalID])
        XCTAssertEqual(selection?.localBBox.cgRect, region)
    }
}

final class NativeImportCoordinateTests: XCTestCase {
    func testAspectFitLargeLandscapePhotoUsesDisplayedImageRect() {
        let mapper = AspectFitImageTransform(
            sourcePixelSize: CGSize(width: 4032, height: 3024),
            containerRect: CGRect(x: 0, y: 0, width: 1024, height: 1366)
        )
        XCTAssertEqual(mapper.imageRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(mapper.imageRect.minY, 299, accuracy: 0.001)
        XCTAssertEqual(mapper.imageRect.width, 1024, accuracy: 0.001)
        XCTAssertEqual(mapper.imageRect.height, 768, accuracy: 0.001)
        XCTAssertEqual(mapper.viewToSourcePixel(CGPoint(x: 0, y: 299)), .zero)
        XCTAssertEqual(mapper.viewToSourcePixel(CGPoint(x: 1024, y: 1067)),
                       CGPoint(x: 4031, y: 3023))
    }

    func testAspectFitRoundTripIsSubpixelForRepresentativeSources() {
        let sources = [CGSize(width: 4032, height: 3024),
                       CGSize(width: 3024, height: 4032),
                       CGSize(width: 1920, height: 1080),
                       CGSize(width: 1080, height: 1920),
                       CGSize(width: 2048, height: 2048),
                       CGSize(width: 6000, height: 900),
                       CGSize(width: 900, height: 6000)]
        for source in sources {
            let mapper = AspectFitImageTransform(
                sourcePixelSize: source,
                containerRect: CGRect(x: 17, y: 29, width: 1024, height: 1366)
            )
            let points = [CGPoint.zero,
                          CGPoint(x: source.width - 1, y: 0),
                          CGPoint(x: source.width - 1, y: source.height - 1),
                          CGPoint(x: 0, y: source.height - 1),
                          CGPoint(x: source.width * 0.37, y: source.height * 0.61)]
            for point in points {
                let roundTrip = mapper.viewToSourcePixel(mapper.sourcePixelToView(point))
                XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.5, "source=\(source)")
                XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.5, "source=\(source)")
            }
        }
    }

    func testCornerClampNeverProducesServerExclusiveWidthOrHeight() {
        let mapper = AspectFitImageTransform(
            sourcePixelSize: CGSize(width: 4032, height: 3024),
            containerRect: CGRect(x: 0, y: 0, width: 1024, height: 1366)
        )
        XCTAssertEqual(mapper.viewToSourcePixel(CGPoint(x: 10_000, y: 10_000)),
                       CGPoint(x: 4031, y: 3023))
        XCTAssertEqual(mapper.viewToSourcePixel(CGPoint(x: -10_000, y: -10_000)),
                       .zero)
    }

    @MainActor
    func testImageOrientationIsBakedIntoUploadedPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format)
        let base = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let rotated = UIImage(cgImage: try XCTUnwrap(base.cgImage), scale: 1, orientation: .right)
        let normalized = try XCTUnwrap(NormalizedImageAsset.make(image: rotated))
        XCTAssertEqual(normalized.image.imageOrientation, .up)
        XCTAssertEqual(normalized.pixelSize, CGSize(width: 20, height: 40))
        let encoded = try XCTUnwrap(UIImage(data: normalized.uploadData))
        XCTAssertEqual(encoded.imageOrientation, .up)
        XCTAssertEqual(encoded.cgImage?.width, 20)
        XCTAssertEqual(encoded.cgImage?.height, 40)
    }

    func testInvalidCornerGeometryIsRejectedBeforeNetwork() {
        let size = CGSize(width: 4032, height: 3024)
        XCTAssertNil(CornerGeometry.validationMessage(
            [CGPoint(x: 0, y: 0), CGPoint(x: 4031, y: 0),
             CGPoint(x: 4031, y: 3023), CGPoint(x: 0, y: 3023)],
            sourceSize: size
        ))
        XCTAssertNotNil(CornerGeometry.validationMessage(
            [CGPoint(x: 0, y: 0), CGPoint(x: 4031, y: 3023),
             CGPoint(x: 4031, y: 0), CGPoint(x: 0, y: 3023)],
            sourceSize: size
        ))
    }
}

final class ImportFlowStateMachineTests: XCTestCase {
    func testFailedCornersCanRetryAndCompletionResetsOnCancel() {
        let upload = UUID(), firstSubmit = UUID(), retry = UUID()
        var state = ImportFlowStateMachine()
        state.sourceSelected()
        XCTAssertTrue(state.beginImageUpload(upload))
        XCTAssertFalse(state.beginImageUpload(UUID()), "a second tap must not submit again")
        XCTAssertTrue(state.requireCorners(after: upload))
        XCTAssertTrue(state.beginCornerSubmission(firstSubmit))
        XCTAssertTrue(state.failToCorners(firstSubmit))
        XCTAssertTrue(state.beginCornerSubmission(retry))
        XCTAssertTrue(state.complete(retry))
        state.cancel()
        XCTAssertEqual(state.phase, .choosing)
    }

    func testPickerCancelAndPDFFailureReturnToReusableState() {
        var state = ImportFlowStateMachine()
        state.sourceSelected()
        let pdf = UUID()
        XCTAssertTrue(state.beginPDFUpload(pdf))
        XCTAssertTrue(state.failToPreview(pdf))
        state.cancel()
        XCTAssertEqual(state.phase, .choosing)
        state.sourceSelected()
        XCTAssertTrue(state.beginImageUpload(UUID()))
    }
}

final class PDFVisibleSourceTests: XCTestCase {
    func testPDFTopLeftBoardTransformRoundTripsPageCorners() {
        let transform = PDFPageBoardTransform(boardSize: CGSize(width: 612, height: 792))
        let page = CGSize(width: 1224, height: 1584)
        XCTAssertEqual(transform.pdfTopLeftToBoard(.zero, pdfDisplaySize: page), .zero)
        XCTAssertEqual(transform.pdfTopLeftToBoard(CGPoint(x: 1224, y: 1584), pdfDisplaySize: page),
                       CGPoint(x: 612, y: 792))
        let sample = CGPoint(x: 183, y: 475)
        let roundTrip = transform.boardToPDFTopLeft(
            transform.pdfTopLeftToBoard(sample, pdfDisplaySize: page),
            pdfDisplaySize: page
        )
        XCTAssertEqual(roundTrip.x, sample.x, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, sample.y, accuracy: 0.001)
    }

    @MainActor
    func testPaperPDFProfessorAndUserLayersHaveCanonicalZOrder() throws {
        let document = try SVGDocument.parse("<svg viewBox='0 0 612 792'/>")
        let editor = try JSONDecoder().decode(EditorState.self, from: Data("""
        {"schema_version":4,"revision":0,"viewport":{"x":0,"y":0,"width":612,"height":792},"objects":[],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}
        """.utf8))
        let canvas = InfiniteCanvasUIView(
            boardID: "pdf-board", document: document, pdfData: Data("%PDF-invalid".utf8),
            camera: editor.viewport, objects: [],
            composition: SceneComposition.build(boardID: "pdf-board", document: document, editor: editor)
        )
        let order = canvas.sourceLayerOrderForTesting
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: "VBoardPaper")),
                          try XCTUnwrap(order.firstIndex(of: "VBoardPDFSource")))
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: "VBoardPDFSource")),
                          try XCTUnwrap(order.firstIndex(of: "VBoardProfessorSource")))
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: "VBoardProfessorSource")),
                          try XCTUnwrap(order.firstIndex(of: "VBoardUserContent")))
    }

    @MainActor
    func testPDFPageRendererProducesVisiblePixels() throws {
        let pageBounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let pdf = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(pageBounds)
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 40, y: 60, width: 120, height: 180))
        }
        let view = PDFPageRenderView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        view.display(data: pdf)
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
            view.draw(view.bounds)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                                              bitsPerComponent: 8, bytesPerRow: 4,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: -100, y: -150, width: 200, height: 300))
        XCTAssertGreaterThan(pixel[0], 180)
        XCTAssertLessThan(pixel[1], 100)
        XCTAssertLessThan(pixel[2], 100)
        XCTAssertEqual(view.renderState, .ready)
    }
}

final class SourceAssetCacheTests: XCTestCase {
    func testCacheIsNamespacedByAccountAndBoard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VBoardAssetCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SourceAssetCache(root: root)
        let data = Data("private-pdf".utf8)
        let keyA = SourceAssetCache.key(accountNamespace: "account-a", boardID: "board-a",
                                        path: "/boards/board-a/source.pdf", version: "1")
        try await cache.store(data, forKey: keyA, accountNamespace: "account-a", boardID: "board-a")
        let accountA = try await cache.data(forKey: keyA, accountNamespace: "account-a", boardID: "board-a")
        let accountB = try await cache.data(forKey: keyA, accountNamespace: "account-b", boardID: "board-a")
        let boardB = try await cache.data(forKey: keyA, accountNamespace: "account-a", boardID: "board-b")
        XCTAssertEqual(accountA, data)
        XCTAssertNil(accountB)
        XCTAssertNil(boardB)
    }

    @MainActor
    func testProtectedPDFFetchUsesBearerAndThenLocalCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VBoardProtectedAssetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var requests = 0
        WorkspaceURLProtocolStub.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/boards/board-pdf/source.pdf")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/pdf"])!,
                    Data("%PDF-protected".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://assets.test")!,
                            session: URLSession(configuration: configuration),
                            sourceAssetCache: SourceAssetCache(root: root))
        api.install(credentials: AuthCredentials(accessToken: "access-token",
                                                  refreshToken: "refresh-token",
                                                  accessExpiresAt: 100,
                                                  refreshExpiresAt: 200,
                                                  appleUserIdentifier: nil))
        let first = try await api.cachedBoardAsset(boardID: "board-pdf",
                                                   path: "/boards/board-pdf/source.pdf",
                                                   version: "1")
        let second = try await api.cachedBoardAsset(boardID: "board-pdf",
                                                    path: "/boards/board-pdf/source.pdf",
                                                    version: "1")
        XCTAssertEqual(first, second)
        XCTAssertEqual(requests, 1)
    }
}

private final class WorkspaceURLProtocolStub: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
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

final class WorldScreenTransformTests: XCTestCase {
    func testWorldOverlayLayerIsPinnedToUntransformedCanvasOrigin() {
        let layer = CALayer()
        let bounds = CGRect(x: 0, y: 0, width: 1194, height: 742)

        WorldOverlayLayerLayout.pin(layer, to: bounds)

        XCTAssertEqual(layer.anchorPoint, .zero)
        XCTAssertEqual(layer.position, .zero)
        XCTAssertEqual(layer.bounds, bounds)
        XCTAssertEqual(layer.frame.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(layer.frame.origin.y, 0, accuracy: 0.0001)
    }

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
    private func stroke(id: String, x: Double, y: Double) -> CanvasObject {
        CanvasObject(id: id, type: "stroke", color: "#183153", width: 4,
                     opacity: 1,
                     points: [WorldPoint(x: x, y: y, pressure: 1),
                              WorldPoint(x: x + 20, y: y + 20, pressure: 1)],
                     translation: nil, sourceMarkdown: nil, text: nil,
                     x: nil, y: nil, height: nil, fontSize: nil)
    }

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

    func testPointSelectionChoosesTopmostEditorObject() {
        let lower = stroke(id: "lower", x: 10, y: 10)
        let upper = stroke(id: "upper", x: 10, y: 10)
        XCTAssertEqual(
            BoardHitTestPolicy.topmostEditorObjectID(
                at: CGPoint(x: 20, y: 20),
                objects: [lower, upper],
                tolerance: 2
            ),
            "upper"
        )
    }

    @MainActor
    func testDeletingEditorObjectDoesNotCreateProfessorSoftDelete() throws {
        let boardID = "delete-ownership-\(UUID().uuidString)"
        let object = stroke(id: "user-stroke", x: 10, y: 10)
        let editor = EditorState(schemaVersion: 4, revision: 0, updatedAt: nil,
                                 viewport: CameraRect(x: 0, y: 0, width: 800, height: 600),
                                 objects: [object], groups: [], importedTransforms: [:],
                                 sourceBoards: [], mergedBoardIDs: [])
        let store = BoardDocumentStore(boardID: boardID, editor: editor)
        let api = APIClient(baseURL: URL(string: "https://ownership.test")!)

        store.deleteObjects(editorObjectIDs: [object.id], professorPathIDs: [], api: api)

        XCTAssertTrue(store.editor.objects.isEmpty)
        XCTAssertNil(store.editor.importedTransforms[object.id])
        store.undo(api: api)
        XCTAssertEqual(store.editor.objects.map(\.id), [object.id])
        XCTAssertNil(store.editor.importedTransforms[object.id])
    }

    @MainActor
    func testCollidingEditorAndProfessorIDsRetainTypedMoveOwnership() throws {
        let boardID = "move-ownership-\(UUID().uuidString)"
        let object = stroke(id: "shared-id", x: 10, y: 10)
        let editor = EditorState(schemaVersion: 4, revision: 0, updatedAt: nil,
                                 viewport: CameraRect(x: 0, y: 0, width: 800, height: 600),
                                 objects: [object], groups: [], importedTransforms: [:],
                                 sourceBoards: [], mergedBoardIDs: [])
        let store = BoardDocumentStore(boardID: boardID, editor: editor)
        let api = APIClient(baseURL: URL(string: "https://ownership.test")!)

        store.moveObjects(editorObjectIDs: [object.id],
                          professorPathIDs: [object.id],
                          by: CGPoint(x: -7, y: 13), api: api)

        XCTAssertEqual(store.editor.objects.first?.translation?.x, -7)
        XCTAssertEqual(store.editor.objects.first?.translation?.y, 13)
        XCTAssertEqual(store.editor.importedTransforms[object.id]?.x, -7)
        XCTAssertEqual(store.editor.importedTransforms[object.id]?.y, 13)
    }
}

final class ServerContractDecodingTests: XCTestCase {
    func testCompactPresentationKeepsMathAndChemistryReadable() {
        let source = #"Predict $\text{Pd}(0)$ for $\ce{SO4^{2-}}$, then use $\frac{a}{b} \rightarrow \alpha$."#
        let rendered = CompactStudyPresentation.readableText(from: source)

        XCTAssertEqual(rendered, "Predict Pd(0) for SO4^2-, then use (a)/(b) → α.")
        XCTAssertFalse(rendered.contains("\\frac"))
        XCTAssertFalse(rendered.contains("\\ce"))
        XCTAssertFalse(rendered.contains("$"))
    }

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

final class StudySelectionRequestTests: XCTestCase {
    private func item(boardID: String = "board-a", x: Double = 1_200,
                      y: Double = -700) -> WorkspaceBoardItem {
        WorkspaceBoardItem(
            id: "board:\(boardID)", kind: "board", boardID: boardID,
            canvasX: x, canvasY: y, boardWidth: 800, boardHeight: 600,
            effectiveContentBounds: CameraRect(x: x - 200, y: y - 100,
                                                width: 1_200, height: 900),
            createdAt: 1, capturedAt: nil, detectedBoardDate: nil,
            unitLabel: "Unit 1", unitNumber: 1, unitConfidence: 1,
            unitSource: .manual, title: "Board A", thumbnailURL: nil, zIndex: 0
        )
    }

    private func editor(objects: [CanvasObject],
                        transforms: [String: ObjectTransform] = [:]) -> EditorState {
        EditorState(schemaVersion: 4, revision: 2, updatedAt: nil,
                    viewport: CameraRect(x: -300, y: -200, width: 1_200, height: 900),
                    objects: objects, groups: [], importedTransforms: transforms,
                    sourceBoards: [], mergedBoardIDs: [])
    }

    private func scene(document: SVGDocument, editor: EditorState) -> WorkspaceBoardScene {
        WorkspaceBoardScene(boardID: "board-a", document: document, pdfData: nil, editor: editor,
                            composition: SceneComposition.build(boardID: "board-a",
                                                                document: document,
                                                                editor: editor))
    }

    func testLectureSelectionConvertsToBoardLocalBBoxAndCanonicalIDs() throws {
        let document = try SVGDocument.parse(
            "<svg viewBox='0 0 800 600'><path id='prof-1' d='M 20 30 L 60 30 L 60 70 L 20 70 Z'/></svg>"
        )
        let stroke = CanvasObject(
            id: "stroke-1", type: "stroke", color: "#183153", width: 4, opacity: 1,
            points: [WorldPoint(x: -80, y: -40, pressure: 1),
                     WorldPoint(x: -20, y: 10, pressure: 1)],
            translation: nil, sourceMarkdown: nil, text: nil,
            x: nil, y: nil, height: nil, fontSize: nil
        )
        let currentEditor = editor(objects: [stroke])
        let keys: Set<SelectionKey> = [
            SelectionKey(boardID: "board-a", objectID: "prof-1", kind: .professorPath),
            SelectionKey(boardID: "board-a", objectID: "stroke-1", kind: .editorObject),
            SelectionKey(boardID: "board-b", objectID: "board-b:foreign", kind: .editorObject)
        ]

        let selection = try XCTUnwrap(BoardStudySelection.lecture(
            boardID: "board-a", selectionKeys: keys, item: item(),
            scene: scene(document: document, editor: currentEditor)
        ))

        XCTAssertEqual(selection.canonicalObjectIDs, ["prof-1", "stroke-1"])
        XCTAssertFalse(selection.canonicalObjectIDs.contains("board-a:prof-1"))
        XCTAssertEqual(selection.localBBox.cgRect, CGRect(x: -80, y: -40, width: 140, height: 110))
        XCTAssertEqual(selection.lectureWorldBBox,
                       CGRect(x: 1_120, y: -740, width: 140, height: 110))
    }

    func testMovedProfessorPathUsesImportedTransformExactlyOnce() throws {
        let document = try SVGDocument.parse(
            "<svg viewBox='0 0 100 100'><path id='prof-moved' d='M 0 0 L 10 0 L 10 20 L 0 20 Z'/></svg>"
        )
        let currentEditor = editor(objects: [], transforms: [
            "prof-moved": ObjectTransform(x: -40, y: 25, scaleX: 2, scaleY: 3, deleted: false)
        ])
        let selection = try XCTUnwrap(BoardStudySelection.lecture(
            boardID: "board-a",
            selectionKeys: [SelectionKey(boardID: "board-a", objectID: "prof-moved",
                                          kind: .professorPath)],
            item: item(), scene: scene(document: document, editor: currentEditor)
        ))

        XCTAssertEqual(selection.canonicalObjectIDs, ["prof-moved"])
        XCTAssertEqual(selection.localBBox.x, -40, accuracy: 0.000001)
        XCTAssertEqual(selection.localBBox.y, 25, accuracy: 0.000001)
        XCTAssertEqual(selection.localBBox.width, 20, accuracy: 0.000001)
        XCTAssertEqual(selection.localBBox.height, 60, accuracy: 0.000001)
    }

    func testTextAndPracticeObjectsUseCanonicalIDsAndPayloadMetadata() throws {
        let document = try SVGDocument.parse("<svg viewBox='0 0 800 600'></svg>")
        let note = CanvasObject(
            id: "note-1", type: "text", color: "#183153", width: 320, opacity: 1,
            points: nil, translation: WorldPoint(x: -20, y: 15, pressure: nil),
            sourceMarkdown: "Keep $x^2$ exact.", text: "Keep $x^2$ exact.",
            x: -500, y: 80, height: 140, fontSize: 28
        )
        let practice = CanvasObject(
            id: "problem-1", type: "text", color: "#183153", width: 360, opacity: 1,
            points: nil, translation: nil, sourceMarkdown: "Solve $x=2$.",
            text: "Solve $x=2$.", x: 300, y: 100, height: 180, fontSize: 32,
            role: "ai_practice_problem", sourceStudyInteractionID: "0123456789abcdef"
        )
        let currentEditor = editor(objects: [note, practice])
        let selection = try XCTUnwrap(BoardStudySelection.lecture(
            boardID: "board-a",
            selectionKeys: [
                SelectionKey(boardID: "board-a", objectID: "note-1", kind: .editorObject),
                SelectionKey(boardID: "board-a", objectID: "problem-1", kind: .editorObject)
            ],
            item: item(), scene: scene(document: document, editor: currentEditor)
        ))

        XCTAssertEqual(selection.canonicalObjectIDs, ["note-1", "problem-1"])
        XCTAssertEqual(selection.localBBox.x, -520, accuracy: 0.000001)
        XCTAssertEqual(selection.selectedTextObjects.map(\.id), ["note-1", "problem-1"])
        XCTAssertEqual(selection.selectedTextObjects.last?.practiceProblemId, "problem-1")
        XCTAssertEqual(selection.selectedTextObjects.last?.sourceStudyInteractionId,
                       "0123456789abcdef")
    }

    func testExplainRequestEncodesExactCurrentServerKeysAndRequestIDFormat() throws {
        let selection = BoardStudySelection(
            boardID: "board-a", canonicalObjectIDs: ["prof-1"],
            localBBox: StudySelectionBBox(rect: CGRect(x: -10, y: 20, width: 40, height: 60))!,
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let request = BoardStudyExplainRequest.make(
            selection: selection, requestID: "0123456789abcdef"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any])
        let expectedKeys: Set<String> = [
            "selectedObjectIds", "selectedTextObjects", "selectionBBox",
            "anchorX", "anchorY", "anchorOffsetNx", "anchorOffsetNy",
            "studyInteractionId", "requestId", "question", "action"
        ]

        XCTAssertEqual(Set(json.keys), expectedKeys)
        XCTAssertNil(json["boardID"])
        XCTAssertNil(json["selected_object_ids"])
        XCTAssertEqual(json["selectedObjectIds"] as? [String], ["prof-1"])
        XCTAssertEqual(json["requestId"] as? String, "0123456789abcdef")
        XCTAssertNotNil((json["selectionBBox"] as? [String: Any])?["width"])
        XCTAssertTrue(BoardStudyExplainRequest.makeRequestID().range(
            of: "^[0-9a-f]{16}$", options: .regularExpression
        ) != nil)
    }

    func testSelectionBBoxRejectsNonFiniteAndServerOutOfRangeGeometry() {
        XCTAssertNil(StudySelectionBBox(rect: CGRect(x: CGFloat.nan, y: 0,
                                                     width: 10, height: 10)))
        XCTAssertNil(StudySelectionBBox(rect: CGRect(x: 10_000_001, y: 0,
                                                     width: 10, height: 10)))
        let pointSelection = StudySelectionBBox(rect: CGRect(x: -20, y: -30,
                                                              width: 0, height: 0))
        XCTAssertEqual(pointSelection?.width, 1)
        XCTAssertEqual(pointSelection?.height, 1)
        XCTAssertLessThan(pointSelection?.x ?? 0, 0)
        XCTAssertLessThan(pointSelection?.y ?? 0, 0)
    }

    @MainActor
    func testOneExplainActionCreatesOneNetworkRequestAnd400BodyIsLogged() async throws {
        var requestCount = 0
        var logs: [String] = []
        WorkspaceURLProtocolStub.handler = { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 400,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!,
                    Data("{\"error\":\"Select something on the board first.\"}".utf8))
        }
        defer { WorkspaceURLProtocolStub.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://study.test")!,
                            session: URLSession(configuration: configuration),
                            diagnostics: { logs.append($0) })
        let selection = BoardStudySelection(
            boardID: "board-a", canonicalObjectIDs: ["prof-1"],
            localBBox: StudySelectionBBox(rect: CGRect(x: 1, y: 2, width: 3, height: 4))!,
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let request = BoardStudyExplainRequest.make(
            selection: selection, requestID: "0123456789abcdef"
        )
        let gate = StudySubmissionGate()
        let firstInvocationOwnsRequest = gate.begin(requestID: request.requestId)
        let duplicateInvocationOwnsRequest = gate.begin(requestID: "fedcba9876543210")

        if firstInvocationOwnsRequest {
            do { _ = try await api.explain(request: request) }
            catch APIError.server(let status, _, _) { XCTAssertEqual(status, 400) }
            gate.end(requestID: request.requestId)
        }
        if duplicateInvocationOwnsRequest {
            _ = try? await api.explain(request: request)
        }

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(duplicateInvocationOwnsRequest)
        let failure = try XCTUnwrap(logs.first { $0.contains("STUDY REQUEST FAILED") })
        XCTAssertTrue(failure.contains("status=400"))
        XCTAssertTrue(failure.contains("Select something on the board first."))
        XCTAssertTrue(failure.contains("selectedBoardID=board-a"))
        XCTAssertTrue(failure.contains("selectedCanonicalIDs=[\"prof-1\"]"))
        XCTAssertTrue(failure.contains("requestID=0123456789abcdef"))
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

@MainActor
final class LectureWorkspacePersistenceTests: XCTestCase {
    override func tearDown() {
        WorkspaceURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testLectureStudyRemainsAvailableForCrossBoardSelection() {
        XCTAssertTrue(LectureStudyRouting.isAvailable(
            selectedBoardIDs: ["board-a", "board-b"]
        ))
        XCTAssertFalse(LectureStudyRouting.isAvailable(
            selectedBoardIDs: []
        ))
    }

    func testStudyGuideEnvelopeIgnoresSiblingStaleFlag() async throws {
        let guideJSON = Data(#"""
        {"study_guide":{"id":"guide-1","title":"Chemistry","content":"Use $\\ce{H2O}$.","version":1,"stale":false,"source_board_ids":["board-a"]},"study_guide_stale":false}
        """#.utf8)
        WorkspaceURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/folders/lecture/study-guide")
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!, guideJSON)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://guide.test")!,
                            session: URLSession(configuration: configuration))

        let guide = try await api.generateStudyGuide(folderID: "lecture")

        XCTAssertEqual(guide?.id, "guide-1")
        XCTAssertEqual(guide?.content, #"Use $\ce{H2O}$."#)
    }

    func testDebouncedSaveDoesNotCancelItsOwnWorkspacePUT() async throws {
        let boardID = "board-a"
        let folderID = "lecture-\(UUID().uuidString)"
        let workspaceJSON = { (revision: Int, canvasX: Int) in
            Data("""
            {"workspace":{"schema_version":1,"revision":\(revision),"camera":{"x":0,"y":0,"width":1200,"height":800},"items":[{"id":"board:\(boardID)","kind":"board","board_id":"\(boardID)","canvas_x":\(canvasX),"canvas_y":0,"board_width":800,"board_height":600,"effective_content_bounds":{"x":\(canvasX),"y":0,"width":800,"height":600},"created_at":1,"unit_label":"No Unit","unit_confidence":0,"unit_source":"none","title":"Board A","z_index":0}],"active_board_id":"\(boardID)","last_viewed_at":1}}
            """.utf8)
        }
        let lectureJSON = Data("""
        {"folder":{"id":"\(folderID)","name":"Lecture","workspace_board_id":"\(boardID)","board_order":["\(boardID)"]},"boards":[{"id":"\(boardID)","name":"Board A","folder_id":"\(folderID)","status":"ready","width":800,"height":600,"created_at":1}],"study_guide":null,"study_guide_stale":false}
        """.utf8)
        let editorJSON = Data("""
        {"editor":{"schema_version":4,"revision":0,"viewport":{"x":0,"y":0,"width":800,"height":600},"objects":[],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}}
        """.utf8)
        let putReachedServer = expectation(description: "workspace PUT reached server")

        WorkspaceURLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            let headers = ["Content-Type": path.hasSuffix(".svg") ? "image/svg+xml" : "application/json"]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/api/folders/\(folderID)/lecture"):
                return (response, lectureJSON)
            case ("GET", "/api/folders/\(folderID)/workspace"):
                return (response, workspaceJSON(7, 0))
            case ("GET", "/api/boards/\(boardID)/editor"):
                return (response, editorJSON)
            case ("GET", "/boards/\(boardID)/board.svg"):
                return (response, Data("<svg viewBox='0 0 800 600'></svg>".utf8))
            case ("PUT", "/api/folders/\(folderID)/workspace"):
                putReachedServer.fulfill()
                return (response, workspaceJSON(8, 12))
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                        httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "application/json"])!,
                        Data("{\"error\":\"not found\"}".utf8))
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://workspace.test")!,
                            session: URLSession(configuration: configuration))
        let store = LectureWorkspaceStore(folderID: folderID)
        await store.load(api: api)
        XCTAssertEqual(store.status, .clean)

        store.moveBoard(boardID: boardID, by: CGPoint(x: 12, y: 0), api: api)
        await fulfillment(of: [putReachedServer], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.status, .clean)
        XCTAssertEqual(store.workspace?.revision, 8)
        XCTAssertEqual(store.workspace?.items.first?.canvasX, 12)
    }

    func testDebouncedBoardSaveDoesNotCancelItsOwnEditorPUT() async throws {
        let boardID = "board-\(UUID().uuidString)"
        let initial = try JSONDecoder().decode(EditorState.self, from: Data("""
        {"schema_version":4,"revision":4,"viewport":{"x":0,"y":0,"width":800,"height":600},"objects":[],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}
        """.utf8))
        let saved = Data("""
        {"editor":{"schema_version":4,"revision":5,"viewport":{"x":0,"y":0,"width":800,"height":600},"objects":[{"id":"stroke-a","type":"stroke","color":"#183153","width":4,"opacity":1,"points":[{"x":10,"y":12,"p":1}],"translation":{"x":0,"y":0}}],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}}
        """.utf8)
        let putReachedServer = expectation(description: "editor PUT reached server")

        WorkspaceURLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            let status = request.httpMethod == "PUT" && path == "/api/boards/\(boardID)/editor" ? 200 : 404
            if status == 200 { putReachedServer.fulfill() }
            return (HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!,
                    status == 200 ? saved : Data("{\"error\":\"not found\"}".utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://editor.test")!,
                            session: URLSession(configuration: configuration))
        let store = BoardDocumentStore(boardID: boardID, editor: initial)
        store.applyStroke(UserStroke(id: "stroke-a",
                                     points: [StrokePoint(x: 10, y: 12, pressure: 1)]), api: api)

        await fulfillment(of: [putReachedServer], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.status, .clean)
        XCTAssertEqual(store.editor.revision, 5)
        XCTAssertEqual(store.editor.objects.map(\.id), ["stroke-a"])
    }

    func testUndoAndRedoRebaseHistoryOntoAcceptedServerRevision() async throws {
        let boardID = "history-rebase-\(UUID().uuidString)"
        let initial = try JSONDecoder().decode(EditorState.self, from: Data("""
        {"schema_version":4,"revision":4,"viewport":{"x":0,"y":0,"width":800,"height":600},"objects":[],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}
        """.utf8))
        let strokeJSON = """
        {"id":"stroke-a","type":"stroke","color":"#183153","width":4,"opacity":1,"points":[{"x":10,"y":12,"p":1}],"translation":{"x":0,"y":0}}
        """
        var requestCount = 0
        let requestsReachedServer = expectation(description: "save, undo, and redo reached server")
        requestsReachedServer.expectedFulfillmentCount = 3

        WorkspaceURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/boards/\(boardID)/editor")
            requestCount += 1
            requestsReachedServer.fulfill()
            let revision = 4 + requestCount
            let objects = requestCount == 2 ? "" : strokeJSON
            let body = Data("""
            {"editor":{"schema_version":4,"revision":\(revision),"viewport":{"x":0,"y":0,"width":800,"height":600},"objects":[\(objects)],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}}
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!, body)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://history.test")!,
                            session: URLSession(configuration: configuration))
        let store = BoardDocumentStore(boardID: boardID, editor: initial)

        store.applyStroke(UserStroke(id: "stroke-a",
                                     points: [StrokePoint(x: 10, y: 12, pressure: 1)]), api: api)
        while requestCount < 1 { try await Task.sleep(nanoseconds: 25_000_000) }
        while store.status != .clean { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(store.editor.revision, 5)

        store.undo(api: api)
        while requestCount < 2 { try await Task.sleep(nanoseconds: 25_000_000) }
        while store.status != .clean { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(store.editor.revision, 6)
        XCTAssertTrue(store.editor.objects.isEmpty)
        XCTAssertNil(store.conflictServerEditor)

        store.redo(api: api)
        await fulfillment(of: [requestsReachedServer], timeout: 2)
        while store.status != .clean { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(store.editor.revision, 7)
        XCTAssertEqual(store.editor.objects.map(\.id), ["stroke-a"])
        XCTAssertNil(store.conflictServerEditor)
    }
}
