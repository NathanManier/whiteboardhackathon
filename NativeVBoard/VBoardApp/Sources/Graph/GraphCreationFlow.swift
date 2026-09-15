import Combine
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class GraphRecognitionController: ObservableObject {
    nonisolated static let maximumExpressions = 8
    nonisolated static let maximumLatexLength = 1_000

    @Published private(set) var result: GraphRecognitionResult?
    @Published private(set) var isClassifying = false
    @Published private(set) var failed = false

    private var selectionSignature: String?
    private var inFlight: Task<GraphRecognitionEnvelope, Error>?
    private var automaticTask: Task<Void, Never>?

    deinit {
        automaticTask?.cancel()
        inFlight?.cancel()
    }

    func selectionChanged(_ target: GraphRecognitionTarget?, api: APIClient,
                          prepareSelection: @escaping () async -> Void) {
        let signature = target?.cacheSignature
        guard signature != selectionSignature else { return }
        automaticTask?.cancel()
        inFlight?.cancel()
        inFlight = nil
        selectionSignature = signature
        result = nil
        failed = false
        isClassifying = false
        guard let target,
              GraphAutomaticRecognitionPolicy.shouldClassify(target) else { return }
        automaticTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self,
                  self.selectionSignature == target.cacheSignature else { return }
            do {
                _ = try await self.recognize(target, api: api,
                                             prepareSelection: prepareSelection)
            } catch {
                // Automatic graphability is intentionally quiet. The manual
                // Graph Selection action still exposes retry/manual entry.
            }
        }
    }

    func selectionChanged(_ selection: BoardStudySelection?, api: APIClient,
                          prepareSelection: @escaping () async -> Void) {
        selectionChanged(selection.map(GraphRecognitionTarget.board), api: api,
                         prepareSelection: prepareSelection)
    }

    func recognize(_ target: GraphRecognitionTarget, api: APIClient,
                   prepareSelection: @escaping () async -> Void) async throws
        -> GraphRecognitionResult {
        let signature = target.cacheSignature
        if selectionSignature == signature, let result { return result }
        if selectionSignature != signature {
            automaticTask?.cancel()
            inFlight?.cancel()
            inFlight = nil
            selectionSignature = signature
            result = nil
            failed = false
        }
        if let inFlight { return try await inFlight.value.result.validated() }

        isClassifying = true
        failed = false
        let requestID = BoardStudyExplainRequest.makeRequestID()
        let task = Task<GraphRecognitionEnvelope, Error> { @MainActor in
            await prepareSelection()
            return try await api.recognizeGraph(target: target, requestID: requestID)
        }
        inFlight = task
        do {
            let envelope = try await task.value
            guard selectionSignature == signature else { throw CancellationError() }
            let validated = try envelope.result.validated()
            result = validated
            isClassifying = false
            inFlight = nil
            return validated
        } catch {
            if selectionSignature == signature {
                failed = true
                isClassifying = false
                inFlight = nil
            }
            throw error
        }
    }

    func recognize(_ selection: BoardStudySelection, api: APIClient,
                   prepareSelection: @escaping () async -> Void) async throws
        -> GraphRecognitionResult {
        try await recognize(.board(selection), api: api,
                            prepareSelection: prepareSelection)
    }

    func clear() {
        automaticTask?.cancel()
        inFlight?.cancel()
        automaticTask = nil
        inFlight = nil
        selectionSignature = nil
        result = nil
        failed = false
        isClassifying = false
    }

    static func signature(_ selection: BoardStudySelection) -> String {
        GraphRecognitionTarget.board(selection).cacheSignature
    }
}

enum GraphAutomaticRecognitionPolicy {
    static func shouldClassify(_ target: GraphRecognitionTarget) -> Bool {
        target.selections.contains(where: shouldClassify)
    }

