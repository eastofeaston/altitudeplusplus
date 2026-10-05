import SwiftUI

@main
struct AltitudePlusPlusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.launch() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                SignInView()
            case .ready:
                MainTabs()
            }
        }
    }
}

/// Live first (and the launch default); on-demand by team after it.
private struct MainTabs: View {
    @Environment(AppModel.self) private var model

    private enum Tab: Hashable {
        case live
        case team(Team)
        case settings
    }

    @State private var selection: Tab = Self.initialTab

    /// Debug builds accept `-tab avalanche|nuggets|settings` to open on a tab.
    private static var initialTab: Tab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-tab"), index + 1 < args.count {
            if let team = Team(rawValue: args[index + 1]) { return .team(team) }
            if args[index + 1] == "settings" { return .settings }
        }
        #endif
        return .live
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Text("Live") }
                .tag(Tab.live)
            ForEach(model.orderedTeams) { team in
                TeamView(team: team)
                    .tabItem { Text(team.title) }
                    .tag(Tab.team(team))
            }
            NavigationStack {
                SettingsView()
            }
            .tabItem { Text("Settings") }
            .tag(Tab.settings)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.29, green: 0.62, blue: 0.95)
    static let background = LinearGradient(
        colors: [Color(red: 0.03, green: 0.07, blue: 0.14), Color(red: 0.01, green: 0.02, blue: 0.05)],
        startPoint: .top,
        endPoint: .bottom
    )
}
