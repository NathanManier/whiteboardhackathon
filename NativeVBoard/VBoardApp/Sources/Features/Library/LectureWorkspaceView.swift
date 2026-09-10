import SwiftUI

struct LectureWorkspaceView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folder: LectureFolder
    let initialFocusBoardID: String?
    @StateObject private var store: LectureWorkspaceStore
    @State private var activeTool: CanvasTool = .navigation
    @State private var showImporter = false
    @State private var showNavigator = false
    @State private var showGuide = false
    @State private var showStudy = false
    @State private var showNote = false
    @State private var showDelete = false
    @State private var showConflict = false

    init(folder: LectureFolder, focusBoardID: String? = nil) {
        self.folder = folder
        initialFocusBoardID = focusBoardID
        _store = StateObject(wrappedValue: LectureWorkspaceStore(folderID: folder.id))
    }

    var body: some View {
        Group {
            if let workspace = store.workspace {
                workspaceSurface(workspace)
            } else if case .failed(let message) = store.status {
                ContentUnavailableView("Couldn’t open lecture", systemImage: "rectangle.stack.badge.exclamationmark",
                                       description: Text(message))
                    .overlay(alignment: .bottom) {
                        Button("Retry") { Task { await store.load(api: api, focusBoardID: initialFocusBoardID) } }
                            .buttonStyle(.borderedProminent)
                            .padding(.bottom, 30)
                    }
            } else {
                ProgressView("Opening lecture workspace…")
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { store.undo(api: api) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!store.canUndo)
                Button { store.redo(api: api) } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!store.canRedo)
                Button { showNavigator = true } label: { Image(systemName: "list.bullet.rectangle") }
                    .accessibilityLabel("Lecture navigator")
                Menu {
                    Button { showImporter = true } label: { Label("Add Whiteboard", systemImage: "photo.badge.plus") }
                    Button { showGuide = true } label: { Label("Study Guide", systemImage: "text.book.closed") }
                    Button { showNote = true } label: { Label("Add Note", systemImage: "note.text.badge.plus") }
                        .disabled(store.activeBoardStore == nil)
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete Lecture", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showImporter) {
            ImportFlowView(folderID: folder.id) { board in
                showImporter = false
                Task { await store.refreshAfterImport(boardID: board.id, api: api) }
            }
        }
        .sheet(isPresented: $showNavigator) {
            LectureNavigatorSheet(store: store, api: api)
        }
        .sheet(isPresented: $showGuide) {
            StudyGuideView(folderID: folder.id, guide: store.lecture?.studyGuide)
        }
        .sheet(isPresented: $showNote) {
            LectureNoteSheet(unitLabel: activeUnitLabel) { markdown in
                store.addNote(markdown, api: api)
                showNote = false
            }
        }
        .sheet(isPresented: $showStudy) {
            if selectedBoardIDs.count > 1 {
                LectureSelectionStudyView(
                    folderID: folder.id,
                    selectedObjectIDsByBoard: selectedObjectIDsByBoard
                )
            } else if let boardID = studyBoardID,
                      let selection = store.studySelection(for: boardID) {
                StudyActionsView(selection: selection,
                                 prepareSelection: { await store.saveBoardNow(boardID, api: api) }) { problems, interactionID in
                    store.applyPracticeProblems(problems, interactionID: interactionID,
                                                boardID: boardID, api: api)
                }
            }
        }
        .alert("Delete lecture?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await api.deleteLecture(id: folder.id, recursive: true); dismiss() }
                    catch { }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the lecture and all of its whiteboards.")
        }
        .alert("Lecture layout changed", isPresented: $showConflict) {
            Button("Keep My Layout") { store.keepLocalChanges(api: api) }
            Button("Reload Server Layout", role: .destructive) { store.reloadServerVersion() }
        } message: {
            Text("Your local camera and whiteboard placements are saved on this iPad. Choose which layout should remain.")
        }
        .onChange(of: store.status) { _, status in
            if status == .conflict { showConflict = true }
        }
        .task { await store.load(api: api, focusBoardID: initialFocusBoardID) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            store.persistForBackgrounding()
        }
    }

    private func workspaceSurface(_ workspace: LectureWorkspace) -> some View {
        ZStack(alignment: .bottom) {
            LectureCanvasView(
                workspace: workspace,
                scenes: store.scenes,
                selectedKeys: store.selectedKeys,
                tool: activeTool,
                thumbnailURLs: Dictionary(uniqueKeysWithValues: workspace.items.compactMap { item in
                    api.resolvedURL(item.thumbnailURL).map { (item.boardID, $0) }
                }),
                loadAsset: { try await api.authorizedAsset(path: $0) },
                focusRequest: store.focusRequest,
                onCameraChanged: { store.updateCamera($0, api: api) },
                onActiveBoardChanged: { store.setActiveBoard($0, api: api) },
                onDetailDemand: { store.requestDetail(for: $0, api: api) },
                onSelectionChanged: { keys, pdfRegions in
                    store.setSelection(keys, pdfRegions: pdfRegions)
                },
                onStroke: { stroke, boardID in store.applyStroke(stroke, boardID: boardID, api: api) },
                onMoveSelection: { keys, delta in store.moveSelection(keys, by: delta, api: api) },
                onResizeTextObject: { key, size in store.resizeTextObject(key, to: size, api: api) },
                onDelete: { store.deleteSelection($0, api: api) },
                onMoveBoard: { boardID, delta in store.moveBoard(boardID: boardID, by: delta, api: api) },
                onUndo: { store.undo(api: api) },
                onRedo: { store.redo(api: api) }
            )
            .ignoresSafeArea(edges: .bottom)

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CanvasTool.allCases, id: \.self) { tool in
                            WorkspaceToolButton(tool: tool, selected: activeTool == tool) { activeTool = tool }
                        }
                    }
                }
                Divider().frame(height: 28)
                Text(store.status.userLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button { showStudy = true } label: {
                    Label("Study", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!LectureStudyRouting.isAvailable(
                    selectedBoardIDs: selectedBoardIDs
                ))
                Button { showImporter = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Add Whiteboard")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Button("") { store.undo(api: api) }
                .keyboardShortcut("z", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0.001)
            Button("") { store.redo(api: api) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .frame(width: 0, height: 0).opacity(0.001)
        }
    }

    private var studyBoardID: String? {
        if selectedBoardIDs.count == 1 { return selectedBoardIDs.first }
        return nil
    }

    private var selectedBoardIDs: Set<String> { Set(store.selectedKeys.map(\.boardID)) }

    private var selectedObjectIDsByBoard: [String: [String]] {
        Dictionary(grouping: store.selectedKeys, by: \.boardID)
            .mapValues { keys in Array(Set(keys.map(\.objectID))).sorted() }
    }

    private var activeUnitLabel: String {
        store.workspace?.items.first(where: { $0.boardID == store.activeBoardID })?.unitLabel ?? "No Unit"
    }

}

enum LectureStudyRouting {
    static func isAvailable(selectedBoardIDs: Set<String>) -> Bool {
        !selectedBoardIDs.isEmpty
    }
}

private struct LectureNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let unitLabel: String
    let onAdd: (String) -> Void
    @State private var markdown = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("This note will stay with the active whiteboard and inherit \(unitLabel).")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $markdown)
                    .font(.body)
                    .padding(8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if markdown.isEmpty {
                            Text("Write a study note…")
                                .foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(20)
            .navigationTitle("New Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Canvas") { onAdd(markdown) }
                        .disabled(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LectureSelectionStudyView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folderID: String
    let selectedObjectIDsByBoard: [String: [String]]
    @State private var question = ""
    @State private var loading = false
    @State private var result: StudyInteractionResponse?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if loading {
                    ProgressView("Connecting the selected whiteboards…")
                } else if let interaction = result?.interaction {
                    Text(interaction.title ?? "Across this lecture").font(.title2.bold())
                    ScrollView {
                        StudyContentView(source: interaction.answer ?? "No explanation was returned.",
                                         maximumWidth: 700)
                    }
                } else {
                    Image(systemName: "rectangle.3.group.bubble.left")
                        .font(.largeTitle).foregroundStyle(.tint)
                    Text("Explain across whiteboards").font(.title2.bold())
                    Text("The selected regions stay owned by their original whiteboards. V-Board will connect only this evidence across the lecture.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .frame(maxWidth: 560)
                    TextField("Optional question", text: $question)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 560)
                    Button("Explain Selection") { explain() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedObjectIDsByBoard.count < 2 || selectedObjectIDsByBoard.count > 8)
                }
                if selectedObjectIDsByBoard.count > 8 {
                    Text("Select content from up to eight whiteboards at a time.").foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding(28)
            .navigationTitle("Study Across Boards")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func explain() {
        loading = true; error = nil
        Task {
            do {
                result = try await api.explainLectureSelection(
                    folderID: folderID,
                    selectedObjectIDsByBoard: selectedObjectIDsByBoard,
                    question: question
                )
                loading = false
            } catch {
                loading = false
                self.error = "AI is temporarily unavailable. Your whiteboards are still saved."
            }
        }
    }
}

private struct WorkspaceToolButton: View {
    let tool: CanvasTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(title)
        .help(title)
    }

    private var title: String {
        switch tool {
        case .navigation: return "Hand"
        case .objectEraser: return "Erase"
        default: return tool.rawValue.capitalized
        }
    }

    private var icon: String {
        switch tool {
        case .navigation: return "hand.draw"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .select: return "cursorarrow"
        case .lasso: return "lasso"
        case .objectEraser: return "eraser"
        }
    }
}

private struct LectureNavigatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LectureWorkspaceStore
    let api: APIClient

    private var sections: [(String, [WorkspaceBoardItem])] {
        guard let items = store.workspace?.items else { return [] }
        let grouped = Dictionary(grouping: items.sorted { $0.createdAt < $1.createdAt }, by: \.unitLabel)
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "No Unit" { return false }
            if rhs == "No Unit" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { section in
                    Section(section.0.uppercased()) {
                        ForEach(section.1) { item in
                            Button {
                                store.setActiveBoard(item.boardID, api: api, requestFocus: true)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).foregroundStyle(.primary)
                                        Text(dateLabel(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.boardID == store.activeBoardID {
                                        Image(systemName: "location.fill").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .contextMenu {
                                Button("No Unit") { store.setUnit(boardID: item.boardID, label: "No Unit", number: nil, api: api) }
                                ForEach(1...12, id: \.self) { number in
                                    Button("Unit \(number)") {
                                        store.setUnit(boardID: item.boardID, label: "Unit \(number)", number: number, api: api)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lecture Navigator")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func dateLabel(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