    static func shouldClassify(_ selection: BoardStudySelection) -> Bool {
        if selection.selectedTextObjects.contains(where: { $0.role == "graph" }) { return false }
        if GraphabilityPolicy.hasLocalSemanticHint(selection) { return true }
        let count = selection.canonicalObjectIDs.count
        let bbox = selection.localBBox
        let ratio = bbox.width / max(bbox.height, 0.001)
        // This cheap geometry gate avoids invoking recognition for every
        // arbitrary lasso while retaining likely handwritten equation rows.
        return (2...80).contains(count)
            && bbox.width >= 24 && bbox.height >= 8
            && (1.15...16).contains(ratio)
    }
}

/// Extracts already-semantic equations without an AI request. Visual
/// handwriting still uses explicit recognition after the user chooses Graph.
enum GraphLocalExpressionExtractor {
    static func expressions(from target: GraphRecognitionTarget) -> [GraphExpression] {
        var seen = Set<String>()
        var result: [GraphExpression] = []
        for item in target.selections.flatMap(\.selectedTextObjects) {
            for candidate in candidates(in: item.text) {
                let normalized = GraphLatexNormalizer.normalize(candidate)
                guard isGraphable(normalized), seen.insert(normalized).inserted else { continue }
                let expression = GraphExpression(
                    id: "expression-" + UUID().uuidString.lowercased(),
                    latex: candidate,
                    type: GraphExpressionInference.type(for: candidate)
                )
                if let clean = try? GraphPersistenceValidator.sanitized(expression) {
                    result.append(clean)
                }
                if result.count == GraphRecognitionController.maximumExpressions { return result }
            }
        }
        return result
    }

