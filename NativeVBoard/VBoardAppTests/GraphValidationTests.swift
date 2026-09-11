import XCTest
@testable import VBoardApp

final class GraphPersistenceValidatorTests: XCTestCase {
    private let boardID = "603f5213ab0a249716833214c5ab88da"

    private func expression(
        id: String = "expression-1",
        latex: String = "y=x^2-4",
        type: GraphExpressionType = .explicitFunction,
        style: GraphExpressionDisplayStyle? = nil,
        restrictions: [String] = [],
        additionalFields: [String: JSONValue] = [:]
    ) -> GraphExpression {
        GraphExpression(id: id, latex: latex, type: type, displayStyle: style,
                        restrictions: restrictions, additionalFields: additionalFields)
    }

    private func graph(
        id: String = "graph-one",
        owner: String? = nil,
        frame: GraphFrame = GraphFrame(x: -240, y: 900, width: 640, height: 420),
        expressions: [GraphExpression]? = nil,
        viewport: GraphViewport = .conventional,
        settings: GraphSettings = GraphSettings(),
        source: GraphSourceSelection? = nil,
        provider: GraphProviderMetadata? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) -> GraphObject {
        GraphObject(
            id: id,
            owningBoardID: owner ?? boardID,
            frame: frame,
            expressions: expressions ?? [expression()],
            viewport: viewport,
            settings: settings,
            sourceSelection: source,
            providerMetadata: provider,
            createdAt: 10.123456,
            updatedAt: 20.654321,
            version: 1,
            additionalFields: additionalFields
        )
    }

