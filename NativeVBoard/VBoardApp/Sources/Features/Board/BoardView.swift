import SwiftUI

struct BoardView: View {
    @EnvironmentObject private var api: APIClient
    let board: LibraryBoard
    @State private var state: BoardLoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading: ProgressView("Opening board…")
            case .ready(let document, let editor): NativeCanvasView(document: document, camera: editor.viewport)
            case .failed(let message): ContentUnavailableView("Couldn’t open board", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
    private func load() async {
        do {
            // Validate the canonical board metadata route first. The SVG and
            // editor routes remain separate so the board stays isolated.
            async let metadata = api.board(id: board.id)
            async let svg = api.professorSVG(id: board.id)
            async let editor = api.editor(id: board.id)
            _ = try await metadata
            let document = try SVGDocument.parse(await svg)
            state = .ready(document, try await editor)
        } catch { state = .failed(error.localizedDescription) }
    }
}

private enum BoardLoadState { case loading, ready(SVGDocument, EditorState), failed(String) }
