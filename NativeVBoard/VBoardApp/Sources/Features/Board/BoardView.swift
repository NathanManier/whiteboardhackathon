import SwiftUI

struct BoardView: View {
    @EnvironmentObject private var api: APIClient
    let board: LibraryBoard
    @State private var state: BoardLoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading: ProgressView("Opening board…")
            case .ready(let document, let editor): NativeCanvasView(document: document, camera: editor.viewport, objects: editor.objects, importedTransforms: editor.importedTransforms)
            case .failed(let message): ContentUnavailableView("Couldn’t open board", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
    private func load() async {
        do {
            debug("BOARD OPEN START id=\(board.id)")
            // Validate the canonical board metadata route first. The SVG and
            // editor routes remain separate so the board stays isolated.
            _ = try await api.board(id: board.id)
            debug("BOARD OPEN METADATA SUCCEEDED id=\(board.id)")
            let editor = try await api.editor(id: board.id)
            debug("BOARD OPEN EDITOR SUCCEEDED id=\(board.id) objects=\(editor.objects.count)")
            let source = try await api.professorSVG(id: board.id)
            debug("BOARD OPEN SVG RESPONSE SUCCEEDED id=\(board.id) chars=\(source.utf8.count)")
            let document = try SVGDocument.parse(source)
            debug("BOARD OPEN SVG PARSE SUCCEEDED id=\(board.id) paths=\(document.paths.count)")
            state = .ready(document, editor)
            debug("BOARD OPEN FIRST SCENE READY id=\(board.id)")
        } catch let error as APIError {
            let message: String
            switch error {
            case .transport: message = "Network unavailable. Check your connection and try again."
            case .server(let status, _, _): message = "Couldn’t load board data (HTTP \(status))."
            case .decoding: message = "Couldn’t decode board data returned by the server."
            case .invalidBaseURL: message = "Couldn’t load board data because the server URL is invalid."
            case .conflict: message = "This board changed elsewhere. Reload it before editing."
            }
            state = .failed(message); debug("BOARD OPEN FAILED id=\(board.id) userMessage=\(message) technical=\(error.localizedDescription)")
        } catch {
            state = .failed("Couldn’t parse board artwork."); debug("BOARD OPEN FAILED id=\(board.id) stage=svgParse technical=\(error)")
        }
    }

    private func debug(_ message: String) {
        #if DEBUG
        print("[VBoard] \(message)")
        #endif
    }
}

private enum BoardLoadState { case loading, ready(SVGDocument, EditorState), failed(String) }
