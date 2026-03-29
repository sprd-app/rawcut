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

    override init() {
        super.init()
        restoreSession()
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
        isAuthenticated = false
        userIdentifier = nil
        displayName = nil
    }

    // MARK: - Session Persistence

    private func restoreSession() {
        guard let storedUserID = readKeychainItem(key: Self.userIDKey) else { return }

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

        Task { @MainActor in
            saveKeychainItem(key: Self.userIDKey, value: userID)
            if let name, !name.isEmpty {
                saveKeychainItem(key: Self.nameKey, value: name)
            }
            userIdentifier = userID
            displayName = name ?? readKeychainItem(key: Self.nameKey)
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
