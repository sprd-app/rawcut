import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .library
    @State private var isOnboardingComplete: Bool =
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    enum Tab: Hashable {
        case library
        case create
        case projects
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                MediaHubView()
            }
            .tabItem {
                Label("라이브러리", systemImage: "photo.on.rectangle.angled")
            }
            .tag(Tab.library)

            NavigationStack {
                CreatePlaceholderView()
            }
            .tabItem {
                Label("만들기", systemImage: "plus.circle.fill")
            }
            .tag(Tab.create)

            NavigationStack {
                ProjectsPlaceholderView()
            }
            .tabItem {
                Label("프로젝트", systemImage: "film.stack")
            }
            .tag(Tab.projects)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("설정", systemImage: "gearshape")
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

// MARK: - Placeholder Views

private struct CreatePlaceholderView: View {
    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()
            EmptyStateView(
                icon: "plus.circle",
                title: "브이로그 만들기",
                description: "영상을 선택하고 스크립트를 작성하면, rawcut이 나머지를 처리합니다."
            )
        }
        .navigationTitle("만들기")
    }
}

private struct ProjectsPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()
            EmptyStateView(
                icon: "film.stack",
                title: "프로젝트가 없습니다",
                description: "완성된 브이로그가 여기에 표시됩니다."
            )
        }
        .navigationTitle("프로젝트")
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
    static let rcTitleLarge = Font.system(size: 28, weight: .semibold, design: .default)
    static let rcTitleMedium = Font.system(size: 20, weight: .semibold, design: .default)
    static let rcBody = Font.system(size: 15, weight: .regular, design: .default)
    static let rcCaption = Font.system(size: 12, weight: .regular, design: .default)
    static let rcTabBar = Font.system(size: 10, weight: .medium, design: .default)
}

#Preview {
    ContentView()
}
