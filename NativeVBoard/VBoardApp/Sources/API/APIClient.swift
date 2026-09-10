import Foundation

enum APIError: LocalizedError {
    case invalidBaseURL
    case transport(String)
    case server(status: Int, message: String, retryable: Bool)
    case conflict(EditorState)
    case workspaceConflict(LectureWorkspace)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "The V-Board server URL is invalid."
        case .transport(let detail), .decoding(let detail): return detail
        case .server(_, let message, _): return message
        case .conflict: return "This board changed elsewhere. Reload before saving."
        case .workspaceConflict: return "This lecture layout changed elsewhere. Reload before saving."
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
    func lecture(id: String) async throws -> LectureResponse { try await get("/api/folders/\(id)/lecture", label: "lecture") }
    func lectureWorkspace(id: String) async throws -> LectureWorkspace {
        let envelope: LectureWorkspaceEnvelope = try await get("/api/folders/\(id)/workspace", label: "lecture workspace")
        return envelope.workspace
    }
    func saveLectureWorkspace(_ workspace: LectureWorkspace, folderID: String) async throws -> LectureWorkspace {
        var request = try request(path: "/api/folders/\(folderID)/workspace", method: "PUT")
        request.httpBody = try encoder.encode(LectureWorkspaceEnvelope(workspace: workspace))
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409,
           let envelope = try? decoder.decode(LectureWorkspaceEnvelope.self, from: data) {
            throw APIError.workspaceConflict(envelope.workspace)
        }
        try validate(response, data: data)
        do { return try decoder.decode(LectureWorkspaceEnvelope.self, from: data).workspace }
        catch { throw APIError.decoding("Could not decode the saved lecture workspace.") }
    }

    func resolvedURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
    func createLecture(name: String) async throws -> LectureFolder {
        var request = try request(path: "/api/folders", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, response) = try await data(for: request); try validate(response, data: data)
        struct Envelope: Decodable { let folder: LectureFolder }
        return try decoder.decode(Envelope.self, from: data).folder
    }
    func renameLecture(id: String, name: String) async throws -> LectureFolder {
        var request = try request(path: "/api/folders/\(id)", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, response) = try await data(for: request); try validate(response, data: data)
        struct Envelope: Decodable { let folder: LectureFolder }
        return try decoder.decode(Envelope.self, from: data).folder
    }
    func deleteLecture(id: String, recursive: Bool = false) async throws {
        let suffix = recursive ? "?recursive=true" : ""
        let request = try request(path: "/api/folders/\(id)\(suffix)", method: "DELETE")
        let (data, response) = try await data(for: request); try validate(response, data: data)
    }
    func updateBoard(id: String, name: String? = nil, folderID: String? = nil) async throws -> LibraryBoard {
        var request = try request(path: "/api/boards/\(id)", method: "PATCH")
        var payload: [String: Any] = [:]
        if let name { payload["name"] = name }
        if let folderID { payload["folder_id"] = folderID }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await data(for: request); try validate(response, data: data)
        struct Envelope: Decodable { let board: LibraryBoard }
        return try decoder.decode(Envelope.self, from: data).board
    }
    func board(id: String) async throws -> BoardRecord { try await get("/board/\(id)") }
    func editor(id: String) async throws -> EditorState {
        // Flask deliberately wraps this response as {"editor": {...}}.
        // Decode the envelope first; decoding EditorState at the root produces
        // keyNotFound(schema_version), which was the native board blocker.
        let envelope: EditorEnvelope = try await get("/api/boards/\(id)/editor", label: "editor")
        debugLog("EDITOR DECODE SUCCEEDED endpoint=/api/boards/\(id)/editor objects=\(envelope.editor.objects.count) revision=\(envelope.editor.revision)")
        return envelope.editor
    }

    func professorSVG(id: String) async throws -> String {
        // `/board/<id>/svg` is the combined/export route and embeds user ink.
        // The editor must load only immutable pipeline geometry.
        let path = "/boards/\(id)/board.svg"
        let request = try request(path: path, accept: "image/svg+xml")
        let (data, response) = try await data(for: request)
        debugResponse(path: path, method: "GET", response: response, data: data)
        try validate(response, data: data)
        guard let svg = String(data: data, encoding: .utf8) else { throw APIError.decoding("The professor SVG was not UTF-8.") }
        return svg
    }

    func asset(boardID: String, name: String) async throws -> Data {
        let path = "/board/\(boardID)/asset/\(name)"
        let request = try request(path: path, accept: "image/*")
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        return data
    }

