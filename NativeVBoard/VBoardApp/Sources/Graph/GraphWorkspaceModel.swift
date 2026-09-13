import Foundation
import SwiftUI

enum GraphMathKeyboardCategory: String, CaseIterable, Identifiable {
    case basic = "123"
    case functions = "f(x)"
    case calculus = "Calculus"

    var id: String { rawValue }
}

enum GraphCalculusOperation: String, CaseIterable, Identifiable {
    case derivative = "Derivative"
    case integral = "Integral"
    case evaluate = "Evaluate"
    case roots = "Roots"

    var id: String { rawValue }
}

struct GraphCalculusDraft: Equatable {
    var operation: GraphCalculusOperation
    var functionSource: String
    var evaluationPoint = ""
    var lowerBound = "0"
    var upperBound = "2"
}

enum GraphRowFeedbackKind: Equatable {
    case value
    case derivative
    case integral
    case error
}

struct GraphRowFeedback: Equatable {
    let kind: GraphRowFeedbackKind
    let message: String

    var isError: Bool { kind == .error }
}

struct GraphParameterSlider: Equatable {
    let name: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
}

enum GraphMathKeyAction: Equatable {
    case insert(text: String, cursorBacktrack: Int = 0)
    case backspace
    case clear
}

struct GraphMathInsertionResult: Equatable {
    let source: String
    let selection: NSRange
}

/// Pure cursor editing used by both the UIKit source field and unit tests.
/// Template keys carry a cursor backtrack so `sin()` and `integral(,,)` put
/// the insertion point in the first meaningful slot instead of at the end.
enum GraphMathInsertionPlan {
    static func apply(_ action: GraphMathKeyAction, to source: String,
                      selection proposedSelection: NSRange) -> GraphMathInsertionResult {
        let sourceLength = source.utf16.count
        let selection = NSRange(
            location: min(max(0, proposedSelection.location), sourceLength),
            length: min(max(0, proposedSelection.length),
                        max(0, sourceLength - proposedSelection.location))
        )
        guard let range = Range(selection, in: source) else {
            return GraphMathInsertionResult(
                source: source, selection: NSRange(location: sourceLength, length: 0)
            )
        }
        switch action {
        case .clear:
            return GraphMathInsertionResult(source: "", selection: NSRange(location: 0, length: 0))
        case .backspace:
            if !range.isEmpty {
                var result = source
                result.removeSubrange(range)
                return GraphMathInsertionResult(
                    source: result, selection: NSRange(location: selection.location, length: 0)
                )
            }
            guard range.lowerBound > source.startIndex else {
                return GraphMathInsertionResult(source: source, selection: selection)
            }
            let previous = source.index(before: range.lowerBound)
            var result = source
            result.removeSubrange(previous..<range.lowerBound)
            return GraphMathInsertionResult(
                source: result,
                selection: NSRange(previous..<previous, in: result)
            )
        case .insert(let text, let cursorBacktrack):
            var result = source
            result.replaceSubrange(range, with: text)
            let insertedEnd = selection.location + text.utf16.count
            let cursor = max(selection.location, insertedEnd - max(0, cursorBacktrack))
            return GraphMathInsertionResult(
                source: result, selection: NSRange(location: cursor, length: 0)
            )
        }
    }
}

enum GraphViewportNavigation {
    static let zoomInFactor = 0.8
    static let zoomOutFactor = 1 / zoomInFactor

