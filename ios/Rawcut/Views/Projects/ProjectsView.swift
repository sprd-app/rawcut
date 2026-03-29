import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var authManager: AuthManager

    @State private var projects: [APIClient.Project] = []
    @State private var isLoading = false
    @State private var showingCreate = false
    @State private var isAutoVideoLoading = false
    @State private var autoVideoError: String?
    @State private var activeAutoRender: APIClient.Render?

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
        .sheet(item: $activeAutoRender) { render in
            RenderStatusView(renderId: render.id)
        }
        .task {
            await loadProjects()
        }
    }

    // MARK: - Projects List

    // MARK: - Hero Card

    private var heroCard: some View {
        Button {
            Task { await createAutoVideo() }
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "film")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.rcAccent)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("오늘의 영상 만들기")
                        .font(.rcBodyMedium)
                        .foregroundStyle(Color.rcTextPrimary)

                    if isAutoVideoLoading {
                        Text("준비 중...")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    } else if let error = autoVideoError {
                        Text(error)
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                            .lineLimit(1)
                    } else {
                        Text("원탭으로 시네마틱 영상을 만들어보세요")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                }

                Spacer()

                if isAutoVideoLoading {
                    ProgressView()
                        .tint(Color.rcAccent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
            }
            .padding(Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.rcSurface)
            )
        }
        .disabled(isAutoVideoLoading)
        .accessibilityLabel("오늘의 영상 만들기")
        .accessibilityHint("원탭으로 시네마틱 영상을 자동으로 만듭니다")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg))
        .listRowSeparator(.hidden)
    }

    private var projectsList: some View {
        List {
            heroCard

            ForEach(projects) { project in
                NavigationLink(value: project) {
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
                }
                .listRowBackground(Color.rcSurface)
            }
            .onDelete(perform: deleteProjects)
        }
        .listStyle(.plain)
        .background(Color.rcBackground)
        .scrollContentBackground(.hidden)
        .navigationDestination(for: APIClient.Project.self) { project in
            ProjectDetailView(project: project)
        }
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

    private func createAutoVideo() async {
        guard let token = authManager.authToken else { return }
        isAutoVideoLoading = true
        autoVideoError = nil

        do {
            let tz = TimeZone.current.secondsFromGMT()
            let result = try await APIClient.createAutoVideo(
                timezoneOffset: tz,
                authToken: token
            )

            if result.is_existing {
                // Navigate to existing render
                activeAutoRender = APIClient.Render(
                    id: result.render_id,
                    project_id: result.project_id,
                    user_id: "",
                    status: "processing",
                    preset: result.preset,
                    aspect_ratio: result.aspect_ratio,
                    progress: 0,
                    output_blob: nil,
                    error: nil,
                    created_at: "",
                    completed_at: nil
                )
            } else {
                // Navigate to new render
                activeAutoRender = APIClient.Render(
                    id: result.render_id,
                    project_id: result.project_id,
                    user_id: "",
                    status: "queued",
                    preset: result.preset,
                    aspect_ratio: result.aspect_ratio,
                    progress: 0,
                    output_blob: nil,
                    error: nil,
                    created_at: "",
                    completed_at: nil
                )
                // Refresh projects list to show the new auto project
                await loadProjects()
            }
        } catch {
            autoVideoError = "영상 만들기에 실패했습니다"
            print("[Rawcut] Auto-video failed: \(error)")
        }

        isAutoVideoLoading = false
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
