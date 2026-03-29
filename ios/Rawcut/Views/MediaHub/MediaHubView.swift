import SwiftUI
import SwiftData

struct MediaHubView: View {
    @Query(sort: \MediaAsset.createdDate, order: .reverse)
    private var assets: [MediaAsset]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            if assets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(assets) { asset in
                            ThumbnailCell(asset: asset)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .navigationTitle("rawcut")
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(Color.rcTextTertiary)
            Text("Your Media Library")
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)
            Text("Grant photo library access to get started.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Button {
                // TODO: Request PHPhotoLibrary access
            } label: {
                Text("Open Photo Library")
                    .font(.rcBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
                    .background(Color.rcAccent, in: Capsule())
            }
        }
    }
}

// MARK: - Thumbnail Cell

private struct ThumbnailCell: View {
    let asset: MediaAsset

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.rcSurface)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: asset.mediaType == .video ? "video.fill" : "photo")
                        .foregroundStyle(Color.rcTextTertiary)
                }

            // Sync status indicator
            Circle()
                .fill(syncColor)
                .frame(width: 8, height: 8)
                .padding(6)
        }
    }

    private var syncColor: Color {
        switch asset.syncStatus {
        case .synced: Color.rcAccent
        case .uploading: Color.rcWarning
        case .failed: Color.rcError
        case .pending: Color.rcTextTertiary
        }
    }
}

#Preview {
    NavigationStack {
        MediaHubView()
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
