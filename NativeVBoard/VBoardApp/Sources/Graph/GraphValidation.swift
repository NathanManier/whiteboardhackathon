import Foundation

/// A field-addressable error suitable for both user-safe save failures and
/// detailed DEBUG logging. The messages intentionally describe the native
/// persistence contract rather than exposing Flask implementation details.
struct GraphPersistenceValidationError: Error, Equatable, LocalizedError, Sendable {
    let path: String
    let reason: String

    var errorDescription: String? {
        path.isEmpty ? reason : "\(path): \(reason)"
    }
}

/// Native preflight for the canonical graph record stored in `editor.json`.
///
/// Keep these limits aligned with `app.validate_graph_object` and
/// `study.graph_recognition`. The returned value is server-normalized (for
/// example, LaTeX is trimmed, colors are lowercased, and persisted numbers are
/// rounded to four decimal places). Provider state remains optional and never
/// becomes the canonical graph representation.
enum GraphPersistenceValidator {
    static let maximumWorldCoordinate = 10_000_000.0
    static let maximumExpressions = 8
    static let maximumLatexScalars = 1_000
    static let maximumRestrictions = 16
    static let maximumRestrictionScalars = 500
    static let maximumSourceBoards = 8
    static let maximumSelectedObjectKeys = 400
    static let maximumSelectedObjectKeyScalars = 160
    static let maximumExpressionExtensionBytes = 16 * 1_024
    static let maximumGraphExtensionBytes = 64 * 1_024
    static let maximumProviderStateBytes = 256 * 1_024

    private static let knownExpressionTypes: Set<String> = [
        "explicitFunction", "implicitEquation", "inequality", "verticalLine",
        "horizontalLine", "point", "parametric", "polar", "table", "unknown",
    ]

    private static let expressionReservedFields: Set<String> = [
        "id", "latex", "type", "visible", "display_style", "restrictions",
    ]

    private static let graphReservedFields: Set<String> = [
        "id", "type", "owning_board_id", "owningBoardID", "frame", "expressions",
        "viewport", "settings", "source_selection", "provider_metadata", "created_at",
        "updated_at", "version",
    ]

    /// Validates without requiring callers to retain the normalized value.
    static func validate(_ graph: GraphObject, expectedBoardID: String? = nil) throws {
        _ = try sanitized(graph, expectedBoardID: expectedBoardID)
    }

    /// Validates and returns the exact canonical shape safe to insert into an
    /// editor document or send through the existing autosave/outbox pipeline.
    static func sanitized(_ graph: GraphObject,
                          expectedBoardID: String? = nil) throws -> GraphObject {
        try requireStrokeIdentifier(graph.id, path: "graph.id")
        try requireBoardIdentifier(graph.owningBoardID, path: "graph.owning_board_id")
        if let expectedBoardID {
            try requireBoardIdentifier(expectedBoardID, path: "expected_board_id")
            guard graph.owningBoardID == expectedBoardID else {
                throw failure("graph.owning_board_id", "belongs to a different board")
            }
        }

        let frame = try sanitizedFrame(graph.frame, path: "graph.frame", minimumSize: 32)
        guard (1...maximumExpressions).contains(graph.expressions.count) else {
            throw failure("graph.expressions",
                          "must contain between 1 and \(maximumExpressions) expressions")
        }

        var expressionIDs = Set<String>()
        let expressions = try graph.expressions.enumerated().map { index, expression in
            try sanitizedExpression(expression, index: index, seenIDs: &expressionIDs)
        }
        let viewport = try sanitizedViewport(graph.viewport)
        let settings = try sanitizedSettings(graph.settings)
        let sourceSelection = try graph.sourceSelection.map(sanitizedSourceSelection)
        let providerMetadata = try graph.providerMetadata.map(sanitizedProviderMetadata)
        let createdAt = try sanitizedFinite(graph.createdAt, path: "graph.created_at",
                                            minimum: 0)
        let updatedAt = try sanitizedFinite(graph.updatedAt, path: "graph.updated_at",
                                            minimum: 0)
        guard (1...10_000).contains(graph.version) else {
            throw failure("graph.version", "must be between 1 and 10000")
        }

        let additionalFields = try sanitizedFieldMap(
            graph.additionalFields.filter { !graphReservedFields.contains($0.key) },
            path: "graph.extensions",
            maximumBytes: maximumGraphExtensionBytes
        )

        return GraphObject(
            id: graph.id,
            owningBoardID: graph.owningBoardID,
            frame: frame,
            expressions: expressions,
            viewport: viewport,
            settings: settings,
            sourceSelection: sourceSelection,
            providerMetadata: providerMetadata,
            createdAt: createdAt,
            updatedAt: updatedAt,
            version: graph.version,
            additionalFields: additionalFields
        )
    }

