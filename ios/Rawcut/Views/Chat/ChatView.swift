import SwiftUI

/// Chat-based vlog editor. User types intent, AI generates script,
/// user iterates via chat until satisfied, then renders.
struct ChatView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var currentScript: ScriptResponse?
    @State private var suggestions: [String] = []
    @State private var clipCount = 0

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Spacing.md) {
                            if messages.isEmpty {
                                welcomeView
                            }

                            ForEach(messages) { message in
                                chatBubble(message)
                            }

                            if isLoading {
                                HStack {
                                    ProgressView()
                                        .tint(Color.rcAccent)
                                    Text("Generating script...")
                                        .font(.rcCaption)
                                        .foregroundStyle(Color.rcTextSecondary)
                                    Spacer()
                                }
                                .padding(.horizontal, Spacing.lg)
                                .id("loading")
                            }
                        }
                        .padding(.vertical, Spacing.md)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let lastId = messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }

                // Input bar
                inputBar
            }
        }
        .navigationTitle("Create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await loadSuggestions()
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer().frame(height: 60)

            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Color.rcAccent)

            Text("What's your vlog about?")
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)

            Text("Describe your day and I'll create a cinematic edit from your footage.")
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            if !suggestions.isEmpty {
                VStack(spacing: Spacing.sm) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            sendMessage(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.rcBody)
                                .foregroundStyle(Color.rcAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.rcSurface)
                                )
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

            Spacer()
        }
    }

    // MARK: - Chat Bubble

    @ViewBuilder
    private func chatBubble(_ message: ChatMessage) -> some View {
        if message.isUser {
            // User message
            HStack {
                Spacer()
                Text(message.text)
                    .font(.rcBody)
                    .foregroundStyle(.white)
                    .padding(Spacing.md)
                    .background(Color.rcAccent, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.leading, 60)
            }
            .padding(.horizontal, Spacing.lg)
            .id(message.id)
        } else if let script = message.script {
            // AI message with script
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                        .padding(.horizontal, Spacing.lg)
                }

                ScriptCardView(script: script) {
                    renderScript(script)
                }
                .padding(.horizontal, Spacing.lg)
            }
            .id(message.id)
        } else {
            // Plain AI text
            HStack {
                Text(message.text)
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.trailing, 60)
                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .id(message.id)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: Spacing.sm) {
            TextField("Describe your vlog...", text: $inputText, axis: .vertical)
                .font(.rcBody)
                .foregroundStyle(Color.rcTextPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.rcSurface, in: RoundedRectangle(cornerRadius: 20))

            Button {
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                sendMessage(text)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.rcTextTertiary : Color.rcAccent
                    )
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Color.rcBackground)
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
            struct SuggestionsResp: Decodable { let suggestions: [String]; let clip_count: Int }
            let resp = try JSONDecoder().decode(SuggestionsResp.self, from: data)
            suggestions = resp.suggestions
            clipCount = resp.clip_count
        } catch {
            print("[Rawcut] Failed to load suggestions: \(error)")
        }
    }

    private func sendMessage(_ text: String) {
        let userMsg = ChatMessage(text: text, isUser: true)
        messages.append(userMsg)
        inputText = ""
        isLoading = true

        Task {
            await generateScript(userMessage: text)
            isLoading = false
        }
    }

    private func generateScript(userMessage: String) async {
        guard let token = authManager.authToken else {
            messages.append(ChatMessage(text: "Sign in required.", isUser: false))
            return
        }

        guard let url = URL(string: "\(APIClient.baseURL)/api/chat") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct ChatReq: Encodable {
            let message: String
            let timezone_offset: Int
            let current_script: [String: AnyCodable]?

            struct AnyCodable: Encodable {
                let value: Any
                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    if let s = value as? String { try container.encode(s) }
                    else if let i = value as? Int { try container.encode(i) }
                    else if let d = value as? Double { try container.encode(d) }
                    else { try container.encode(String(describing: value)) }
                }
            }
        }

        let body: [String: Any] = [
            "message": userMessage,
            "timezone_offset": TimeZone.current.secondsFromGMT(),
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                struct ErrorResp: Decodable { let detail: String }
                if let err = try? JSONDecoder().decode(ErrorResp.self, from: data) {
                    messages.append(ChatMessage(text: err.detail, isUser: false))
                } else {
                    messages.append(ChatMessage(text: "Something went wrong.", isUser: false))
                }
                return
            }

            struct ChatResp: Decodable {
                let script: ScriptResponse
                let clip_count: Int
            }
            let resp = try JSONDecoder().decode(ChatResp.self, from: data)
            currentScript = resp.script
            clipCount = resp.clip_count

            let totalDur = resp.script.segments.reduce(0) { $0 + $1.duration }
            let aiMsg = ChatMessage(
                text: "Here's your \(totalDur)s vlog with \(resp.script.segments.count) segments:",
                isUser: false,
                script: resp.script
            )
            messages.append(aiMsg)
        } catch {
            messages.append(ChatMessage(text: "Failed to generate script.", isUser: false))
            print("[Rawcut] Chat error: \(error)")
        }
    }

    private func renderScript(_ script: ScriptResponse) {
        // TODO: Convert script to project + clips + start render
        messages.append(ChatMessage(text: "Rendering... (coming soon)", isUser: false))
    }
}

// MARK: - Models

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    var script: ScriptResponse?
}

struct ScriptResponse: Codable {
    let title: String
    let total_duration_estimate: Int?
    let segments: [ScriptSegment]
}

struct ScriptSegment: Codable, Identifiable {
    var id: String { clip_id + label }
    let label: String
    let clip_id: String
    let trim_start: Double
    let trim_end: Double?
    let duration: Int
    let reason: String
    let transition: String
}
