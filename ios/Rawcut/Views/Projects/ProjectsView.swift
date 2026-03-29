import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var authManager: AuthManager

    @State private var projects: [APIClient.Project] = []
    @State private var isLoading = false
    @State private var showingCreate = false

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            if isLoading && projects.isEmpty {
                ProgressView()
                    .tint(Color.rcAccent)
            } else if projects.isEmpty {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No Projects Yet",
                    description: "Select footage and create your first vlog.",
                    actionTitle: "New Project",
                    action: { showingCreate = true }
                )
            } else {
                projectsList
            }
        }
        .navigationTitle("Projects")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(Color.rcAccent)
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateView { _ in
                showingCreate = false
                Task { await loadProjects() }
            }
        }
        .task {
            await loadProjects()
        }
    }

    // MARK: - Projects List

    private var projectsList: some View {
        List {
            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(project.title)
                        .font(.rcBodyMedium)
                        .foregroundStyle(Color.rcTextPrimary)

                    if !project.description.isEmpty {
                        Text(project.description)
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                            .lineLimit(2)
                    }

                    Text(project.formattedDate)
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
                .padding(.vertical, Spacing.xs)
                .listRowBackground(Color.rcSurface)
            }
            .onDelete(perform: deleteProjects)
        }
        .listStyle(.plain)
        .background(Color.rcBackground)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Actions

    private func loadProjects() async {
        guard let token = authManager.authToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await APIClient.listProjects(authToken: token)
        } catch {
            print("[Rawcut] Failed to load projects: \(error)")
        }
    }

    private func deleteProjects(at offsets: IndexSet) {
        guard let token = authManager.authToken else { return }
        let ids = offsets.map { projects[$0].id }
        projects.remove(atOffsets: offsets)
        Task {
            for id in ids {
                try? await APIClient.deleteProject(id: id, authToken: token)
            }
        }
    }
}
