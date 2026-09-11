import Foundation
import CryptoKit

enum APIError: LocalizedError {
    case invalidBaseURL
    case transport(String)
    case authenticationExpired
    case forbidden
    case notFound
    case server(status: Int, message: String, retryable: Bool)
    case conflict(EditorState)
    case workspaceConflict(LectureWorkspace)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "The V-Board server URL is invalid."
        case .transport(let detail), .decoding(let detail): return detail
        case .authenticationExpired: return "Your session expired. Sign in again."
        case .forbidden: return "You don’t have permission to access this content."
        case .notFound: return "The requested V-Board content is no longer available."
        case .server(_, let message, _): return message
        case .conflict: return "This board changed elsewhere. Reload before saving."
        case .workspaceConflict: return "This lecture layout changed elsewhere. Reload before saving."
        }
    }
}

enum AuthSessionUpdateReason: String, Sendable {
    case restore
    case appleLogin
    case debugLogin
    case refresh
    case logout
    case sessionExpired
}

#if DEBUG
enum DebugAPIEnvironment: String, CaseIterable, Identifiable {
    case production
    case localDevelopment
    case staging

    var id: String { rawValue }
    var title: String {
        switch self {
        case .production: return "Production"
        case .localDevelopment: return "Local Development"
        case .staging: return "Staging"
        }
    }

    var baseURL: URL {
        switch self {
        case .production:
            return URL(string: "https://chsinteract.com")!
        case .localDevelopment:
            return URL(string: "http://127.0.0.1:5000")!
        case .staging:
            let configured = ProcessInfo.processInfo.environment["VBoardStagingBaseURL"]
                ?? "https://staging.chsinteract.com"
            return URL(string: configured)!
        }
    }

    var allowsTestUser: Bool { self != .production }
}
#endif

