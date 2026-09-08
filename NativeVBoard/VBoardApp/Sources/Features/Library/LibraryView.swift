import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var api: APIClient
    @State private var library: LibraryResponse?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let library {
                    List {
                        if !library.folders.isEmpty {
                            Section("Lectures") { ForEach(library.folders) { folder in Text(folder.name).foregroundStyle(.secondary) } }
                        }
                        Section("Whiteboards") {
                            ForEach(library.boards) { board in
                                NavigationLink(value: board) {
                                    VStack(alignment: .leading) { Text(board.name); Text(board.status.capitalized).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    .navigationDestination(for: LibraryBoard.self) { BoardView(board: $0) }
                } else if let error { ContentUnavailableView("Couldn’t load library", systemImage: "wifi.exclamationmark", description: Text(error)).toolbar { Button("Retry") { load() } } }
                else { ProgressView("Loading V-Board library…") }
            }
            .navigationTitle("V-Board")
            .toolbar { Button { load() } label: { Image(systemName: "arrow.clockwise") } }
            .task { load() }
        }
    }
    private func load() { Task { do { library = try await api.library(); error = nil } catch { self.error = error.localizedDescription } } }
}
