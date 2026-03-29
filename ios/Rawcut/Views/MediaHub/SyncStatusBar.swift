import SwiftUI

struct SyncStatusBar: View {
    @EnvironmentObject var syncEngine: SyncEngine
    @State private var isExpanded: Bool = false
    @State private var isPulsing: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Compact bar
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                compactBar
            }
            .buttonStyle(.plain)

            // Progress track
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.rcSurface)
                        .frame(height: 2)

                    Rectangle()
                        .fill(Color.rcAccent)
                        .frame(
                            width: geometry.size.width * syncEngine.syncProgress.fraction,
                            height: 2
                        )
                        .opacity(isPulsing ? 0.6 : 1.0)
                }
            }
            .frame(height: 2)

            // Expanded detail view
            if isExpanded {
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.rcSurface)
        .onChange(of: syncEngine.isSyncing) { _, syncing in
            withAnimation(syncing ? syncPulseAnimation : .default) {
                isPulsing = syncing
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Tap to \(isExpanded ? "collapse" : "expand") sync details")
    }

    // MARK: - Compact Bar

    private var compactBar: some View {
        HStack(spacing: Spacing.sm) {
            if syncEngine.isSyncing {
                syncIndicator
            } else if syncEngine.syncProgress.failedCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.rcError)
            } else if syncEngine.syncProgress.isComplete && syncEngine.syncProgress.totalItems > 0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.rcAccent)
            }

            Text(statusText)
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextSecondary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.rcTextTertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Expanded Detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Divider()
                .background(Color.rcSurfaceElevated)

            // Status rows
            if syncEngine.syncProgress.syncedCount > 0 {
                statusRow(
                    icon: "checkmark.circle.fill",
                    color: .rcAccent,
                    label: "\(syncEngine.syncProgress.syncedCount) synced",
                    detail: formattedBytes(syncEngine.syncProgress.totalBytesSynced)
                )
            }

            if syncEngine.syncProgress.uploadingCount > 0 {
                statusRow(
                    icon: "arrow.up.circle.fill",
                    color: .rcWarning,
                    label: "\(syncEngine.syncProgress.uploadingCount) uploading",
                    detail: nil
                )
            }

            if syncEngine.syncProgress.pendingCount > 0 {
                statusRow(
                    icon: "clock.fill",
                    color: .rcTextTertiary,
                    label: "\(syncEngine.syncProgress.pendingCount) pending",
                    detail: nil
                )
            }

            if syncEngine.syncProgress.failedCount > 0 {
                HStack {
                    statusRow(
                        icon: "xmark.circle.fill",
                        color: .rcError,
                        label: "\(syncEngine.syncProgress.failedCount) failed",
                        detail: nil
                    )

                    Spacer()

                    Button {
                        syncEngine.retryFailed()
                    } label: {
                        Text("Retry")
                            .font(.rcCaption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.rcAccent)
                    }
                }
            }

            // Pause / Resume
            if syncEngine.syncProgress.pendingCount > 0 || syncEngine.isSyncing {
                Divider()
                    .background(Color.rcSurfaceElevated)

                Button {
                    if syncEngine.isSyncing {
                        syncEngine.pauseSync()
                    } else {
                        syncEngine.startSync()
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: syncEngine.isSyncing ? "pause.fill" : "play.fill")
                            .font(.system(size: 10))
                        Text(syncEngine.isSyncing ? "Pause Sync" : "Resume Sync")
                            .font(.rcCaption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(Color.rcAccent)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Components

    private var syncIndicator: some View {
        Circle()
            .fill(Color.rcAccent)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(syncPulseAnimation, value: isPulsing)
    }

    private func statusRow(
        icon: String,
        color: Color,
        label: String,
        detail: String?
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)

            Text(label)
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextSecondary)

            if let detail {
                Spacer()
                Text(detail)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextTertiary)
            }
        }
    }

    // MARK: - Formatting

    private var statusText: String {
        let progress = syncEngine.syncProgress

        guard progress.totalItems > 0 else {
            return "No media to sync"
        }

        var parts: [String] = []

        if progress.totalBytesSynced > 0 {
            parts.append("\(formattedBytes(progress.totalBytesSynced)) synced")
        }

        if progress.uploadingCount > 0 {
            parts.append("\(progress.uploadingCount) uploading")
        }

        if progress.pendingCount > 0 {
            parts.append("\(progress.pendingCount) pending")
        }

        if progress.failedCount > 0 {
            parts.append("\(progress.failedCount) failed")
        }

        if progress.isComplete && progress.totalItems > 0 {
            return "\(formattedBytes(progress.totalBytesSynced)) synced — All done"
        }

        return parts.joined(separator: " · ")
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private var accessibilityDescription: String {
        let p = syncEngine.syncProgress
        return "Sync status: \(p.syncedCount) of \(p.totalItems) items synced, \(p.pendingCount) pending, \(p.failedCount) failed"
    }

    // MARK: - Animation

    private var syncPulseAnimation: Animation {
        .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
    }
}

#Preview {
    // Preview requires a mock; show static layout
    VStack {
        Text("SyncStatusBar preview requires SyncEngine")
            .font(.rcCaption)
            .foregroundStyle(Color.rcTextSecondary)
    }
    .frame(maxWidth: .infinity)
    .background(Color.rcBackground)
}
