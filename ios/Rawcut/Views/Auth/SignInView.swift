import AuthenticationServices
import SwiftUI

/// Full-screen sign-in view shown when user is not authenticated.
/// Uses Sign in with Apple as the sole auth method.
struct SignInView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            VStack(spacing: Spacing.xxl) {
                Spacer()

                // Logo / Brand
                VStack(spacing: Spacing.md) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.rcAccent)

                    Text("rawcut")
                        .font(.rcDisplay)
                        .foregroundStyle(Color.rcTextPrimary)

                    Text("내 미디어, 내 클라우드")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextSecondary)
                }

                Spacer()

                // Sign In with Apple
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success:
                        // ASAuthorizationControllerDelegate handles the rest
                        break
                    case .failure(let error):
                        print("[Rawcut] Sign in cancelled: \(error.localizedDescription)")
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, Spacing.xl)

                // Manual trigger as fallback (SignInWithAppleButton may not call delegate)
                Button {
                    authManager.signInWithApple()
                } label: {
                    EmptyView()
                }
                .frame(width: 0, height: 0)
                .hidden()

                Text("Apple 계정으로 안전하게 로그인")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextTertiary)
                    .padding(.bottom, Spacing.xxl)
            }
        }
    }
}
