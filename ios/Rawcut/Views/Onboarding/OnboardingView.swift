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

            Text("당신의 영상, 당신의 이야기")
                .font(.rcTitleLarge)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            Text("rawcut이 촬영한 모든 영상을 안전하게 보관하고\n시네마틱 브이로그로 만들어 드립니다.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)

            Spacer()

            nextButton(label: "다음") {
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

            Text("모든 영상을 동기화합니다")
                .font(.rcTitleLarge)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            Text("사진 라이브러리에 접근하여\n영상과 사진을 안전하게 클라우드에 백업합니다.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)

            Spacer()

            VStack(spacing: Spacing.md) {
                Button {
                    requestPhotoAccess()
                } label: {
                    Text("사진 접근 허용")
                        .font(.rcBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.rcAccent, in: Capsule())
                }
                .accessibilityLabel("사진 라이브러리 접근 허용")

                Button {
                    withAnimation { currentPage = 2 }
                } label: {
                    Text("나중에")
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

            Text("15분 만에 시네마틱 브이로그")
                .font(.rcTitleLarge)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            Text("영상을 선택하고 스크립트를 작성하면\nrawcut이 나머지를 처리합니다.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)

            Spacer()

            Button {
                completeOnboarding()
            } label: {
                Text("시작하기")
                    .font(.rcBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .background(Color.rcAccent, in: Capsule())
            }
            .padding(.horizontal, Spacing.xxl)
            .accessibilityLabel("시작하기")
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
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                withAnimation { currentPage = 2 }
            }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        withAnimation {
            isOnboardingComplete = true
        }
    }
}

#Preview {
    OnboardingView(isOnboardingComplete: .constant(false))
}