    private static func candidates(in source: String) -> [String] {
        var values: [String] = []
        for pattern in [#"\$([^$\n]+)\$"#, #"\\\(([\s\S]*?)\\\)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) where match.numberOfRanges > 1 {
                guard let swiftRange = Range(match.range(at: 1), in: source) else { continue }
                values.append(String(source[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if values.isEmpty {
            values = source.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return values.filter { !$0.isEmpty && $0.count <= GraphRecognitionController.maximumLatexLength }
    }

    private static func isGraphable(_ value: String) -> Bool {
        GraphEquationClassifier.point(in: value) != nil
            || GraphEquationClassifier.explicitRightHandSide(value) != nil
            || GraphEquationClassifier.constant(after: "x", in: value) != nil
            || GraphEquationClassifier.originCircleRadius(in: value) != nil
            || (value.contains("=") && value.contains("x") && value.contains("y"))
            || ((value.contains(">") || value.contains("<"))
                && (value.contains("x") || value.contains("y")))
    }
}

struct GraphIntegralProposal: Equatable {
    let sourceLatex: String
    let integrandLatex: String

    var graphLatex: String { "y=\(integrandLatex)" }
}

/// An integral is not itself a graph expression. This local policy offers the
/// integrand, but never invents or graphs an antiderivative for the user.
enum GraphNonDirectExpressionPolicy {
    static func integralProposal(from target: GraphRecognitionTarget) -> GraphIntegralProposal? {
        for item in target.selections.flatMap(\.selectedTextObjects) {
            for candidate in candidates(in: item.text) {
                if let proposal = integralProposal(in: candidate) { return proposal }
            }
        }
        return nil
    }

    private static func candidates(in source: String) -> [String] {
        var values: [String] = []
        for pattern in [#"\$([^$\n]+)\$"#, #"\\\(([\s\S]*?)\\\)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) where match.numberOfRanges > 1 {
                guard let swiftRange = Range(match.range(at: 1), in: source) else { continue }
                values.append(String(source[swiftRange]))
            }
        }
        if values.isEmpty { values = source.split(whereSeparator: \.isNewline).map(String.init) }
        return values
    }

    private static func integralProposal(in candidate: String) -> GraphIntegralProposal? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenRange: Range<String.Index>
        if let range = trimmed.range(of: "\\int") { tokenRange = range }
        else if let range = trimmed.range(of: "∫") { tokenRange = range }
        else { return nil }

        var remainder = String(trimmed[tokenRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        remainder = droppingIntegralLimits(remainder)
        guard let differential = remainder.range(
            of: #"(?:\\,)?\s*d\s*x\s*$"#,
            options: .regularExpression
        ) else { return nil }
        let integrand = String(remainder[..<differential.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !integrand.isEmpty,
              integrand.count <= GraphRecognitionController.maximumLatexLength,
              !GraphLatexNormalizer.normalize(integrand).isEmpty else { return nil }
        return GraphIntegralProposal(sourceLatex: trimmed, integrandLatex: integrand)
    }

    private static func droppingIntegralLimits(_ source: String) -> String {
        let characters = Array(source)
        var cursor = 0
        while cursor < characters.count,
              characters[cursor] == "_" || characters[cursor] == "^" {
            cursor += 1
            if cursor < characters.count, characters[cursor] == "{" {
                var depth = 0
                repeat {
                    if characters[cursor] == "{" { depth += 1 }
                    if characters[cursor] == "}" { depth -= 1 }
                    cursor += 1
                } while cursor < characters.count && depth > 0
            } else {
                while cursor < characters.count,
                      !characters[cursor].isWhitespace,
                      characters[cursor] != "_", characters[cursor] != "^" {
                    cursor += 1
                }
            }
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        }
        return String(characters[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GraphCreationRequest: Identifiable {
    let id = UUID()
    let target: GraphRecognitionTarget
    let sourceBoardIDs: [String]
    let selectedObjectKeys: [String]

    var selection: BoardStudySelection { target.primarySelection }

    init(selection: BoardStudySelection,
         sourceBoardIDs: [String]? = nil,
         selectedObjectKeys: [String]? = nil) {
        target = .board(selection)
        self.sourceBoardIDs = sourceBoardIDs ?? target.sourceBoardIDs
        self.selectedObjectKeys = selectedObjectKeys ?? selection.canonicalObjectIDs
    }

    init(target: GraphRecognitionTarget, selectedObjectKeys: [String]) {
        self.target = target
        sourceBoardIDs = target.sourceBoardIDs
        self.selectedObjectKeys = selectedObjectKeys
    }
}

struct GraphCreationSheet: View {
    private enum Phase { case reading, confirm, editing, unrecognized }

    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let target: GraphRecognitionTarget
    @ObservedObject var recognition: GraphRecognitionController
    let prepareSelection: () async -> Void
    let onCreate: ([GraphExpression], String?) -> Void

    private var selection: BoardStudySelection { target.primarySelection }

    @State private var phase: Phase = .reading
    @State private var drafts: [GraphExpressionDraft] = []
    @State private var recognitionRequestID: String?
    @State private var integralProposal: GraphIntegralProposal?
    @State private var error: String?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .reading: readingView
                case .confirm: confirmationView
                case .editing: editorView
                case .unrecognized: unrecognizedView
                }
            }
            .padding(20)
            .navigationTitle("Graph Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await recognizeIfNeeded() }
    }

    private var readingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading equation…").font(.headline)
            Text("Only the selected canvas region is being analyzed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var confirmationView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(integralProposal == nil ? "Recognized equation" : "Graph the integrand?")
                .font(.headline)
            if let integralProposal {
                Text("An integral is not itself a y = f(x) curve. V-Board can graph the expression inside it without inventing an antiderivative.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                StudyContentView(source: "\\(\(integralProposal.sourceLatex)\\)",
                                 maximumWidth: 560)
                    .frame(minHeight: 34, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($drafts) { $draft in
                        Toggle(isOn: $draft.enabled) {
                            StudyContentView(source: "\\(\(draft.latex)\\)", maximumWidth: 560)
                                .frame(minHeight: 34, alignment: .leading)
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Edit") { phase = .editing }.buttonStyle(.bordered)
                Spacer()
                Button(drafts.filter(\.enabled).count > 1 ? "Graph Selected" : "Graph") {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || drafts.allSatisfy { !$0.enabled })
            }
        }
    }

    private var editorView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Equations").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle("", isOn: $draft.enabled).labelsHidden()
                                TextField("y=x^2", text: $draft.latex)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onSubmit { create() }
                                Button(role: .destructive) {
                                    drafts.removeAll { $0.id == draft.id }
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                            }
                            if !draft.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                StudyContentView(source: "\\(\(draft.latex)\\)", maximumWidth: 520)
                                    .frame(minHeight: 30, alignment: .leading)
                            }
                        }
                    }
                    Button { addDraft() } label: { Label("Add equation", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Back") { phase = .confirm }.buttonStyle(.bordered)
                    .disabled(drafts.isEmpty)
                Spacer()
                Button("Graph") { create() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || drafts.isEmpty)
            }
        }
    }

    private var unrecognizedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "function").font(.largeTitle).foregroundStyle(.secondary)
            Text("Couldn’t confidently recognize a graphable equation.")
                .font(.headline).multilineTextAlignment(.center)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            Button("Enter Equation") {
                drafts = [GraphExpressionDraft(latex: "")]
                phase = .editing
                self.error = nil
            }
            .buttonStyle(.borderedProminent)
            Button("Retry") { Task { await recognizeIfNeeded(force: true) } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recognizeIfNeeded(force: Bool = false) async {
        phase = .reading
        error = nil
        if !force {
            if let proposal = GraphNonDirectExpressionPolicy.integralProposal(from: target) {
                recognitionRequestID = nil
                integralProposal = proposal
                drafts = [GraphExpressionDraft(latex: proposal.graphLatex)]
                phase = .confirm
                return
            }
            let local = GraphLocalExpressionExtractor.expressions(from: target)
            if !local.isEmpty {
                recognitionRequestID = nil
                integralProposal = nil
                drafts = local.map(GraphExpressionDraft.init(expression:))
                phase = .confirm
                return
            }
        }
        do {
            if force { recognition.clear() }
            let result = try await recognition.recognize(
                target, api: api, prepareSelection: prepareSelection
            )
            recognitionRequestID = result.requestID
            integralProposal = nil
            if result.graphable, !result.expressions.isEmpty {
                drafts = result.expressions.prefix(GraphRecognitionController.maximumExpressions).map {
                    GraphExpressionDraft(expression: $0.canonicalExpression)
                }
                phase = .confirm
            } else {
                phase = .unrecognized
            }
        } catch is CancellationError {
            dismiss()
        } catch {
            self.error = "Couldn’t read this equation."
            phase = .unrecognized
        }
    }

    private func addDraft() {
        guard drafts.count < GraphRecognitionController.maximumExpressions else { return }
        drafts.append(GraphExpressionDraft(latex: ""))
    }

    private func create() {
        guard !isCreating else { return }
        do {
            let expressions = try drafts.filter(\.enabled).map { try $0.expression() }
            guard !expressions.isEmpty else {
                error = "Select at least one equation."
                return
            }
            isCreating = true
            onCreate(expressions, recognitionRequestID)
            dismiss()
        } catch {
            isCreating = false
            self.error = "Check the equation and try again."
        }
    }
}

struct GraphExpressionDraft: Identifiable, Equatable {
    let id: String
    var latex: String
    var type: GraphExpressionType
    var enabled: Bool
    var displayStyle: GraphExpressionDisplayStyle?
    var restrictions: [String]
    var additionalFields: [String: JSONValue]
    private let infersTypeOnSave: Bool

    init(id: String = "expression-" + UUID().uuidString.lowercased(),
         latex: String, type: GraphExpressionType? = nil, enabled: Bool = true,
         displayStyle: GraphExpressionDisplayStyle? = nil,
         restrictions: [String] = [],
         additionalFields: [String: JSONValue] = [:]) {
        self.id = id
        self.latex = latex
        self.type = type ?? GraphExpressionInference.type(for: latex)
        self.enabled = enabled
        self.displayStyle = displayStyle
        self.restrictions = restrictions
        self.additionalFields = additionalFields
        infersTypeOnSave = type == nil
    }

    init(expression: GraphExpression) {
        self.init(id: expression.id, latex: expression.latex, type: expression.type,
                  enabled: expression.visible, displayStyle: expression.displayStyle,
                  restrictions: expression.restrictions,
                  additionalFields: expression.additionalFields)
    }

    func expression() throws -> GraphExpression {
        let value = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= GraphRecognitionController.maximumLatexLength,
              !value.contains("<"), !value.lowercased().contains("javascript:") else {
            throw GraphRendererError.invalidExpression("unsafe or empty")
        }
        return try GraphPersistenceValidator.sanitized(GraphExpression(
            id: id, latex: value,
            type: infersTypeOnSave ? GraphExpressionInference.type(for: value) : type,
            visible: enabled, displayStyle: displayStyle,
            restrictions: restrictions, additionalFields: additionalFields
        ))
    }
}

enum GraphExpressionInference {
    static func type(for latex: String) -> GraphExpressionType {
        let value = GraphLatexNormalizer.normalize(latex)
        if GraphEquationClassifier.point(in: value) != nil { return .point }
        if value.hasPrefix("x=") { return .verticalLine }
        if value.contains(">=") || value.contains("<=") || value.contains(">") || value.contains("<") {
            return .inequality
        }
        if GraphEquationClassifier.originCircleRadius(in: value) != nil { return .implicitEquation }
        if value.hasPrefix("y=") {
            let rhs = GraphEquationClassifier.explicitRightHandSide(value) ?? ""
            return rhs.contains("x") ? .explicitFunction : .horizontalLine
        }
        if value.hasPrefix("f(x)=") || value.hasPrefix("g(x)=") || value.hasPrefix("h(x)=") {
            return .explicitFunction
        }
        if value.contains("=") && value.contains("x") && value.contains("y") {
            return .implicitEquation
        }
        return .unknown
    }
}

enum GraphPlacementPolicy {
    static func frame(source: CGRect, occupied: [CGRect], cameraScale: CGFloat,
                      containerWidth: CGFloat? = nil) -> GraphFrame {
        let safeScale = max(cameraScale, 0.01)
        let width = min(1_200, max(260, 420 / safeScale))
        let height = min(900, max(195, 300 / safeScale))
        let gap = max(24, 28 / safeScale)
        let x: CGFloat
        if let containerWidth {
            x = min(max(0, source.minX), max(0, containerWidth - width))
        } else {
            x = source.minX
        }
        var candidate = CGRect(x: x, y: source.maxY + gap,
                               width: width, height: height)
        // Placement is intentionally monotonic and deterministic: remain
        // below the source and advance only far enough to clear each actual
        // collision. It can never silently choose the right side of a board.
        for _ in 0..<256 {
            let collisions = occupied.filter {
                !$0.isNull && !$0.isInfinite && candidate.intersects($0)
            }
            guard let bottom = collisions.map(\.maxY).max() else { break }
            candidate.origin.y = bottom + gap
        }
        return GraphFrame(x: Double(candidate.minX), y: Double(candidate.minY),
                          width: Double(candidate.width), height: Double(candidate.height))
    }
}

enum GraphPlacementGeometry {
    /// One conservative professor-ink obstacle is sufficient for placement.
    /// Canonical paths and imported transforms are read only; no source
    /// geometry is rewritten or moved into editor ownership.
    static func professorBounds(document: SVGDocument,
                                editor: EditorState) -> CGRect? {
        var result = CGRect.null
        for source in document.paths {
            let transform = source.id.flatMap { editor.importedTransforms[$0] }
            guard transform?.deleted != true,
                  let path = try? SVGPathParser.cachedPath(from: source.d) else {
                continue
            }
            var affine = CGAffineTransform.identity
                .translatedBy(x: CGFloat(transform?.x ?? 0),
                              y: CGFloat(transform?.y ?? 0))
                .scaledBy(x: CGFloat(transform?.scaleX ?? 1),
                          y: CGFloat(transform?.scaleY ?? 1))
            let transformed = path.copy(using: &affine) ?? path
            let bounds = transformed.boundingBoxOfPath
            guard !bounds.isNull, !bounds.isInfinite else { continue }
            result = result.union(bounds)
        }
        return result.isNull ? nil : result
    }
}

enum GraphObjectFactory {
    static func make(boardID: String, selection: BoardStudySelection,
                     expressions: [GraphExpression], recognitionRequestID: String?,
                     cameraScale: CGFloat, occupied: [CGRect],
                     sourceBoardIDs: [String]? = nil,
                     selectedObjectKeys: [String]? = nil,
                     placementSource: CGRect? = nil,
                     containerWidth: CGFloat? = nil) -> GraphObject {
        // Board screens use the canonical board-local selection directly.
        // Lecture callers may supply the same lecture-world source converted
        // into the owning board's coordinates after scoring all nearby boards.
        let source = placementSource ?? selection.localBBox.cgRect
        let now = Date().timeIntervalSince1970
        let stableID = recognitionRequestID.map { "graph-recognition-" + $0 }
            ?? "graph-" + UUID().uuidString.lowercased()
        return GraphObject(
            id: stableID,
            owningBoardID: boardID,
            frame: GraphPlacementPolicy.frame(source: source, occupied: occupied,
                                              cameraScale: cameraScale,
                                              containerWidth: containerWidth),
            expressions: Array(expressions.prefix(GraphRecognitionController.maximumExpressions)),
            viewport: .conventional,
            settings: GraphSettings(),
            sourceSelection: GraphSourceSelection(
                interactionID: recognitionRequestID,
                sourceBoardIDs: sourceBoardIDs ?? [boardID],
                selectedObjectKeys: selectedObjectKeys ?? selection.canonicalObjectIDs,
                originalRecognitionRequestID: recognitionRequestID,
                originalSelectionBBox: GraphFrame(
                    x: selection.localBBox.x, y: selection.localBBox.y,
                    width: selection.localBBox.width, height: selection.localBBox.height
                )
            ),
            providerMetadata: GraphProviderMetadata(preference: "native-lightweight",
                                                    semanticContentHash: nil,
                                                    renderVersion: 1),
            createdAt: now, updatedAt: now, version: 1
        )
    }
}

struct GraphExpressionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let graph: GraphObject
    let onSave: ([GraphExpression]) -> Void
    @State private var drafts: [GraphExpressionDraft]
    @State private var error: String?

    init(graph: GraphObject, onSave: @escaping ([GraphExpression]) -> Void) {
        self.graph = graph
        self.onSave = onSave
        _drafts = State(initialValue: graph.expressions.map(GraphExpressionDraft.init(expression:)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Equations") {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle("Visible", isOn: $draft.enabled).labelsHidden()
                                TextField("y=x^2", text: $draft.latex)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            if !draft.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                StudyContentView(source: "\\(\(draft.latex)\\)", maximumWidth: 520)
                                    .frame(minHeight: 30, alignment: .leading)
                            }
                        }
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    Button {
                        if drafts.count < GraphRecognitionController.maximumExpressions {
                            drafts.append(GraphExpressionDraft(latex: ""))
                        }
                    } label: {
                        Label("Add equation", systemImage: "plus")
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit Graph")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        do {
            let expressions = try drafts.map { try $0.expression() }
            guard !expressions.isEmpty else {
                error = "Add at least one equation."
                return
            }
            onSave(expressions)
            dismiss()
        } catch {
            self.error = "Check the equations and try again."
        }
    }
}