    /// Convenience for validating every canonical graph before an editor save.
    /// The first invalid record fails atomically; no partial result is returned.
    static func sanitized(_ graphs: [GraphObject],
                          expectedBoardID: String? = nil) throws -> [GraphObject] {
        try graphs.map { try sanitized($0, expectedBoardID: expectedBoardID) }
    }

    private static func sanitizedExpression(
        _ expression: GraphExpression,
        index: Int,
        seenIDs: inout Set<String>
    ) throws -> GraphExpression {
        let path = "graph.expressions[\(index)]"
        try requireStrokeIdentifier(expression.id, path: "\(path).id")
        guard seenIDs.insert(expression.id).inserted else {
            throw failure("\(path).id", "is duplicated")
        }

        let type = expression.type.rawValue
        guard knownExpressionTypes.contains(type) || isFutureExpressionType(type) else {
            throw failure("\(path).type", "is invalid")
        }
        let latex = try sanitizedLatex(expression.latex, path: "\(path).latex")

        guard expression.restrictions.count <= maximumRestrictions else {
            throw failure("\(path).restrictions",
                          "must contain at most \(maximumRestrictions) items")
        }
        for (restrictionIndex, restriction) in expression.restrictions.enumerated() {
            let scalarCount = restriction.unicodeScalars.count
            guard (1...maximumRestrictionScalars).contains(scalarCount),
                  !restriction.unicodeScalars.contains(where: { $0.value < 32 }) else {
                throw failure("\(path).restrictions[\(restrictionIndex)]", "is invalid")
            }
        }

        let style = try expression.displayStyle.map {
            try sanitizedDisplayStyle($0, path: "\(path).display_style")
        }
        let additionalFields = try sanitizedFieldMap(
            expression.additionalFields.filter { !expressionReservedFields.contains($0.key) },
            path: "\(path).extensions",
            maximumBytes: maximumExpressionExtensionBytes
        )

        return GraphExpression(
            id: expression.id,
            latex: latex,
            type: GraphExpressionType(rawValue: type),
            visible: expression.visible,
            displayStyle: style,
            restrictions: expression.restrictions,
            additionalFields: additionalFields
        )
    }

    private static func sanitizedLatex(_ value: String, path: String) throws -> String {
        let latex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty, latex.unicodeScalars.count <= maximumLatexScalars else {
            throw failure(path, "must contain between 1 and \(maximumLatexScalars) characters")
        }
        guard !latex.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw failure(path, "contains a control character")
        }

        let unsafePattern = #"(?:<|>|javascript:|\\(?:begin\s*\{document\}|end\s*\{document\}|input|include|write|openout|read|usepackage|href|url|htmlClass|htmlStyle|class|style))"#
        if latex.range(of: unsafePattern,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            throw failure(path, "contains unsupported or unsafe LaTeX")
        }

        var depth = 0
        var escaped = false
        for scalar in latex.unicodeScalars {
            if escaped {
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == "{" {
                depth += 1
            } else if scalar == "}" {
                depth -= 1
                if depth < 0 { break }
            }
        }
        guard depth == 0 else {
            throw failure(path, "contains unbalanced braces")
        }
        return latex
    }

