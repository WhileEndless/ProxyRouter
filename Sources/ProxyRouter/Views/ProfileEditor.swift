import SwiftUI
import AppKit

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    let profileID: UUID
    @State private var showPAC = false

    var body: some View {
        if let p = model.binding(for: profileID) {
            editor(p)
        } else {
            ContentUnavailableView("Profile not found", systemImage: "questionmark")
        }
    }

    private func editor(_ p: Binding<Profile>) -> some View {
        Form {
            Section {
                TextField("Profile name", text: p.name)
                Toggle(isOn: Binding(
                    get: { p.wrappedValue.isActive },
                    set: { model.setActive(profileID, $0) }
                )) {
                    Text("Active")
                    Text("While active, the rules below are applied to the selected networks.")
                }
            }

            Section {
                if model.services.isEmpty {
                    Text("Reading network services…").foregroundStyle(.secondary)
                }
                ForEach(model.services) { s in
                    Toggle(isOn: serviceBinding(p, s.name)) {
                        HStack(spacing: 6) {
                            Text(s.name)
                            if s.isPrimary { Badge("in use", color: .green) }
                            if !s.enabled { Badge("disabled", color: .gray) }
                            Spacer()
                            Text([s.bsdName, s.hardware].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Apply proxy rules to these networks")
            } footer: {
                Text("Only the networks you tick are changed; every other network keeps its own settings. macOS follows the proxy settings of the network marked **in use** (the one currently connected to the internet), so tick that one. “Route via interface” rules do not depend on this list.")
            }

            Section {
                if p.wrappedValue.rules.isEmpty {
                    Text("No rules yet. Add one to start sending traffic somewhere.").foregroundStyle(.secondary)
                }
                ForEach(p.rules) { $rule in
                    let idx = p.wrappedValue.rules.firstIndex { $0.id == rule.id } ?? 0
                    RuleEditor(
                        rule: $rule,
                        index: idx + 1,
                        interfaces: model.interfaces,
                        canMoveUp: idx > 0,
                        canMoveDown: idx < p.wrappedValue.rules.count - 1,
                        onMove: { delta in moveRule(rule.id, by: delta) },
                        onDelete: { model.update(profileID) { $0.rules.removeAll { $0.id == rule.id } } }
                    )
                }
                Button {
                    model.update(profileID) { $0.rules.append(Rule()) }
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules are checked from top to bottom and the first match decides. Anything that matches no rule connects directly, as if this app were not running.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(p.wrappedValue.name.isEmpty ? "Untitled" : p.wrappedValue.name)
        .toolbar {
            ToolbarItem {
                Button { showPAC = true } label: { Label("Show PAC File", systemImage: "doc.text.magnifyingglass") }
                    .help("Show the proxy auto-config (PAC) file generated from this profile")
            }
        }
        .sheet(isPresented: $showPAC) {
            TextSheet(title: "PAC file — \(p.wrappedValue.name)",
                      subtitle: "This is what macOS receives. It is regenerated automatically whenever you edit the profile.",
                      text: PACGenerator.generate(profiles: [p.wrappedValue], title: p.wrappedValue.name))
        }
    }

    private func serviceBinding(_ p: Binding<Profile>, _ name: String) -> Binding<Bool> {
        Binding(
            get: { p.wrappedValue.services.contains(name) },
            set: { on in
                model.update(profileID) {
                    $0.services.removeAll { $0 == name }
                    if on { $0.services.append(name) }
                }
            }
        )
    }

    private func moveRule(_ id: UUID, by delta: Int) {
        model.update(profileID) { prof in
            guard let i = prof.rules.firstIndex(where: { $0.id == id }) else { return }
            let j = i + delta
            guard prof.rules.indices.contains(j) else { return }
            prof.rules.swapAt(i, j)
        }
    }
}

struct RuleEditor: View {
    @Binding var rule: Rule
    let index: Int
    let interfaces: [NetInterface]
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        let parsed = rule.parsedTargets
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(index)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(rule.enabled ? "Rule is on" : "Rule is off (kept but ignored)")
                TextField("Rule name (optional)", text: $rule.name)
                    .textFieldStyle(.roundedBorder)
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp).help("Move up (checked earlier)")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown).help("Move down (checked later)")
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                    .help("Delete rule")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text("When the destination is…").font(.subheadline.weight(.medium))
                Text("One per line. Examples: 142.250.0.0/15 (CIDR) · 216.58.192.0-216.58.223.255 (range) · 8.8.8.8 (single IP) · mail.google.com (exact host) · *.google.com (domain and all subdomains) · *cdn* (wildcard) · * (everything). Text after # is a comment.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $rule.targets)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            ForEach(Array(parsed.enumerated()), id: \.offset) { _, t in
                if let err = t.error {
                    Label("“\(t.raw)” — \(err). This line is ignored.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            let valid = parsed.compactMap(\.spec)
            if !valid.isEmpty {
                Text("Understood as: " + valid.map(\.description).joined(separator: "   "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
            }

            Text("…then").font(.subheadline.weight(.medium))
            Picker("Action", selection: $rule.action) {
                ForEach(RuleAction.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch rule.action {
            case .proxy:
                Text("Send the connection through this proxy server.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Type", selection: $rule.proxyKind) {
                        ForEach(ProxyKind.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 150)
                    TextField("Proxy host, e.g. 127.0.0.1", text: $rule.proxyHost).textFieldStyle(.roundedBorder)
                    Text(":")
                    TextField("Port", value: $rule.proxyPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                if !rule.isProxyHostValid {
                    Label("The proxy host or port is not valid, so this rule is skipped.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Toggle("If the proxy cannot be reached, connect directly instead", isOn: $rule.fallbackDirect)
            case .direct:
                Text("Connect directly, without any proxy. Put this above a broader rule to make exceptions — for example, send *.google.com through a proxy but keep accounts.google.com direct.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .interface:
                Text("Connect directly, but force the traffic out of the chosen network interface (for example a VPN tunnel or a second network adapter). This adds entries to the system routing table, affects every app, and asks for your administrator password.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("Interface", selection: $rule.interfaceName) {
                        Text("Choose…").tag("")
                        ForEach(interfaces) { Text($0.label).tag($0.name) }
                        if !rule.interfaceName.isEmpty && !interfaces.contains(where: { $0.name == rule.interfaceName }) {
                            Text("\(rule.interfaceName) (not connected)").tag(rule.interfaceName)
                        }
                    }
                    TextField("Gateway (leave empty for automatic)", text: $rule.gateway)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                Text("Works with IPs, ranges, CIDRs and exact host names (looked up when the rule is applied). Wildcard domains such as *.google.com cannot become routes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct TextSheet: View {
    let title: String
    var subtitle: String?
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 460)
    }
}
