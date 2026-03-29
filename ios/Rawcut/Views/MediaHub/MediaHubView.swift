import SwiftUI
import SwiftData

struct MediaHubView: View {
    @Query(sort: \MediaAsset.createdDate, order: .reverse)
    private var assets: [MediaAsset]

    @State private var selectedViewMode: ViewMode = .grid
    @State private var isRefreshing = false

    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case timeline = "Timeline"
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Sync status bar
                syncStatusBar

                // Segmented control
                Picker("View Mode", selection: $selectedViewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)

                // Content
                if assets.isEmpty {
                    Spacer()
                    EmptyStateView(
                        icon: "photo.on.rectangle.angled",
                        title: "Media Library",
                        description: "Please grant access to your photo library.",
                        actionTitle: "Open Photo Library",
                        action: {
                            // TODO: Request PHPhotoLibrary access
                        }
                    )
                    Spacer()
                } else {
                    switch selectedViewMode {
                    case .grid:
                        gridView
                    case .timeline:
                        TimelineView()
                    }
                }
            }
        }
        .navigationTitle("rawcut")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.rcTextPrimary)
                }
                .accessibilityLabel("Search")
            }
        }
    }

    // MARK: - Sync Status Bar

    private var syncStatusBar: some View {
        let uploadingCount = assets.filter { $0.syncStatus == .uploading }.count
        let failedCount = assets.filter { $0.syncStatus == .failed }.count
        let syncedCount = assets.filter { $0.syncStatus == .synced }.count

        return Group {
            if uploadingCount > 0 || failedCount > 0 {
                HStack(spacing: Spacing.sm) {
                    if uploadingCount > 0 {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(Color.rcWarning)
                        Text("\(uploadingCount) uploading")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                    if failedCount > 0 {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.rcError)
                        Text("\(failedCount) failed")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                    Spacer()
                    Text("\(syncedCount) synced")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .background(Color.rcSurface)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Grid View with Pull-to-Refresh

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets) { asset in
                    AssetThumbnailView(asset: asset)
                }
            }
            .padding(.horizontal, 2)
        }
        .refreshable {
            // Trigger manual sync
            await performRefresh()
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        // Allow the sync engine to pick up; simulate a brief wait
        try? await Task.sleep(for: .seconds(1))
        isRefreshing = false
    }
}

#Preview {
    NavigationStack {
        MediaHubView()
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
