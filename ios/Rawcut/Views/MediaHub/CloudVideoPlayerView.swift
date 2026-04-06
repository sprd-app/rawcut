import AVKit
import SwiftUI

/// Streams a cloud-only video via signed URL without full download.
/// Uses AVPlayer with progressive download (Azure Blob supports Range requests).
struct CloudVideoPlayerView: View {
    let blobName: String
    @EnvironmentObject private var authManager: AuthManager
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onDisappear {
                        player.pause()
                    }
            } else if let errorMessage {
                VStack(spacing: Spacing.md) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.rcError)

                    Text(errorMessage)
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextSecondary)
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        loadStream()
                    }
                    .font(.rcBodyMedium)
                    .foregroundStyle(Color.rcAccent)
                }
                .padding(Spacing.xxl)
            } else {
                ProgressView()
                    .tint(Color.rcAccent)
            }
        }
        .onAppear {
            loadStream()
        }
    }

    private func loadStream() {
        isLoading = true
        errorMessage = nil

        Task {
            guard let token = authManager.authToken else {
                errorMessage = "Not authenticated"
                isLoading = false
                return
            }

            do {
                let streamURL = try await APIClient.getMediaStreamURL(
                    blobName: blobName,
                    authToken: token
                )
                guard let url = URL(string: streamURL) else {
                    errorMessage = "Invalid stream URL"
                    isLoading = false
                    return
                }

                let avPlayer = AVPlayer(url: url)
                self.player = avPlayer
                self.isLoading = false
                avPlayer.play()
            } catch {
                errorMessage = "Failed to load video: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}
