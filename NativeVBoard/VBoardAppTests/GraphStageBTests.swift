import XCTest
import UIKit
@testable import VBoardApp

@MainActor
final class GraphRecognitionAndRenderingTests: XCTestCase {
    private let boardID = "603f5213ab0a249716833214c5ab88da"

    override func tearDown() {
        GraphURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testRecognitionRequestUsesExactBoardLocalContract() throws {
        let selection = BoardStudySelection(
            boardID: boardID,
            canonicalObjectIDs: ["path-professor-7", "stroke-user-2"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: -42.5, y: 18.25, width: 311, height: 94)
            )),
            selectedTextObjects: [],
            lectureWorldBBox: CGRect(x: 2_000, y: 3_000, width: 311, height: 94)
        )
        let request = GraphRecognitionRequest.make(
            selection: selection, requestID: "0123456789abcdef"
        )
        let data = try JSONEncoder().encode(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(root.keys), Set(["requestId", "selection", "contextScope", "action"]))
        XCTAssertNil(root["boardID"])
        XCTAssertEqual(root["requestId"] as? String, "0123456789abcdef")
        XCTAssertEqual(root["contextScope"] as? String, "local")
        XCTAssertEqual(root["action"] as? String, "graph_recognition")
        let encodedSelection = try XCTUnwrap(root["selection"] as? [String: Any])
        XCTAssertEqual(Set(encodedSelection.keys), Set(["selectedObjectIds", "bbox"]))
        XCTAssertEqual(encodedSelection["selectedObjectIds"] as? [String],
                       ["path-professor-7", "stroke-user-2"])
        let bbox = try XCTUnwrap(encodedSelection["bbox"] as? [String: Any])
        XCTAssertEqual(bbox["x"] as? Double, -42.5)
        XCTAssertEqual(bbox["y"] as? Double, 18.25)
        XCTAssertEqual(bbox["width"] as? Double, 311)
        XCTAssertEqual(bbox["height"] as? Double, 94)
    }

    func testOneRecognitionInvocationProducesOnePOSTAndCorrelatesRequestID() async throws {
        let requestID = "fedcba9876543210"
        let selection = BoardStudySelection(
            boardID: boardID,
            canonicalObjectIDs: ["path-17"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: 12, y: -8, width: 260, height: 70)
            )),
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let request = GraphRecognitionRequest.make(selection: selection, requestID: requestID)
        let lock = NSLock()
        var requestCount = 0
        GraphURLProtocolStub.handler = { urlRequest in
            lock.lock(); requestCount += 1; lock.unlock()
            XCTAssertEqual(urlRequest.httpMethod, "POST")
            XCTAssertEqual(urlRequest.url?.path,
                           "/api/boards/\(self.boardID)/study/graph-recognition")
            let payload = try JSONSerialization.jsonObject(
                with: try graphRequestBody(urlRequest)
            ) as? [String: Any]
            XCTAssertEqual(payload?["requestId"] as? String, requestID)
            let response = Data(#"{"result":{"graphable":true,"confidence":0.97,"expressions":[{"id":"expression-1","latex":"y=x^2-4","type":"explicitFunction","confidence":0.99}],"warnings":[],"requestID":"fedcba9876543210","recognitionVersion":1},"requestId":"fedcba9876543210","cacheHit":false}"#.utf8)
            return (HTTPURLResponse(url: urlRequest.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!, response)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://graph.test")!,
                            session: URLSession(configuration: configuration))

        let result = try await api.recognizeGraph(request: request)
        XCTAssertEqual(result.result.requestID, requestID)
        XCTAssertEqual(result.result.expressions.first?.latex, "y=x^2-4")
        XCTAssertEqual(lock.withLock { requestCount }, 1)
    }

    func testRecognitionControllerCoalescesConcurrentInvocationForSameSelection() async throws {
        let selection = BoardStudySelection(
            boardID: boardID,
            canonicalObjectIDs: ["path-equation"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: 20, y: 30, width: 280, height: 64)
            )),
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let lock = NSLock()
        var requestCount = 0
        GraphURLProtocolStub.handler = { request in
            lock.withLock { requestCount += 1 }
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try graphRequestBody(request)) as? [String: Any]
            )
            let requestID = try XCTUnwrap(payload["requestId"] as? String)
            let body: [String: Any] = [
                "result": [
                    "graphable": true, "confidence": 0.94,
                    "expressions": [[
                        "id": "expression-1", "latex": "y=2x+1",
                        "type": "explicitFunction", "confidence": 0.96
                    ]],
                    "warnings": [], "requestID": requestID, "recognitionVersion": 1
                ],
                "requestId": requestID, "cacheHit": false
            ]
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: body))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://graph.test")!,
                            session: URLSession(configuration: configuration))
        let controller = GraphRecognitionController()

        async let first = controller.recognize(selection, api: api, prepareSelection: {})
        async let second = controller.recognize(selection, api: api, prepareSelection: {})
        let values = try await [first, second]

        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(lock.withLock { requestCount }, 1)
    }

    func testLectureRecognitionRequestUsesExactCamelCaseBoardLocalContract() throws {
        let folderID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let boardOne = "11111111111111111111111111111111"
        let boardTwo = "22222222222222222222222222222222"
        let first = BoardStudySelection(
            boardID: boardOne,
            canonicalObjectIDs: ["professor-path-1"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: -35.5, y: 20.25, width: 180, height: 62)
            )),
            selectedTextObjects: [],
            lectureWorldBBox: CGRect(x: 4_000, y: 5_000, width: 180, height: 62)
        )
        let second = BoardStudySelection(
            boardID: boardTwo,
            canonicalObjectIDs: ["stroke-9", "text-2"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: 14, y: -88, width: 260, height: 104)
            )),
            selectedTextObjects: [],
            lectureWorldBBox: CGRect(x: -9_000, y: 7_500, width: 260, height: 104)
        )
        let target = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: folderID,
            selections: [second, first],
            preferredPrimaryBoardID: boardTwo
        ))
        guard case .lecture(let lecture) = target else {
            return XCTFail("Two boards must use the grouped lecture target.")
        }

        let request = LectureGraphRecognitionRequest(
            target: lecture, requestID: "0123456789abcdef"
        )
        let data = try JSONEncoder().encode(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(root.keys), Set([
            "requestId", "action", "contextScope", "primaryBoardId", "boards"
        ]))
        XCTAssertNil(root["folderID"])
        XCTAssertEqual(root["requestId"] as? String, "0123456789abcdef")
        XCTAssertEqual(root["action"] as? String, "graph_recognition")
        XCTAssertEqual(root["contextScope"] as? String, "local")
        XCTAssertEqual(root["primaryBoardId"] as? String, boardTwo)
        let boards = try XCTUnwrap(root["boards"] as? [[String: Any]])
        XCTAssertEqual(boards.count, 2)
        XCTAssertEqual(boards.map { $0["boardId"] as? String }, [boardOne, boardTwo])
        XCTAssertEqual(Set(boards[0].keys), Set(["boardId", "selectedObjectIds", "bbox"]))
        XCTAssertEqual(boards[0]["selectedObjectIds"] as? [String], ["professor-path-1"])
        let firstBBox = try XCTUnwrap(boards[0]["bbox"] as? [String: Any])
        XCTAssertEqual(firstBBox["x"] as? Double, -35.5)
        XCTAssertEqual(firstBBox["y"] as? Double, 20.25)
        XCTAssertEqual(firstBBox["width"] as? Double, 180)
        XCTAssertEqual(firstBBox["height"] as? Double, 62)
        let secondBBox = try XCTUnwrap(boards[1]["bbox"] as? [String: Any])
        XCTAssertEqual(secondBBox["x"] as? Double, 14)
        XCTAssertEqual(secondBBox["y"] as? Double, -88)
        XCTAssertNotEqual(secondBBox["x"] as? Double,
                          second.lectureWorldBBox.map { Double($0.minX) })
    }

    func testLectureRecognitionTargetEnforcesOwnershipPrimaryAndTwoToEightBoards() throws {
        let folderID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let selections = try (1...9).map { index -> BoardStudySelection in
            let boardID = String(repeating: String(index), count: 32)
            return BoardStudySelection(
                boardID: boardID,
                canonicalObjectIDs: ["object-\(index)"],
                localBBox: try XCTUnwrap(StudySelectionBBox(
                    rect: CGRect(x: index * 10, y: -index * 2, width: 100, height: 40)
                )),
                selectedTextObjects: [], lectureWorldBBox: nil
            )
        }

        let one = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: [selections[0]],
            preferredPrimaryBoardID: selections[0].boardID
        ))
        guard case .board(let singleSelection) = one else {
            return XCTFail("One selected board must retain the board endpoint.")
        }
        XCTAssertEqual(singleSelection.boardID, selections[0].boardID)

        let two = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: Array(selections.prefix(2)),
            preferredPrimaryBoardID: selections[1].boardID
        ))
        guard case .lecture(let groupedTwo) = two else {
            return XCTFail("Two selected boards must use the grouped endpoint.")
        }
        XCTAssertEqual(groupedTwo.primaryBoardID, selections[1].boardID)
        XCTAssertEqual(two.primarySelection.boardID, selections[1].boardID)
        XCTAssertEqual(two.sourceBoardIDs, Array(selections.prefix(2)).map(\.boardID))

        let eight = GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: Array(selections.prefix(8)),
            preferredPrimaryBoardID: "not-selected"
        )
        XCTAssertNotNil(eight)
        XCTAssertEqual(eight?.primarySelection.boardID, selections[0].boardID)
        XCTAssertNil(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: selections,
            preferredPrimaryBoardID: selections[0].boardID
        ))
        XCTAssertNil(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: [selections[0], selections[0]],
            preferredPrimaryBoardID: selections[0].boardID
        ))
    }

    func testGroupedRecognitionSingleFlightSavesEveryBoardBeforeOnePOST() async throws {
        let folderID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let boardOne = "11111111111111111111111111111111"
        let boardTwo = "22222222222222222222222222222222"
        let selections = try [boardOne, boardTwo].enumerated().map { index, boardID in
            BoardStudySelection(
                boardID: boardID,
                canonicalObjectIDs: ["object-\(index)"],
                localBBox: try XCTUnwrap(StudySelectionBBox(
                    rect: CGRect(x: index * 30, y: -index * 8, width: 220, height: 70)
                )),
                selectedTextObjects: [], lectureWorldBBox: nil
            )
        }
        let target = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: selections,
            preferredPrimaryBoardID: boardTwo
        ))
        let lock = NSLock()
        var requestCount = 0
        var preparedBoardIDs: [String] = []
        GraphURLProtocolStub.handler = { request in
            lock.withLock { requestCount += 1 }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path,
                           "/api/folders/\(folderID)/study/graph-recognition")
            XCTAssertEqual(lock.withLock { preparedBoardIDs }, [boardOne, boardTwo])
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try graphRequestBody(request)) as? [String: Any]
            )
            let requestID = try XCTUnwrap(payload["requestId"] as? String)
            XCTAssertEqual(payload["primaryBoardId"] as? String, boardTwo)
            XCTAssertEqual((payload["boards"] as? [[String: Any]])?.count, 2)
            let body: [String: Any] = [
                "result": [
                    "graphable": true, "confidence": 0.96,
                    "expressions": [[
                        "id": "expression-1", "latex": "y=x+1",
                        "type": "explicitFunction", "confidence": 0.97
                    ]],
                    "warnings": [], "requestID": requestID, "recognitionVersion": 1
                ],
                "requestId": requestID, "cacheHit": false, "idempotentReplay": false
            ]
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!,
                    try JSONSerialization.data(withJSONObject: body))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://graph.test")!,
                            session: URLSession(configuration: configuration))
        let controller = GraphRecognitionController()
        let prepare: () async -> Void = {
            lock.withLock { preparedBoardIDs = target.sourceBoardIDs }
        }

        async let first = controller.recognize(target, api: api, prepareSelection: prepare)
        async let second = controller.recognize(target, api: api, prepareSelection: prepare)
        let values = try await [first, second]

        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(lock.withLock { requestCount }, 1)
        XCTAssertEqual(lock.withLock { preparedBoardIDs }, [boardOne, boardTwo])
    }

    func testGroupedRecognitionCacheSignatureIncludesEveryBoardAndIsOrderStable() throws {
        let folderID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let first = BoardStudySelection(
            boardID: "11111111111111111111111111111111",
            canonicalObjectIDs: ["path-a"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: 10, y: 20, width: 180, height: 60)
            )),
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let second = BoardStudySelection(
            boardID: "22222222222222222222222222222222",
            canonicalObjectIDs: ["stroke-b"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: -40, y: 12, width: 240, height: 80)
            )),
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let original = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: [first, second],
            preferredPrimaryBoardID: first.boardID
        ))
        let reordered = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: [second, first],
            preferredPrimaryBoardID: first.boardID
        ))
        XCTAssertEqual(original.cacheSignature, reordered.cacheSignature)

        let changedSecondary = BoardStudySelection(
            boardID: second.boardID,
            canonicalObjectIDs: ["stroke-b", "stroke-c"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: -40, y: 12, width: 280, height: 80)
            )),
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let changed = try XCTUnwrap(GraphRecognitionTarget.makeLecture(
            folderID: folderID, selections: [first, changedSecondary],
            preferredPrimaryBoardID: first.boardID
        ))
        XCTAssertNotEqual(original.cacheSignature, changed.cacheSignature)

        let creation = GraphCreationRequest(
            target: original,
            selectedObjectKeys: [
                "\(first.boardID):professorPath:path-a",
                "\(second.boardID):editorObject:stroke-b"
            ]
        )
        XCTAssertEqual(creation.selection.boardID, first.boardID)
        XCTAssertEqual(creation.sourceBoardIDs, [first.boardID, second.boardID])
        XCTAssertEqual(creation.selectedObjectKeys.count, 2)
    }

    func testGraphFactoryRetainsCanonicalSourceAndPlacesBesideIt() throws {
        let selection = BoardStudySelection(
            boardID: boardID,
            canonicalObjectIDs: ["professor-path-9"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: -80, y: 30, width: 300, height: 90)
            )),
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let expression = GraphExpression(id: "expression-1", latex: "y=x^2",
                                         type: .explicitFunction)
        let graph = GraphObjectFactory.make(
            boardID: boardID, selection: selection, expressions: [expression],
            recognitionRequestID: "0123456789abcdef", cameraScale: 1,
            occupied: [selection.localBBox.cgRect]
        )

        XCTAssertEqual(graph.owningBoardID, boardID)
        XCTAssertEqual(graph.sourceSelection?.selectedObjectKeys, ["professor-path-9"])
        XCTAssertEqual(graph.sourceSelection?.originalRecognitionRequestID,
                       "0123456789abcdef")
        XCTAssertEqual(graph.expressions, [expression])
        XCTAssertFalse(graph.frame.cgRect.intersects(selection.localBBox.cgRect))
    }

    func testRecognizedExpressionEntersLosslessCanonicalDraftPath() throws {
        let recognized = GraphRecognizedExpression(
            id: "expression-source", latex: "y=x^2-4",
            type: .explicitFunction, confidence: 0.98
        )
        let canonical = recognized.canonicalExpression
        let draft = GraphExpressionDraft(expression: canonical)

        XCTAssertEqual(try draft.expression(), canonical)
        XCTAssertTrue(canonical.visible)
        XCTAssertNil(canonical.displayStyle)
        XCTAssertEqual(canonical.restrictions, [])
        XCTAssertEqual(canonical.additionalFields, [:])
    }

    func testFallbackSamplesSupportedFunctionAndSplitsDiscontinuity() {
        let viewport = GraphViewport.conventional
        let parabola = GraphFallbackSampler.segments(for: "y=x^2-4", viewport: viewport)
        XCTAssertFalse(parabola.isEmpty)
        XCTAssertTrue(parabola.flatMap { $0 }.contains { abs($0.x) < 0.1 && abs($0.y + 4) < 0.2 })

        let reciprocal = GraphFallbackSampler.segments(for: "y=1/x", viewport: viewport,
                                                       sampleCount: 513)
        XCTAssertGreaterThanOrEqual(reciprocal.count, 2)
        XCTAssertFalse(reciprocal.contains { segment in
            guard let first = segment.first, let last = segment.last else { return false }
            return first.x < 0 && last.x > 0
        })
    }

    func testPassiveGraphLayerContainsNoWebView() {
        let graph = GraphObject(
            id: "graph-passive", owningBoardID: boardID,
            frame: GraphFrame(x: 10, y: 20, width: 420, height: 300),
            expressions: [GraphExpression(id: "e1", latex: "y=sin(x)",
                                          type: .explicitFunction)]
        )
        let layer = GraphFallbackRenderer.layer(for: graph, contentsScale: 2)
        XCTAssertEqual(layer.frame, graph.frame.cgRect)
        XCTAssertGreaterThan(layer.sublayers?.count ?? 0, 1)
        XCTAssertNil(layer.delegate as? UIView)
    }

    func testSelectedGraphAddsProviderIndependentSemanticAIContext() throws {
        let graph = GraphObject(
            id: "graph-context", owningBoardID: boardID,
            frame: GraphFrame(x: -20, y: 40, width: 400, height: 260),
            expressions: [
                GraphExpression(id: "a", latex: "y=x^2", type: .explicitFunction),
                GraphExpression(id: "b", latex: "y=2x+1", type: .explicitFunction)
            ]
        )
        let document = try SVGDocument.parse(
            #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600"></svg>"#
        )
        let editor = EditorState(
            schemaVersion: 4, revision: 1, updatedAt: nil,
            viewport: CameraRect(x: 0, y: 0, width: 800, height: 600),
            objects: [CanvasObject(graph: graph)], groups: [], importedTransforms: [:],
            sourceBoards: [], mergedBoardIDs: []
        )
        let selection = try XCTUnwrap(BoardStudySelection.isolated(
            boardID: boardID, selectedIDs: [graph.id], document: document, editor: editor
        ))
        XCTAssertEqual(selection.selectedTextObjects.count, 1)
        XCTAssertEqual(selection.selectedTextObjects.first?.type, "graph")
        XCTAssertEqual(selection.selectedTextObjects.first?.role, "graph")
        XCTAssertEqual(selection.selectedTextObjects.first?.text, "y=x^2\ny=2x+1")
        XCTAssertEqual(selection.localBBox.cgRect, graph.frame.cgRect)
    }
}

private final class GraphURLProtocolStub: URLProtocol, @unchecked Sendable {
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

private func graphRequestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
    stream.open()
    defer { stream.close() }
    var result = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16_384)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 16_384)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}