    static func zoomed(_ source: GraphViewport, by factor: Double,
                       anchor: CGPoint? = nil, size: CGSize? = nil) -> GraphViewport {
        let safe = min(4, max(0.25, factor))
        let oldWidth = source.xMax - source.xMin
        let oldHeight = source.yMax - source.yMin
        let xFraction: Double
        let yFraction: Double
        if let anchor, let size {
            xFraction = min(1, max(0, Double(anchor.x / max(size.width, 1))))
            yFraction = min(1, max(0, Double(anchor.y / max(size.height, 1))))
        } else {
            xFraction = 0.5
            yFraction = 0.5
        }
        let anchorX = source.xMin + oldWidth * xFraction
        let anchorY = source.yMax - oldHeight * yFraction
        let newWidth = min(1_000_000, max(0.001, oldWidth * safe))
        let newHeight = min(1_000_000, max(0.001, oldHeight * safe))
        return source.replacingBounds(with: GraphViewport(
            xMin: anchorX - newWidth * xFraction,
            xMax: anchorX + newWidth * (1 - xFraction),
            yMin: anchorY - newHeight * (1 - yFraction),
            yMax: anchorY + newHeight * yFraction
        ))
    }

    static func panned(_ source: GraphViewport, by translation: CGSize,
                       size: CGSize) -> GraphViewport {
        let xRange = source.xMax - source.xMin
        let yRange = source.yMax - source.yMin
        let dx = -Double(translation.width / max(size.width, 1)) * xRange
        let dy = Double(translation.height / max(size.height, 1)) * yRange
        return source.replacingBounds(with: GraphViewport(
            xMin: source.xMin + dx, xMax: source.xMax + dx,
            yMin: source.yMin + dy, yMax: source.yMax + dy
        ))
    }
}

@MainActor
final class GraphWorkspaceModel: ObservableObject {
    typealias ExpressionMutationSink = (GraphObject) -> Void

    @Published private(set) var workingGraph: GraphObject
    @Published var selectedExpressionID: String?
    @Published var editingExpressionID: String?
    @Published var keyboardCategory: GraphMathKeyboardCategory = .basic
    @Published var calculusDraft: GraphCalculusDraft?

    private let onExpressionMutation: ExpressionMutationSink

    init(graph: GraphObject,
         onExpressionMutation: @escaping ExpressionMutationSink = { _ in }) {
        workingGraph = graph
        selectedExpressionID = graph.expressions.first?.id
        editingExpressionID = nil
        self.onExpressionMutation = onExpressionMutation
    }

    var expressions: [GraphExpression] { workingGraph.expressions }
    var viewport: GraphViewport { workingGraph.viewport }
    var isEditing: Bool { editingExpressionID != nil }

    func expression(id: String) -> GraphExpression? {
        expressions.first(where: { $0.id == id })
    }

    func beginEditing(_ id: String) {
        guard expression(id: id) != nil else { return }
        selectedExpressionID = id
        editingExpressionID = id
    }

    func finishEditing() { editingExpressionID = nil }

    func updateSource(id: String, source: String) {
        mutateExpression(id: id) { expression in
            GraphExpression(
                id: expression.id, latex: source,
                type: GraphExpressionInference.type(for: source),
                visible: expression.visible,
                displayStyle: expression.displayStyle,
                restrictions: expression.restrictions,
                additionalFields: expression.additionalFields
            )
        }
    }

    func toggleVisibility(id: String) {
        mutateExpression(id: id) { expression in
            GraphExpression(
                id: expression.id, latex: expression.latex, type: expression.type,
                visible: !expression.visible, displayStyle: expression.displayStyle,
                restrictions: expression.restrictions,
                additionalFields: expression.additionalFields
            )
        }
    }

    func setColor(_ hex: String, id: String) {
        mutateExpression(id: id) { expression in
            let old = expression.displayStyle
            let style = GraphExpressionDisplayStyle(
                color: hex, lineWidth: old?.lineWidth, lineStyle: old?.lineStyle,
                opacity: old?.opacity, pointStyle: old?.pointStyle,
                additionalFields: old?.additionalFields ?? [:]
            )
            return GraphExpression(
                id: expression.id, latex: expression.latex, type: expression.type,
                visible: expression.visible, displayStyle: style,
                restrictions: expression.restrictions,
                additionalFields: expression.additionalFields
            )
        }
    }

