import Photos
import SwiftUI

/// 4-screen first-launch onboarding flow.
/// Shows only on first launch (UserDefaults flag).
struct OnboardingView: View {
    @State private var currentPage = 0
    @Binding var isOnboardingComplete: Bool
    @State private var iCloudPhotosEnabled: Bool = false

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                syncPage.tag(1)
                iCloudWarningPage.tag(2)
                getStartedPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .preferredColorScheme(.dark)
        .onAppear {
            iCloudPhotosEnabled = FileManager.default.ubiquityIdentityToken != nil
        }
    }

    // MARK: - Screen 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Color.rcTextSecondary)
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
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Color.rcTextSecondary)
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
                        .background(Color.rcAccent, in: RoundedRectangle(cornerRadius: 10))
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

    // MARK: - Screen 3: iCloud Warning

    private var iCloudWarningPage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: iCloudPhotosEnabled ? "exclamationmark.icloud.fill" : "checkmark.icloud.fill")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(iCloudPhotosEnabled ? Color.rcWarning : Color.rcAccent)
                .accessibilityHidden(true)

            Text(iCloudPhotosEnabled ? "iCloud Photos Conflict" : "iCloud Photos Off")
                .font(.rcDisplay)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            if iCloudPhotosEnabled {
                VStack(spacing: Spacing.md) {
                    Text("iCloud Photos is on. Your media will\nupload to both iCloud and rawcut.")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextSecondary)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        iCloudStep(number: "1", text: "Open the Settings app")
                        iCloudStep(number: "2", text: "[Your Name] → iCloud → Photos")
                        iCloudStep(number: "3", text: "Turn off 'Sync this iPhone'")
                    }
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.md)
                    .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, Spacing.xl)

                    Text("You can also check this later in Settings.")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
            } else {
                Text("rawcut will keep all your media\nsafe in the cloud.")
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl)
            }

            Spacer()

            nextButton(label: iCloudPhotosEnabled ? "Got it" : "Next") {
                withAnimation { currentPage = 3 }
            }
        }
        .padding(.bottom, Spacing.xxl)
    }

    private func iCloudStep(number: String, text: String) -> some View {
        HStack(spacing: Spacing.md) {
            Text(number)
                .font(.rcCaptionBold)
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(Color.rcAccent, in: Circle())

            Text(text)
                .font(.rcBody)
                .foregroundStyle(Color.rcTextPrimary)
        }
    }

    // MARK: - Screen 4: Get Started

    private var getStartedPage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "film")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Color.rcTextSecondary)
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
