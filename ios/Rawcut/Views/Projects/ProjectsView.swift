import AVKit
import SwiftUI

/// Gallery of completed vlogs. Each entry shows thumbnail, title, duration.
/// Tap to watch + see segments. "Resume editing" goes back to chat.
struct ProjectsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var projects: [APIClient.Project] = []
    @State private var renders: [String: APIClient.Render] = [:]
    @State private var thumbnails: [String: String] = [:]  // renderId → thumbnail URL
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            if isLoading && projects.isEmpty {
                ProgressView().tint(Color.rcAccent)
            } else if projects.isEmpty {
                emptyState
            } else {
                vlogList
            }
        }
        .navigationTitle("My Vlogs")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadAll() }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Color.rcTextTertiary)
            Text("No vlogs yet")
                .font(.rcBodyMedium)
                .foregroundStyle(Color.rcTextSecondary)
            Text("Go to Create tab to make your first vlog")
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextTertiary)
        }
    }

    // MARK: - List

    private var vlogList: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.md) {
                ForEach(projects) { project in
                    let render = renders[project.id]
                    NavigationLink(value: project) {
                        vlogCard(project, render: render)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .navigationDestination(for: APIClient.Project.self) { project in
            VlogDetailView(project: project, render: renders[project.id])
        }
    }

    private func vlogCard(_ project: APIClient.Project, render: APIClient.Render?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.rcSurfaceElevated)
                    .aspectRatio(16/9, contentMode: .fit)

                if let render, let thumbURL = thumbnails[render.id], let url = URL(string: thumbURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.rcSurfaceElevated
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16/9, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else if let render, render.isComplete {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.8))
                } else if let render, render.isProcessing {
                    VStack(spacing: 4) {
                        ProgressView()
                            .tint(Color.rcAccent)
                        Text("Rendering \(Int(render.progress * 100))%")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                } else if let render, render.isFailed {
                    VStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.rcError)
                        Text("Failed")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcError)
                    }
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.rcTextTertiary)
                }
            }

            // Info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(.rcBodyMedium)
                        .foregroundStyle(Color.rcTextPrimary)
                        .lineLimit(1)

                    Text(project.formattedDate)
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
                Spacer()
                if let render, render.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.rcAccent)
                }
            }
        }
        .padding(Spacing.sm)
        .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Load

    private func loadAll() async {
        guard let token = authManager.authToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await APIClient.listProjects(authToken: token)
            // Load latest render + thumbnails for each project
            for project in projects {
                let projectRenders = try await APIClient.listProjectRenders(projectId: project.id, authToken: token)
                if let latest = projectRenders.first {
                    renders[project.id] = latest
                    if latest.isComplete {
                        if let thumbURL = try? await APIClient.getThumbnailURL(renderId: latest.id, authToken: token) {
                            thumbnails[latest.id] = thumbURL
                        }
                    }
                }
            }
        } catch {
            print("[Rawcut] Load error: \(error)")
        }
    }
}

// MARK: - Vlog Detail View

struct VlogDetailView: View {
    let project: APIClient.Project
    let render: APIClient.Render?
    @EnvironmentObject private var authManager: AuthManager
    @State private var player: AVPlayer?
    @State private var videoURL: String?
    @State private var selectedSegment: Int?
    @State private var timeObserver: Any?

