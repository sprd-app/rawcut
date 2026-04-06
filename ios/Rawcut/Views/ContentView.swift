import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authManager: AuthManager

    @State private var selectedTab: Tab = .library
    @State private var isOnboardingComplete: Bool =
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.hasCompletedOnboarding)

    enum Tab: Hashable {
        case library
        case create
        case projects
        case settings
    }

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                authenticatedContent
            } else {
                SignInView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToCreateTab)) { _ in
            selectedTab = .create
        }
    }

    // MARK: - Authenticated Content

    private var authenticatedContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                MediaHubView()
            }
            .tabItem {
                Label("Library", systemImage: "photo.on.rectangle.angled")
            }
            .tag(Tab.library)

            NavigationStack {
                ChatView()
            }
            .tabItem {
                Label("Create", systemImage: "plus.circle.fill")
            }
            .tag(Tab.create)

            NavigationStack {
                ProjectsView()
            }
            .tabItem {
                Label("Projects", systemImage: "film.stack")
            }
            .tag(Tab.projects)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .tint(Color.rcAccent)
        .fullScreenCover(isPresented: Binding(
            get: { !isOnboardingComplete },
            set: { isOnboardingComplete = !$0 }
        )) {
            OnboardingView(isOnboardingComplete: $isOnboardingComplete)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted from ProjectsView to switch to Create tab and resume a chat session.
    static let switchToCreateTab = Notification.Name("com.rawcut.switchToCreateTab")
}

// MARK: - Placeholder Views

private struct CreatePlaceholderView: View {
    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()
            EmptyStateView(
                icon: "plus.circle",
                title: "Create a Vlog",
                description: "Select footage, write a script, and let rawcut handle the rest."
            )
        }
        .navigationTitle("Create")
    }
}

private struct ProjectsPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()
            EmptyStateView(
                icon: "film.stack",
                title: "No Projects Yet",
                description: "Your finished vlogs will appear here."
            )
        }
        .navigationTitle("Projects")
    }
}

// MARK: - UserDefaults Keys

extension UserDefaults {
    enum Keys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }
}

// MARK: - Design Tokens

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

extension Color {
    static let rcBackground = Color(red: 0, green: 0, blue: 0)
    static let rcSurface = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)
    static let rcSurfaceElevated = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255)
    static let rcAccent = Color(red: 0x4E / 255, green: 0xCD / 255, blue: 0xC4 / 255)
    static let rcAccentDim = Color(red: 0x3A / 255, green: 0xA8 / 255, blue: 0x9F / 255)
    static let rcTextPrimary = Color.white
    static let rcTextSecondary = Color(red: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255)
    static let rcTextTertiary = Color(red: 0x55 / 255, green: 0x55 / 255, blue: 0x55 / 255)
    static let rcError = Color(red: 0xFF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    static let rcWarning = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x47 / 255)
}

extension Font {
    // Display fonts — rounded design for hero moments, brand presence
    static let rcDisplay = Font.system(size: 34, weight: .bold, design: .rounded)
    static let rcDisplayMedium = Font.system(size: 28, weight: .bold, design: .rounded)

    // Title fonts — rounded for section headers, gives character
    static let rcTitleLarge = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let rcTitleMedium = Font.system(size: 20, weight: .semibold, design: .rounded)

    // Body + UI fonts — default design, clean and readable
    static let rcBody = Font.system(size: 15, weight: .regular, design: .default)
    static let rcBodyMedium = Font.system(size: 15, weight: .medium, design: .default)
    static let rcCaption = Font.system(size: 12, weight: .regular, design: .default)
    static let rcCaptionBold = Font.system(size: 12, weight: .semibold, design: .default)
    static let rcTabBar = Font.system(size: 10, weight: .medium, design: .default)

    // Accent font — monospaced rounded for numbers, stats, cost display
    static let rcStat = Font.system(size: 24, weight: .bold, design: .rounded)
}

#Preview {
    ContentView()
}
