import SwiftUI
import AppKit

struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    let profileID: UUID
    @State private var showPAC = false
    @State private var showNetworks = false

    var body: some View {
        if let p = model.binding(for: profileID) {
            editor(p)
        } else {
            ContentUnavailableView("Profile not found", systemImage: "questionmark")
        }
    }

    private func editor(_ p: Binding<Profile>) -> some View {
        let profile = p.wrappedValue
        return Form {
            Section {
                TextField("Name", text: p.name)
                Toggle(isOn: Binding(
                    get: { profile.isActive },
                    set: { model.setActive(profileID, $0) }
                )) {
                    Text("Active")
                    Text("Turning the profile on applies its rules; turning it off puts everything back.")
                }
                if model.routesNeedAttention(profile) {
                    RouteAttentionBanner()
                }
            }

            Section {
                if profile.rules.isEmpty {
                    Text("No rules yet. Add one to start sending traffic somewhere.").foregroundStyle(.secondary)
                }
                ForEach(p.rules) { $rule in
                    let idx = profile.rules.firstIndex { $0.id == rule.id } ?? 0
                    RuleEditor(
                        rule: $rule,
                        index: idx + 1,
                        interfaces: model.interfaces,
                        warnings: model.routeWarnings.filter { $0.ruleID == rule.id }.map(\.text),
                        canMoveUp: idx > 0,
                        canMoveDown: idx < profile.rules.count - 1,
                        onRoutingChange: { model.routingChanged(in: profileID) },
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
                Text("Checked from top to bottom; the first matching rule decides. Anything that matches no rule connects directly, as if this app were not running.")
            }

            Section {
                TargetListEditor(text: p.excludes, minHeight: 44, placeholder: "e.g. 203.0.113.0/24 or login.example.com")
            } header: {
                Text("Exceptions")
            } footer: {
                Text("Destinations listed here skip every rule of this profile: they are not proxied and get no routes. They fall through to the next active profile, or connect directly. IP ranges are cut out of the rules' ranges.")
            }

            Section {
                Toggle(isOn: p.followPrimary) {
                    Text("Network in use")
                    Text(model.primaryService.map { "Currently **\($0.name)**. Follows automatically when you switch between Wi-Fi, Ethernet and other networks." }
                         ?? "No network is connected right now. The rules are applied as soon as one is.")
                }
                if model.services.isEmpty {
                    Text("Reading network services…").foregroundStyle(.secondary)
                }
                DisclosureGroup(isExpanded: $showNetworks) {
                    ForEach(model.services) { s in
                        let covered = profile.followPrimary && s.isPrimary
                        Toggle(isOn: covered ? .constant(true) : serviceBinding(p, s.name)) {
                            HStack(spacing: 6) {
                                Text(s.name)
                                if s.isPrimary { Badge("in use", color: .green) }
                                if !s.enabled { Badge("disabled", color: .gray) }
                                Spacer()
                                Text([s.bsdName, s.hardware].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(covered)
                    }
                } label: {
                    Text(profile.services.isEmpty ? "Also apply to specific networks" : "Also applied to: \(profile.services.joined(separator: ", "))")
                }
                if !profile.followPrimary, profile.rules.contains(where: { $0.enabled && $0.action == .proxy }),
                   let prim = model.primaryService, !profile.services.contains(prim.name) {
                    HStack {
                        Label("macOS is using **\(prim.name)** right now, which is not selected, so the proxy rules have no effect.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Use Network in Use") { p.wrappedValue.followPrimary = true }
                    }
                }
            } header: {
                Text("Proxy settings are applied to")
            } footer: {
                Text("macOS only follows the proxy settings of the network it is using, so keep **Network in use** on unless you need something special. This does not choose where traffic leaves the Mac — that is the “Out through” setting of each rule.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile.name.isEmpty ? "Untitled" : profile.name)
        .toolbar {
            ToolbarItem {
                Button { showPAC = true } label: { Label("Show PAC File", systemImage: "doc.text.magnifyingglass") }
                    .help("Show the proxy auto-config (PAC) file generated from this profile")
            }
        }
        .sheet(isPresented: $showPAC) {
            TextSheet(title: "PAC file — \(profile.name)",
                      subtitle: "This is what macOS receives. It is regenerated automatically whenever you edit the profile.",
                      text: PACGenerator.generate(profiles: [profile], title: profile.name))
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
    let warnings: [String]
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// The rule started or stopped producing routes (interface picked, rule switched on/off)
    let onRoutingChange: () -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    label("Destinations")
                    TargetListEditor(text: $rule.targets, minHeight: 64,
                                     placeholder: "198.51.100.0/24, 192.0.2.1-192.0.2.50, *.example.com …")
                }
                GridRow {
                    label("Action")
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Action", selection: $rule.action) {
                            ForEach(RuleAction.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if rule.action == .direct {
                            caption("Connect without a proxy. Put a Direct rule above a broader rule to make exceptions.")
                        }
                    }
                }
                if rule.action == .proxy {
                    GridRow {
                        label("Proxy server")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Picker("Type", selection: $rule.proxyKind) {
                                    ForEach(ProxyKind.allCases) { Text($0.label).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                                TextField("Host", text: $rule.proxyHost, prompt: Text("127.0.0.1"))
                                    .textFieldStyle(.roundedBorder).labelsHidden()
                                Text(":").foregroundStyle(.secondary)
                                TextField("Port", value: $rule.proxyPort, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 70)
                            }
                            if !rule.isProxyHostValid {
                                Label("The host or port is not valid, so this rule is skipped.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.red)
                            }
                            Toggle("Connect directly if the proxy is unreachable", isOn: $rule.fallbackDirect)
                        }
                    }
                }
                GridRow {
                    label("Out through")
                    VStack(alignment: .leading, spacing: 6) {
                        InterfacePicker(selection: $rule.outInterface, interfaces: interfaces)
                            .labelsHidden().frame(maxWidth: 360, alignment: .leading)
                        caption(interfaceExplanation)
                        if rule.usesInterface {
                            DisclosureGroup(rule.outGateway.isEmpty ? "Gateway: automatic" : "Gateway: \(rule.outGateway)") {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField("Gateway", text: $rule.outGateway, prompt: Text("automatic"))
                                        .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 180)
                                    caption("Leave empty: the interface's own router is detected, and VPN tunnels need none. Only fill in if routes go to the wrong router.")
                                }
                                .padding(.top, 4)
                            }
                            .font(.caption)
                        }
                        ForEach(warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .opacity(rule.enabled ? 1 : 0.5)
        .onChange(of: rule.outInterface) { onRoutingChange() }
        .onChange(of: rule.enabled) { if rule.usesInterface { onRoutingChange() } }
        .onChange(of: rule.action) { if rule.usesInterface { onRoutingChange() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 20, minHeight: 20)
                .background(Circle().fill(Color.accentColor.opacity(rule.enabled ? 0.2 : 0.08)))
            TextField("Rule name", text: $rule.name, prompt: Text("Untitled rule"))
                .textFieldStyle(.plain).font(.headline)
            Spacer()
            Toggle("Enabled", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help(rule.enabled ? "Rule is on" : "Rule is off (kept but ignored)")
            Group {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp).help("Move up (checked earlier)")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown).help("Move down (checked later)")
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                    .help("Delete rule")
            }
            .buttonStyle(.borderless)
        }
    }

    private var interfaceExplanation: String {
        guard rule.usesInterface else {
            return "Traffic takes the Mac's normal route. Pick an interface (VPN tunnel, second adapter…) to force it out of that one."
        }
        let i = rule.outInterface
        let what: String
        switch rule.action {
        case .direct:
            what = "The destinations above are routed out of \(i)."
        case .proxy where rule.isLocalProxy:
            what = "The proxy runs on this Mac, so the destinations above are routed out of \(i) — the proxy's own connections to them leave through \(i)."
        case .proxy:
            what = "The proxy server \(rule.proxyHost) and the destinations above are routed out of \(i)."
        }
        return what + " Routes are added when the profile is turned on and removed when it is off (administrator password). They affect every app. IPs, ranges and exact host names only — wildcard domains cannot become routes."
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Shown while the system's routes do not match the rules, until the user applies them
struct RouteAttentionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let refused = model.routeIssue != nil
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(refused ? .red : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(refused ? "Routes are not applied" : "Route changes are waiting")
                    .font(.headline)
                Text(model.routeIssue ?? "Edits to destinations or gateways are applied when you click Apply, so you are not asked for your password on every keystroke.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(refused ? "Try Again" : "Apply Now") { model.applyNow() }
                .buttonStyle(.borderedProminent)
                .tint(refused ? .red : .orange)
                .disabled(model.busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((refused ? Color.red : Color.orange).opacity(0.1)))
    }
}

/// Multi-line destination list with inline parse errors and a summary of what was understood
struct TargetListEditor: View {
    @Binding var text: String
    let minHeight: CGFloat
    var placeholder = ""

    var body: some View {
        let parsed = TargetSpec.parseList(text)
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
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
                Text(valid.map(\.description).joined(separator: " · "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    .help("How each line was understood")
            }
        }
    }
}

struct InterfacePicker: View {
    @Binding var selection: String
    let interfaces: [NetInterface]

    var body: some View {
        Picker("Interface", selection: $selection) {
            Text("System default").tag("")
            Divider()
            ForEach(interfaces) { Text($0.label).tag($0.name) }
            if !selection.isEmpty && !interfaces.contains(where: { $0.name == selection }) {
                Text("\(selection) (not connected)").tag(selection)
            }
        }
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