    @discardableResult
    func addExpression(source: String = "y=x") -> String? {
        guard expressions.count < GraphRecognitionController.maximumExpressions else {
            return nil
        }
        let expression = GraphExpression(
            id: "native-\(UUID().uuidString.lowercased())", latex: source,
            type: GraphExpressionInference.type(for: source)
        )
        var next = expressions
        next.append(expression)
        commitExpressions(next)
        beginEditing(expression.id)
        return expression.id
    }

    @discardableResult
    func duplicateExpression(id: String) -> String? {
        guard expressions.count < GraphRecognitionController.maximumExpressions,
              let source = expression(id: id) else { return nil }
        let duplicate = GraphExpression(
            id: "native-\(UUID().uuidString.lowercased())", latex: source.latex,
            type: source.type, visible: source.visible,
            displayStyle: source.displayStyle, restrictions: source.restrictions,
            additionalFields: source.additionalFields
        )
        var next = expressions
        if let index = next.firstIndex(where: { $0.id == id }) {
            next.insert(duplicate, at: index + 1)
        } else {
            next.append(duplicate)
        }
        commitExpressions(next)
        selectedExpressionID = duplicate.id
        return duplicate.id
    }

    func deleteExpression(id: String) {
        guard expressions.contains(where: { $0.id == id }) else { return }
        let next = expressions.filter { $0.id != id }
        commitExpressions(next)
        if selectedExpressionID == id { selectedExpressionID = next.first?.id }
        if editingExpressionID == id { editingExpressionID = nil }
    }

    func updateViewport(_ viewport: GraphViewport) {
        guard viewport.isValid, workingGraph.viewport != viewport else { return }
        workingGraph = workingGraph.replacing(viewport: viewport)
    }

    func resetViewport() { updateViewport(.conventional) }

    func slider(for expression: GraphExpression) -> GraphParameterSlider? {
        guard let definition = GraphMathEnvironment.scalarDefinition(in: expression.latex) else {
            return nil
        }
        let environment = mathEnvironment
        guard let value = environment.variables[definition.name] else { return nil }
        let suppliedMinimum = number(expression.additionalFields["slider_min"]) ?? -10
        let suppliedMaximum = number(expression.additionalFields["slider_max"]) ?? 10
        let minimum: Double
        let maximum: Double
        if suppliedMinimum < suppliedMaximum {
            minimum = suppliedMinimum
            maximum = suppliedMaximum
        } else if suppliedMaximum < suppliedMinimum {
            minimum = suppliedMaximum
            maximum = suppliedMinimum
        } else {
            minimum = suppliedMinimum - 1
            maximum = suppliedMaximum + 1
        }
        let suppliedStep = number(expression.additionalFields["slider_step"]) ?? 0.1
        return GraphParameterSlider(
            name: definition.name, value: value,
            minimum: minimum, maximum: maximum,
            step: max(0.000_001, suppliedStep)
        )
    }

    func updateSlider(id: String, value: Double) {
        guard let expression = expression(id: id),
              let slider = slider(for: expression) else { return }
        let clamped = min(slider.maximum, max(slider.minimum, value))
        updateSource(id: id, source: "\(slider.name)=\(Self.format(clamped))")
    }

    @discardableResult
    func addParameter(named name: String, value: Double = 0) -> String? {
        guard GraphMathEnvironment.scalarDefinition(in: "\(name)=1")?.name == name,
              mathEnvironment.variables[name] == nil else { return nil }
        guard expressions.count < GraphRecognitionController.maximumExpressions else {
            return nil
        }
        let expression = GraphExpression(
            id: "native-\(UUID().uuidString.lowercased())",
            latex: "\(name)=\(Self.format(value))",
            type: .unknown,
            additionalFields: [
                "slider_min": .number(-10),
                "slider_max": .number(10),
                "slider_step": .number(0.1)
            ]
        )
        var next = expressions
        next.append(expression)
        commitExpressions(next)
        selectedExpressionID = expression.id
        return expression.id
    }

