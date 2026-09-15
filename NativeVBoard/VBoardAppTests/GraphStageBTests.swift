import XCTest
import UIKit
@testable import VBoardApp

@MainActor
final class GraphRecognitionAndRenderingTests: XCTestCase {
    private let boardID = "603f5213ab0a249716833214c5ab88da"

    func testIntegralSelectionOffersIntegrandInsteadOfInventingAntiderivative() throws {
        let text = StudySelectedTextObject(
            id: "integral-text", type: "text", role: "study",
            text: #"$\int_0^1 \frac{1}{1+x^2}\,dx$"#,
            fontSize: 20, x: 0, y: 0, width: 260, height: 60,
            practiceProblemId: nil, sourceStudyInteractionId: nil
        )
        let selection = BoardStudySelection(
            boardID: boardID, canonicalObjectIDs: [text.id],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: 0, y: 0, width: 260, height: 60)
            )), selectedTextObjects: [text], lectureWorldBBox: nil
        )
        let proposal = try XCTUnwrap(GraphNonDirectExpressionPolicy.integralProposal(
            from: .board(selection)
        ))

        XCTAssertEqual(proposal.sourceLatex, #"\int_0^1 \frac{1}{1+x^2}\,dx"#)
        XCTAssertEqual(proposal.integrandLatex, #"\frac{1}{1+x^2}"#)
        XCTAssertEqual(proposal.graphLatex, #"y=\frac{1}{1+x^2}"#)
        XCTAssertEqual(GraphExpressionInference.type(for: proposal.graphLatex), .explicitFunction)
    }

    func testUnicodeIntegralWithoutDifferentialIsNotSilentlyConverted() throws {
        let text = StudySelectedTextObject(
            id: "ambiguous-integral", type: "text", role: "study",
            text: "∫ 1/(1+x²)", fontSize: nil, x: nil, y: nil, width: nil, height: nil,
            practiceProblemId: nil, sourceStudyInteractionId: nil
        )
        let selection = BoardStudySelection(
            boardID: boardID, canonicalObjectIDs: [text.id],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: 0, y: 0, width: 200, height: 50)
            )), selectedTextObjects: [text], lectureWorldBBox: nil
        )

        XCTAssertNil(GraphNonDirectExpressionPolicy.integralProposal(from: .board(selection)))
    }

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

    func testNativeParserHonorsPrecedenceUnaryMinusAndRightAssociativePower() throws {
        XCTAssertEqual(try SafeGraphExpression(source: "2+3*4").evaluate(x: 0), 14,
                       accuracy: 1e-12)
        XCTAssertEqual(try SafeGraphExpression(source: "-2^2").evaluate(x: 0), -4,
                       accuracy: 1e-12)
        XCTAssertEqual(try SafeGraphExpression(source: "2^3^2").evaluate(x: 0), 512,
                       accuracy: 1e-12)
        XCTAssertEqual(try SafeGraphExpression(source: "3(x+1)").evaluate(x: 2), 9,
                       accuracy: 1e-12)
        XCTAssertEqual(try SafeGraphExpression(source: "x+y").evaluate(x: 2, y: 5), 7,
                       accuracy: 1e-12)
    }

    func testNativeCalculatorSupportsClassroomConstantsAndFunctions() throws {
        XCTAssertEqual(try NativeGraphMath.calculate("2+3*4").values.first!, 14,
                       accuracy: 1e-12)
        XCTAssertEqual(try NativeGraphMath.calculate("sqrt(81)").values.first!, 9,
                       accuracy: 1e-12)
        XCTAssertEqual(try NativeGraphMath.calculate("sin(pi/2)").values.first!, 1,
                       accuracy: 1e-12)
        XCTAssertEqual(try NativeGraphMath.calculate("asin(1)", angleMode: "degrees")
            .values.first!, 90, accuracy: 1e-10)
    }

    func testNativeLinearAndStableQuadraticSolvers() throws {
        let linear = try NativeGraphMath.solve("2x+3=7", domain: -10...10)
        XCTAssertEqual(linear.kind, .linear)
        XCTAssertEqual(linear.values, [2])
        XCTAssertTrue(linear.isExact)

        let quadratic = try NativeGraphMath.solve("x²-5x+6=0", domain: -10...10)
        XCTAssertEqual(quadratic.kind, .quadratic)
        XCTAssertEqual(quadratic.values.count, 2)
        XCTAssertEqual(quadratic.values[0], 2, accuracy: 1e-10)
        XCTAssertEqual(quadratic.values[1], 3, accuracy: 1e-10)
        XCTAssertTrue(quadratic.isExact)
    }

    func testNativeNumericalRootsAndIntersectionsStayInsideRequestedDomain() throws {
        let roots = try NativeGraphMath.solve("sin(x)=0.5", domain: 0...Double.pi)
        XCTAssertEqual(roots.kind, .numericalRoots)
        XCTAssertEqual(roots.values.count, 2)
        XCTAssertEqual(roots.values[0], Double.pi / 6, accuracy: 1e-7)
        XCTAssertEqual(roots.values[1], 5 * Double.pi / 6, accuracy: 1e-7)

        let intersections = try NativeGraphMath.intersections(
            "y=x", "y=2-x", domain: -10...10
        )
        XCTAssertEqual(intersections.kind, .intersections)
        XCTAssertEqual(intersections.values.count, 2)
        XCTAssertEqual(intersections.values[0], 1, accuracy: 1e-7)
        XCTAssertEqual(intersections.values[1], 1, accuracy: 1e-7)
    }

    func testNativeNumericalCalculusAndHonestIndefiniteIntegral() throws {
        let derivative = try NativeGraphMath.derivative("y=x^2", at: 3)
        XCTAssertEqual(derivative.values.first!, 6, accuracy: 1e-7)

        let integral = try NativeGraphMath.integral("y=x", from: 0, to: 1)
        XCTAssertEqual(integral.values.first!, 0.5, accuracy: 1e-9)

        let unsupported = try NativeGraphMath.solve(
            #"\int 1/(1+x^2) dx"#, domain: -10...10
        )
        XCTAssertEqual(unsupported.kind, .unsupportedIndefiniteIntegral)
        XCTAssertTrue(unsupported.values.isEmpty)
        XCTAssertTrue(unsupported.message.localizedCaseInsensitiveContains("indefinite"))
    }

    func testNativeEnvironmentSupportsVariablesUserFunctionsAndTrigAliases() throws {
        let expressions = [
            GraphExpression(id: "a", latex: "a=2", type: .unknown),
            GraphExpression(id: "f", latex: "f(x)=x^2+a", type: .explicitFunction),
        ]
        let environment = GraphMathEnvironment.build(from: expressions)

        XCTAssertEqual(environment.variables["a"], 2)
        XCTAssertEqual(
            try NativeGraphMath.calculate(
                "f(3)", variables: environment.variables,
                functions: environment.functions
            ).values.first!,
            11, accuracy: 1e-10
        )
        XCTAssertEqual(try NativeGraphMath.calculate("sec(0)").values.first!,
                       1, accuracy: 1e-10)
        XCTAssertEqual(try NativeGraphMath.calculate("csc(pi/2)").values.first!,
                       1, accuracy: 1e-10)
        XCTAssertEqual(try NativeGraphMath.calculate("cot(pi/4)").values.first!,
                       1, accuracy: 1e-10)
        XCTAssertEqual(
            try NativeGraphMath.calculate("arcsin(1)", angleMode: "degrees")
                .values.first!,
            90, accuracy: 1e-10
        )
    }

    func testGraphWorkspaceKeepsExpressionAndViewportMutationsIndependent() {
        let originalViewport = GraphViewport(xMin: -8, xMax: 8, yMin: -6, yMax: 6)
        let expression = GraphExpression(
            id: "expression-1", latex: "y=sin(x)", type: .explicitFunction
        )
        let graph = GraphObject(
            id: "graph-workspace", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [expression], viewport: originalViewport
        )
        var expressionCommits: [GraphObject] = []
        let model = GraphWorkspaceModel(graph: graph) { expressionCommits.append($0) }
        let moved = GraphViewport(xMin: -4, xMax: 12, yMin: -10, yMax: 14)

        model.updateViewport(moved)
        XCTAssertEqual(model.expressions, [expression])
        XCTAssertTrue(expressionCommits.isEmpty,
                      "Viewport movement must not rewrite the expression array")

        model.updateSource(id: expression.id, source: "y=cos(x)")
        XCTAssertEqual(model.viewport, moved,
                       "Expression editing must not reset the live viewport")
        XCTAssertEqual(expressionCommits.count, 1)
        XCTAssertEqual(expressionCommits.first?.expressions.first?.latex, "y=cos(x)")

        model.resetViewport()
        XCTAssertEqual(model.expressions.first?.latex, "y=cos(x)")
        XCTAssertEqual(model.viewport, .conventional)
    }

    func testTypingPreservesRowIdentityFocusCategoryAndViewport() throws {
        let viewport = GraphViewport(xMin: -19, xMax: 7, yMin: -4, yMax: 13)
        let expression = GraphExpression(
            id: "stable-row", latex: "y=sin(x)", type: .explicitFunction
        )
        let graph = GraphObject(
            id: "stable-editor", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [expression], viewport: viewport
        )
        let model = GraphWorkspaceModel(graph: graph)
        model.beginEditing(expression.id)
        model.keyboardCategory = .functions

        model.updateSource(id: expression.id, source: "y=asin(x)")

        XCTAssertEqual(model.expressions.first?.id, expression.id)
        XCTAssertEqual(model.editingExpressionID, expression.id)
        XCTAssertEqual(model.selectedExpressionID, expression.id)
        XCTAssertEqual(model.keyboardCategory, .functions)
        XCTAssertEqual(model.viewport, viewport)

        _ = try XCTUnwrap(model.addExpression(source: "y=x^2"))
        XCTAssertEqual(model.viewport, viewport)
        XCTAssertEqual(model.keyboardCategory, .functions)
    }

    func testGraphWorkspaceDirectDerivativeIntegralAndParameterSlider() throws {
        let function = GraphExpression(
            id: "function", latex: "f(x)=x^2", type: .explicitFunction
        )
        let derivative = GraphExpression(
            id: "derivative", latex: "f'(2)", type: .unknown
        )
        let integral = GraphExpression(
            id: "integral", latex: "integral(f(x),0,2)", type: .unknown
        )
        let parameterized = GraphExpression(
            id: "curve", latex: "y=a*sin(x)", type: .explicitFunction
        )
        let graph = GraphObject(
            id: "graph-calculus", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [function, derivative, integral, parameterized]
        )
        let model = GraphWorkspaceModel(graph: graph)

        XCTAssertEqual(model.feedback(for: derivative)?.message, "4")
        XCTAssertEqual(
            try XCTUnwrap(Double(model.feedback(for: integral)?.message ?? "")),
            8.0 / 3.0, accuracy: 0.000_001
        )
        XCTAssertTrue(model.undefinedParameters(for: derivative).isEmpty)
        XCTAssertTrue(model.undefinedParameters(for: integral).isEmpty)
        XCTAssertTrue(model.undefinedParameters(for: GraphExpression(
            id: "symbolic-derivative", latex: "d/dx(f(x))", type: .unknown
        )).isEmpty)
        XCTAssertEqual(model.undefinedParameters(for: parameterized), ["a"])

        let parameterID = try XCTUnwrap(model.addParameter(named: "a"))
        let sliderExpression = try XCTUnwrap(model.expression(id: parameterID))
        let initialSlider = try XCTUnwrap(model.slider(for: sliderExpression))
        XCTAssertEqual(initialSlider.value, 0)
        XCTAssertEqual(initialSlider.minimum, -10)
        XCTAssertEqual(initialSlider.maximum, 10)
        XCTAssertEqual(initialSlider.step, 0.1)
        model.updateSlider(id: parameterID, value: 2.5)
        XCTAssertEqual(model.expression(id: parameterID)?.latex, "a=2.5")

        let environment = GraphMathEnvironment.build(from: model.expressions)
        let segments = GraphFallbackSampler.segments(
            for: "y=a*sin(x)", viewport: .conventional,
            environment: environment
        )
        XCTAssertFalse(segments.isEmpty)
    }

    func testFirstClassDerivativeSyntaxEvaluatesConstantsAndNeverInventsDSlider() {
        let derivative = GraphExpression(
            id: "constant-derivative", latex: "d/dx(2)", type: .unknown
        )
        let graph = GraphObject(
            id: "graph-constant-derivative", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [derivative]
        )
        let model = GraphWorkspaceModel(graph: graph)

        XCTAssertEqual(model.feedback(for: derivative), GraphRowFeedback(
            kind: .derivative, message: "0"
        ))
        XCTAssertTrue(model.undefinedParameters(for: derivative).isEmpty)
    }

    func testCalculusSyntaxSupportsFunctionsPrimesAndDefiniteIntegrals() throws {
        let function = GraphExpression(
            id: "function", latex: "f(x)=x^2", type: .explicitFunction
        )
        let directFunction = GraphExpression(
            id: "direct-function", latex: "d/dx(f(x))", type: .unknown
        )
        let directExpression = GraphExpression(
            id: "direct-expression", latex: "d/dx(x^2)", type: .unknown
        )
        let primeFunction = GraphExpression(
            id: "prime-function", latex: "f'(x)", type: .unknown
        )
        let primeValue = GraphExpression(
            id: "prime-value", latex: "f'(3)", type: .unknown
        )
        let secondPrime = GraphExpression(
            id: "second-prime", latex: "f''(2)", type: .unknown
        )
        let integral = GraphExpression(
            id: "integral", latex: "integral(x^2,0,2)", type: .unknown
        )
        let graph = GraphObject(
            id: "calculus-language", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [function, directFunction, directExpression,
                          primeFunction, primeValue, secondPrime, integral]
        )
        let model = GraphWorkspaceModel(graph: graph)

        XCTAssertEqual(model.feedback(for: directFunction)?.message, "Derivative function")
        XCTAssertEqual(model.feedback(for: directExpression)?.message, "Derivative function")
        XCTAssertEqual(model.feedback(for: primeFunction)?.message, "Derivative function")
        XCTAssertEqual(model.feedback(for: primeValue)?.message, "6")
        XCTAssertEqual(model.feedback(for: secondPrime)?.message, "2")
        XCTAssertEqual(
            try XCTUnwrap(Double(model.feedback(for: integral)?.message ?? "")),
            8.0 / 3.0, accuracy: 0.000_001
        )
        for expression in graph.expressions {
            XCTAssertTrue(model.undefinedParameters(for: expression).isEmpty,
                          "calculus or known function leaked a slider from \(expression.latex)")
        }
    }

    func testGuidedCalculusCreatesNewRowsWithoutConcatenatingSource() throws {
        let function = GraphExpression(
            id: "function", latex: "f(x)=sin(x)", type: .explicitFunction
        )
        let graph = GraphObject(
            id: "guided-calculus", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [function]
        )
        let model = GraphWorkspaceModel(graph: graph)

        model.beginCalculus(.derivative)
        XCTAssertEqual(model.calculusDraft?.functionSource, "f(x)")
        model.calculusDraft?.evaluationPoint = "2"
        let derivativeID = try XCTUnwrap(model.commitCalculusDraft())
        XCTAssertEqual(model.expression(id: derivativeID)?.latex, "f'(2)")
        XCTAssertEqual(model.expressions.first?.latex, "f(x)=sin(x)")

        model.selectedExpressionID = function.id
        model.beginCalculus(.integral)
        model.calculusDraft?.lowerBound = "0"
        model.calculusDraft?.upperBound = "2"
        let integralID = try XCTUnwrap(model.commitCalculusDraft())
        XCTAssertEqual(model.expression(id: integralID)?.latex, "integral(f(x),0,2)")
        XCTAssertFalse(model.expressions.contains {
            $0.latex.contains("integral(,,)d/dx")
        })
    }

    func testReadModeCalculusActionRevealsSemanticConfigurationTray() {
        let graph = GraphObject(
            id: "guided-graph", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [GraphExpression(
                id: "function", latex: "f(x)=x^2", type: .explicitFunction
            )]
        )
        let model = GraphWorkspaceModel(graph: graph)

        model.beginGuidedCalculus(.derivative, from: "function")

        XCTAssertEqual(model.selectedExpressionID, "function")
        XCTAssertEqual(model.editingExpressionID, "function")
        XCTAssertEqual(model.keyboardCategory, .calculus)
        XCTAssertEqual(model.calculusDraft?.operation, .derivative)
        XCTAssertEqual(model.calculusDraft?.functionSource, "f(x)")
    }

    func testSliderMetadataPersistsThroughGraphJSONRoundTrip() throws {
        let graph = GraphObject(
            id: "slider-persistence", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [GraphExpression(
                id: "curve", latex: "y=a*sin(x)", type: .explicitFunction
            )]
        )
        let model = GraphWorkspaceModel(graph: graph)
        let id = try XCTUnwrap(model.addParameter(named: "a"))
        model.updateSlider(id: id, value: 2.7)

        let restored = try JSONDecoder().decode(
            GraphObject.self, from: JSONEncoder().encode(model.workingGraph)
        )
        let reopened = GraphWorkspaceModel(graph: restored)
        let expression = try XCTUnwrap(reopened.expression(id: id))
        let slider = try XCTUnwrap(reopened.slider(for: expression))
        XCTAssertEqual(slider.name, "a")
        XCTAssertEqual(slider.value, 2.7)
        XCTAssertEqual(slider.minimum, -10)
        XCTAssertEqual(slider.maximum, 10)
        XCTAssertEqual(slider.step, 0.1)
    }

    func testCheckMyWorkUsesDedicatedEndpointInsteadOfExplainEndpoint() async throws {
        let selection = BoardStudySelection(
            boardID: boardID,
            canonicalObjectIDs: ["practice-1", "stroke-1"],
            localBBox: try XCTUnwrap(StudySelectionBBox(
                rect: CGRect(x: 20, y: 30, width: 240, height: 180)
            )),
            selectedTextObjects: [], lectureWorldBBox: nil
        )
        let payload = BoardStudyExplainRequest.make(
            selection: selection,
            action: "check_my_work",
            requestID: "1234567890abcdef"
        )
        let lock = NSLock()
        var observedPath: String?
        GraphURLProtocolStub.handler = { request in
            lock.withLock { observedPath = request.url?.path }
            XCTAssertEqual(request.httpMethod, "POST")
            let requestBody = try JSONSerialization.jsonObject(
                with: try graphRequestBody(request)
            ) as? [String: Any]
            XCTAssertEqual(requestBody?["action"] as? String, "check_my_work")
            XCTAssertEqual(requestBody?["selectedObjectIds"] as? [String],
                           ["practice-1", "stroke-1"])
            let body = Data(#"{"interaction":{"id":"1234567890abcdef","title":"Check My Work","answer":"Correct"}}"#.utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200,
                                httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphURLProtocolStub.self]
        let api = APIClient(baseURL: URL(string: "https://study.test")!,
                            session: URLSession(configuration: configuration))

        _ = try await api.performStudyAction(.checkWork, request: payload)

        XCTAssertEqual(lock.withLock { observedPath },
                       "/api/boards/\(boardID)/study/check")
    }

    func testEveryInitialStudyActionHasOneEndpointAndSpecificLoadingCopy() {
        XCTAssertEqual(StudyAction.explain.endpoint(boardID: boardID),
                       "/api/boards/\(boardID)/study/explain")
        XCTAssertEqual(StudyAction.practice.endpoint(boardID: boardID),
                       "/api/boards/\(boardID)/study/practice")
        XCTAssertEqual(StudyAction.checkWork.endpoint(boardID: boardID),
                       "/api/boards/\(boardID)/study/check")
        XCTAssertEqual(StudyAction.explain.loadingCopy, "Explaining…")
        XCTAssertEqual(StudyAction.practice.loadingCopy, "Creating practice problems…")
        XCTAssertEqual(StudyAction.checkWork.loadingCopy, "Checking your work…")
        XCTAssertNotEqual(StudyAction.checkWork.endpoint(boardID: boardID),
                          StudyAction.explain.endpoint(boardID: boardID))
        XCTAssertTrue(StudyActionResultPolicy.savesExplanationMarker(for: .explain))
        XCTAssertFalse(StudyActionResultPolicy.savesExplanationMarker(for: .practice))
        XCTAssertFalse(StudyActionResultPolicy.savesExplanationMarker(for: .checkWork))
        XCTAssertTrue(StudyActionResultPolicy.placesPracticeCards(
            for: .practice, problemCount: 3
        ))
        XCTAssertFalse(StudyActionResultPolicy.placesPracticeCards(
            for: .explain, problemCount: 3
        ))
        XCTAssertFalse(StudyActionResultPolicy.placesPracticeCards(
            for: .practice, problemCount: 2
        ))
    }

    func testMathKeyboardInsertsAtCursorAndPlacesTemplateCursor() {
        let middle = GraphMathInsertionPlan.apply(
            .insert(text: "cos()", cursorBacktrack: 1),
            to: "y=+1", selection: NSRange(location: 2, length: 0)
        )
        XCTAssertEqual(middle.source, "y=cos()+1")
        XCTAssertEqual(middle.selection, NSRange(location: 6, length: 0))

        let integral = GraphMathInsertionPlan.apply(
            .insert(text: "integral(,,)", cursorBacktrack: 3),
            to: "", selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(integral.source, "integral(,,)")
        XCTAssertEqual(integral.selection, NSRange(location: 9, length: 0))
    }

    func testMathKeyboardCaretButtonsMoveExactlyOnePositionAndClamp() {
        let left = GraphMathInsertionPlan.apply(
            .moveCaret(offset: -1), to: "y=sin(x)",
            selection: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(left.source, "y=sin(x)")
        XCTAssertEqual(left.selection, NSRange(location: 4, length: 0))

        let right = GraphMathInsertionPlan.apply(
            .moveCaret(offset: 1), to: left.source, selection: left.selection
        )
        XCTAssertEqual(right.selection, NSRange(location: 5, length: 0))
        XCTAssertEqual(GraphMathInsertionPlan.apply(
            .moveCaret(offset: -1), to: "x", selection: NSRange(location: 0, length: 0)
        ).selection.location, 0)
        XCTAssertEqual(GraphMathInsertionPlan.apply(
            .moveCaret(offset: 1), to: "x", selection: NSRange(location: 99, length: 4)
        ).selection.location, 1)
    }

    func testSupportedInverseTrigLatexNormalizesWithoutChangingReciprocalSine() {
        XCTAssertEqual(GraphLatexNormalizer.normalize(#"\arcsin(x)"#), "asin(x)")
        XCTAssertEqual(GraphLatexNormalizer.normalize(#"\sin^{-1}(x)"#), "asin(x)")
        XCTAssertEqual(GraphLatexNormalizer.normalize(#"\cos^{-1}(x)"#), "acos(x)")
        XCTAssertEqual(GraphLatexNormalizer.normalize(#"\tan^{-1}(x)"#), "atan(x)")
        XCTAssertEqual(GraphLatexNormalizer.normalize(#"\sin(x)"#), "sin(x)")
        XCTAssertEqual(GraphLatexNormalizer.normalize("sin(x)^-1"), "sin(x)^-1")
    }

    func testGraphViewportNavigationAndTicksRemainIndependentAndReadable() {
        let source = GraphViewport(xMin: -10, xMax: 10, yMin: -8, yMax: 12)
        let zoomed = GraphViewportNavigation.zoomed(source, by: 0.5)
        XCTAssertEqual(zoomed.xMax - zoomed.xMin, 10, accuracy: 1e-10)
        XCTAssertEqual(zoomed.yMax - zoomed.yMin, 10, accuracy: 1e-10)
        let anchored = GraphViewportNavigation.zoomed(
            source, by: 0.5, anchor: CGPoint(x: 0, y: 0),
            size: CGSize(width: 600, height: 400)
        )
        XCTAssertEqual(anchored.xMin, source.xMin, accuracy: 1e-10)
        XCTAssertEqual(anchored.yMax, source.yMax, accuracy: 1e-10)
        let panned = GraphViewportNavigation.panned(
            source, by: CGSize(width: 60, height: -40),
            size: CGSize(width: 600, height: 400)
        )
        XCTAssertEqual(panned.xMin, -12, accuracy: 1e-10)
        XCTAssertEqual(panned.yMin, -10, accuracy: 1e-10)

        let ticks = GraphTickPolicy.ticks(
            min: -10, max: 10, pixelLength: 700, minimumSpacing: 64
        )
        XCTAssertEqual(ticks.map(\.label), ["-10", "-8", "-6", "-4", "-2", "0", "2", "4", "6", "8", "10"])
        XCTAssertEqual(Set(ticks.map(\.label)).count, ticks.count)
    }

    func testZoomInThenOutIsAnExactInverseAndNeverMutatesExpressions() {
        let expression = GraphExpression(
            id: "source", latex: "y=a*sin(x)", type: .explicitFunction,
            additionalFields: ["future": .string("byte-identical")]
        )
        let source = GraphViewport(xMin: -13, xMax: 27, yMin: -7, yMax: 9)
        let graph = GraphObject(
            id: "zoom-inverse", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [expression], viewport: source
        )
        let model = GraphWorkspaceModel(graph: graph)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytesBefore = try? encoder.encode(model.expressions)

        model.updateViewport(GraphViewportNavigation.zoomed(
            model.viewport, by: GraphViewportNavigation.zoomInFactor
        ))
        model.updateViewport(GraphViewportNavigation.zoomed(
            model.viewport, by: GraphViewportNavigation.zoomOutFactor
        ))

        XCTAssertEqual(model.viewport.xMin, source.xMin, accuracy: 1e-10)
        XCTAssertEqual(model.viewport.xMax, source.xMax, accuracy: 1e-10)
        XCTAssertEqual(model.viewport.yMin, source.yMin, accuracy: 1e-10)
        XCTAssertEqual(model.viewport.yMax, source.yMax, accuracy: 1e-10)
        XCTAssertEqual(try? encoder.encode(model.expressions), bytesBefore)
    }

    func testGraphPlacementStaysBelowSourceClearsCollisionsAndFitsFixedWidth() {
        let source = CGRect(x: 780, y: 120, width: 180, height: 60)
        let firstObstacle = CGRect(x: 580, y: 200, width: 420, height: 320)
        let secondObstacle = CGRect(x: 580, y: 540, width: 420, height: 260)
        let frame = GraphPlacementPolicy.frame(
            source: source, occupied: [firstObstacle, secondObstacle],
            cameraScale: 1, containerWidth: 1_000
        ).cgRect

        XCTAssertGreaterThan(frame.minY, source.maxY)
        XCTAssertFalse(frame.intersects(firstObstacle))
        XCTAssertFalse(frame.intersects(secondObstacle))
        XCTAssertLessThanOrEqual(frame.maxX, 1_000)
        XCTAssertEqual(frame.width, 420)
    }

    func testPassiveGraphOpenPolicyUsesFingerOnceAndNeverConsumesPencil() {
        XCTAssertEqual(PassiveGraphOpenPolicy.tapCount(for: .direct), 1)
        XCTAssertEqual(PassiveGraphOpenPolicy.tapCount(for: .indirectPointer), 2)
        XCTAssertNil(PassiveGraphOpenPolicy.tapCount(for: .pencil))
    }

    func testPracticePlacementUsesThreeScreenSizedCardsAndFixedBoardWidth() {
        let workspace = CGRect(x: 0, y: 0, width: 900, height: 700)
        let obstacle = CGRect(x: 250, y: 340, width: 420, height: 190)
        let layout = PracticePlacementPlanner.layout(
            count: 3,
            source: CGRect(x: 300, y: 180, width: 260, height: 110),
            occupied: [obstacle], workspace: workspace, cameraScale: 1
        )

        XCTAssertEqual(layout.frames.count, 3)
        XCTAssertTrue(layout.frames.allSatisfy { $0.width == 320 && $0.height == 150 })
        XCTAssertTrue(layout.frames.allSatisfy {
            $0.minX >= workspace.minX && $0.maxX <= workspace.maxX
        })
        XCTAssertFalse(layout.frames[0].intersects(obstacle))
        XCTAssertFalse(layout.frames[0].intersects(layout.frames[1]))
        XCTAssertFalse(layout.frames[1].intersects(layout.frames[2]))
        XCTAssertEqual(layout.requiredWorkspace.width, workspace.width)
        XCTAssertGreaterThan(layout.requiredWorkspace.height, workspace.height)

        let zoomed = PracticePlacementPlanner.layout(
            count: 1, source: .zero, occupied: [],
            workspace: workspace, cameraScale: 2
        )
        XCTAssertEqual(zoomed.frames[0].width * 2, 320)
        XCTAssertEqual(zoomed.frames[0].height * 2, 150)
    }

    func testCompactStatusThumbnailAndPencilToolContracts() {
        XCTAssertEqual(EditorStatusPresentation("Saved"), .saved)
        XCTAssertEqual(EditorStatusPresentation("Saving…"), .saving)
        XCTAssertTrue(EditorStatusPresentation("Saving…").isProgress)
        XCTAssertEqual(EditorStatusPresentation("Saved locally"), .offline)
        XCTAssertEqual(EditorStatusPresentation("Save failed"), .error)
        XCTAssertEqual(LibraryThumbnailPolicy.aspectRatio, 16.0 / 9.0)
        XCTAssertEqual(PencilRadialPaletteModel.tools,
                       [.pen, .highlighter, .objectEraser, .lasso])
        XCTAssertEqual(EditorStatusPresentation("Saved").indicatorRole, .saved)
        XCTAssertEqual(EditorStatusPresentation("Saving…").indicatorRole, .pending)
        XCTAssertEqual(EditorStatusPresentation("Saved locally").indicatorRole, .pending)
        XCTAssertEqual(EditorStatusPresentation("Save failed").indicatorRole, .error)

        XCTAssertEqual(CanvasColorPalette.skyPink, "#F2C4D7")
        XCTAssertEqual(CanvasColorPalette.name(for: CanvasColorPalette.skyPink),
                       "Sky Pink")
        XCTAssertEqual(CanvasColorPalette.accessibilityValue(
            for: CanvasColorPalette.skyPink
        ), "F2C4D7")
        XCTAssertTrue(CanvasColorPalette.standard.contains("#F2C4D7"))

        XCTAssertEqual(LibraryTilePolicy.outerWidth, 272)
        XCTAssertEqual(LibraryTilePolicy.outerHeight, 240)
        XCTAssertGreaterThanOrEqual(
            LibraryTilePolicy.outerHeight,
            LibraryTilePolicy.padding * 2
                + LibraryTilePolicy.thumbnailHeight
                + LibraryTilePolicy.labelHeight + 12
        )
    }

    func testCheckWorkIsContextualToPracticeAndStudentInkOnSameBoard() {
        func object(id: String, type: String, role: String? = nil) -> CanvasObject {
            CanvasObject(
                id: id, type: type, color: "#183153", width: 4, opacity: 1,
                points: type == "stroke" ? [WorldPoint(x: 0, y: 0, pressure: 1)] : nil,
                translation: nil, sourceMarkdown: nil, text: type == "text" ? "Problem" : nil,
                x: type == "text" ? 0 : nil, y: type == "text" ? 0 : nil,
                height: type == "text" ? 120 : nil, fontSize: 22, role: role
            )
        }
        let practice = object(id: "practice", type: "text", role: "ai_practice_problem")
        let work = object(id: "work", type: "stroke")

        XCTAssertFalse(CheckWorkVisibilityPolicy.isVisible(
            selected: [(boardID, practice)]
        ))
        XCTAssertTrue(CheckWorkVisibilityPolicy.isVisible(
            selected: [(boardID, practice), (boardID, work)]
        ))
        XCTAssertFalse(CheckWorkVisibilityPolicy.isVisible(
            selected: [(boardID, practice), ("other-board", work)]
        ))
    }

    func testGraphWorkspacePreservesInvalidSourceAndReportsInlineError() {
        let expression = GraphExpression(
            id: "invalid", latex: "f(x)=sin(", type: .explicitFunction
        )
        let graph = GraphObject(
            id: "graph-invalid", owningBoardID: boardID,
            frame: GraphFrame(x: 0, y: 0, width: 640, height: 420),
            expressions: [expression]
        )
        let model = GraphWorkspaceModel(graph: graph)

        XCTAssertEqual(model.expression(id: expression.id)?.latex, "f(x)=sin(")
        XCTAssertEqual(model.feedback(for: expression), GraphRowFeedback(
            kind: .error, message: "Close the open parenthesis."
        ))
    }

    func testNativeMarchingSquaresRendersGeneralImplicitCircle() {
        let expression = GraphExpression(
            id: "implicit-circle", latex: "x²+y²=1", type: .implicitEquation
        )
        let path = GraphFallbackSampler.path(
            for: expression, viewport: GraphViewport(xMin: -2, xMax: 2, yMin: -2, yMax: 2),
            frame: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        XCTAssertFalse(path.isEmpty)
        XCTAssertGreaterThan(path.bounds.width, 150)
        XCTAssertGreaterThan(path.bounds.height, 150)
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