    private var parsedSegments: [ScriptSegment] {
        guard let segsJSON = render?.segments_json,
              let data = segsJSON.data(using: .utf8),
              let segs = try? JSONDecoder().decode([ScriptSegment].self, from: data) else { return [] }
        return segs
    }

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Video player
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 220)
                        .onAppear { player.play() }
                } else {
                    ZStack {
                        Color.rcSurface.frame(height: 220)
                        if render?.isComplete == true {
                            ProgressView().tint(Color.rcAccent)
                        } else {
                            Image(systemName: "film")
                                .font(.system(size: 30, weight: .ultraLight))
                                .foregroundStyle(Color.rcTextTertiary)
                        }
                    }
                }

                // Timeline bar
                if !parsedSegments.isEmpty {
                    SegmentTimelineBar(
                        segments: parsedSegments,
                        selectedIndex: selectedSegment,
                        onTapSegment: { i in
                            selectedSegment = selectedSegment == i ? nil : i
                            seekToSegment(i)
                        }
                    )
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                }

                // Info header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title)
                            .font(.rcTitleMedium)
                            .foregroundStyle(Color.rcTextPrimary)
                        HStack(spacing: Spacing.sm) {
                            Text(project.formattedDate)
                            if render?.isComplete == true {
                                Text("·")
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.rcAccent)
                                Text("Complete")
                                    .foregroundStyle(Color.rcAccent)
                            }
                        }
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)

                // Segments — same style as Create tab
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(parsedSegments.enumerated()), id: \.offset) { i, seg in
                            let segType = seg.type ?? "clip"
                            let isSelected = selectedSegment == i
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: Spacing.sm) {
                                    Text("SC \(i + 1)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.rcAccent, in: RoundedRectangle(cornerRadius: 4))

                                    Text(seg.label.uppercased())
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.rcTextPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    let badge = segType == "clip" ? "SRC" : segType == "title" ? "TXT" : "AI"
                                    Text(badge)
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(segType == "clip" ? Color.rcAccentDim : Color.rcWarning)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 3)
                                            .stroke(Color.rcTextTertiary.opacity(0.3), lineWidth: 0.5))

                                    Text("\(seg.duration ?? 0)s")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.rcTextSecondary)
                                }

                                if let cin = seg.cinematography, !cin.isEmpty {
                                    Text(cin)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.rcAccentDim)
                                        .lineLimit(1)
                                }

                                if let desc = seg.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.rcTextTertiary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.rcSurfaceElevated : Color.rcSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? Color.rcAccent.opacity(0.4) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedSegment = selectedSegment == i ? nil : i
                                seekToSegment(i)
                            }

                            if i < parsedSegments.count - 1 {
                                HStack(spacing: 4) {
                                    Rectangle()
                                        .fill(Color.rcAccent.opacity(0.3))
                                        .frame(width: 1, height: 10)
                                        .padding(.leading, 16)
                                    Text("↓ " + (seg.transition ?? "cut").uppercased())
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.rcTextTertiary.opacity(0.5))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                }

                // Actions
                VStack(spacing: Spacing.sm) {
                    if render?.isComplete == true, let url = videoURL, let shareURL = URL(string: url) {
                        Button {
                            let av = UIActivityViewController(activityItems: [shareURL], applicationActivities: nil)
                            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let root = scene.windows.first?.rootViewController {
                                root.present(av, animated: true)
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                Text("Share")
                                    .font(.rcBodyMedium)
                                Spacer()
                            }
                            .foregroundStyle(Color.rcAccent)
                            .padding(.vertical, Spacing.sm)
                            .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    Button {
                        NotificationCenter.default.post(name: .switchToCreateTab, object: nil)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "bubble.left.fill")
                            Text("Resume in Chat")
                                .font(.rcBodyMedium)
                            Spacer()
                        }
                        .foregroundStyle(Color.rcTextPrimary)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.rcSurfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.sm)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadVideo() }
    }

    private func loadVideo() async {
        guard let token = authManager.authToken,
              let render, render.isComplete else { return }
        do {
            let url = try await APIClient.getRenderDownloadURL(renderId: render.id, authToken: token)
            videoURL = url
            if let videoUrl = URL(string: url) {
                player = AVPlayer(url: videoUrl)
                startTimeTracking()
            }
        } catch {
            print("[Rawcut] Video load error: \(error)")
        }
    }

    private func segmentOffsets() -> [Double] {
        // Use render_offset if available (exact), fallback to cumulative calculation
        if let first = parsedSegments.first, first.render_offset != nil {
            return parsedSegments.map { $0.render_offset ?? 0 }
        }
        var offsets: [Double] = []
        var acc: Double = 0
        for seg in parsedSegments {
            offsets.append(acc)
            acc += seg.effectiveDuration
        }
        return offsets
    }

    private func seekToSegment(_ index: Int) {
        guard let player else { return }
        let offsets = segmentOffsets()
        guard index < offsets.count else { return }
        Task {
            await player.seek(to: CMTime(seconds: offsets[index], preferredTimescale: 600))
            player.play()
        }
    }

    private func startTimeTracking() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let capturedOffsets = segmentOffsets()
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak player] time in
            guard player != nil else { return }
            let seconds = time.seconds
            var current: Int? = nil
            for i in (0..<capturedOffsets.count).reversed() {
                if seconds >= capturedOffsets[i] - 0.1 {
                    current = i
                    break
                }
            }
            Task { @MainActor in
                if current != self.selectedSegment {
                    self.selectedSegment = current
                }
            }
        }
    }
}
