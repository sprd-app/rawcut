import SwiftUI

/// Native card displaying a vlog script with segments.
/// Shows title, segments with labels/durations, and a render button.
struct ScriptCardView: View {
    let script: ScriptResponse
    let onRender: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Title
            Text(script.title)
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)

            // Total duration
            let totalDur = script.segments.reduce(0) { $0 + $1.duration }
            Text("\(totalDur)s \u{00B7} \(script.segments.count) segments")
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextSecondary)

            // Segments list
            VStack(spacing: 2) {
                ForEach(Array(script.segments.enumerated()), id: \.offset) { index, segment in
                    segmentRow(segment, index: index)
                }
            }

            // Render button
            Button(action: onRender) {
                HStack {
                    Spacer()
                    Image(systemName: "film")
                    Text("Render Video")
                        .font(.rcBodyMedium)
                    Spacer()
                }
                .foregroundStyle(.black)
                .padding(.vertical, Spacing.md)
                .background(Color.rcAccent, in: RoundedRectangle(cornerRadius: 10))
            }

            // Hint
            Text("Type feedback to refine, or tap Render")
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(Spacing.lg)
        .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func segmentRow(_ segment: ScriptSegment, index: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            // Index
            Text("\(index + 1)")
                .font(.rcCaptionBold)
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Color.rcAccent, in: Circle())

            // Label + reason
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.label)
                    .font(.rcBodyMedium)
                    .foregroundStyle(Color.rcTextPrimary)

                Text(segment.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rcTextTertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text("\(segment.duration)s")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.rcTextSecondary)

            // Transition icon
            transitionIcon(segment.transition)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(Color.rcSurfaceElevated, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func transitionIcon(_ transition: String) -> some View {
        switch transition {
        case "fade_from_black":
            Image(systemName: "square.filled.on.square")
                .font(.system(size: 10))
                .foregroundStyle(Color.rcTextTertiary)
        case "fade":
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 10))
                .foregroundStyle(Color.rcTextTertiary)
        case "dissolve":
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(Color.rcTextTertiary)
        default: // "cut"
            Image(systemName: "scissors")
                .font(.system(size: 10))
                .foregroundStyle(Color.rcTextTertiary)
        }
    }
}
