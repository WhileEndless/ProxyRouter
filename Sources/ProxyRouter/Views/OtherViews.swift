import SwiftUI
import AppKit

struct TestView: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""
    @State private var service = ""
    @State private var onlyActive = true
    @State private var result: Evaluation?
    @State private var running = false

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $input, prompt: Text("e.g. https://www.google.com, 8.8.8.8 or 142.250.1.1"))
                    .onSubmit(run)
                Picker("Network", selection: $service) {
                    Text("Any network (all profiles)").tag("")
                    ForEach(model.services) { s in
                        Text(s.name + (s.isPrimary ? "  (in use)" : "")).tag(s.name)
                    }
                }
                Toggle("Only consider active profiles", isOn: $onlyActive)
                HStack {
                    Button("Test", action: run).keyboardShortcut(.defaultAction).disabled(input.isEmpty || running)
                    if running { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Where would this address go?")
            } footer: {
                Text("Runs the same logic as the generated PAC file and shows which profile and rule would handle the address. Host names are looked up in DNS when an IP-based rule needs them. Nothing is sent to the address itself.")
            }

            if let r = result {
                Section("Result") {
                    row("Host", r.host)
                    if let ip = r.resolvedIP { row("Resolved IP", ip) }
                    row("Profile", r.profileName ?? "—")
                    row("Rule", r.ruleName ?? (r.profileName == nil ? "—" : "(unnamed)"))
                    row("Matched target", r.matchedTarget ?? "—")
                    row("Outcome", r.action)
                    row("PAC returns", r.result)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Test an Address")
        .onAppear { if service.isEmpty { service = model.primaryService?.name ?? "" } }
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
    }

    private func run() {
        let profiles = model.profiles.filter { p in
            (!onlyActive || p.isActive) && (service.isEmpty || p.services.contains(service) || p.rules.contains { $0.action == .interface })
        }
        let text = input
        running = true
        Task {
            result = await Task.detached { Evaluator.evaluate(input: text, profiles: profiles) }.value
            running = false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var port = 18089

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .frame(width: 200)
                    Button("Apply") {
                        model.settings.pacPort = port
                        model.restartServer()
                    }
                    .disabled(port == model.settings.pacPort || !(1024...65535).contains(port))
                    Spacer()
                    Label(model.serverRunning ? "Running" : "Stopped",
                          systemImage: model.serverRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(model.serverRunning ? .green : .red)
                }
                LabeledContent("Address") {
                    Text(model.pacBaseURL + "/pac/<network>.pac").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            } header: {
                Text("Built-in PAC server")
            } footer: {
                Text("macOS reads proxy rules from a small web address that this app serves on your own computer (127.0.0.1, not reachable from other machines). Keep the app running while a profile is active. Only change the port if another program already uses it.")
            }

            Section {
                Toggle("Restore the original proxy settings when quitting", isOn: $model.settings.restoreOnQuit)
                Toggle("Also remove added routes when quitting (asks for your password)", isOn: $model.settings.removeRoutesOnQuit)
                    .disabled(!model.settings.restoreOnQuit)
            } header: {
                Text("When the app quits")
            } footer: {
                Text("Active profiles are remembered and turned back on the next time the app starts.")
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.launchAtLogin = $0 }
                ))
            }

            Section("Data") {
                Button("Show Configuration File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.configURL])
                }
            }

            Section("About") {
                LabeledContent("Version") { Text("\(AppInfo.version) (build \(AppInfo.build))").textSelection(.enabled) }
                LabeledContent("License") { Text(AppInfo.license) }
                LabeledContent("Source code") {
                    Link(AppInfo.repository.absoluteString, destination: AppInfo.repository)
                }
                Button("Show About Window") { AppInfo.showAboutPanel() }
            }

            Section("Good to know") {
                Text("• Proxy rules are followed by apps that use the macOS proxy settings, such as Safari, Chrome and most Mac apps. Command-line tools like curl ignore them.")
                Text("• “Route via interface” rules change the system routing table, so they apply to every app, including command-line tools.")
                Text("• If another program (for example a VPN client) already has a route for the same network, this app replaces it while the profile is on.")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { port = model.settings.pacPort }
    }
}
