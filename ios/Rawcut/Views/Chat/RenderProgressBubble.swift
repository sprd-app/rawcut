import SwiftUI

/// Shows render progress inline in a chat bubble.
/// Polls render status and calls onComplete with video URL when done.
struct RenderProgressBubble: View {
    let renderId: String
    let token: String
    let onComplete: (String) -> Void

    @State private var progress: Double = 0
    @State private var status = "queued"
    @State private var error: String?
    @State private var isPolling = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let error {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.rcError)
                    Text("Render failed: \(error)")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcError)
                        .lineLimit(2)
                }
                .padding(Spacing.md)
                .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, Spacing.lg)
            } else {
                HStack(spacing: Spacing.md) {
                    // Progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.rcSurface, lineWidth: 4)
                            .frame(width: 40, height: 40)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.rcAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 40, height: 40)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.rcTextPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rendering...")
                            .font(.rcBodyMedium)
                            .foregroundStyle(Color.rcTextPrimary)
                        Text(progressDetail)
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                }
                .padding(Spacing.md)
                .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, Spacing.lg)
            }
        }
        .task {
            await pollRender()
        }
    }

    private var progressDetail: String {
        let pct = Int(progress * 100)
        if pct < 30 { return "Downloading clips..." }
        if pct < 80 { return "Applying color grading..." }
        return "Final compositing..."
    }

    private func pollRender() async {
        while isPolling {
            do {
                let render = try await APIClient.getRenderStatus(renderId: renderId, authToken: token)
                progress = render.progress
                status = render.status

                if render.isComplete {
                    isPolling = false
                    let url = try await APIClient.getRenderDownloadURL(renderId: renderId, authToken: token)
                    onComplete(url)
                    return
                }
                if render.isFailed {
                    isPolling = false
                    error = render.error ?? "Unknown error"
                    return
                }
            } catch {
                // Keep polling
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
