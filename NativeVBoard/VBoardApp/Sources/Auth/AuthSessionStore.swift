import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct AccountUser: Codable, Equatable, Sendable {
    let id: String
    let displayName: String?
    let email: String?
}

struct AuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var accessExpiresAt: Double
    var refreshExpiresAt: Double
    var appleUserIdentifier: String?
}

struct AuthEnvelope: Codable, Sendable {
    let user: AccountUser
    var session: AuthCredentials
    let debug: Bool?
}

struct AccountEnvelope: Codable, Sendable { let user: AccountUser }

struct AppleSignInPayload: Encodable, Sendable {
    let identityToken: String
    let authorizationCode: String
    let nonce: String
    let user: String
    let givenName: String?
    let familyName: String?
    let email: String?
    let deviceName: String
}

enum AuthState: Equatable {
    case resolving
    case signedOut
    case authenticating
    case signedIn(AccountUser)
    case failed(String)
}

enum AuthStoreError: LocalizedError {
    case invalidAppleCredential
    case randomGeneration

    var errorDescription: String? {
        switch self {
        case .invalidAppleCredential: return "Apple did not provide a valid sign-in credential. Please try again."
        case .randomGeneration: return "V-Board could not securely begin sign in. Please try again."
        }
    }
}

enum SignInNonce {
    static func make(length: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AuthStoreError.randomGeneration
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum LocalAccountNamespace {
    private(set) static var value = "signed-out"

    static func activate(_ userID: String) {
        value = SHA256.hash(data: Data(userID.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func clear() { value = "signed-out" }
}

final class AuthKeychain {
    private let service: String
    private let account = "current-vboard-session"

    init(service: String = Bundle.main.bundleIdentifier ?? "com.vboard.ipad") {
        self.service = service
    }

    func load() -> AuthCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    func save(_ credentials: AuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as [String: Any]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = baseQuery
            attributes.forEach { insertion[$0.key] = $0.value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw APIError.transport("V-Board could not securely save the session.")
            }
        } else if status != errSecSuccess {
            throw APIError.transport("V-Board could not securely update the session.")
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

@MainActor
final class AuthSessionStore: ObservableObject {
    @Published private(set) var state: AuthState = .resolving
    private(set) var rawNonce: String?
    private var expectedState: String?

    let api: APIClient
    private let keychain: AuthKeychain

    init(api: APIClient = .shared, keychain: AuthKeychain = AuthKeychain()) {
        self.api = api
        self.keychain = keychain
        api.onCredentialsChanged = { [weak self] credentials in
            guard let self else { return }
            if let credentials { try? self.keychain.save(credentials) }
            else { self.keychain.clear() }
        }
    }

    func resolveLaunchSession() async {
        guard let credentials = keychain.load(), credentials.refreshExpiresAt > Date().timeIntervalSince1970 else {
            keychain.clear()
            api.install(credentials: nil)
            state = .signedOut
            return
        }
        if let appleUser = credentials.appleUserIdentifier {
            let credentialState = await appleCredentialState(for: appleUser)
            guard credentialState == .authorized else {
                await signOut(revokeServerSession: true)
                return
            }
        }
        api.install(credentials: credentials)
        do {
            state = .signedIn(try await api.currentAccount())
            if case .signedIn(let user) = state { LocalAccountNamespace.activate(user.id) }
        } catch {
            api.install(credentials: nil)
            keychain.clear()
            state = .signedOut
        }
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let nonce = try SignInNonce.make()
            let state = try SignInNonce.make(length: 24)
            rawNonce = nonce
            expectedState = state
            request.requestedScopes = [.fullName, .email]
            request.nonce = SignInNonce.hash(nonce)
            request.state = state
            self.state = .authenticating
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let codeData = credential.authorizationCode,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let authorizationCode = String(data: codeData, encoding: .utf8),
                  let nonce = rawNonce,
                  credential.state == expectedState else {
                throw AuthStoreError.invalidAppleCredential
            }
            let payload = AppleSignInPayload(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce,
                user: credential.user,
                givenName: credential.fullName?.givenName,
                familyName: credential.fullName?.familyName,
                email: credential.email,
                deviceName: UIDevice.current.name
            )
            var envelope = try await api.authenticateWithApple(payload)
            envelope.session.appleUserIdentifier = credential.user
            try keychain.save(envelope.session)
            api.install(credentials: envelope.session)
            LocalAccountNamespace.activate(envelope.user.id)
            state = .signedIn(envelope.user)
            rawNonce = nil
            expectedState = nil
        } catch let error as ASAuthorizationError where error.code == .canceled {
            state = .signedOut
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    func signInAsSimulatorTestUser(_ name: String = "simulator") async {
        state = .authenticating
        do {
            let envelope = try await api.debugAuthentication(testUser: name)
            try keychain.save(envelope.session)
            api.install(credentials: envelope.session)
            LocalAccountNamespace.activate(envelope.user.id)
            state = .signedIn(envelope.user)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
    #endif

    func signOut(revokeServerSession: Bool = true) async {
        if revokeServerSession { try? await api.logout() }
        api.install(credentials: nil)
        keychain.clear()
        LocalAccountNamespace.clear()
        state = .signedOut
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        api.install(credentials: nil)
        keychain.clear()
        LocalAccountNamespace.clear()
        state = .signedOut
    }

    func returnToSignIn() { state = .signedOut }

    private func appleCredentialState(for user: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: user) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}
