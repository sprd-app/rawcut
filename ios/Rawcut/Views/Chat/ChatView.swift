import AVKit
import PhotosUI
import SwiftUI

/// Unified chat-based vlog editor.
/// Timeline pins to top when script exists. Chat is purely conversational.
/// LLM decides when to render based on user approval in chat.
struct ChatView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var currentScript: ScriptResponse?
    @State private var suggestions: [String] = []
    @State private var clipCount = 0
    @State private var currentVideoURL: String?
    @State private var sessionId: String?
    @State private var savedSessions: [APIClient.ChatSessionListItem] = []
    @State private var showSessionList = false
    @State private var selectedSegmentIndex: Int?
    @State private var player: AVPlayer?
    @State private var showVideoPlayer = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var attachedImages: [AttachedMedia] = []

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Pinned preview (when script exists)
                if let script = currentScript {
                    previewHeader(script)
                }

                // Chat
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Spacing.sm) {
                            if messages.isEmpty && currentScript == nil {
                                welcomeView
                            }

                            ForEach(messages) { message in
                                chatBubble(message)
                            }

                            if isLoading {
                                HStack {
                                    TypingIndicator()
                                        .padding(.horizontal, Spacing.md)
                                        .padding(.vertical, 14)
                                        .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 18))
                                    Spacer(minLength: 60)
                                }
                                .padding(.horizontal, Spacing.lg)
                                .id("loading")
                            }
                        }
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.md)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let lastId = messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }

                inputBar
            }
        }
        .navigationTitle("Create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSessionList = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15))
                }
                .tint(Color.rcAccent)
                .accessibilityLabel("Session history")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !messages.isEmpty {
                    Button { startNewSession() } label: {
                        Image(systemName: "plus.message")
                            .font(.system(size: 15))
                    }
                    .tint(Color.rcAccent)
                    .accessibilityLabel("New session")
                }
            }
        }
        .task { await loadSuggestions() }
        .sheet(isPresented: $showSessionList) {
            SessionListSheet(
                sessions: $savedSessions,
                onSelect: { s in showSessionList = false; Task { await resumeSession(s) } },
                onDelete: { s in Task { await deleteSession(s) } }
            )
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Preview Header

    private func previewHeader(_ script: ScriptResponse) -> some View {
        VStack(spacing: 0) {
            if showVideoPlayer, let player {
                VideoPlayer(player: player)
                    .frame(height: 200)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if currentVideoURL != nil && !showVideoPlayer {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        showVideoPlayer = true
                        if player == nil, let u = currentVideoURL, let url = URL(string: u) {
                            player = AVPlayer(url: url)
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Watch video")
                            .font(.rcCaption)
                        Spacer()
                    }
                    .foregroundStyle(Color.rcAccent)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 6)
                }
            }

            // Timeline bar
            SegmentTimelineBar(
                segments: script.segments,
                selectedIndex: selectedSegmentIndex,
                onTapSegment: { i in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedSegmentIndex = selectedSegmentIndex == i ? nil : i
                    }
                    seekToSegment(i)
                }
            )
            .padding(.horizontal, Spacing.lg)
            .padding(.top, currentVideoURL != nil && !showVideoPlayer ? 0 : Spacing.sm)

            // Segment info row
            HStack(spacing: Spacing.xs) {
                if let idx = selectedSegmentIndex, idx < script.segments.count {
                    let seg = script.segments[idx]
                    Text("\(idx + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 16, height: 16)
                        .background(Color.rcAccent, in: Circle())
                    Text(seg.label)
                        .font(.rcCaptionBold)
                        .foregroundStyle(Color.rcTextPrimary)
                        .lineLimit(1)
                    let segDur = seg.duration ?? Int((seg.out_point ?? 0) - (seg.in_point ?? 0))
                    Text("\u{00B7} \(segDur)s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.rcTextTertiary)
                } else {
                    let total = script.segments.reduce(0) { $0 + ($1.duration ?? Int(($1.out_point ?? 0) - ($1.in_point ?? 0))) }
                    Text(script.title)
                        .font(.rcCaptionBold)
                        .foregroundStyle(Color.rcTextSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(script.segments.count) segs \u{00B7} \(total)s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.rcTextTertiary)
                }
                Spacer()
                if showVideoPlayer {
                    Button {
                        player?.pause()
                        withAnimation(.easeOut(duration: 0.2)) { showVideoPlayer = false }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.rcTextTertiary)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 6)
        }
        .background(Color.rcSurface)
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer().frame(height: 40)

            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Color.rcTextSecondary)

            Text("What's your vlog about?")
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)

            Text("Describe your day and I'll create\na cinematic edit from your footage.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)

            if !suggestions.isEmpty {
                VStack(spacing: Spacing.sm) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button { sendMessage(suggestion) } label: {
                            Text(suggestion)
                                .font(.rcBody)
                                .foregroundStyle(Color.rcTextPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.md)
                                .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.rcTextTertiary.opacity(0.5), lineWidth: 0.5))
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
            }

            if clipCount > 0 {
                Text("\(clipCount) clips ready")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextTertiary)
            }

            if !savedSessions.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Text("Recent sessions")
                        .font(.rcCaptionBold)
                        .foregroundStyle(Color.rcTextSecondary)

                    ForEach(savedSessions.prefix(3)) { session in
                        Button { Task { await resumeSession(session) } } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.rcTextTertiary)
                                Text(session.title)
                                    .font(.rcBody)
                                    .foregroundStyle(Color.rcTextPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(session.message_count) msgs")
                                    .font(.rcCaption)
                                    .foregroundStyle(Color.rcTextTertiary)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.sm)
            }

            Spacer()
        }
        .task { await loadSessions() }
    }

    // MARK: - Chat Bubbles

    @ViewBuilder
    private func chatBubble(_ message: ChatMessage) -> some View {
        if message.isUser {
            // User
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        Spacer(minLength: 60)
                        ForEach(Array(attachments.prefix(4).enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: attachments.count == 1 ? 120 : 56,
                                       height: attachments.count == 1 ? 120 : 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if attachments.count > 4 {
                            Text("+\(attachments.count - 4)")
                                .font(.rcCaptionBold)
                                .foregroundStyle(Color.rcTextSecondary)
                        }
                    }
                }
                if !message.text.isEmpty {
                    HStack {
                        Spacer(minLength: 60)
                        Text(message.text)
                            .font(.rcBody)
                            .foregroundStyle(Color.rcTextPrimary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 10)
                            .background(Color.rcSurfaceElevated, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .id(message.id)
        } else if message.videoURL != nil {
            // Render complete
            HStack {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.rcAccent)
                    Text(message.text)
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 10)
                .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 60)
            }
            .padding(.horizontal, Spacing.lg)
            .id(message.id)
        } else if let renderId = message.renderId {
            // Render progress
            RenderProgressBubble(renderId: renderId, token: authManager.authToken ?? "") { url in
                if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                    currentVideoURL = url
                    messages[idx] = ChatMessage(
                        text: "Done! Tap the player above to watch.",
                        isUser: false,
                        videoURL: url
                    )
                }
            }
            .id(message.id)
        } else if let script = message.script {
            // Director's script view
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // AI message
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 8)
                        .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 14))
                }

                // Script card
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Header
                    HStack {
                        Text(script.title)
                            .font(.rcTitleMedium)
                            .foregroundStyle(Color.rcTextPrimary)
                        Spacer()
                        let total = script.segments.reduce(0) { $0 + ($1.duration ?? Int(($1.out_point ?? 0) - ($1.in_point ?? 0))) }
                        Text("\(total)s")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.rcAccent)
                    }

                    // Segments
                    ForEach(Array(script.segments.enumerated()), id: \.offset) { index, seg in
                        let segType = seg.type ?? "clip"
                        VStack(alignment: .leading, spacing: 4) {
                            // Scene header
                            HStack(spacing: Spacing.sm) {
                                Text("SC \(index + 1)")
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

                                // Type badge
                                let badge = segType == "clip" ? "SRC" : segType == "title" ? "TXT" : "AI"
                                let badgeColor = segType == "clip" ? Color.rcAccentDim : Color.rcWarning
                                Text(badge)
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(badgeColor)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .stroke(badgeColor.opacity(0.4), lineWidth: 0.5))

                                // Duration
                                if let dur = seg.duration {
                                    Text("\(dur)s")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.rcTextSecondary)
                                } else if let out = seg.out_point, let inp = seg.in_point {
                                    Text("\(Int(out - inp))s")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.rcTextSecondary)
                                }
                            }

                            // Storyboard thumbnail (if available)
                            if let sbURL = seg.storyboard_url, let url = URL(string: sbURL) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.rcSurfaceElevated
                                }
                                .frame(height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            // Cinematography
                            if let cin = seg.cinematography, !cin.isEmpty {
                                Text(cin)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.rcAccentDim)
                                    .lineLimit(1)
                            }

                            // Description
                            if let desc = seg.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.rcTextTertiary)
                                    .lineLimit(2)
                            }

                            // Image prompt (for AI segments)
                            if segType != "clip", let prompt = seg.image_prompt, !prompt.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 8))
                                    Text(prompt)
                                        .font(.system(size: 10))
                                        .lineLimit(2)
                                }
                                .foregroundStyle(Color.rcWarning.opacity(0.7))
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, Spacing.sm)
                        .background(Color.rcSurfaceElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                        // Transition
                        if index < script.segments.count - 1 {
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
                .padding(Spacing.md)
                .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, Spacing.lg)
            .id(message.id)
        } else {
            // Plain AI text
            HStack {
                Text(message.text)
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                    .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 60)
            }
            .padding(.horizontal, Spacing.lg)
            .id(message.id)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Attachment preview
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(attachedImages) { media in
                            ZStack(alignment: .topTrailing) {
                                if let img = media.thumbnail {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    attachedImages.removeAll { $0.id == media.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Color.rcTextPrimary)
                                        .background(Color.rcBackground, in: Circle())
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                }
            }

            HStack(spacing: Spacing.sm) {
                // Segment context
                if let idx = selectedSegmentIndex, let script = currentScript, idx < script.segments.count {
                    Button { selectedSegmentIndex = nil } label: {
                        HStack(spacing: 2) {
                            Text("\(idx + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 16, height: 16)
                                .background(Color.rcAccent, in: Circle())
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Color.rcTextTertiary)
                        }
                    }
                }

                // Photo picker
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10,
                             matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.rcTextSecondary)
                }
                .accessibilityLabel("Attach photos or videos")
                .onChange(of: selectedPhotos) { _, items in
                    Task { await loadSelectedPhotos(items) }
                }

                let placeholder = selectedSegmentIndex != nil
                    ? "Feedback on segment \(selectedSegmentIndex! + 1)..."
                    : currentScript != nil
                        ? "Give feedback or say 'render'..."
                        : "Describe your vlog..."

                TextField(placeholder, text: $inputText, axis: .vertical)
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 12))

                if isLoading {
                    ProgressView()
                        .tint(Color.rcAccent)
                        .frame(width: 30, height: 30)
                } else {
                    Button {
                        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty || !attachedImages.isEmpty else { return }
                        let msg: String
                        if let idx = selectedSegmentIndex, let script = currentScript, idx < script.segments.count {
                            msg = "[Segment \(idx + 1): \(script.segments[idx].label)] \(text)"
                            selectedSegmentIndex = nil
                        } else {
                            msg = text
                        }
                        sendMessage(msg)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(
                                (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImages.isEmpty)
                                ? Color.rcTextTertiary : Color.rcAccent
                            )
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImages.isEmpty)
                    .accessibilityLabel("Send message")
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 8)
        }
        .background(Color.rcBackground)
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            // Skip if already attached
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                let thumb = img.preparingThumbnail(of: CGSize(width: 112, height: 112)) ?? img
                attachedImages.append(AttachedMedia(thumbnail: thumb, data: data, isVideo: item.supportedContentTypes.contains(.movie)))
            }
        }
        selectedPhotos = []
    }

    // MARK: - Actions

    private func loadSuggestions() async {
        guard let token = authManager.authToken else { return }
        let tz = TimeZone.current.secondsFromGMT()
        guard let url = URL(string: "\(APIClient.baseURL)/api/chat/suggestions?timezone_offset=\(tz)") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct R: Decodable { let suggestions: [String]; let clip_count: Int }
            let resp = try JSONDecoder().decode(R.self, from: data)
            suggestions = resp.suggestions
            clipCount = resp.clip_count
        } catch {
            print("[Rawcut] Suggestions error: \(error)")
        }
    }

    private func loadSessions() async {
        guard let token = authManager.authToken else { return }
        do { savedSessions = try await APIClient.listSessions(authToken: token) }
        catch { print("[Rawcut] Sessions error: \(error)") }
    }

    private func sendMessage(_ text: String) {
        let thumbs = attachedImages.map { $0.thumbnail }.compactMap { $0 }
        let mediaData = attachedImages.map { $0.data }
        messages.append(ChatMessage(text: text, isUser: true, attachments: thumbs.isEmpty ? nil : thumbs))
        let msgText = text.isEmpty ? "\(attachedImages.count) media attached" : text
        attachedImages = []
        inputText = ""
        isLoading = true
        Task {
            if !mediaData.isEmpty {
                await uploadAttachments(mediaData)
            }
            await chat(userMessage: msgText)
            isLoading = false
            await autoSaveSession()
        }
    }

    private func uploadAttachments(_ items: [Data]) async {
        guard let token = authManager.authToken else { return }
        for (i, data) in items.enumerated() {
            let isImage = UIImage(data: data) != nil
            let ext = isImage ? "jpg" : "mp4"
            let contentType = isImage ? "image/jpeg" : "video/mp4"
            let filename = "chat_attach_\(UUID().uuidString.prefix(8)).\(ext)"

            guard let url = URL(string: "\(APIClient.baseURL)/api/upload/\(filename)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(filename, forHTTPHeaderField: "X-Filename")

            do {
                let (_, resp) = try await URLSession.shared.upload(for: request, from: data)
                if let http = resp as? HTTPURLResponse {
                    print("[Rawcut] Upload attachment \(i): HTTP \(http.statusCode)")
                }
            } catch {
                print("[Rawcut] Upload attachment failed: \(error)")
            }
        }
    }

    private func chat(userMessage: String) async {
        guard let token = authManager.authToken else {
            messages.append(ChatMessage(text: "Sign in required.", isUser: false))
            return
        }

        guard let url = URL(string: "\(APIClient.baseURL)/api/chat") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let history: [[String: String]] = messages.dropLast().compactMap { msg in
            if msg.isUser { return ["role": "user", "content": msg.text] }
            if !msg.text.isEmpty { return ["role": "assistant", "content": msg.text] }
            return nil
        }

        var body: [String: Any] = [
            "message": userMessage,
            "timezone_offset": TimeZone.current.secondsFromGMT(),
            "history": history,
        ]
        if let script = currentScript,
           let data = try? JSONEncoder().encode(script),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body["current_script"] = dict
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                struct E: Decodable { let detail: String }
                let msg = (try? JSONDecoder().decode(E.self, from: data))?.detail ?? "Something went wrong."
                messages.append(ChatMessage(text: msg, isUser: false))
                return
            }

            struct ChatResp: Decodable {
                let script: ScriptResponse
                let message: String?
                let action: String?
                let clip_count: Int
            }
            let resp = try JSONDecoder().decode(ChatResp.self, from: data)
            let action = resp.action ?? "update"
            let aiMessage = resp.message ?? ""

            // Update script if segments exist
            if !resp.script.segments.isEmpty {
                currentScript = resp.script
                selectedSegmentIndex = nil
            }
            clipCount = resp.clip_count

            // Show AI message
            let displayText = aiMessage.isEmpty
                ? "\(resp.script.segments.count) segments, \(resp.script.segments.reduce(0) { $0 + ($1.duration ?? Int(($1.out_point ?? 0) - ($1.in_point ?? 0))) })s"
                : aiMessage
            messages.append(ChatMessage(
                text: displayText,
                isUser: false,
                script: resp.script.segments.isEmpty ? nil : resp.script
            ))

            // Auto-trigger storyboard for visual preview
            if !resp.script.segments.isEmpty && action == "update" {
                await generateStoryboard(resp.script)
            }

            // Auto-render if LLM says so
            if action == "render" && !resp.script.segments.isEmpty {
                // Generate storyboard first if not already done
                if currentScript?.segments.first?.storyboard_url == nil {
                    await generateStoryboard(resp.script)
                }
                await triggerRender(currentScript ?? resp.script)
            }
        } catch {
            messages.append(ChatMessage(text: "Failed to connect.", isUser: false))
            print("[Rawcut] Chat error: \(error)")
        }
    }

    private func generateStoryboard(_ script: ScriptResponse) async {
        guard let token = authManager.authToken else { return }
        guard let url = URL(string: "\(APIClient.baseURL)/api/chat/storyboard") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let segsData = try? JSONEncoder().encode(script.segments)
        let segsObj = segsData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let body: [String: Any] = [
            "segments": segsObj ?? [],
            "session_id": sessionId ?? "default",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                print("[Rawcut] Storyboard API error")
                return
            }

            struct SBResponse: Decodable {
                let segments: [ScriptSegment]
            }
            let sbResp = try JSONDecoder().decode(SBResponse.self, from: data)

            // Update current script with storyboard URLs
            currentScript = ScriptResponse(
                title: script.title,
                total_duration_estimate: script.total_duration_estimate,
                segments: sbResp.segments
            )

            // Update the last script message with storyboard data
            if let lastIdx = messages.lastIndex(where: { $0.script != nil }) {
                messages[lastIdx] = ChatMessage(
                    text: messages[lastIdx].text,
                    isUser: false,
                    script: currentScript
                )
            }
            print("[Rawcut] Storyboard: \(sbResp.segments.filter { $0.storyboard_url != nil }.count)/\(sbResp.segments.count) images ready")
        } catch {
            print("[Rawcut] Storyboard error: \(error)")
        }
    }

    private func triggerRender(_ script: ScriptResponse) async {
        guard let token = authManager.authToken else { return }

        do {
            let project = try await APIClient.createProject(
                title: script.title,
                description: "Generated by AI chat",
                authToken: token
            )

            struct ClipItem: Encodable {
                let asset_id: String; let position: Int
                let trim_start: Double; let trim_end: Double?; let role: String
            }
            struct ClipBody: Encodable { let clips: [ClipItem] }

            // Only include clip-based segments
            let clips = script.segments.enumerated().compactMap { i, seg -> ClipItem? in
                guard seg.type == "clip" || seg.type == nil, let clipId = seg.clip_id else { return nil }
                return ClipItem(asset_id: clipId, position: i,
                                trim_start: seg.in_point ?? 0, trim_end: seg.out_point, role: "auto")
            }

            guard let clipsURL = URL(string: "\(APIClient.baseURL)/api/projects/\(project.id)/clips") else { return }
            var clipsReq = URLRequest(url: clipsURL)
            clipsReq.httpMethod = "PUT"
            clipsReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            clipsReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            clipsReq.httpBody = try JSONEncoder().encode(ClipBody(clips: clips))
            let (_, clipsResp) = try await URLSession.shared.data(for: clipsReq)
            if let h = clipsResp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { return }

            // Pass full segments JSON for AI provider support
            let segmentsData = try JSONEncoder().encode(script.segments)
            let segmentsDicts = try JSONSerialization.jsonObject(with: segmentsData) as? [[String: Any]]

            let render = try await APIClient.startRender(
                projectId: project.id, preset: "warm_film",
                segments: segmentsDicts, authToken: token
            )

            messages.append(ChatMessage(text: "Rendering...", isUser: false, renderId: render.id))

            // Link session to project for bidirectional navigation
            if let sid = sessionId {
                try? await APIClient.updateSession(
                    id: sid, projectId: project.id, authToken: token
                )
            }
        } catch {
            messages.append(ChatMessage(text: "Render failed: \(error.localizedDescription)", isUser: false))
        }
    }

    // MARK: - Seek

    private func seekToSegment(_ index: Int) {
        guard let player, currentVideoURL != nil, let script = currentScript else { return }
        var offset: Double = 0
        for i in 0..<index { offset += Double(script.segments[i].duration ?? Int((script.segments[i].out_point ?? 0) - (script.segments[i].in_point ?? 0))) }
        Task {
            await player.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
            player.play()
        }
        if !showVideoPlayer {
            withAnimation(.easeOut(duration: 0.25)) { showVideoPlayer = true }
        }
    }

    // MARK: - Session Management

    private func autoSaveSession() async {
        guard let token = authManager.authToken else { return }
        let msgDicts: [[String: String]] = messages.map { msg in
            var d: [String: String] = ["text": msg.text, "isUser": msg.isUser ? "true" : "false"]
            if let v = msg.videoURL { d["videoURL"] = v }
            return d
        }
        do {
            if let sid = sessionId {
                try await APIClient.updateSession(id: sid, messages: msgDicts,
                                                  currentScript: currentScript, authToken: token)
            } else {
                let title = currentScript?.title ?? "Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                let session = try await APIClient.createSession(title: title, authToken: token)
                sessionId = session.id
                try await APIClient.updateSession(id: session.id, messages: msgDicts,
                                                  currentScript: currentScript, authToken: token)
            }
        } catch { print("[Rawcut] Save error: \(error)") }
    }

    private func resumeSession(_ session: APIClient.ChatSessionListItem) async {
        guard let token = authManager.authToken else { return }
        do {
            let full = try await APIClient.getSession(id: session.id, authToken: token)
            startNewSession()
            sessionId = full.id
            currentScript = full.current_script
            messages = (full.messages ?? []).map { dict in
                ChatMessage(text: dict["text"] ?? "", isUser: dict["isUser"] == "true",
                            renderId: nil, videoURL: dict["videoURL"])
            }
            if let lastVideo = messages.last(where: { $0.videoURL != nil }) {
                currentVideoURL = lastVideo.videoURL
            }
            if let script = currentScript,
               let idx = messages.lastIndex(where: { !$0.isUser && $0.text.contains("seg") }) {
                messages[idx] = ChatMessage(text: messages[idx].text, isUser: false, script: script)
            }
        } catch { print("[Rawcut] Resume error: \(error)") }
    }

    private func startNewSession() {
        messages.removeAll()
        currentScript = nil
        currentVideoURL = nil
        inputText = ""
        sessionId = nil
        selectedSegmentIndex = nil
        showVideoPlayer = false
        player?.pause()
        player = nil
    }

    private func deleteSession(_ session: APIClient.ChatSessionListItem) async {
        guard let token = authManager.authToken else { return }
        do {
            try await APIClient.deleteSession(id: session.id, authToken: token)
            savedSessions.removeAll { $0.id == session.id }
        } catch { print("[Rawcut] Delete error: \(error)") }
    }
}

