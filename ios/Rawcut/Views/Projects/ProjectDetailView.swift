import SwiftData
import SwiftUI

/// Shows project clips and allows triggering a cinematic render.
struct ProjectDetailView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Query private var allAssets: [MediaAsset]

    let project: APIClient.Project

    @State private var clips: [APIClient.ProjectClip] = []
    @State private var renders: [APIClient.Render] = []
    @State private var isLoading = true
    @State private var selectedPreset = "warm_film"
    @State private var selectedRatio = "2.0"
    @State private var isRendering = false
    @State private var activeRender: APIClient.Render?
    @State private var errorMessage: String?

    private let presets: [(id: String, label: String, desc: String)] = [
        ("warm_film", "Warm Film", "Kodak-inspired warm tones"),
        ("cool_minimal", "Cool Minimal", "Cool desaturated, startup feel"),
        ("natural_vivid", "Natural Vivid", "Vivid natural colors"),
    ]

    private let ratios: [(id: String, label: String)] = [
        ("16:9", "16:9"),
        ("2.0", "2.0:1"),
        ("2.39", "2.39:1"),
    ]

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(Color.rcAccent)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        projectHeader
                        clipsSection
                        presetSection
                        ratioSection
                        renderButton
                        rendersSection
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $activeRender) { render in
            RenderStatusView(renderId: render.id)
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Sections

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !project.description.isEmpty {
                Text(project.description)
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextSecondary)
            }
            Text(project.formattedDate)
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextTertiary)
        }
    }

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Clips (\(clips.count))")
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)

            if clips.isEmpty {
                Text("No clips in this project.")
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Spacing.xl)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4),
                    spacing: 2
                ) {
                    ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                        clipCell(clip, index: index)
                    }
                }
            }
        }
    }

    private func clipCell(_ clip: APIClient.ProjectClip, index: Int) -> some View {
        let matchingAsset = allAssets.first { $0.cloudBlobName == clip.blob_name }

        return ZStack(alignment: .bottomTrailing) {
            if let asset = matchingAsset {
                AssetThumbnailView(asset: asset)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.rcSurface)
                    .overlay {
                        Image(systemName: clip.media_type == "video" ? "video.fill" : "photo.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.rcAccent)
                    }
            }

            Text("\(index + 1)")
                .font(.rcCaptionBold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.black.opacity(0.6), in: Circle())
                .padding(4)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Preset")
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)

            ForEach(presets, id: \.id) { preset in
                Button {
                    selectedPreset = preset.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.label)
                                .font(.rcBodyMedium)
                                .foregroundStyle(Color.rcTextPrimary)
                            Text(preset.desc)
                                .font(.rcCaption)
                                .foregroundStyle(Color.rcTextSecondary)
                        }
                        Spacer()
                        if selectedPreset == preset.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.rcAccent)
                        } else {
                            Circle()
                                .strokeBorder(Color.rcTextTertiary, lineWidth: 1.5)
                                .frame(width: 22, height: 22)
                        }
                    }
                    .padding(Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedPreset == preset.id ? Color.rcSurfaceElevated : Color.rcSurface)
                    )
                }
            }
        }
    }

    private var ratioSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Aspect Ratio")
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)

            HStack(spacing: Spacing.sm) {
                ForEach(ratios, id: \.id) { ratio in
                    Button {
                        selectedRatio = ratio.id
                    } label: {
                        Text(ratio.label)
                            .font(.rcBodyMedium)
                            .foregroundStyle(selectedRatio == ratio.id ? .black : Color.rcTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(selectedRatio == ratio.id ? Color.rcAccent : Color.rcSurface)
                            )
                    }
                }
            }
        }
    }

    private var renderButton: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                Task { await startRender() }
            } label: {
                HStack {
                    Spacer()
                    if isRendering {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "film")
                        Text("Start Render")
                            .font(.rcBodyMedium)
                    }
                    Spacer()
                }
                .foregroundStyle(.black)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(clips.isEmpty || isRendering ? Color.rcAccentDim.opacity(0.5) : Color.rcAccent)
                )
            }
            .disabled(clips.isEmpty || isRendering)

            if let errorMessage {
                Text(errorMessage)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcError)
            }
        }
    }

    private var rendersSection: some View {
        Group {
            if !renders.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Render History")
                        .font(.rcTitleMedium)
                        .foregroundStyle(Color.rcTextPrimary)

                    ForEach(renders) { render in
                        Button {
                            activeRender = render
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(render.preset.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.rcBodyMedium)
                                        .foregroundStyle(Color.rcTextPrimary)
                                    Text(renderStatusText(render))
                                        .font(.rcCaption)
                                        .foregroundStyle(renderStatusColor(render))
                                }
                                Spacer()
                                Image(systemName: renderStatusIcon(render))
                                    .foregroundStyle(renderStatusColor(render))
                            }
                            .padding(Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.rcSurface)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func renderStatusText(_ render: APIClient.Render) -> String {
        switch render.status {
        case "queued": return "Queued..."
        case "processing": return "Rendering \(Int(render.progress * 100))%"
        case "complete": return "Complete"
        case "failed": return render.error ?? "Failed"
        default: return render.status
        }
    }

    private func renderStatusColor(_ render: APIClient.Render) -> Color {
        switch render.status {
        case "complete": return Color.rcAccent
        case "failed": return Color.rcError
        default: return Color.rcTextSecondary
        }
    }

    private func renderStatusIcon(_ render: APIClient.Render) -> String {
        switch render.status {
        case "complete": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "processing": return "arrow.triangle.2.circlepath"
        default: return "clock"
        }
    }

    // MARK: - Actions

    private func loadData() async {
        guard let token = authManager.authToken else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let fetchClips = APIClient.getProjectClips(projectId: project.id, authToken: token)
            async let fetchRenders = APIClient.listProjectRenders(projectId: project.id, authToken: token)
            clips = try await fetchClips
            renders = try await fetchRenders
        } catch {
            print("[Rawcut] Failed to load project detail: \(error)")
        }
    }

    private func startRender() async {
        guard let token = authManager.authToken else {
            errorMessage = "Sign in required."
            return
        }

        isRendering = true
        errorMessage = nil

        do {
            let render = try await APIClient.startRender(
                projectId: project.id,
                preset: selectedPreset,
                aspectRatio: selectedRatio,
                authToken: token
            )
            activeRender = render
            // Refresh renders list
            renders.insert(render, at: 0)
        } catch {
            errorMessage = "Failed to start render."
            print("[Rawcut] Render start failed: \(error)")
        }

        isRendering = false
    }
}
