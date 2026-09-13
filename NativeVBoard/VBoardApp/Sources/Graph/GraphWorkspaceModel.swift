import Foundation
import SwiftUI

enum GraphMathKeyboardCategory: String, CaseIterable, Identifiable {
    case basic = "123"
    case functions = "f(x)"
    case calculus = "Calculus"

    var id: String { rawValue }
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

@MainActor
final class GraphWorkspaceModel: ObservableObject {
    typealias ExpressionMutationSink = (GraphObject) -> Void

    @Published private(set) var workingGraph: GraphObject
    @Published var selectedExpressionID: String?
    @Published var editingExpressionID: String?
    @Published var keyboardCategory: GraphMathKeyboardCategory = .basic

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
        return GraphParameterSlider(
            name: definition.name, value: value,
            minimum: number(expression.additionalFields["slider_min"]) ?? -10,
            maximum: number(expression.additionalFields["slider_max"]) ?? 10,
            step: max(0.000_001, number(expression.additionalFields["slider_step"]) ?? 0.1)
        )
    }

    func updateSlider(id: String, value: Double) {
        guard let expression = expression(id: id),
              let slider = slider(for: expression) else { return }
        let clamped = min(slider.maximum, max(slider.minimum, value))
        updateSource(id: id, source: "\(slider.name)=\(Self.format(clamped))")
    }

    @discardableResult
    func addParameter(named name: String, value: Double = 1) -> String? {
        guard GraphMathEnvironment.empty.undefinedSliderParameters(in: name) == [name],
              mathEnvironment.variables[name] == nil else { return nil }
        return addExpression(source: "\(name)=\(Self.format(value))")
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
        if let derivative = derivativeCall(normalized, environment: environment) {
            do {
                let point = try scalarValue(derivative.argument, environment: environment)
                let result = try NativeGraphMath.derivative(
                    derivative.body, at: point,
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
        }
        if let integrand = derivativeExpression(normalized, environment: environment) {
            do {
                _ = try SafeGraphExpression(
                    source: integrand, angleMode: workingGraph.settings.angleMode,
                    variables: environment.variables, functions: environment.functions
                )
                return GraphRowFeedback(kind: .derivative, message: "Derivative")
            } catch {
                return friendlyError(error, source: source, environment: environment)
            }
        }
        if normalized.hasPrefix("integral(") {
            do {
                let value = try integralValue(normalized, environment: environment)
                return GraphRowFeedback(kind: .integral, message: Self.format(value))
            } catch {
                return friendlyError(error, source: source, environment: environment)
            }
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

    private func derivativeCall(_ source: String,
                                environment: GraphMathEnvironment)
        -> (body: String, argument: String)? {
        guard source.hasSuffix(")"), let marker = source.range(of: "'(") else { return nil }
        let name = String(source[..<marker.lowerBound])
        let argumentStart = marker.upperBound
        let argument = String(source[argumentStart..<source.index(before: source.endIndex)])
        guard !argument.isEmpty, let body = environment.functions[name] else { return nil }
        return (body, argument)
    }

    private func derivativeExpression(_ source: String,
                                      environment: GraphMathEnvironment) -> String? {
        guard source.hasPrefix("d/dx("), source.hasSuffix(")") else { return nil }
        let inner = String(source.dropFirst(5).dropLast())
        guard inner.hasSuffix("(x)"),
              let body = environment.functions[String(inner.dropLast(3))] else { return nil }
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
