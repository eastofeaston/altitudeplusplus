import SwiftUI

/// Shows the last entitlement response (secrets shortened) so stream problems
/// can be debugged from the couch.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?
    @State private var isProbing = false
    @FocusState private var testFocused: Bool
    private let topID = "top"

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                Button {
                    isProbing = true
                    Task {
                        status = await model.probeEntitlement()
                        isProbing = false
                    }
                } label: {
                    HStack {
                        Text("Test Live Channel Access")
                        if isProbing { Spacer(); ProgressView() }
                    }
                }
                .focused($testFocused)
                .id(topID)
                if let status {
                    Text(status)
                }
            }

            Section("Request") {
                LabeledContent("Device profile", value: "\(model.profile.deviceType) / \(model.profile.contentConsumption)")
                LabeledContent("Install ID", value: model.auth.deviceId)
                LabeledContent("Location sent", value: locationSent)
                if let date = model.lastEntitlementDate {
                    LabeledContent("Last checked", value: date.formatted(date: .omitted, time: .standard))
                }
                if let url = model.lastStreamURL {
                    LabeledContent("Stream host", value: url.host() ?? "—")
                }
            }

            if let json = model.lastEntitlement {
                Section("Last entitlement response") {
                    ForEach(Array(json.redactedDescription().split(separator: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 20, design: .monospaced))
                            .focusable()
                    }
                }
            }
        }
        // Same as Settings: scroll fully up when the top button takes focus so
        // the tab bar can come back after browsing a long response.
        .onChange(of: testFocused) { _, focused in
            if focused {
                withAnimation { proxy.scrollTo(topID, anchor: .top) }
            }
        }
        }
        .navigationTitle("Diagnostics")
    }

    private var locationSent: String {
        guard let location = model.location else { return "—" }
        switch location.source {
        case .coordinates:
            guard let latitude = location.latitude, let longitude = location.longitude else { return "Coordinates" }
            return String(format: "%.4f, %.4f", latitude, longitude)
        case .ipAddress:
            return "None (IP address used)"
        }
    }
}