    func beginCalculus(_ operation: GraphCalculusOperation) {
        guard let source = calculusOperand else { return }
        if operation == .evaluate {
            _ = addExpression(source: source)
            return
        }
        if operation == .roots {
            _ = addExpression(source: "\(source)=0")
            return
        }
        calculusDraft = GraphCalculusDraft(
            operation: operation,
            functionSource: source,
            evaluationPoint: operation == .derivative ? "" : "",
            lowerBound: "0", upperBound: "2"
        )
    }

    /// Enters the visible guided-calculus workflow from a read-mode row.
    /// The semantic fields live in the Calculus keyboard tray, so the row,
    /// keyboard category, and operation draft must transition together.
    func beginGuidedCalculus(_ operation: GraphCalculusOperation,
                             from expressionID: String) {
        guard expression(id: expressionID) != nil else { return }
        beginEditing(expressionID)
        keyboardCategory = .calculus
        beginCalculus(operation)
    }

    func cancelCalculus() { calculusDraft = nil }

    @discardableResult
    func commitCalculusDraft() -> String? {
        guard let draft = calculusDraft else { return nil }
        let source: String
        switch draft.operation {
        case .derivative:
            if let definition = GraphMathEnvironment.functionDefinition(
                in: expression(id: selectedExpressionID ?? "")?.latex ?? ""
            ) {
                let point = draft.evaluationPoint.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                source = point.isEmpty
                    ? "d/dx(\(definition.name)(x))"
                    : "\(definition.name)'(\(point))"
            } else {
                source = "d/dx(\(draft.functionSource))"
            }
        case .integral:
            let lower = draft.lowerBound.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = draft.upperBound.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lower.isEmpty, !upper.isEmpty else { return nil }
            source = "integral(\(draft.functionSource),\(lower),\(upper))"
        case .evaluate, .roots:
            return nil
        }
        calculusDraft = nil
        return addExpression(source: source)
    }

    var calculusOperand: String? {
        guard let id = selectedExpressionID, let expression = expression(id: id) else {
            return nil
        }
        if let definition = GraphMathEnvironment.functionDefinition(in: expression.latex) {
            return "\(definition.name)(x)"
        }
        if let right = GraphEquationClassifier.explicitRightHandSide(expression.latex) {
            return right.isEmpty ? nil : right
        }
        let source = GraphLatexNormalizer.normalize(expression.latex)
        return source.isEmpty || GraphCalculusSyntax.parse(source) != nil ? nil : source
    }

    var calculusDraftRequiresPoint: Bool {
        guard calculusDraft?.operation == .derivative,
              let id = selectedExpressionID, let expression = expression(id: id) else {
            return false
        }
        return GraphMathEnvironment.functionDefinition(in: expression.latex) != nil
    }

    func displaySource(for expression: GraphExpression) -> String {
        switch GraphCalculusSyntax.parse(expression.latex) {
        case .derivative(let operand):
            return "\\frac{d}{dx}\\left(\(operand)\\right)"
        case .prime(let function, let order, let argument):
            return "\(function)\(String(repeating: "'", count: order))(\(argument))"
        case .definiteIntegral(let integrand, let lower, let upper):
            return "\\int_{\(lower)}^{\(upper)} \(integrand)\\,dx"
        case nil:
            return expression.latex
        }
    }

    func undefinedParameters(for expression: GraphExpression) -> [String] {
        mathEnvironment.undefinedSliderParameters(in: expression.latex)
    }

