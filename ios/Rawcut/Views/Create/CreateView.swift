import SwiftUI
import SwiftData

/// Multi-step project creation flow:
///   Step 0 — Select clips from the media library
///   Step 1 — Enter project title and description
struct CreateView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \MediaAsset.createdDate, order: .reverse)
    private var allAssets: [MediaAsset]

    @State private var selectedIDs: Set<String> = []
    @State private var title = ""
    @State private var description = ""
    @State private var step = 0
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    let onCreated: (APIClient.Project) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    // Only show synced assets (they're in the cloud and can be used in projects)
    private var syncedAssets: [MediaAsset] {
        allAssets.filter { $0.syncStatus == .synced }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rcBackground.ignoresSafeArea()

                if step == 0 {
                    assetSelectionStep
                } else {
                    projectDetailsStep
                }
            }
            .navigationTitle(step == 0 ? "Select Clips" : "Project Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == 0 {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Color.rcTextSecondary)
                    } else {
                        Button("Back") { step = 0 }
                            .foregroundStyle(Color.rcAccent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step == 0 {
                        Button("Next") { step = 1 }
                            .disabled(selectedIDs.isEmpty)
                            .foregroundStyle(selectedIDs.isEmpty ? Color.rcTextTertiary : Color.rcAccent)
                    }
                }
            }
        }
    }

    // MARK: - Step 0: Asset Selection

    private var assetSelectionStep: some View {
        VStack(spacing: 0) {
            if !selectedIDs.isEmpty {
                Text("\(selectedIDs.count) clip\(selectedIDs.count == 1 ? "" : "s") selected")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
            }

            if syncedAssets.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Synced Clips",
                    description: "Wait for your photos and videos to finish syncing, then come back."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(syncedAssets) { asset in
                            assetCell(asset)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func assetCell(_ asset: MediaAsset) -> some View {
        let isSelected = selectedIDs.contains(asset.localIdentifier)

        return ZStack(alignment: .topTrailing) {
            AssetThumbnailView(asset: asset)

            if isSelected {
                ZStack {
                    Circle()
                        .fill(Color.rcAccent)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                }
                .padding(6)
            } else {
                Circle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .padding(6)
            }
        }
        .onTapGesture {
            if isSelected {
                selectedIDs.remove(asset.localIdentifier)
            } else {
                selectedIDs.insert(asset.localIdentifier)
            }
        }
    }

    // MARK: - Step 1: Project Details

    private var projectDetailsStep: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Project title", text: $title)
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                        .listRowBackground(Color.rcSurface)

                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                        .lineLimit(3...6)
                        .listRowBackground(Color.rcSurface)
                } header: {
                    Text("Details")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextSecondary)
                }

                Section {
                    Text("\(selectedIDs.count) clip\(selectedIDs.count == 1 ? "" : "s") selected")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextSecondary)
                        .listRowBackground(Color.rcSurface)
                } header: {
                    Text("Footage")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextSecondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcError)
                            .listRowBackground(Color.rcSurface)
                    }
                }

                Section {
                    Button {
                        Task { await submitProject() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Text("Create Project")
                                    .font(.rcBodyMedium)
                                    .foregroundStyle(.black)
                            }
                            Spacer()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    .listRowBackground(Color.rcAccent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.rcBackground)
        }
    }

    // MARK: - Submit

    private func submitProject() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        guard let token = authManager.authToken else {
            errorMessage = "Not authenticated. Please sign in again."
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            let project = try await APIClient.createProject(
                title: trimmedTitle,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                authToken: token
            )
            onCreated(project)
        } catch {
            errorMessage = "Failed to create project. Please try again."
            print("[Rawcut] Project creation failed: \(error)")
        }

        isSubmitting = false
    }
}