    private static func sanitizedDisplayStyle(
        _ style: GraphExpressionDisplayStyle,
        path: String
    ) throws -> GraphExpressionDisplayStyle {
        var color: String?
        if let rawColor = style.color {
            guard rawColor.unicodeScalars.count == 7,
                  rawColor.first == "#",
                  rawColor.dropFirst().unicodeScalars.allSatisfy(isASCIIHexDigit) else {
                throw failure("\(path).color", "must be a six-digit hexadecimal color")
            }
            color = rawColor.lowercased()
        }

        let lineWidth = try style.lineWidth.map {
            try sanitizedFinite($0, path: "\(path).line_width", minimum: 0.1, maximum: 40)
        }
        let opacity = try style.opacity.map {
            try sanitizedFinite($0, path: "\(path).opacity", minimum: 0, maximum: 1)
        }
        if let lineStyle = style.lineStyle,
           !isStyleIdentifier(lineStyle) {
            throw failure("\(path).line_style", "is invalid")
        }
        if let pointStyle = style.pointStyle,
           !isStyleIdentifier(pointStyle) {
            throw failure("\(path).point_style", "is invalid")
        }
        return GraphExpressionDisplayStyle(
            color: color,
            lineWidth: lineWidth,
            lineStyle: style.lineStyle,
            opacity: opacity,
            pointStyle: style.pointStyle
        )
    }

