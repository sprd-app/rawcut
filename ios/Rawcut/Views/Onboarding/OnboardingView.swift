import Photos
import SwiftUI

/// 3-screen first-launch onboarding flow.
/// Shows only on first launch (UserDefaults flag).
struct OnboardingView: View {
    @State private var currentPage = 0
    @Binding var isOnboardingComplete: Bool

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                syncPage.tag(1)
                getStartedPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Screen 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 80, weight: .ultraLight))
                .foregroundStyle(Color.rcAccent)
                .accessibilityHidden(true)

            Text("Your footage, your story")
                .font(.rcDisplay)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            Text("rawcut keeps all your footage safe\nand turns it into cinematic vlogs.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)

            Spacer()

            nextButton(label: "Next") {
                withAnimation { currentPage = 1 }
            }
        }
        .padding(.bottom, Spacing.xxl)
    }

    // MARK: - Screen 2: Sync / Photo Access

    private var syncPage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 80, weight: .ultraLight))
                .foregroundStyle(Color.rcAccent)
                .accessibilityHidden(true)

            Text("We sync everything")
                .font(.rcDisplay)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            Text("rawcut automatically syncs all your photos\nand videos to the cloud.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)

            Spacer()

            VStack(spacing: Spacing.md) {
                Button {
                    requestPhotoAccess()
                } label: {
                    Text("Grant Photo Access")
                        .font(.rcBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.rcAccent, in: Capsule())
                }
                .accessibilityLabel("Grant Photo Access")

                Button {
                    withAnimation { currentPage = 2 }
                } label: {
                    Text("Later")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextSecondary)
                }
            }
            .padding(.horizontal, Spacing.xxl)
        }
        .padding(.bottom, Spacing.xxl)
    }

    // MARK: - Screen 3: Get Started

    private var getStartedPage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "film")
                .font(.system(size: 80, weight: .ultraLight))
                .foregroundStyle(Color.rcAccent)
                .accessibilityHidden(true)

            Text("Cinematic vlogs in 15 minutes")
                .font(.rcDisplay)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            Text("rawcut's AI turns your footage\ninto cinematic vlogs.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)

            Spacer()

            Button {
                completeOnboarding()
            } label: {
                Text("Get Started")
                    .font(.rcBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .background(Color.rcAccent, in: Capsule())
            }
            .padding(.horizontal, Spacing.xxl)
            .accessibilityLabel("Get Started")
        }
        .padding(.bottom, Spacing.xxl)
    }

    // MARK: - Helpers

    private func nextButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.rcBody)
                .fontWeight(.semibold)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(Color.rcAccent, in: Capsule())
        }
        .padding(.horizontal, Spacing.xxl)
        .accessibilityLabel(label)
    }

    private func requestPhotoAccess() {
        Task {
            let _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await MainActor.run {
                withAnimation { currentPage = 2 }
            }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: UserDefaults.Keys.hasCompletedOnboarding)
        withAnimation {
            isOnboardingComplete = true
        }
    }
}

#Preview {
    OnboardingView(isOnboardingComplete: .constant(false))
}
