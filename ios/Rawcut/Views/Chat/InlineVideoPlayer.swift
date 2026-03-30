import AVKit
import SwiftUI

/// Inline video player for chat bubbles.
struct InlineVideoPlayer: View {
    let urlString: String

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ZStack {
                    Color.rcSurface
                    ProgressView()
                        .tint(Color.rcAccent)
                }
            }
        }
        .onAppear {
            if let url = URL(string: urlString) {
                player = AVPlayer(url: url)
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}
