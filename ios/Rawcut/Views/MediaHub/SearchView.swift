import SwiftUI
import SwiftData

/// Natural language search UI.
/// Search bar at top with real-time debounced results shown as a grid.
struct SearchView: View {
    @Query(sort: \MediaAsset.createdDate, order: .reverse)
    private var allAssets: [MediaAsset]

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var searchResults: [MediaAsset] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)

                Divider()
                    .overlay(Color.rcSurface)

                if searchText.isEmpty && !hasSearched {
                    emptySearchState
                } else if isSearching {
                    loadingState
                } else if hasSearched && searchResults.isEmpty {
                    noResultsState
                } else {
                    resultsGrid
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onChange(of: searchText) { _, newValue in
            debounceSearch(query: newValue)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.rcTextTertiary)

            TextField("Search your footage — 'whiteboard meeting' or 'outdoor walk'", text: $searchText)
                .font(.rcBody)
                .foregroundStyle(Color.rcTextPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Enter search query")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    hasSearched = false
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.rcTextTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.rcSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - States

    private var emptySearchState: some View {
        Spacer()
            .frame(maxHeight: .infinity)
            .overlay {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Search your footage",
                    description: "Try 'whiteboard meeting' or 'outdoor walk'"
                )
            }
    }

    private var loadingState: some View {
        Spacer()
            .frame(maxHeight: .infinity)
            .overlay {
                ProgressView()
                    .tint(Color.rcAccent)
                    .accessibilityLabel("Searching")
            }
    }

    private var noResultsState: some View {
        Spacer()
            .frame(maxHeight: .infinity)
            .overlay {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results found",
                    description: "Try different keywords."
                )
            }
    }

    // MARK: - Results Grid

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(searchResults) { asset in
                    VStack(spacing: Spacing.xs) {
                        AssetThumbnailView(asset: asset)

                        // Show matching tag
                        if let matchingTag = matchingTag(for: asset) {
                            Text(matchingTag)
                                .font(.rcCaption)
                                .foregroundStyle(Color.rcAccent)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, Spacing.sm)
        }
    }

    // MARK: - Search Logic

    private func debounceSearch(query: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    @MainActor
    private func performSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            hasSearched = false
            return
        }

        debouncedQuery = trimmed
        isSearching = true

        // Try backend search first, fall back to local tag matching
        do {
            let results = try await fetchFromBackend(query: trimmed)
            searchResults = results
        } catch {
            // Fallback: local tag search
            let lowered = trimmed.lowercased()
            searchResults = allAssets.filter { asset in
                asset.tags?.contains(where: { $0.lowercased().contains(lowered) }) == true
            }
        }

        isSearching = false
        hasSearched = true
    }

    private func fetchFromBackend(query: String) async throws -> [MediaAsset] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://localhost:8080/api/search?q=\(encoded)") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Decode response and match to local assets
        let identifiers = try JSONDecoder().decode([String].self, from: data)
        return allAssets.filter { identifiers.contains($0.localIdentifier) }
    }

    private func matchingTag(for asset: MediaAsset) -> String? {
        let lowered = debouncedQuery.lowercased()
        return asset.tags?.first { $0.lowercased().contains(lowered) }
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