    func feedback(for expression: GraphExpression) -> GraphRowFeedback? {
        let source = expression.latex
        let normalized = GraphLatexNormalizer.normalize(source)
        guard !normalized.isEmpty else {
            return GraphRowFeedback(kind: .error, message: "Enter an expression.")
        }
        let environment = mathEnvironment
        if let definition = GraphMathEnvironment.scalarDefinition(in: source) {
            guard let value = environment.variables[definition.name] else {
                return parseError(for: source, environment: environment)
            }
            return GraphRowFeedback(kind: .value, message: Self.format(value))
        }
        if let definition = GraphMathEnvironment.functionDefinition(in: source) {
            do {
                _ = try SafeGraphExpression(
                    source: definition.body,
                    angleMode: workingGraph.settings.angleMode,
                    variables: environment.variables,
                    functions: environment.functions
                )
                return nil
            } catch {
                return friendlyError(error, source: source, environment: environment)
            }
        }
        switch GraphCalculusSyntax.parse(normalized) {
        case .prime(let function, let order, let argument):
            do {
                guard let body = environment.functions[function] else {
                    return GraphRowFeedback(
                        kind: .error, message: "Unknown function \(function)."
                    )
                }
                if argument == "x" {
                    return GraphRowFeedback(
                        kind: .derivative,
                        message: order == 1 ? "Derivative function" : "Derivative order \(order)"
                    )
                }
                let point = try scalarValue(argument, environment: environment)
                let result = try NativeGraphMath.derivative(
                    body, at: point, order: order,
                    angleMode: workingGraph.settings.angleMode,
                    variables: environment.variables,
                    functions: environment.functions
                )
                return GraphRowFeedback(
                    kind: .derivative,
                    message: Self.format(result.values.first ?? .nan)
                )
            } catch {
                return friendlyError(error, source: source, environment: environment)
            }
        case .derivative(let operand):
            let integrand = resolvedCalculusOperand(operand, environment: environment)
            do {
                let parsed = try SafeGraphExpression(
                    source: integrand, angleMode: workingGraph.settings.angleMode,
                    variables: environment.variables, functions: environment.functions
                )
                guard !parsed.usesVariable else {
                    return GraphRowFeedback(kind: .derivative, message: "Derivative function")
                }
                let result = try NativeGraphMath.derivative(
                    integrand, at: 0,
                    angleMode: workingGraph.settings.angleMode,
                    variables: environment.variables,
                    functions: environment.functions
                )
                return GraphRowFeedback(
                    kind: .derivative,
                    message: Self.format(result.values.first ?? .nan)
                )
            } catch {
                return friendlyError(error, source: source, environment: environment)
            }
        case .definiteIntegral:
            do {
                let value = try integralValue(normalized, environment: environment)
                return GraphRowFeedback(kind: .integral, message: Self.format(value))
            } catch {
                return friendlyError(error, source: source, environment: environment)
            }
        case nil:
            break
        }
        if let relation = GraphEquationClassifier.relation(in: source) {
            do {
                if relation.left == "y" {
                    _ = try SafeGraphExpression(
                        source: relation.right, angleMode: workingGraph.settings.angleMode,
                        variables: environment.variables, functions: environment.functions
                    )
                    return nil
                }
                let result = try NativeGraphMath.solve(
                    source, domain: viewport.xMin...viewport.xMax,
                    angleMode: workingGraph.settings.angleMode,
                    variables: environment.variables, functions: environment.functions
                )
                return GraphRowFeedback(kind: .value, message: result.message)
            } catch {
                return friendlyError(error, source: source, environment: environment)
            }
        }
        do {
            let result = try NativeGraphMath.calculate(
                source, angleMode: workingGraph.settings.angleMode,
                variables: environment.variables, functions: environment.functions
            )
            return GraphRowFeedback(kind: .value, message: result.message)
        } catch {
            return friendlyError(error, source: source, environment: environment)
        }
    }

    private var mathEnvironment: GraphMathEnvironment {
        GraphMathEnvironment.build(
            from: expressions, angleMode: workingGraph.settings.angleMode
        )
    }

    private func mutateExpression(id: String,
                                  transform: (GraphExpression) -> GraphExpression) {
        guard let index = expressions.firstIndex(where: { $0.id == id }) else { return }
        var next = expressions
        let updated = transform(next[index])
        guard updated.id == next[index].id, updated != next[index] else { return }
        next[index] = updated
        commitExpressions(next)
    }

    private func commitExpressions(_ expressions: [GraphExpression]) {
        workingGraph = workingGraph.replacing(expressions: expressions)
        onExpressionMutation(workingGraph)
    }

