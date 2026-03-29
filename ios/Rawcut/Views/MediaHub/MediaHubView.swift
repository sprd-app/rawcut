import SwiftUI
import SwiftData

struct MediaHubView: View {
    @Query(sort: \MediaAsset.createdDate, order: .reverse)
    private var assets: [MediaAsset]

    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var photoObserver: PhotoLibraryObserver

    @State private var selectedViewMode: ViewMode = .grid

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
                // Sync status bar (only when syncing)
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
    }

    // MARK: - Grid View

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
            syncEngine.startSync()
            try? await Task.sleep(for: .seconds(1))
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
