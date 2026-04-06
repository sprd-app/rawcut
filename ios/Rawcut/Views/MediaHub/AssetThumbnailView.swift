import Photos
import SwiftUI

/// Enhanced thumbnail component for the media grid.
/// Square thumbnail with rounded corners (12pt), sync badge, video duration, and content tag.
/// Shows inline download progress for cloud-only assets being restored.
struct AssetThumbnailView: View {
    let asset: MediaAsset
    var onRetry: (() -> Void)? = nil
    /// Download progress (0.0 to 1.0), nil when not downloading
    var downloadProgress: Double? = nil

    @State private var thumbnail: UIImage?
    @State private var isPulsing = false

    private static let imageManager = PHCachingImageManager()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail image
            thumbnailImage
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Download progress overlay
            if let progress = downloadProgress {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.5))

                // Circular progress indicator
                CircularProgressView(progress: progress)
                    .frame(width: 36, height: 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Content type tag (top-left)
            if let firstTag = asset.tags?.first, downloadProgress == nil {
                Text(firstTag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(Spacing.sm)
                    .accessibilityLabel("Tag: \(firstTag)")
            }

            // Bottom-right overlays
            if downloadProgress == nil {
                VStack(alignment: .trailing, spacing: Spacing.xs) {
                    Spacer()
                    HStack(spacing: Spacing.xs) {
                        Spacer()

                        // Video duration badge
                        if asset.mediaType == .video {
                            durationBadge
                        }

                        // Sync status indicator
                        syncBadge
                    }
                }
                .padding(Spacing.sm)
            }
        }
        .onAppear {
            loadThumbnail()
            if asset.syncStatus == .uploading {
                isPulsing = true
            }
        }
        .onChange(of: asset.syncStatusRaw) { _, newValue in
            isPulsing = SyncStatus(rawValue: newValue) == .uploading
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .accessibilityLabel(thumbnailAccessibilityLabel)
        } else {
            Rectangle()
                .fill(Color.rcSurface)
                .overlay {
                    Image(systemName: asset.mediaType == .video ? "video.fill" : "photo")
                        .foregroundStyle(Color.rcTextTertiary)
                }
                .accessibilityLabel(thumbnailAccessibilityLabel)
        }
    }

    private var durationBadge: some View {
        Text(formattedDuration)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.6), in: Capsule())
            .accessibilityLabel("Duration \(formattedDuration)")
    }

    @ViewBuilder
    private var syncBadge: some View {
        switch asset.syncStatus {
        case .synced:
            // No badge — synced is the default state
            EmptyView()

        case .uploading:
            syncIcon(systemName: "arrow.up", color: Color.rcAccent)
                .opacity(isPulsing ? 0.4 : 1.0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .accessibilityLabel("uploading")

        case .pending:
            // Subtle dot only
            Circle()
                .fill(Color.rcTextTertiary)
                .frame(width: 8, height: 8)
                .accessibilityLabel("pending")

        case .failed:
            Button {
                onRetry?()
            } label: {
                syncIcon(systemName: "exclamationmark", color: Color.rcError)
            }
            .accessibilityLabel("Upload failed, tap to retry")

        case .cloudOnly:
            syncIcon(systemName: "icloud", color: Color.rcAccent)
                .accessibilityLabel("cloud only")
        }
    }

    private func syncIcon(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color, in: Circle())
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() {
        // Try loading from Photos library first
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.localIdentifier],
            options: nil
        )

        if let phAsset = fetchResult.firstObject {
            let scale = UIScreen.main.scale
            let cellWidth: CGFloat = (UIScreen.main.bounds.width - 4) / 3 // 3-column grid with 2pt spacing
            let size = CGSize(width: cellWidth * scale, height: cellWidth * scale)
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            Self.imageManager.requestImage(
                for: phAsset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                Task { @MainActor in
                    if let image {
                        self.thumbnail = image
                    }
                }
            }
            return
        }

        // Fallback: load cached thumbnail for cloud-only assets
        if let cached = StorageManager.loadCachedThumbnail(fileName: asset.cachedThumbnail) {
            thumbnail = cached
        }
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let totalSeconds = Int(asset.durationSeconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var thumbnailAccessibilityLabel: String {
        let type = asset.mediaType == .video ? "video" : "photo"
        let status: String
        switch asset.syncStatus {
        case .synced: status = "synced"
        case .uploading: status = "uploading"
        case .pending: status = "pending"
        case .failed: status = "upload failed"
        case .cloudOnly: status = "cloud only"
        }
        return "\(type), \(status)"
    }
}

// MARK: - Circular Progress View

/// Minimal circular progress indicator for download overlays.
private struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.black.opacity(0.6))

            // Progress arc
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(6)

            // Center icon
            if progress < 0.01 {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.7)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.rcBackground.ignoresSafeArea()
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 2) {
            AssetThumbnailView(asset: MediaAsset(
                localIdentifier: "preview-1",
                syncStatus: .synced,
                fileSize: 5_000_000,
                mediaType: .video,
                tags: ["whiteboard"]
            ))
            AssetThumbnailView(asset: MediaAsset(
                localIdentifier: "preview-2",
                syncStatus: .uploading,
                fileSize: 3_000_000,
                mediaType: .photo
            ))
            AssetThumbnailView(asset: MediaAsset(
                localIdentifier: "preview-3",
                syncStatus: .cloudOnly,
                fileSize: 1_000_000,
                mediaType: .photo
            ), downloadProgress: 0.65)
        }
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