    private func validationPath(
        _ expectedPath: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? GraphPersistenceValidationError)?.path,
                           expectedPath, file: file, line: line)
        }
    }

    func testValidGraphIsNormalizedLikeFlaskBeforePersistence() throws {
        let source = GraphSourceSelection(
            interactionID: "interaction-1",
            sourceBoardIDs: [boardID],
            selectedObjectKeys: ["professor:path-7"],
            originalRecognitionRequestID: " ABCDEF0123456789 ",
            originalSelectionBBox: GraphFrame(x: -2.55555, y: 3.44444,
                                               width: 1.23456, height: 9.87654)
        )
        let provider = GraphProviderMetadata(
            preference: "desmos.v1",
            state: .object(["opaque": .array([.integer(7), .bool(true)])]),
            semanticContentHash: String(repeating: "a", count: 64),
            renderVersion: 3
        )
        let original = graph(
            frame: GraphFrame(x: -240.123456, y: 900.987654,
                              width: 640.123456, height: 420.987654),
            expressions: [expression(
                latex: "  y=x^2-4  ",
                style: GraphExpressionDisplayStyle(
                    color: "#2D70B3", lineWidth: 3.123456,
                    lineStyle: "solid", opacity: 0.876543, pointStyle: "point"
                ),
                restrictions: ["x>0"]
            )],
            viewport: GraphViewport(xMin: -10.123456, xMax: 10.987654,
                                    yMin: -8.111119, yMax: 12.222229),
            settings: GraphSettings(showXAxis: true, showYAxis: false,
                                    showGrid: true, showExpressionsPanel: false,
                                    lockViewport: true, angleMode: nil),
            source: source,
            provider: provider,
            additionalFields: [
                "future_graph_option": .object(["mode": .string("safe")]),
                "owningBoardID": .string("must-not-override-canonical-owner"),
            ]
        )

        let clean = try GraphPersistenceValidator.sanitized(
            original, expectedBoardID: boardID
        )

        XCTAssertEqual(clean.frame, GraphFrame(x: -240.1235, y: 900.9877,
                                               width: 640.1235, height: 420.9877))
        XCTAssertEqual(clean.expressions[0].latex, "y=x^2-4")
        XCTAssertEqual(clean.expressions[0].displayStyle?.color, "#2d70b3")
        XCTAssertEqual(clean.expressions[0].displayStyle?.lineWidth, 3.1235)
        XCTAssertEqual(clean.expressions[0].displayStyle?.opacity, 0.8765)
        XCTAssertEqual(clean.viewport,
                       GraphViewport(xMin: -10.1235, xMax: 10.9877,
                                     yMin: -8.1111, yMax: 12.2222))
        XCTAssertEqual(clean.settings.angleMode, "radians")
        XCTAssertEqual(clean.createdAt, 10.1235)
        XCTAssertEqual(clean.updatedAt, 20.6543)
        XCTAssertEqual(clean.sourceSelection?.originalSelectionBBox,
                       GraphFrame(x: -2.5556, y: 3.4444, width: 1.2346, height: 9.8765))
        XCTAssertEqual(clean.sourceSelection?.originalRecognitionRequestID,
                       " ABCDEF0123456789 ", "Flask validates the normalized ID but preserves it")
        XCTAssertEqual(clean.additionalFields["future_graph_option"],
                       .object(["mode": .string("safe")]))
        XCTAssertNil(clean.additionalFields["owningBoardID"])
    }

    func testGraphAndBoardIdentifiersAndOwnershipMatchServerContract() {
        validationPath("graph.id") {
            try GraphPersistenceValidator.validate(graph(id: "graph id"))
        }
        validationPath("graph.owning_board_id") {
            try GraphPersistenceValidator.validate(graph(owner: String(repeating: "A", count: 32)))
        }
        validationPath("graph.owning_board_id") {
            try GraphPersistenceValidator.validate(
                graph(owner: String(repeating: "b", count: 32)), expectedBoardID: boardID
            )
        }
    }

    func testExpressionCountIDsAndFutureTypesMatchServerLimits() throws {
        validationPath("graph.expressions") {
            try GraphPersistenceValidator.validate(graph(expressions: []))
        }
        validationPath("graph.expressions") {
            let expressions = (0..<9).map { expression(id: "expression-\($0)") }
            try GraphPersistenceValidator.validate(graph(expressions: expressions))
        }
        validationPath("graph.expressions[1].id") {
            try GraphPersistenceValidator.validate(
                graph(expressions: [expression(), expression()])
            )
        }
        validationPath("graph.expressions[0].type") {
            try GraphPersistenceValidator.validate(
                graph(expressions: [expression(type: GraphExpressionType(rawValue: "9bad"))])
            )
        }

        let future = expression(type: GraphExpressionType(rawValue: "futureCurveKind"))
        XCTAssertNoThrow(try GraphPersistenceValidator.validate(graph(expressions: [future])))
        let eight = (0..<8).map { expression(id: "expression-\($0)") }
        XCTAssertEqual(try GraphPersistenceValidator.sanitized(graph(expressions: eight))
            .expressions.count, 8)
    }

    func testLatexUsesExactLengthSafetyAndBalancedBraceRules() throws {
        XCTAssertNoThrow(try GraphPersistenceValidator.validate(
            graph(expressions: [expression(latex: String(repeating: "x", count: 1_000))])
        ))
        validationPath("graph.expressions[0].latex") {
            try GraphPersistenceValidator.validate(
                graph(expressions: [expression(latex: String(repeating: "x", count: 1_001))])
            )
        }
        for latex in [#"y=\input{secret}"#, #"y=\href{evil}"#, "y=<x", "y=x\n+1",
                      #"y=\frac{x}{2"#] {
            validationPath("graph.expressions[0].latex") {
                try GraphPersistenceValidator.validate(
                    graph(expressions: [expression(latex: latex)])
                )
            }
        }
        XCTAssertNoThrow(try GraphPersistenceValidator.validate(
            graph(expressions: [expression(latex: #"y=\{x\}"#)])
        ))
    }

    func testRestrictionsMatchCountLengthAndControlCharacterLimits() {
        validationPath("graph.expressions[0].restrictions") {
            try GraphPersistenceValidator.validate(graph(expressions: [
                expression(restrictions: Array(repeating: "x>0", count: 17)),
            ]))
        }
        for invalid in ["", String(repeating: "x", count: 501), "x>0\n"] {
            validationPath("graph.expressions[0].restrictions[0]") {
                try GraphPersistenceValidator.validate(
                    graph(expressions: [expression(restrictions: [invalid])])
                )
            }
        }
        XCTAssertNoThrow(try GraphPersistenceValidator.validate(graph(expressions: [
            expression(restrictions: Array(repeating: String(repeating: "x", count: 500),
                                           count: 16)),
        ])))
    }

    func testFrameAndViewportRejectNonFiniteOutOfRangeAndCollapsedBounds() {
        validationPath("graph.frame.x") {
            try GraphPersistenceValidator.validate(
                graph(frame: GraphFrame(x: .nan, y: 0, width: 640, height: 420))
            )
        }
        validationPath("graph.frame.width") {
            try GraphPersistenceValidator.validate(
                graph(frame: GraphFrame(x: 0, y: 0, width: 31.9999, height: 420))
            )
        }
        validationPath("graph.viewport.x_max") {
            try GraphPersistenceValidator.validate(
                graph(viewport: GraphViewport(xMin: -10, xMax: 10_000_001,
                                              yMin: -10, yMax: 10))
            )
        }
        validationPath("graph.viewport") {
            try GraphPersistenceValidator.validate(
                graph(viewport: GraphViewport(xMin: 0.000041, xMax: 0.000049,
                                              yMin: -10, yMax: 10))
            )
        }
    }

    func testDisplayStyleAndSettingsAreValidatedAndNormalized() throws {
        validationPath("graph.expressions[0].display_style.color") {
            try GraphPersistenceValidator.validate(graph(expressions: [
                expression(style: GraphExpressionDisplayStyle(color: "red")),
            ]))
        }
        validationPath("graph.expressions[0].display_style.line_width") {
            try GraphPersistenceValidator.validate(graph(expressions: [
                expression(style: GraphExpressionDisplayStyle(lineWidth: 40.1)),
            ]))
        }
        validationPath("graph.expressions[0].display_style.opacity") {
            try GraphPersistenceValidator.validate(graph(expressions: [
                expression(style: GraphExpressionDisplayStyle(opacity: .infinity)),
            ]))
        }
        validationPath("graph.settings.angle_mode") {
            try GraphPersistenceValidator.validate(
                graph(settings: GraphSettings(angleMode: "gradians"))
            )
        }

        let degrees = try GraphPersistenceValidator.sanitized(
            graph(settings: GraphSettings(angleMode: "degrees"))
        )
        XCTAssertEqual(degrees.settings.angleMode, "degrees")
    }

    func testProvenanceAndProviderMetadataMatchPersistenceBounds() {
        validationPath("graph.source_selection.source_board_ids") {
            try GraphPersistenceValidator.validate(graph(source: GraphSourceSelection(
                sourceBoardIDs: Array(repeating: boardID, count: 2)
            )))
        }
        validationPath("graph.source_selection.selected_object_keys[0]") {
            try GraphPersistenceValidator.validate(graph(source: GraphSourceSelection(
                sourceBoardIDs: [boardID], selectedObjectKeys: ["has a space"]
            )))
        }
        validationPath("graph.source_selection.original_recognition_request_id") {
            try GraphPersistenceValidator.validate(graph(source: GraphSourceSelection(
                sourceBoardIDs: [boardID], originalRecognitionRequestID: "request-one"
            )))
        }
        validationPath("graph.provider_metadata.preference") {
            try GraphPersistenceValidator.validate(graph(provider: GraphProviderMetadata(
                preference: "9provider"
            )))
        }
        validationPath("graph.provider_metadata.semantic_content_hash") {
            try GraphPersistenceValidator.validate(graph(provider: GraphProviderMetadata(
                semanticContentHash: String(repeating: "A", count: 64)
            )))
        }
        validationPath("graph.provider_metadata.render_version") {
            try GraphPersistenceValidator.validate(graph(provider: GraphProviderMetadata(
                renderVersion: 10_001
            )))
        }
    }

    func testOpaqueJSONRejectsUnsafeDepthNumbersNamesAndByteSize() {
        validationPath("graph.expressions[0].extensions") {
            try GraphPersistenceValidator.validate(graph(expressions: [expression(
                additionalFields: ["bad field": .string("value")]
            )]))
        }
        validationPath("graph.provider_metadata.state.value") {
            try GraphPersistenceValidator.validate(graph(provider: GraphProviderMetadata(
                state: .object(["value": .number(.nan)])
            )))
        }

        var deeplyNested: JSONValue = .string("leaf")
        for _ in 0..<6 { deeplyNested = .object(["nested": deeplyNested]) }
        validationPath("graph.extensions.nested.nested.nested.nested.nested.nested") {
            try GraphPersistenceValidator.validate(graph(additionalFields: [
                "nested": deeplyNested,
            ]))
        }

        let oversized = Dictionary(uniqueKeysWithValues: (0..<9).map {
            ("field_\($0)", JSONValue.string(String(repeating: "x", count: 7_900)))
        })
        validationPath("graph.extensions") {
            try GraphPersistenceValidator.validate(graph(additionalFields: oversized))
        }
    }

    func testArrayValidationIsAtomicAndPreservesOrder() throws {
        let first = graph(id: "graph-one")
        let second = graph(id: "graph-two")
        XCTAssertEqual(
            try GraphPersistenceValidator.sanitized([first, second], expectedBoardID: boardID)
                .map(\.id),
            ["graph-one", "graph-two"]
        )

        XCTAssertThrowsError(try GraphPersistenceValidator.sanitized(
            [first, graph(id: "invalid id")], expectedBoardID: boardID
        ))
    }
}