@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var baseURL: URL
    private let diagnostics: ((String) -> Void)?
    private let sourceAssetCache: SourceAssetCache
    private var credentials: AuthCredentials?
    private var refreshTask: Task<AuthCredentials?, Error>?
    private(set) var accessTokenGeneration = 0
    private var sourceAssetTasks: [String: Task<Data, Error>] = [:]
    private(set) var hasInstalledCredentials = false
    #if DEBUG
    @Published private(set) var debugEnvironment: DebugAPIEnvironment
    #endif
    var onCredentialsChanged: ((AuthCredentials?) -> Void)?
    var onAuthenticationExpired: (() -> Void)?

    init(baseURL: URL? = nil, session: URLSession = .shared,
         diagnostics: ((String) -> Void)? = nil,
         sourceAssetCache: SourceAssetCache = SourceAssetCache()) {
        // The bundled HTTPS endpoint is the production default. A Run-scheme
        // environment value remains available for a local Flask development server.
        let configured = ProcessInfo.processInfo.environment["VBoardAPIBaseURL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "VBoardAPIBaseURL") as? String
            ?? "https://chsinteract.com"
        self.baseURL = baseURL ?? URL(string: configured)!
        #if DEBUG
        if self.baseURL.host == "127.0.0.1" || self.baseURL.host == "localhost" {
            self.debugEnvironment = .localDevelopment
        } else if self.baseURL.host == URL(string: "https://chsinteract.com")?.host {
            self.debugEnvironment = .production
        } else {
            self.debugEnvironment = .staging
        }
        #endif
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.diagnostics = diagnostics
        self.sourceAssetCache = sourceAssetCache
    }

    func install(credentials: AuthCredentials?, reason: AuthSessionUpdateReason = .restore) {
        self.credentials = credentials
        hasInstalledCredentials = !(credentials?.accessToken.isEmpty ?? true)
        accessTokenGeneration += 1
        onCredentialsChanged?(credentials)
        debugLog("AUTH SESSION UPDATED reason=\(reason.rawValue) hasAccessToken=\(!(credentials?.accessToken.isEmpty ?? true)) hasRefreshToken=\(!(credentials?.refreshToken.isEmpty ?? true)) generation=\(accessTokenGeneration)")
    }

    func authenticateWithApple(_ payload: AppleSignInPayload) async throws -> AuthEnvelope {
        var request = try request(path: "/api/auth/apple", method: "POST")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await data(for: request, authenticated: false,
                                                  refreshOnUnauthorized: false)
        try validate(response, data: data)
        return try decoder.decode(AuthEnvelope.self, from: data)
    }

    #if DEBUG
    func selectDebugEnvironment(_ environment: DebugAPIEnvironment) {
        baseURL = environment.baseURL
        debugEnvironment = environment
        debugLog("DEBUG API ENVIRONMENT changed=\(environment.rawValue) baseURL=\(baseURL.absoluteString)")
    }

    func debugAuthentication(testUser: String) async throws -> AuthEnvelope {
        guard debugEnvironment.allowsTestUser else {
            throw APIError.forbidden
        }
        var request = try request(path: "/api/auth/debug", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["testUser": testUser])
        let (data, response) = try await data(for: request, authenticated: false,
                                                  refreshOnUnauthorized: false)
        try validate(response, data: data)
        return try decoder.decode(AuthEnvelope.self, from: data)
    }
    #endif

    func currentAccount() async throws -> AccountUser {
        let envelope: AccountEnvelope = try await get("/api/auth/me", label: "account")
        return envelope.user
    }

    func logout() async throws {
        let request = try request(path: "/api/auth/logout", method: "POST")
        let (data, response) = try await data(for: request, refreshOnUnauthorized: false)
        try validate(response, data: data)
        install(credentials: nil, reason: .logout)
    }

    func deleteAccount() async throws {
        let request = try request(path: "/api/account", method: "DELETE")
        let (data, response) = try await data(for: request, refreshOnUnauthorized: false)
        try validate(response, data: data)
        install(credentials: nil, reason: .logout)
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
    func moveBoard(id: String, toFolderID folderID: String?) async throws -> LibraryBoard {
        var request = try request(path: "/api/boards/\(id)", method: "PATCH")
        let destination: Any = folderID ?? NSNull()
        request.httpBody = try JSONSerialization.data(withJSONObject: ["folder_id": destination])
        let (data, response) = try await data(for: request); try validate(response, data: data)
        struct Envelope: Decodable { let board: LibraryBoard }
        return try decoder.decode(Envelope.self, from: data).board
    }
    func createBlankBoard(folderID: String, name: String? = nil) async throws -> LibraryBoard {
        var request = try request(path: "/api/boards/blank", method: "POST")
        var payload: [String: Any] = ["folder_id": folderID]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["name"] = name
        }
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

    func authorizedAsset(path: String) async throws -> Data {
        let request = try request(path: path, accept: "image/*,application/pdf")
        let (data, response) = try await data(for: request)
        try validate(response, data: data)
        return data
    }

    func cachedBoardAsset(boardID: String, path: String, version: String? = nil) async throws -> Data {
        let namespace = LocalAccountNamespace.value
        let key = SourceAssetCache.key(accountNamespace: namespace, boardID: boardID,
                                       path: path, version: version)
        if let cached = try await sourceAssetCache.data(forKey: key,
                                                        accountNamespace: namespace,
                                                        boardID: boardID) {
            #if DEBUG
            debugLog("SOURCE ASSET CACHE HIT board=\(boardID) path=\(path) bytes=\(cached.count)")
            #endif
            return cached
        }
        if let task = sourceAssetTasks[key] { return try await task.value }
        let task = Task<Data, Error> { @MainActor [weak self] in
            guard let self else { throw APIError.transport("The asset request was cancelled.") }
            return try await self.authorizedAsset(path: path)
        }
        sourceAssetTasks[key] = task
        defer { sourceAssetTasks.removeValue(forKey: key) }
        let data = try await task.value
        try await sourceAssetCache.store(data, forKey: key,
                                         accountNamespace: namespace,
                                         boardID: boardID)
        #if DEBUG
        debugLog("SOURCE ASSET CACHE STORE board=\(boardID) path=\(path) bytes=\(data.count)")
        #endif
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

    func importPDF(data pdfData: Data, filename: String, folderID: String? = nil,
                   name: String? = nil, sourceKind: BoardSourceKind = .freeformPDF) async throws -> PDFImportResponse {
        let boundary = "VBoard-PDF-\(UUID().uuidString)"
        var request = try request(path: "/api/import/pdf", method: "POST", accept: "application/json")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let folderID { field("folder_id", folderID) }
        if let name { field("name", name) }
        field("source_kind", sourceKind.rawValue)
        let safeFilename = filename.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"pdf\"; filename=\"\(safeFilename)\"\r\nContent-Type: application/pdf\r\n\r\n".utf8))
        body.append(pdfData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        request.timeoutInterval = 120
        let (data, response) = try await self.data(for: request)
        try validate(response, data: data)
        do { return try decoder.decode(PDFImportResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the imported PDF response.") }
    }

    func processCorners(boardID: String, corners: [[Double]],
                        normalizedCorners: [[String: Double]]? = nil) async throws -> UploadResponse {
        var request = try request(path: "/board/\(boardID)/corners", method: "POST")
        var payload: [String: Any] = ["corners": corners]
        if let normalizedCorners { payload["normalized_corners"] = normalizedCorners }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        #if DEBUG
        debugLog("CORNER REQUEST START board=\(boardID) sourcePixels=\(corners) normalized=\(normalizedCorners ?? [])")
        #endif
        let (data, response) = try await data(for: request)
        #if DEBUG
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data.prefix(8_192), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<non-UTF8>"
            debugLog("CORNER REQUEST FAILED board=\(boardID) status=\(http.statusCode) sourcePixels=\(corners) responseBody=\(body)")
        }
        #endif
        try validate(response, data: data)
        do { return try decoder.decode(UploadResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the processed board response.") }
    }

    func deleteBoard(id: String) async throws { let request = try request(path: "/api/boards/\(id)", method: "DELETE"); let (data, response) = try await data(for: request); try validate(response, data: data) }

    func explain(request payload: BoardStudyExplainRequest) async throws -> StudyInteractionResponse {
        let path = "/api/boards/\(payload.boardID)/study/explain"
        var request = try request(path: path, method: "POST")
        request.httpBody = try encoder.encode(payload)
        let started = Date().timeIntervalSinceReferenceDate
        debugLog("STUDY REQUEST START url=\(request.url?.absoluteString ?? path) board=\(payload.boardID) action=\(payload.action) requestID=\(payload.requestId) canonicalIDs=\(payload.selectedObjectIds) localBBox=\(payload.selectionBBox)")
        let (data, response) = try await data(for: request)
        debugLog("AI TIMELINE request=\(payload.requestId) stage=responseReceived status=\((response as? HTTPURLResponse)?.statusCode ?? -1) bytes=\(data.count) milliseconds=\((Date().timeIntervalSinceReferenceDate - started) * 1_000)")
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            debugStudyFailure(request: request, payload: payload,
                              status: http.statusCode, data: data)
        }
        try validate(response, data: data)
        do { return try decoder.decode(StudyInteractionResponse.self, from: data) }
        catch { throw APIError.decoding("Could not decode the study response.") }
    }

    func recognizeGraph(request payload: GraphRecognitionRequest) async throws
        -> GraphRecognitionEnvelope {
        let path = "/api/boards/\(payload.boardID)/study/graph-recognition"
        return try await performGraphRecognition(
            path: path,
            payload: payload,
            requestID: payload.requestId,
            sanitizedJSON: payload.sanitizedJSON,
            sourceDescription: "board=\(payload.boardID) canonicalIDs=\(payload.selection.selectedObjectIds) localBBox=\(payload.selection.bbox)"
        )
    }

    func recognizeGraph(request payload: LectureGraphRecognitionRequest) async throws
        -> GraphRecognitionEnvelope {
        let path = "/api/folders/\(payload.folderID)/study/graph-recognition"
        let sources = payload.boards.map {
            "\($0.boardId):ids=\($0.selectedObjectIds):bbox=\($0.bbox)"
        }.joined(separator: ";")
        return try await performGraphRecognition(
            path: path,
            payload: payload,
            requestID: payload.requestId,
            sanitizedJSON: payload.sanitizedJSON,
            sourceDescription: "lecture=\(payload.folderID) primary=\(payload.primaryBoardId) boards=[\(sources)]"
        )
    }

    func recognizeGraph(target: GraphRecognitionTarget,
                        requestID: String = BoardStudyExplainRequest.makeRequestID()) async throws
        -> GraphRecognitionEnvelope {
        switch target {
        case .board(let selection):
            return try await recognizeGraph(request: GraphRecognitionRequest.make(
                selection: selection, requestID: requestID
            ))
        case .lecture(let lecture):
            return try await recognizeGraph(request: LectureGraphRecognitionRequest(
                target: lecture, requestID: requestID
            ))
        }
    }

    private func performGraphRecognition<Payload: Encodable>(
        path: String,
        payload: Payload,
        requestID: String,
        sanitizedJSON: String,
        sourceDescription: String
    ) async throws -> GraphRecognitionEnvelope {
        var request = try request(path: path, method: "POST")
        request.httpBody = try encoder.encode(payload)
        let started = Date().timeIntervalSinceReferenceDate
        debugLog("GRAPH RECOGNITION START url=\(request.url?.absoluteString ?? path) requestID=\(requestID) \(sourceDescription)")
        let (data, response) = try await data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        debugLog("GRAPH RECOGNITION RESPONSE request=\(requestID) status=\(status) bytes=\(data.count) milliseconds=\((Date().timeIntervalSinceReferenceDate - started) * 1_000)")
        #if DEBUG
        if !(200..<300).contains(status) {
            let responseBody = String(data: data.prefix(8_192), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ") ?? "<non-UTF8 response>"
            debugLog("GRAPH RECOGNITION FAILED url=\(request.url?.absoluteString ?? path) status=\(status) outgoingJSON=\(sanitizedJSON) responseBody=\(responseBody) \(sourceDescription) requestID=\(requestID)")
        }
        #endif
        try validate(response, data: data)
        do {
            let envelope = try decoder.decode(GraphRecognitionEnvelope.self, from: data)
            guard envelope.requestId == requestID,
                  envelope.result.requestID == requestID else {
                throw APIError.decoding("The graph recognition response did not match this request.")
            }
            _ = try envelope.result.validated()
            return envelope
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decoding("Could not decode the graph recognition response.")
        }
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
        let started = Date().timeIntervalSinceReferenceDate
        let (data, response) = try await data(for: request)
        debugLog("AI TIMELINE request=\(payload["requestId"] ?? "unknown") stage=followUpResponse action=\(action) status=\((response as? HTTPURLResponse)?.statusCode ?? -1) bytes=\(data.count) milliseconds=\((Date().timeIntervalSinceReferenceDate - started) * 1_000)")
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
        struct Envelope: Decodable {
            let studyGuide: StudyGuide?
            enum CodingKeys: String, CodingKey { case studyGuide = "study_guide" }
        }
        do { return try decoder.decode(Envelope.self, from: data).studyGuide }
        catch { throw APIError.decoding("Could not decode the generated study guide.") }
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

    private func data(for request: URLRequest,
                      authenticated: Bool = true,
                      refreshOnUnauthorized: Bool = true) async throws -> (Data, URLResponse) {
        do {
            // A URLRequest is only a metadata template. Authentication is applied
            // immediately before transmission so a request created before a login
            // or concurrent refresh can never retain a stale bearer credential.
            let firstRequest = try rebuiltRequest(from: request, authenticated: authenticated,
                                                  isRetry: false)
            let firstGeneration = accessTokenGeneration
            let first = try await session.data(for: firstRequest)
            logAuthResponse(for: firstRequest, response: first.1)
            guard refreshOnUnauthorized,
                  authenticated,
                  (first.1 as? HTTPURLResponse)?.statusCode == 401,
                  !isNonRefreshingAuthPath(request.url?.path) else {
                return first
            }
            if accessTokenGeneration == firstGeneration {
                guard try await refreshSession() != nil else { return first }
            } else {
                debugLog("AUTH REFRESH REUSED path=\(request.url?.path ?? "<missing>") requestGeneration=\(firstGeneration) currentGeneration=\(accessTokenGeneration)")
            }
            // Rebuild from the original metadata rather than resending or copying
            // the first URLRequest. This reads the newly rotated access token and
            // makes the generation change observable in DEBUG diagnostics.
            let retryRequest = try rebuiltRequest(from: request, authenticated: true,
                                                  isRetry: true)
            let retryGeneration = accessTokenGeneration
            let retry = try await session.data(for: retryRequest)
            logAuthResponse(for: retryRequest, response: retry.1)
            if (retry.1 as? HTTPURLResponse)?.statusCode == 401,
               accessTokenGeneration == retryGeneration {
                invalidateAuthentication()
            }
            return retry
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport("Could not reach V-Board: \(error.localizedDescription)")
        }
    }

    private func rebuiltRequest(from template: URLRequest,
                                authenticated: Bool,
                                isRetry: Bool) throws -> URLRequest {
        guard let url = template.url else { throw APIError.invalidBaseURL }
        var rebuilt = URLRequest(url: url,
                                 cachePolicy: template.cachePolicy,
                                 timeoutInterval: template.timeoutInterval)
        rebuilt.httpMethod = template.httpMethod
        rebuilt.httpBody = template.httpBody
        for (field, value) in template.allHTTPHeaderFields ?? [:]
        where field.caseInsensitiveCompare("Authorization") != .orderedSame {
            rebuilt.setValue(value, forHTTPHeaderField: field)
        }
        let token = authenticated ? credentials?.accessToken : nil
        if let token, !token.isEmpty {
            rebuilt.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        debugLog("AUTH REQUEST method=\(rebuilt.httpMethod ?? "GET") path=\(url.path) authorizationHeaderPresent=\(rebuilt.value(forHTTPHeaderField: "Authorization") != nil) accessTokenAvailable=\(!(token?.isEmpty ?? true)) accessTokenGeneration=\(accessTokenGeneration) isRetry=\(isRetry)")
        return rebuilt
    }

    private func isNonRefreshingAuthPath(_ path: String?) -> Bool {
        path == "/api/auth/apple" || path == "/api/auth/refresh"
    }

    private func logAuthResponse(for request: URLRequest, response: URLResponse) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        debugLog("AUTH RESPONSE path=\(request.url?.path ?? "<missing>") status=\(status)")
    }

    private func invalidateAuthentication() {
        guard credentials != nil else { return }
        install(credentials: nil, reason: .sessionExpired)
        onAuthenticationExpired?()
    }

    private func refreshSession() async throws -> AuthCredentials? {
        if let refreshTask { return try await refreshTask.value }
        let task: Task<AuthCredentials?, Error> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            return try await self.performRefreshSession()
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefreshSession() async throws -> AuthCredentials? {
        guard let current = credentials,
              current.refreshExpiresAt > Date().timeIntervalSince1970 else {
            invalidateAuthentication()
            return nil
        }
        let startingGeneration = accessTokenGeneration
        var refreshRequest = try request(path: "/api/auth/refresh", method: "POST")
        refreshRequest.httpBody = try encoder.encode(["refreshToken": current.refreshToken])
        let outgoing = try rebuiltRequest(from: refreshRequest, authenticated: false,
                                          isRetry: false)
        let (data, response) = try await session.data(for: outgoing)
        logAuthResponse(for: outgoing, response: response)
        guard accessTokenGeneration == startingGeneration else {
            return credentials
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              var envelope = try? decoder.decode(AuthEnvelope.self, from: data),
              !envelope.session.accessToken.isEmpty,
              !envelope.session.refreshToken.isEmpty else {
            invalidateAuthentication()
            return nil
        }
        envelope.session.appleUserIdentifier = current.appleUserIdentifier
        install(credentials: envelope.session, reason: .refresh)
        return envelope.session
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("The server returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ServerError.self, from: data).error) ?? "Server request failed (HTTP \(http.statusCode))."
            if http.statusCode == 401 { throw APIError.authenticationExpired }
            if http.statusCode == 403 { throw APIError.forbidden }
            if http.statusCode == 404 { throw APIError.notFound }
            throw APIError.server(status: http.statusCode, message: message, retryable: http.statusCode >= 500)
        }
    }

    private func debugResponse(path: String, method: String, response: URLResponse, data: Data) {
        #if DEBUG
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "(missing)"
        debugLog("BOARD RESPONSE endpoint=\(path) method=\(method) status=\(http?.statusCode ?? -1) contentType=\(contentType) bytes=\(data.count)")
        // Response bodies can contain handwritten work, study content, and
        // lecture metadata. Status, MIME type, and byte count are sufficient
        // for transport diagnostics; never echo user content into logs.
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

    private func debugStudyFailure(request: URLRequest,
                                   payload: BoardStudyExplainRequest,
                                   status: Int,
                                   data: Data) {
        #if DEBUG
        let responseBody = String(data: data.prefix(8_192), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ") ?? "<non-UTF8 response>"
        debugLog("STUDY REQUEST FAILED url=\(request.url?.absoluteString ?? "<missing>") status=\(status) outgoingJSON=\(payload.sanitizedJSON) responseBody=\(responseBody) selectedBoardID=\(payload.boardID) selectedCanonicalIDs=\(payload.selectedObjectIds) localBBox=\(payload.selectionBBox) action=\(payload.action) requestID=\(payload.requestId)")
        #endif
    }

    private func debugLog(_ message: String) {
        diagnostics?(message)
        #if DEBUG
        print("[VBoard] \(message)")
        #endif
    }
}

private struct ServerError: Decodable { let error: String }

actor SourceAssetCache {
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory,
                                                     in: .userDomainMask)[0]
            .appendingPathComponent("VBoardSourceAssets", isDirectory: true)
    }

    static func key(accountNamespace: String, boardID: String,
                    path: String, version: String?) -> String {
        let material = [accountNamespace, boardID, path, version ?? "immutable"]
            .joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func data(forKey key: String, accountNamespace: String, boardID: String) throws -> Data? {
        let url = try fileURL(forKey: key, accountNamespace: accountNamespace,
                              boardID: boardID, create: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func store(_ data: Data, forKey key: String,
               accountNamespace: String, boardID: String) throws {
        let url = try fileURL(forKey: key, accountNamespace: accountNamespace,
                              boardID: boardID, create: true)
        try data.write(to: url, options: .atomic)
    }

    private func fileURL(forKey key: String, accountNamespace: String,
                         boardID: String, create: Bool) throws -> URL {
        let safeNamespace = sanitized(accountNamespace)
        let safeBoardID = sanitized(boardID)
        let directory = root.appendingPathComponent(safeNamespace, isDirectory: true)
            .appendingPathComponent(safeBoardID, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("\(key).asset", isDirectory: false)
    }

    private func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }
        return String(result.joined().prefix(96))
    }
}