    func exportSVG(boardID: String) async throws -> Data {
        let request = try request(path: "/board/\(boardID)/svg", accept: "image/svg+xml")
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        return data
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

    func upload(imageData: Data, filename: String, mimeType: String, folderID: String? = nil, name: String? = nil) async throws -> UploadResponse {
        let boundary = "VBoard-\(UUID().uuidString)"
        var request = try request(path: "/upload", method: "POST", accept: "application/json")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let folderID { field("folder_id", folderID) }
        if let name { field("name", name) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        do { return try decoder.decode(UploadResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the upload response.") }
    }

    func processCorners(boardID: String, corners: [[Double]]) async throws -> UploadResponse {
        var request = try request(path: "/board/\(boardID)/corners", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["corners": corners])
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        do { return try decoder.decode(UploadResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the processed board response.") }
    }

    func deleteBoard(id: String) async throws { let request = try request(path: "/api/boards/\(id)", method: "DELETE"); let (data, response) = try await data(for: request); try validate(response, data: data) }

    func explain(boardID: String, action: String = "explain", selectedText: String = "", selectedObjectIDs: [String] = []) async throws -> StudyInteractionResponse {
        var request = try request(path: "/api/boards/\(boardID)/study/explain", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "selected_text": selectedText, "selected_object_ids": selectedObjectIDs])
        let (data, response) = try await data(for: request); try validate(response, data: data)
        do { return try decoder.decode(StudyInteractionResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the study response.") }
    }

    func followUp(boardID: String, interactionID: String,
                  action: String = "followup", question: String = "") async throws -> StudyInteractionResponse {
        var request = try request(path: "/api/boards/\(boardID)/study/\(interactionID)/followup", method: "POST")
        var payload: [String: Any] = [
            "action": action,
            "requestId": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        ]
        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["question"] = question
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        do { return try decoder.decode(StudyInteractionResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the study follow-up response.") }
    }

    func explainLectureSelection(folderID: String,
                                 selectedObjectIDsByBoard: [String: [String]],
                                 question: String = "") async throws -> StudyInteractionResponse {
        var request = try request(path: "/api/folders/\(folderID)/study/explain-selection", method: "POST")
        let boards = selectedObjectIDsByBoard.keys.sorted().map { boardID in
            ["board_id": boardID, "selected_ids": selectedObjectIDsByBoard[boardID] ?? []] as [String: Any]
        }
        var payload: [String: Any] = [
            "boards": boards,
            "requestId": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        ]
        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["question"] = question
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        do { return try decoder.decode(StudyInteractionResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the lecture study response.") }
    }

    func generateStudyGuide(folderID: String) async throws -> StudyGuide? {
        var request = try request(path: "/api/folders/\(folderID)/study-guide", method: "POST")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await data(for: request); try validate(response, data: data)
        return try decoder.decode([String: StudyGuide].self, from: data)["study_guide"]
    }

    private func get<T: Decodable>(_ path: String, label: String = "JSON") async throws -> T {
        debugLog("BOARD REQUEST START label=\(label) method=GET endpoint=\(path)")
        let request = try request(path: path)
        let (data, response) = try await data(for: request)
        debugResponse(path: path, method: "GET", response: response, data: data)
        try validate(response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch let error as DecodingError {
            logDecodingError(error, endpoint: path, method: "GET", response: response, data: data)
            throw APIError.decoding("Could not decode \(label) response. The server returned an unexpected JSON shape.")
        } catch {
            debugLog("BOARD DECODE FAILED endpoint=\(path) error=\(error)")
            throw APIError.decoding("Could not decode \(label) response.")
        }
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

    private func debugResponse(path: String, method: String, response: URLResponse, data: Data) {
        #if DEBUG
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "(missing)"
        debugLog("BOARD RESPONSE endpoint=\(path) method=\(method) status=\(http?.statusCode ?? -1) contentType=\(contentType) bytes=\(data.count)")
        guard !data.isEmpty else { return }
        if let object = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]), let text = String(data: pretty, encoding: .utf8) {
            debugLog("BOARD RESPONSE BODY endpoint=\(path)\n\(String(text.prefix(4096)))")
        } else if let text = String(data: data, encoding: .utf8) {
            debugLog("BOARD RESPONSE BODY endpoint=\(path)\n\(String(text.prefix(4096)))")
        }
        #endif
    }

    private func logDecodingError(_ error: DecodingError, endpoint: String, method: String, response: URLResponse, data: Data) {
        #if DEBUG
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "(missing)"
        func path(_ codingPath: [CodingKey]) -> String { codingPath.isEmpty ? "root" : codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let context):
            debugLog("BOARD DECODE FAILED endpoint=\(endpoint) method=\(method) status=\(http?.statusCode ?? -1) contentType=\(contentType) bytes=\(data.count) error=keyNotFound key=\(key.stringValue) codingPath=\(path(context.codingPath)) description=\(context.debugDescription) underlying=\(String(describing: context.underlyingError))")
        case .valueNotFound(let type, let context):
            debugLog("BOARD DECODE FAILED endpoint=\(endpoint) method=\(method) status=\(http?.statusCode ?? -1) contentType=\(contentType) bytes=\(data.count) error=valueNotFound expected=\(type) codingPath=\(path(context.codingPath)) description=\(context.debugDescription) underlying=\(String(describing: context.underlyingError))")
        case .typeMismatch(let type, let context):
            debugLog("BOARD DECODE FAILED endpoint=\(endpoint) method=\(method) status=\(http?.statusCode ?? -1) contentType=\(contentType) bytes=\(data.count) error=typeMismatch expected=\(type) codingPath=\(path(context.codingPath)) description=\(context.debugDescription) underlying=\(String(describing: context.underlyingError))")
        case .dataCorrupted(let context):
            debugLog("BOARD DECODE FAILED endpoint=\(endpoint) method=\(method) status=\(http?.statusCode ?? -1) contentType=\(contentType) bytes=\(data.count) error=dataCorrupted codingPath=\(path(context.codingPath)) description=\(context.debugDescription) underlying=\(String(describing: context.underlyingError))")
        @unknown default:
            debugLog("BOARD DECODE FAILED endpoint=\(endpoint) method=\(method) status=\(http?.statusCode ?? -1) contentType=\(contentType) bytes=\(data.count) error=unknownDecodingError description=\(error)")
        }
        #endif
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[VBoard] \(message)")
        #endif
    }
}

private struct ServerError: Decodable { let error: String }
