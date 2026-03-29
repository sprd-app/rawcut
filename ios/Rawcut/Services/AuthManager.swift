import AuthenticationServices
import Foundation
import Security

@MainActor
final class AuthManager: NSObject, ObservableObject {

    @Published var isAuthenticated: Bool = false
    @Published var userIdentifier: String?
    @Published var displayName: String?

    private static let service = "com.rawcut.app"
    private static let userIDKey = "apple_user_id"
    private static let nameKey = "apple_display_name"
    private static let serverTokenKey = "server_jwt_token"

    private static let backendBaseURL = "https://rawcut-api.wittygrass-ccc95e2e.koreacentral.azurecontainerapps.io"

    override init() {
        super.init()
        restoreSession()
    }

    // MARK: - Auth Token

    /// Server-issued JWT to use as Bearer token for all API calls.
    var authToken: String? {
        readKeychainItem(key: Self.serverTokenKey)
    }

    // MARK: - Sign in with Apple

    func signInWithApple() {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.performRequests()
    }

    func signOut() {
        deleteKeychainItem(key: Self.userIDKey)
        deleteKeychainItem(key: Self.nameKey)
        deleteKeychainItem(key: Self.serverTokenKey)
        isAuthenticated = false
        userIdentifier = nil
        displayName = nil
    }

    // MARK: - Session Persistence

    private func restoreSession() {
        guard let storedUserID = readKeychainItem(key: Self.userIDKey),
              readKeychainItem(key: Self.serverTokenKey) != nil else { return }

        let provider = ASAuthorizationAppleIDProvider()
        provider.getCredentialState(forUserID: storedUserID) { [weak self] state, _ in
            Task { @MainActor in
                switch state {
                case .authorized:
                    self?.userIdentifier = storedUserID
                    self?.displayName = self?.readKeychainItem(key: Self.nameKey)
                    self?.isAuthenticated = true
                default:
                    self?.signOut()
                }
            }
        }
    }

    // MARK: - Token Exchange

    private func exchangeAppleToken(identityToken: String) async {
        guard let url = URL(string: "\(Self.backendBaseURL)/api/auth/token") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct TokenRequest: Encodable {
            let identity_token: String
        }
        guard let body = try? JSONEncoder().encode(TokenRequest(identity_token: identityToken)) else { return }
        request.httpBody = body

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[Rawcut] Token exchange failed: non-200 response")
                return
            }

            struct TokenResponse: Decodable {
                let access_token: String
                let user_id: String
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: responseData)
            saveKeychainItem(key: Self.serverTokenKey, value: tokenResponse.access_token)
            print("[Rawcut] Server JWT obtained for user \(tokenResponse.user_id)")
        } catch {
            print("[Rawcut] Token exchange error: \(error)")
        }
    }

    // MARK: - Keychain Helpers

    private func saveKeychainItem(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func readKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthManager: ASAuthorizationControllerDelegate {

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            return
        }

        let userID = credential.user
        var name: String?
        if let fullName = credential.fullName {
            name = [fullName.givenName, fullName.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
        }

        let identityToken: String? = credential.identityToken.flatMap {
            String(data: $0, encoding: .utf8)
        }

        Task { @MainActor in
            saveKeychainItem(key: Self.userIDKey, value: userID)
            if let name, !name.isEmpty {
                saveKeychainItem(key: Self.nameKey, value: name)
            }
            userIdentifier = userID
            displayName = name ?? readKeychainItem(key: Self.nameKey)

            if let token = identityToken {
                await exchangeAppleToken(identityToken: token)
            }

            isAuthenticated = true
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        print("[Rawcut] Sign in with Apple failed: \(error.localizedDescription)")
    }
}