// MARK: - Session List

struct SessionListSheet: View {
    @Binding var sessions: [APIClient.ChatSessionListItem]
    let onSelect: (APIClient.ChatSessionListItem) -> Void
    let onDelete: (APIClient.ChatSessionListItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "No Saved Sessions",
                        description: "Your chat sessions will appear here."
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            Button { onSelect(session) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title)
                                        .font(.rcBodyMedium)
                                    HStack(spacing: Spacing.sm) {
                                        Text("\(session.message_count) msgs")
                                            .font(.rcCaption)
                                            .foregroundStyle(.secondary)
                                        if session.has_script {
                                            Text("Script ready")
                                                .font(.rcCaption)
                                                .foregroundStyle(Color.rcAccent)
                                        }
                                    }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for idx in indexSet { onDelete(sessions[idx]) }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Models

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.rcAccent)
                    .frame(width: 6, height: 6)
                    .offset(y: animate && !reduceMotion ? -4 : 0)
                    .animation(
                        reduceMotion ? nil :
                            .easeInOut(duration: 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                        value: animate
                    )
            }
        }
        .opacity(reduceMotion ? 0.8 : 1.0)
        .onAppear { animate = true }
        .accessibilityLabel("AI is thinking")
    }
}

struct AttachedMedia: Identifiable {
    let id = UUID()
    let thumbnail: UIImage?
    let data: Data
    let isVideo: Bool
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    var script: ScriptResponse?
    var renderId: String?
    var videoURL: String?
    var attachments: [UIImage]?
}

struct ScriptResponse: Codable {
    let title: String
    let total_duration_estimate: Int?
    let segments: [ScriptSegment]
}

struct ScriptSegment: Codable, Identifiable {
    var id: String { (clip_id ?? label) + label + "\(duration ?? 0)" }
    let type: String?           // clip, title, generate, photo_to_video
    let label: String
    let clip_id: String?
    let in_point: Double?
    let out_point: Double?
    let duration: Int?
    let description: String?
    let transition: String?
    let cinematography: String? // free-text
    let image_prompt: String?
    let video_prompt: String?
    let text: String?           // for title cards
    let text_style: String?
    let storyboard_url: String? // filled after Phase 1
    let storyboard_status: String?
    let actual_duration: Double? // filled after render
    let render_offset: Double?   // exact position in final video
    let render_duration: Double? // exact duration in final video

    /// Best duration estimate
    var effectiveDuration: Double {
        if let rd = render_duration, rd > 0 { return rd }
        if let ad = actual_duration, ad > 0 { return ad }
        if let d = duration, d > 0 { return Double(d) }
        let diff = (out_point ?? 0) - (in_point ?? 0)
        return diff > 0 ? diff : 4.0
    }
}
