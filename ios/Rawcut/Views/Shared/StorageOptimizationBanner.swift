import SwiftUI

/// Non-intrusive banner shown when device storage is low and synced assets can be freed.
/// Replaces the old auto-delete popup that showed a jarring system dialog on launch.
struct StorageOptimizationBanner: View {
    let recommendation: StorageManager.OptimizationRecommendation
    let onOptimize: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 16))
                .foregroundStyle(Color.rcWarning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Storage Low")
                    .font(.rcCaptionBold)
                    .foregroundStyle(Color.rcTextPrimary)

                Text("\(recommendation.assetCount) items can be cleaned up (\(recommendation.formattedSize))")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }

            Spacer()

            Button {
                onOptimize()
            } label: {
                Text("Clean Up")
                    .font(.rcCaptionBold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.rcAccent, in: Capsule())
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.rcTextTertiary)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Color.rcSurface)
    }
}
