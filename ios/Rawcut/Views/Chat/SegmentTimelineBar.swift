import SwiftUI

/// Horizontal timeline bar showing segments proportionally with playback marker.
struct SegmentTimelineBar: View {
    let segments: [ScriptSegment]
    let selectedIndex: Int?
    let onTapSegment: (Int) -> Void

    private var totalDuration: Double {
        segments.reduce(0) { $0 + $1.effectiveDuration }
    }

    private let segmentColors: [Color] = [
        .white,
        Color(white: 0.85),
        Color(white: 0.70),
        Color(white: 0.90),
        Color(white: 0.65),
        Color(white: 0.80),
        Color(white: 0.75),
        Color(white: 0.88),
    ]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let fraction = totalDuration > 0
                        ? CGFloat(segment.effectiveDuration) / CGFloat(totalDuration)
                        : 1.0 / CGFloat(max(segments.count, 1))
                    let width = max((geo.size.width - CGFloat(segments.count - 1) * 2) * fraction, 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(colorFor(index))
                        .frame(width: width)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(selectedIndex == index ? Color.white : Color.clear, lineWidth: 2)
                        )
                        .overlay {
                            if width > 30 {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(selectedIndex == index ? .white : .white.opacity(0.7))
                            }
                        }
                        .onTapGesture {
                            onTapSegment(index)
                        }
                }
            }
        }
        .frame(height: 32)
    }

    private func colorFor(_ index: Int) -> Color {
        let base = segmentColors[index % segmentColors.count]
        if let sel = selectedIndex, sel == index {
            return base
        }
        return base.opacity(0.6)
    }
}