    private func parseError(for source: String,
                            environment: GraphMathEnvironment) -> GraphRowFeedback {
        do {
            let parseSource = GraphEquationClassifier.explicitRightHandSide(source) ?? source
            _ = try SafeGraphExpression(
                source: parseSource, angleMode: workingGraph.settings.angleMode,
                variables: environment.variables, functions: environment.functions
            )
            return GraphRowFeedback(kind: .error, message: "This expression is incomplete.")
        } catch {
            return friendlyError(error, source: source, environment: environment)
        }
    }

    private func friendlyError(_ error: Error, source: String,
                               environment: GraphMathEnvironment) -> GraphRowFeedback {
        let undefined = environment.undefinedSliderParameters(in: source)
        if let name = undefined.first {
            return GraphRowFeedback(kind: .error, message: "Undefined parameter \(name).")
        }
        if case GraphRendererError.invalidExpression(let reason) = error {
            if reason.contains("undefined ") {
                let name = reason.replacingOccurrences(of: "undefined ", with: "")
                return GraphRowFeedback(kind: .error, message: "Unknown function \(name).")
            }
            if reason.contains("parenthesis") || source.filter({ $0 == "(" }).count
                > source.filter({ $0 == ")" }).count {
                return GraphRowFeedback(kind: .error, message: "Close the open parenthesis.")
            }
            if reason.contains("undefined") {
                return GraphRowFeedback(kind: .error, message: "This result is undefined.")
            }
        }
        return GraphRowFeedback(kind: .error, message: "Complete this expression.")
    }

    private func resolvedCalculusOperand(_ source: String,
                                         environment: GraphMathEnvironment) -> String {
        guard source.hasSuffix("(x)"),
              let body = environment.functions[String(source.dropLast(3))] else {
            return source
        }
        return body
    }

    private func integralValue(_ source: String,
                               environment: GraphMathEnvironment) throws -> Double {
        guard source.hasPrefix("integral("), source.hasSuffix(")") else {
            throw GraphRendererError.invalidExpression("integral")
        }
        let body = String(source.dropFirst(9).dropLast())
        let arguments = splitArguments(body)
        guard arguments.count == 3 else {
            throw GraphRendererError.invalidExpression("integral bounds")
        }
        let integrand: String
        if arguments[0].hasSuffix("(x)"),
           let functionBody = environment.functions[String(arguments[0].dropLast(3))] {
            integrand = functionBody
        } else {
            integrand = arguments[0]
        }
        let lower = try scalarValue(arguments[1], environment: environment)
        let upper = try scalarValue(arguments[2], environment: environment)
        let result = try NativeGraphMath.integral(
            integrand, from: lower, to: upper,
            angleMode: workingGraph.settings.angleMode,
            variables: environment.variables, functions: environment.functions
        )
        guard let value = result.values.first else {
            throw GraphRendererError.invalidExpression("integral undefined")
        }
        return value
    }

    private func scalarValue(_ source: String,
                             environment: GraphMathEnvironment) throws -> Double {
        let result = try NativeGraphMath.calculate(
            source, angleMode: workingGraph.settings.angleMode,
            variables: environment.variables, functions: environment.functions
        )
        guard let value = result.values.first else {
            throw GraphRendererError.invalidExpression("undefined result")
        }
        return value
    }

    private func splitArguments(_ source: String) -> [String] {
        var depth = 0
        var start = source.startIndex
        var result: [String] = []
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                result.append(String(source[start..<index]))
                start = source.index(after: index)
            }
            index = source.index(after: index)
        }
        result.append(String(source[start...]))
        return result
    }

    private func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number): return number
        case .integer(let number): return Double(number)
        default: return nil
        }
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "Undefined" }
        if abs(value.rounded() - value) < 1e-10 { return String(Int(value.rounded())) }
        return value.formatted(.number.precision(.fractionLength(0...6)))
    }
}
