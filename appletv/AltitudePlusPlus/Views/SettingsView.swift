import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var signOutFocused: Bool
    private let topID = "top"

    var body: some View {
        @Bindable var model = model

        ScrollViewReader { proxy in
        List {
            Section("Account") {
                LabeledContent("Signed in as", value: model.session?.email ?? "—")
                    .id(topID)
                if let expiry = model.session?.expiresAt {
                    LabeledContent("Session renews", value: expiry.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Sign Out", role: .destructive) { model.signOut() }
                    .focused($signOutFocused)
            }

            Section {
                Picker("Team Order", selection: $model.favoriteTeam) {
                    ForEach(Team.allCases) { team in
                        Text(([team] + Team.allCases.filter { $0 != team }).map(\.title).joined(separator: ", "))
                            .tag(team)
                    }
                }
            } header: {
                Text("Teams")
            } footer: {
                Text("Sets the order of the team tabs. Live always comes first.")
            }

            Section {
                LabeledContent("Location Access", value: model.locationService.permissionDescription)
                LabeledContent("Implied ZIP Code", value: model.location?.postalCode ?? (model.isLocating ? "Checking…" : "Unknown"))
                Button {
                    Task { await model.refreshLocation() }
                } label: {
                    HStack {
                        Text("Refresh Location")
                        if model.isLocating { Spacer(); ProgressView() }
                    }
                }
            } header: {
                Text("Location")
            } footer: {
                Text("Altitude+ only streams inside its broadcast territory, which it checks by ZIP code. Without location access it uses your IP address instead. You can change access in the Apple TV Settings app, under Privacy.")
            }

            Section {
                Toggle("Start Live on Launch", isOn: $model.autoPlayOnLaunch)
                Picker("Device Profile", selection: $model.profile) {
                    ForEach(DeviceProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Device Profile controls how this app identifies itself to Altitude+. Leave it on Apple TV unless streams fail to start.")
            }

            Section("Troubleshooting") {
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
        }
        // tvOS only brings the tab bar back when the list is scrolled to the top,
        // and nothing above Sign Out can take focus. Coming back up from lower
        // rows would otherwise leave the list part-scrolled and the tabs unreachable.
        .onChange(of: signOutFocused) { _, focused in
            if focused {
                withAnimation { proxy.scrollTo(topID, anchor: .top) }
            }
        }
        }
        .navigationTitle("Settings")
    }
}
