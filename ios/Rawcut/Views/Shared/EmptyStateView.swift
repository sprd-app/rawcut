import SwiftUI

/// Reusable empty state component per DESIGN.md:
/// 64pt icon, warm headline, one-line description, primary action button.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(Color.rcTextTertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)
                .multilineTextAlignment(.center)

            Text(description)
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.rcBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                        .background(Color.rcAccent, in: Capsule())
                }
                .accessibilityLabel(actionTitle)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.rcBackground.ignoresSafeArea()
        EmptyStateView(
            icon: "photo.on.rectangle.angled",
            title: "미디어 라이브러리",
            description: "사진 라이브러리 접근 권한을 허용해 주세요.",
            actionTitle: "사진 라이브러리 열기",
            action: {}
        )
    }
}
