import SwiftUI

/// Bottom sheet shown when tapping a cloud-only asset. Shows cached thumbnail,
/// file info, and a download button to restore the asset to the Photos library.
struct CloudAssetDownloadSheet: View {
    let asset: MediaAsset
    @ObservedObject var downloadManager: DownloadManager
    let onDownloaded: (String?) -> Void

    @State private var errorMessage: String?
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
                Text(asset.mediaType == .video ? "동영상" : "사진")
                    .font(.rcTitleMedium)
                    .foregroundStyle(Color.rcTextPrimary)

                Text(formattedFileSize)
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextSecondary)

                Text("iCloud에서 삭제됨 · 클라우드에 보관 중")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextTertiary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcError)
            }

            Spacer()

            // Download button
            Button {
                Task { await download() }
            } label: {
                HStack(spacing: Spacing.sm) {
                    if downloadManager.isDownloading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(downloadManager.isDownloading ? "다운로드 중..." : "기기에 다운로드")
                        .font(.rcBody)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(Color.rcAccent, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .disabled(downloadManager.isDownloading)
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
                        Text("미리보기 없음")
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
            errorMessage = "클라우드 파일을 찾을 수 없습니다"
            return
        }

        do {
            let newLocalId = try await downloadManager.downloadToPhotos(
                blobName: blobName,
                mediaType: asset.mediaType
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
