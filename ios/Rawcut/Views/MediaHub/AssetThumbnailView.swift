import AVFoundation
import Photos
import SwiftUI

/// Enhanced thumbnail component for the media grid.
/// Square thumbnail with rounded corners (12pt), sync badge, video duration, and content tag.
struct AssetThumbnailView: View {
    let asset: MediaAsset
    var onRetry: (() -> Void)? = nil

    @State private var thumbnail: UIImage?
    @State private var isPulsing = false

    private static let imageManager = PHCachingImageManager()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail image
            thumbnailImage
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Content type tag (top-left)
            if let firstTag = asset.tags?.first {
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
            syncIcon(systemName: "checkmark", color: .green)
                .accessibilityLabel("synced")

        case .uploading:
            syncIcon(systemName: "arrow.up", color: .blue)
                .opacity(isPulsing ? 0.4 : 1.0)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .accessibilityLabel("uploading")

        case .pending:
            syncIcon(systemName: "clock", color: Color.rcTextTertiary)
                .accessibilityLabel("pending")

        case .failed:
            Button {
                onRetry?()
            } label: {
                syncIcon(systemName: "xmark", color: Color.rcError)
            }
            .accessibilityLabel("Upload failed, tap to retry")
            .accessibilityHint("Retries upload")
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
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.localIdentifier],
            options: nil
        )
        guard let phAsset = fetchResult.firstObject else {
            print("[Rawcut] Thumbnail: PHAsset not found for \(asset.localIdentifier.prefix(20))")
            return
        }

        let size = CGSize(width: 300, height: 300)
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .fast

        Self.imageManager.requestImage(
            for: phAsset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            Task { @MainActor in
                if let image {
                    self.thumbnail = image
                } else if self.thumbnail == nil {
                    // Fallback: generate thumbnail from video asset
                    if self.asset.mediaType == .video {
                        self.loadVideoThumbnail(phAsset: phAsset)
                    }
                }
            }
        }
    }

    private func loadVideoThumbnail(phAsset: PHAsset) {
        // Extract video URL, then generate thumbnail off-main
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current

        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, info in
            // Skip degraded/progress callbacks
            if info?[PHImageResultIsDegradedKey] as? Bool == true { return }

            guard let urlAsset = avAsset as? AVURLAsset else { return }
            let videoURL = urlAsset.url

            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 300)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
            let uiImage = UIImage(cgImage: cgImage)
            Task { @MainActor in
                self.thumbnail = uiImage
            }
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
        }
        return "\(type), \(status)"
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
                syncStatus: .failed,
                fileSize: 1_000_000,
                mediaType: .video,
                tags: ["outdoor"]
            ))
        }
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
