import Foundation

enum APIError: LocalizedError {
    case invalidBaseURL
    case transport(String)
    case server(status: Int, message: String, retryable: Bool)
    case conflict(EditorState)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "The V-Board server URL is invalid."
        case .transport(let detail), .decoding(let detail): return detail
        case .server(_, let message, _): return message
        case .conflict: return "This board changed elsewhere. Reload before saving."
        }
    }
}

@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let baseURL: URL

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        // The bundled HTTPS endpoint is the production default. A Run-scheme
        // environment value remains available for a local Flask development server.
        let configured = ProcessInfo.processInfo.environment["VBoardAPIBaseURL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "VBoardAPIBaseURL") as? String
            ?? "https://chsinteract.com"
        self.baseURL = baseURL ?? URL(string: configured)!
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func library() async throws -> LibraryResponse { try await get("/api/library") }
    func board(id: String) async throws -> BoardRecord { try await get("/board/\(id)") }
    func editor(id: String) async throws -> EditorState { try await get("/api/boards/\(id)/editor") }

    func professorSVG(id: String) async throws -> String {
        let request = try request(path: "/board/\(id)/svg", accept: "image/svg+xml")
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        guard let svg = String(data: data, encoding: .utf8) else { throw APIError.decoding("The professor SVG was not UTF-8.") }
        return svg
    }

    func save(editor: EditorState, boardID: String) async throws -> EditorState {
        var request = try request(path: "/api/boards/\(boardID)/editor", method: "PUT")
        request.httpBody = try encoder.encode(editor)
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            if let envelope = try? decoder.decode(EditorEnvelope.self, from: data) { throw APIError.conflict(envelope.editor) }
        }
        try validate(response, data: data)
        do { return try decoder.decode(EditorEnvelope.self, from: data).editor }
        catch { throw APIError.decoding("Could not decode saved editor state: \(error.localizedDescription)") }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = try request(path: path)
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding("Could not decode server response: \(error.localizedDescription)") }
    }

    private func request(path: String, method: String = "GET", accept: String = "application/json") throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw APIError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw APIError.transport("Could not reach V-Board: \(error.localizedDescription)") }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("The server returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ServerError.self, from: data).error) ?? "Server request failed (HTTP \(http.statusCode))."
            throw APIError.server(status: http.statusCode, message: message, retryable: http.statusCode >= 500)
        }
    }
}

private struct ServerError: Decodable { let error: String }
