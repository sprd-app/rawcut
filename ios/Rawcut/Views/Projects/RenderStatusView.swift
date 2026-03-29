import SwiftUI

/// Polls render status and shows progress. Opens download on completion.
struct RenderStatusView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    let renderId: String

    @State private var render: APIClient.Render?
    @State private var downloadURL: String?
    @State private var isPolling = true
    @State private var errorMessage: String?
    @State private var showingPresetPicker = false
    @State private var isReRendering = false
    @State private var isDownloading = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rcBackground.ignoresSafeArea()

                if let render {
                    VStack(spacing: Spacing.xl) {
                        Spacer()

                        statusIcon(render)
                        statusText(render)
                        progressSection(render)

                        if render.isComplete {
                            downloadButton
                            reRenderButton
                        }

                        if render.isFailed {
                            failureInfo(render)
                        }

                        Spacer()
                    }
                    .padding(Spacing.xl)
                } else {
                    ProgressView("불러오는 중...")
                        .tint(Color.rcAccent)
                        .foregroundStyle(Color.rcTextSecondary)
                }
            }
            .navigationTitle("렌더 상태")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(Color.rcAccent)
                }
            }
            .task {
                await pollRenderStatus()
            }
        }
    }

    // MARK: - Components

    private func statusIcon(_ render: APIClient.Render) -> some View {
        Group {
            if render.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.rcAccent)
            } else if render.isFailed {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.rcError)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.rcSurface, lineWidth: 6)
                        .frame(width: 80, height: 80)

                    Circle()
                        .trim(from: 0, to: render.progress)
                        .stroke(Color.rcAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: render.progress)

                    Text("\(Int(render.progress * 100))%")
                        .font(.rcStat)
                        .foregroundStyle(Color.rcTextPrimary)
                }
            }
        }
    }

    private func statusText(_ render: APIClient.Render) -> some View {
        VStack(spacing: Spacing.xs) {
            Text(statusTitle(render))
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)

            Text(statusSubtitle(render))
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)

            Text(render.preset.replacingOccurrences(of: "_", with: " ").capitalized
                 + " · " + render.aspect_ratio)
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextTertiary)
        }
    }

    private func progressSection(_ render: APIClient.Render) -> some View {
        Group {
            if render.isProcessing {
                VStack(spacing: Spacing.sm) {
                    ProgressView(value: render.progress)
                        .tint(Color.rcAccent)
                        .scaleEffect(y: 2)

                    Text(progressDetail(render))
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
                .padding(.horizontal, Spacing.xl)
            }
        }
    }

    private var downloadButton: some View {
        Button {
            Task { await downloadAndShare() }
        } label: {
            HStack {
                Spacer()
                if isDownloading {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: "square.and.arrow.up")
                    Text("공유 & 저장")
                        .font(.rcBodyMedium)
                }
                Spacer()
            }
            .foregroundStyle(.black)
            .padding(.vertical, Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.rcAccent)
            )
        }
        .disabled(isDownloading)
        .padding(.horizontal, Spacing.xl)
    }

    private var reRenderButton: some View {
        Button {
            showingPresetPicker = true
        } label: {
            HStack {
                Spacer()
                Image(systemName: "paintbrush")
                Text("다른 느낌으로")
                    .font(.rcBodyMedium)
                Spacer()
            }
            .foregroundStyle(Color.rcAccent)
            .padding(.vertical, Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.rcSurface)
            )
        }
        .padding(.horizontal, Spacing.xl)
        .confirmationDialog("프리셋 선택", isPresented: $showingPresetPicker) {
            Button("Warm Film") { Task { await reRender(preset: "warm_film") } }
            Button("Cool Minimal") { Task { await reRender(preset: "cool_minimal") } }
            Button("Natural Vivid") { Task { await reRender(preset: "natural_vivid") } }
            Button("취소", role: .cancel) {}
        }
    }

    private func failureInfo(_ render: APIClient.Render) -> some View {
        VStack(spacing: Spacing.sm) {
            if let error = render.error {
                Text(error)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcError)
                    .multilineTextAlignment(.center)
            }

            Button("닫기") { dismiss() }
                .font(.rcBodyMedium)
                .foregroundStyle(Color.rcAccent)
        }
    }

    // MARK: - Text Helpers

    private func statusTitle(_ render: APIClient.Render) -> String {
        switch render.status {
        case "queued": return "렌더 대기 중"
        case "processing": return "렌더링 중..."
        case "complete": return "렌더 완료!"
        case "failed": return "렌더 실패"
        default: return render.status
        }
    }

    private func statusSubtitle(_ render: APIClient.Render) -> String {
        switch render.status {
        case "queued": return "곧 시작됩니다"
        case "processing": return "영상을 처리하고 있습니다"
        case "complete": return "시네마틱 영상이 준비되었습니다"
        case "failed": return "문제가 발생했습니다"
        default: return ""
        }
    }

    private func progressDetail(_ render: APIClient.Render) -> String {
        let pct = Int(render.progress * 100)
        if pct < 30 {
            return "클립 다운로드 중..."
        } else if pct < 80 {
            return "색보정 및 필터 적용 중..."
        } else {
            return "최종 합성 중..."
        }
    }

    // MARK: - Actions

    private func pollRenderStatus() async {
        guard let token = authManager.authToken else { return }

        while isPolling {
            do {
                let status = try await APIClient.getRenderStatus(renderId: renderId, authToken: token)
                render = status

                if status.isComplete || status.isFailed {
                    isPolling = false
                    break
                }
            } catch {
                print("[Rawcut] Failed to poll render status: \(error)")
            }

            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func downloadAndShare() async {
        guard let token = authManager.authToken else { return }
        isDownloading = true
        defer { isDownloading = false }

        do {
            let urlString = try await APIClient.getRenderDownloadURL(renderId: renderId, authToken: token)
            guard let remoteURL = URL(string: urlString) else { return }

            // Download to temp file
            let (localURL, _) = try await URLSession.shared.download(from: remoteURL)
            let tempDir = FileManager.default.temporaryDirectory
            let dest = tempDir.appendingPathComponent("\(renderId).mp4")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: localURL, to: dest)

            // Present share sheet
            await MainActor.run {
                let activityVC = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
            }
        } catch {
            errorMessage = "다운로드에 실패했습니다."
            print("[Rawcut] Download failed: \(error)")
        }
    }

    private func reRender(preset: String) async {
        guard let token = authManager.authToken else { return }
        guard let projectId = render?.project_id else { return }

        isReRendering = true
        do {
            let newRender = try await APIClient.startRender(
                projectId: projectId,
                preset: preset,
                authToken: token
            )
            // Reset to polling the new render
            render = newRender
            isPolling = true
            await pollRenderStatus()
        } catch {
            errorMessage = "재렌더링 시작에 실패했습니다."
            print("[Rawcut] Re-render failed: \(error)")
        }
        isReRendering = false
    }
}
