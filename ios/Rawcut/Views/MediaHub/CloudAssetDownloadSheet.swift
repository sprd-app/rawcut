import SwiftUI

/// Bottom sheet shown when tapping a cloud-only asset. Shows cached thumbnail,
/// file info, and a download button to restore the asset to the Photos library.
struct CloudAssetDownloadSheet: View {
    let asset: MediaAsset
    @ObservedObject var downloadManager: DownloadManager
    let onDownloaded: (String?) -> Void

    @State private var errorMessage: String?
    @State private var showVideoPlayer = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Thumbnail preview
            thumbnailPreview
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, Spacing.md)

            // Asset info
            VStack(spacing: Spacing.sm) {
                Text(asset.mediaType == .video ? "Video" : "Photo")
                    .font(.rcTitleMedium)
                    .foregroundStyle(Color.rcTextPrimary)

                Text(formattedFileSize)
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextSecondary)

                Text("Removed from iCloud · Stored in cloud")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextTertiary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcError)
            }

            Spacer()

            VStack(spacing: Spacing.sm) {
                // Stream button (video only)
                if asset.mediaType == .video, let blobName = asset.cloudBlobName {
                    Button {
                        showVideoPlayer = true
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "play.circle.fill")
                            Text("Stream Video")
                                .font(.rcBody)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.rcAccent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                    }
                    .fullScreenCover(isPresented: $showVideoPlayer) {
                        NavigationStack {
                            CloudVideoPlayerView(blobName: blobName)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Done") { showVideoPlayer = false }
                                            .foregroundStyle(Color.rcAccent)
                                    }
                                }
                        }
                    }
                }

                // Download button
                Button {
                    Task { await download() }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        if downloadManager.isDownloading {
                            ProgressView()
                                .tint(asset.mediaType == .video ? Color.rcAccent : .white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(downloadManager.isDownloading ? "Downloading..." : "Download to Device")
                            .font(.rcBody)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .background(
                        asset.mediaType == .video ? Color.rcSurface : Color.rcAccent,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(asset.mediaType == .video ? Color.rcTextPrimary : .black)
                }
                .disabled(downloadManager.isDownloading)
            }
            .padding(.bottom, Spacing.lg)
        }
        .padding(.horizontal, Spacing.lg)
        .background(Color.rcBackground)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailPreview: some View {
        if let cached = StorageManager.loadCachedThumbnail(fileName: asset.cachedThumbnail) {
            Image(uiImage: cached)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.rcSurface)
                .overlay {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "icloud")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.rcAccent)
                        Text("No preview available")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextTertiary)
                    }
                }
        }
    }

    // MARK: - Actions

    private func download() async {
        errorMessage = nil
        guard let blobName = asset.cloudBlobName else {
            errorMessage = "Cloud file not found"
            return
        }

        do {
            let newLocalId = try await downloadManager.downloadToPhotos(
                blobName: blobName,
                mediaType: asset.mediaType,
                assetId: asset.localIdentifier
            )
            onDownloaded(newLocalId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)
    }
}