    private static func sanitizedViewport(_ viewport: GraphViewport) throws -> GraphViewport {
        let xMin = try sanitizedFinite(viewport.xMin, path: "graph.viewport.x_min",
                                       minimum: -maximumWorldCoordinate,
                                       maximum: maximumWorldCoordinate)
        let xMax = try sanitizedFinite(viewport.xMax, path: "graph.viewport.x_max",
                                       minimum: -maximumWorldCoordinate,
                                       maximum: maximumWorldCoordinate)
        let yMin = try sanitizedFinite(viewport.yMin, path: "graph.viewport.y_min",
                                       minimum: -maximumWorldCoordinate,
                                       maximum: maximumWorldCoordinate)
        let yMax = try sanitizedFinite(viewport.yMax, path: "graph.viewport.y_max",
                                       minimum: -maximumWorldCoordinate,
                                       maximum: maximumWorldCoordinate)
        guard xMin < xMax, yMin < yMax else {
            throw failure("graph.viewport", "bounds are invalid")
        }
        return GraphViewport(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
    }

    private static func sanitizedSettings(_ settings: GraphSettings) throws -> GraphSettings {
        let angleMode = settings.angleMode ?? "radians"
        guard angleMode == "radians" || angleMode == "degrees" else {
            throw failure("graph.settings.angle_mode", "must be radians or degrees")
        }
        return GraphSettings(
            showXAxis: settings.showXAxis,
            showYAxis: settings.showYAxis,
            showGrid: settings.showGrid,
            showExpressionsPanel: settings.showExpressionsPanel,
            lockViewport: settings.lockViewport,
            angleMode: angleMode
        )
    }

    private static func sanitizedSourceSelection(
        _ source: GraphSourceSelection
    ) throws -> GraphSourceSelection {
        guard source.sourceBoardIDs.count <= maximumSourceBoards else {
            throw failure("graph.source_selection.source_board_ids",
                          "must contain at most \(maximumSourceBoards) items")
        }
        var boardIDs = Set<String>()
        for boardID in source.sourceBoardIDs {
            try requireBoardIdentifier(boardID,
                                       path: "graph.source_selection.source_board_ids")
            guard boardIDs.insert(boardID).inserted else {
                throw failure("graph.source_selection.source_board_ids", "contains a duplicate")
            }
        }

        guard source.selectedObjectKeys.count <= maximumSelectedObjectKeys else {
            throw failure("graph.source_selection.selected_object_keys",
                          "must contain at most \(maximumSelectedObjectKeys) items")
        }
        var objectKeys = Set<String>()
        for (index, key) in source.selectedObjectKeys.enumerated() {
            let scalars = key.unicodeScalars
            guard (1...maximumSelectedObjectKeyScalars).contains(scalars.count),
                  scalars.allSatisfy({ $0.value >= 33 && $0.value != 127 }) else {
                throw failure("graph.source_selection.selected_object_keys[\(index)]",
                              "is invalid")
            }
            guard objectKeys.insert(key).inserted else {
                throw failure("graph.source_selection.selected_object_keys", "contains a duplicate")
            }
        }

        if let interactionID = source.interactionID {
            try requireStrokeIdentifier(interactionID,
                                        path: "graph.source_selection.interaction_id")
        }
        if let requestID = source.originalRecognitionRequestID {
            let candidate = requestID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard candidate.unicodeScalars.count == 16,
                  candidate.unicodeScalars.allSatisfy(isASCIILowerHexDigit) else {
                throw failure("graph.source_selection.original_recognition_request_id",
                              "is invalid")
            }
        }
        let originalBBox = try source.originalSelectionBBox.map {
            try sanitizedFrame($0, path: "graph.source_selection.original_selection_bbox",
                               minimumSize: 1)
        }

        return GraphSourceSelection(
            interactionID: source.interactionID,
            sourceBoardIDs: source.sourceBoardIDs,
            selectedObjectKeys: source.selectedObjectKeys,
            originalRecognitionRequestID: source.originalRecognitionRequestID,
            originalSelectionBBox: originalBBox
        )
    }

    private static func sanitizedProviderMetadata(
        _ provider: GraphProviderMetadata
    ) throws -> GraphProviderMetadata {
        if let preference = provider.preference,
           !isProviderIdentifier(preference) {
            throw failure("graph.provider_metadata.preference", "is invalid")
        }
        let state = try provider.state.map {
            try sanitizedJSON($0, path: "graph.provider_metadata.state",
                              maximumBytes: maximumProviderStateBytes)
        }
        if let hash = provider.semanticContentHash {
            guard hash.unicodeScalars.count == 64,
                  hash.unicodeScalars.allSatisfy(isASCIILowerHexDigit) else {
                throw failure("graph.provider_metadata.semantic_content_hash", "is invalid")
            }
        }
        if let renderVersion = provider.renderVersion,
           !(1...10_000).contains(renderVersion) {
            throw failure("graph.provider_metadata.render_version",
                          "must be between 1 and 10000")
        }
        return GraphProviderMetadata(
            preference: provider.preference,
            state: state,
            semanticContentHash: provider.semanticContentHash,
            renderVersion: provider.renderVersion
        )
    }

    private static func sanitizedFrame(_ frame: GraphFrame, path: String,
                                       minimumSize: Double) throws -> GraphFrame {
        GraphFrame(
            x: try sanitizedFinite(frame.x, path: "\(path).x",
                                   minimum: -maximumWorldCoordinate,
                                   maximum: maximumWorldCoordinate),
            y: try sanitizedFinite(frame.y, path: "\(path).y",
                                   minimum: -maximumWorldCoordinate,
                                   maximum: maximumWorldCoordinate),
            width: try sanitizedFinite(frame.width, path: "\(path).width",
                                       minimum: minimumSize,
                                       maximum: maximumWorldCoordinate),
            height: try sanitizedFinite(frame.height, path: "\(path).height",
                                        minimum: minimumSize,
                                        maximum: maximumWorldCoordinate)
        )
    }

    private static func sanitizedFieldMap(_ fields: [String: JSONValue], path: String,
                                          maximumBytes: Int) throws -> [String: JSONValue] {
        let value = try sanitizedJSON(.object(fields), path: path, maximumBytes: maximumBytes)
        guard case .object(let result) = value else { return [:] }
        return result
    }

    private static func sanitizedJSON(_ value: JSONValue, path: String,
                                      maximumBytes: Int) throws -> JSONValue {
        let result = try validatedJSON(value, path: path, depth: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data
        do {
            encoded = try encoder.encode(result)
        } catch {
            throw failure(path, "could not be encoded safely")
        }
        guard encoded.count <= maximumBytes else {
            throw failure(path, "is too large")
        }
        return result
    }

    private static func validatedJSON(_ value: JSONValue, path: String,
                                      depth: Int) throws -> JSONValue {
        guard depth <= 5 else {
            throw failure(path, "is nested too deeply")
        }
        switch value {
        case .null, .bool, .integer:
            return value
        case .number(let number):
            guard number.isFinite else {
                throw failure(path, "contains a non-finite number")
            }
            return value
        case .string(let string):
            guard string.unicodeScalars.count <= 8_000,
                  !string.unicodeScalars.contains(where: {
                      $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13
                  }) else {
                throw failure(path, "contains an invalid string")
            }
            return value
        case .array(let values):
            guard values.count <= 64 else {
                throw failure(path, "contains too many items")
            }
            return .array(try values.enumerated().map { index, item in
                try validatedJSON(item, path: "\(path)[\(index)]", depth: depth + 1)
            })
        case .object(let fields):
            guard fields.count <= 64 else {
                throw failure(path, "contains too many fields")
            }
            var result: [String: JSONValue] = [:]
            for (key, item) in fields {
                guard isExtensionFieldName(key) else {
                    throw failure(path, "contains an invalid field name")
                }
                result[key] = try validatedJSON(item, path: "\(path).\(key)",
                                                 depth: depth + 1)
            }
            return .object(result)
        }
    }

    private static func sanitizedFinite(_ value: Double, path: String,
                                        minimum: Double? = nil,
                                        maximum: Double? = nil) throws -> Double {
        guard value.isFinite else {
            throw failure(path, "must be finite")
        }
        if let minimum, value < minimum {
            throw failure(path, "is too small")
        }
        if let maximum, value > maximum {
            throw failure(path, "is too large")
        }
        guard abs(value) <= Double.greatestFiniteMagnitude / 10_000 else { return value }
        return (value * 10_000).rounded(.toNearestOrEven) / 10_000
    }

    private static func requireStrokeIdentifier(_ value: String, path: String) throws {
        guard (1...64).contains(value.unicodeScalars.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  isASCIIAlphaNumeric(scalar) || scalar == "_" || scalar == "." || scalar == "-"
              }) else {
            throw failure(path, "is invalid")
        }
    }

    private static func requireBoardIdentifier(_ value: String, path: String) throws {
        guard value.unicodeScalars.count == 32,
              value.unicodeScalars.allSatisfy(isASCIILowerHexDigit) else {
            throw failure(path, "is invalid")
        }
    }

    private static func isFutureExpressionType(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...40).contains(scalars.count), let first = scalars.first,
              isASCIIAlpha(first) else { return false }
        return scalars.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func isStyleIdentifier(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first,
              isASCIIAlpha(first) else { return false }
        return scalars.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func isProviderIdentifier(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first,
              isASCIIAlpha(first) else { return false }
        return scalars.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == "_" || $0 == "." || $0 == "-"
        }
    }

    private static func isExtensionFieldName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...64).contains(scalars.count), let first = scalars.first,
              isASCIIAlpha(first) || first == "_" else { return false }
        return scalars.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == "_" || $0 == "." || $0 == "-"
        }
    }

    private static func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        isASCIIAlpha(scalar) || (48...57).contains(scalar.value)
    }

    private static func isASCIIHexDigit(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }

    private static func isASCIILowerHexDigit(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }

    private static func failure(_ path: String,
                                _ reason: String) -> GraphPersistenceValidationError {
        GraphPersistenceValidationError(path: path, reason: reason)
    }
}
