import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.busy { ProgressView().controlSize(.small) }
                if model.routesPending {
                    Button { model.applyNow() } label: {
                        Label("Apply Route Changes", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    }
                    .help("Some “Route via interface” rules changed but are not applied yet. Applying them asks for your administrator password.")
                }
                Button { model.applyNow(force: true) } label: {
                    Label("Reapply Everything", systemImage: "arrow.clockwise")
                }
                .help("Push all proxy settings and routes to the system again")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .profile(let id):
            ProfileEditor(profileID: id).id(id)
        case .status:
            StatusView()
        case .test:
            TestView()
        case .settings:
            SettingsView()
        case nil:
            ContentUnavailableView {
                Label("No profile selected", systemImage: "arrow.triangle.branch")
            } description: {
                Text("A profile is a set of rules that decides where traffic goes: through a proxy, directly, or out of a specific network interface. Select a profile on the left, or create a new one with the + button.")
            } actions: {
                Button("Create a Profile") { model.addProfile() }
            }
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Profiles") {
                ForEach(model.profiles) { p in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { p.isActive }, set: { model.setActive(p.id, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help(p.isActive ? "Active — click to turn off" : "Inactive — click to turn on")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name.isEmpty ? "Untitled" : p.name).lineLimit(1)
                            Text(subtitle(p)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(SidebarItem.profile(p.id))
                    .contextMenu {
                        Button(p.isActive ? "Turn Off" : "Turn On") { model.setActive(p.id, !p.isActive) }
                        Button("Duplicate") { model.duplicate(p.id) }
                        Divider()
                        Button("Delete", role: .destructive) { model.delete(p.id) }
                    }
                }
                .onMove { model.profiles.move(fromOffsets: $0, toOffset: $1) }
            }
            Section("System") {
                Label("Current Status", systemImage: "network").tag(SidebarItem.status)
                Label("Test an Address", systemImage: "checkmark.seal").tag(SidebarItem.test)
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.profiles.count > 1 {
                Text("Drag profiles to reorder. Profiles higher in the list win when rules overlap.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.addProfile() } label: { Label("New Profile", systemImage: "plus") }
                    .help("Create a new profile")
                Button {
                    if case .profile(let id) = model.selection { model.delete(id) }
                } label: { Label("Delete Profile", systemImage: "minus") }
                    .help("Delete the selected profile")
                    .disabled(!isProfileSelected)
            }
        }
        .onDeleteCommand {
            if case .profile(let id) = model.selection { model.delete(id) }
        }
    }

    private var isProfileSelected: Bool {
        if case .profile = model.selection { return true }
        return false
    }

    private func subtitle(_ p: Profile) -> String {
        let rules = p.rules.filter(\.enabled).count
        let svc = p.services.isEmpty ? "no network selected" : p.services.joined(separator: ", ")
        return "\(rules) rule\(rules == 1 ? "" : "s") · \(svc)"
    }
}
