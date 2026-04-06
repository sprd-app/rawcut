import SwiftUI
import SwiftData

struct MediaHubView: View {
    @Query(sort: \MediaAsset.createdDate, order: .reverse)
    private var assets: [MediaAsset]

    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var photoObserver: PhotoLibraryObserver
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var authManager: AuthManager

    @State private var selectedViewMode: ViewMode = .grid
    @State private var streamingAsset: MediaAsset?

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
                // Sync status bar (only when syncing or has failures)
                if syncEngine.isSyncing || assets.contains(where: { $0.syncStatus == .failed }) {
                    SyncStatusBar()
                }

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
                    if photoObserver.authorizationStatus == .authorized ||
                       photoObserver.authorizationStatus == .limited {
                        EmptyStateView(
                            icon: "photo.on.rectangle.angled",
                            title: "No Media Yet",
                            description: "Photos and videos will appear here as they sync."
                        )
                    } else {
                        EmptyStateView(
                            icon: "photo.on.rectangle.angled",
                            title: "Media Library",
                            description: "Grant access to sync your photos and videos.",
                            actionTitle: "Grant Photo Access",
                            action: {
                                Task {
                                    await photoObserver.requestAuthorization()
                                    if photoObserver.authorizationStatus == .authorized ||
                                       photoObserver.authorizationStatus == .limited {
                                        syncEngine.startSync()
                                    }
                                }
                            }
                        )
                    }
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
        .fullScreenCover(item: $streamingAsset) { asset in
            if let blobName = asset.cloudBlobName {
                NavigationStack {
                    CloudVideoPlayerView(blobName: blobName)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { streamingAsset = nil }
                                    .foregroundStyle(Color.rcAccent)
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                // Download button in player
                                Button {
                                    streamingAsset = nil
                                    handleCloudAssetTapForDownload(asset)
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color.rcAccent)
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Grid View

    /// Group assets by date for section headers
    private var groupedAssets: [(String, [MediaAsset])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        let grouped = Dictionary(grouping: assets) { asset -> String in
            let date = asset.createdDate
            if calendar.isDateInToday(date) {
                return "Today"
            } else if calendar.isDateInYesterday(date) {
                return "Yesterday"
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now),
                      date > weekAgo {
                formatter.dateFormat = "EEEE" // Day name
                return formatter.string(from: date)
            } else if calendar.component(.year, from: date) == calendar.component(.year, from: .now) {
                formatter.dateFormat = "MMM d"
                return formatter.string(from: date)
            } else {
                formatter.dateFormat = "MMM d, yyyy"
                return formatter.string(from: date)
            }
        }

        // Sort groups by the newest asset date in each group
        return grouped.sorted { group1, group2 in
            let date1 = group1.value.first?.createdDate ?? .distantPast
            let date2 = group2.value.first?.createdDate ?? .distantPast
            return date1 > date2
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(groupedAssets, id: \.0) { dateLabel, dateAssets in
                    // Date section header
                    HStack {
                        Text(dateLabel)
                            .font(.rcCaptionBold)
                            .foregroundStyle(Color.rcTextSecondary)

                        let cloudCount = dateAssets.filter { $0.syncStatus == .cloudOnly }.count
                        if cloudCount > 0 {
                            Text("· \(cloudCount) cloud")
                                .font(.rcCaption)
                                .foregroundStyle(Color.rcTextTertiary)
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.sm)

                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(dateAssets) { asset in
                            AssetThumbnailView(
                                asset: asset,
                                onRetry: asset.syncStatus == .failed ? {
                                    syncEngine.retryFailed()
                                } : nil,
                                downloadProgress: downloadManager.activeDownloads[asset.localIdentifier]?.isDownloading == true
                                    ? downloadManager.activeDownloads[asset.localIdentifier]?.progress
                                    : nil
                            )
                            .onTapGesture {
                                handleCloudAssetTap(asset)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .refreshable {
            syncEngine.startSync()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Cloud Asset Actions

    private func handleCloudAssetTap(_ asset: MediaAsset) {
        guard asset.syncStatus == .cloudOnly else { return }

        // Videos: stream directly, no download needed
        if asset.mediaType == .video {
            streamingAsset = asset
            return
        }

        // Photos: inline download
        handleCloudAssetTapForDownload(asset)
    }

    private func handleCloudAssetTapForDownload(_ asset: MediaAsset) {
        guard asset.syncStatus == .cloudOnly || asset.syncStatus == .synced else { return }
        guard !downloadManager.isDownloading(assetId: asset.localIdentifier) else { return }
        guard let blobName = asset.cloudBlobName else { return }

        let assetId = asset.localIdentifier
        Task {
            do {
                let newLocalId = try await downloadManager.downloadToPhotos(
                    blobName: blobName,
                    mediaType: asset.mediaType,
                    assetId: assetId
                )

                // Update asset record
                let context = ModelContext(syncEngine.modelContainerRef)
                let predicate = #Predicate<MediaAsset> { $0.localIdentifier == assetId }
                if let dbAsset = try context.fetch(FetchDescriptor<MediaAsset>(predicate: predicate)).first {
                    if let newId = newLocalId {
                        dbAsset.localIdentifier = newId
                    }
                    dbAsset.syncStatus = .synced
                    dbAsset.cachedThumbnail = nil
                    try context.save()
                }
                if let newId = newLocalId {
                    downloadManager.clearPendingRestore(newId)
                }
                syncEngine.refreshProgress()
            } catch {
                print("[Rawcut] Download failed: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        MediaHubView()
            .environmentObject(SyncEngine(
                uploadManager: UploadManager(authManager: AuthManager()),
                networkMonitor: NetworkMonitor(),
                modelContainer: try! ModelContainer(for: MediaAsset.self)
            ))
            .environmentObject(PhotoLibraryObserver(
                modelContainer: try! ModelContainer(for: MediaAsset.self)
            ))
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
