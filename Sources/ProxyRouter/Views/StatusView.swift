import SwiftUI
import AppKit

struct StatusView: View {
    @EnvironmentObject var model: AppModel
    @State private var sheet: SheetContent?

    struct SheetContent: Identifiable {
        let id = UUID()
        let title: String
        var subtitle: String?
        let text: String
    }

    var body: some View {
        Form {
            Section {
                ForEach(model.effectiveProxy, id: \.self) { Text($0).textSelection(.enabled) }
            } header: {
                Text("What macOS is using right now")
            } footer: {
                Text("These are the proxy settings of the network currently connected to the internet — the ones apps actually follow.")
            }

            Section {
                ForEach(model.services) { s in
                    ServiceRow(status: s, pacBaseURL: model.pacBaseURL,
                               onImport: { model.importProfile(from: s) },
                               onShowPAC: { showPAC(for: s) })
                }
            } header: {
                Text("Proxy settings of each network")
            } footer: {
                Text("A blue “managed” badge means the network currently gets its rules from this app. Settings you entered by hand in System Settings can be turned into a profile with “Import as Profile”.")
            }

            Section {
                if model.appliedRoutes.isEmpty {
                    Text("This app has not added any routes.").foregroundStyle(.secondary)
                }
                ForEach(model.appliedRoutes) { r in
                    Text(r.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(model.routeWarnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if model.routesPending {
                    Button("Apply Pending Route Changes") { model.applyNow() }
                }
                Button("Show Full Routing Table") {
                    Task {
                        let t = await Task.detached { SystemReader.routingTable() }.value
                        sheet = SheetContent(title: "System routing table (IPv4)",
                                             subtitle: "Output of netstat -rn -f inet. Every entry, including ones added by other software.",
                                             text: t)
                    }
                }
            } header: {
                Text("Routes added by this app")
            } footer: {
                Text("Created by “Route via interface” rules. They are removed when the profile is turned off.")
            }

            Section("Network interfaces") {
                ForEach(model.interfaces) { i in
                    HStack {
                        Text(i.name).font(.system(.body, design: .monospaced)).frame(width: 80, alignment: .leading)
                        Text(i.serviceName ?? (i.isPointToPoint ? "Tunnel / VPN" : "—")).foregroundStyle(.secondary)
                        Spacer()
                        Text(i.addresses.joined(separator: ", ")).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Activity") {
                if model.log.isEmpty { Text("Nothing has happened yet.").foregroundStyle(.secondary) }
                ForEach(model.log.suffix(60).reversed()) { l in
                    HStack(alignment: .firstTextBaseline) {
                        Text(l.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(l.text).font(.callout).foregroundStyle(l.isError ? .red : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Current Status")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshStatus() } } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Read the current system settings again")
            }
        }
        .task { await model.refreshStatus() }
        .sheet(item: $sheet) { TextSheet(title: $0.title, subtitle: $0.subtitle, text: $0.text) }
    }

    private func showPAC(for s: ServiceStatus) {
        let urlString = s.autoProxyURL
        if urlString.hasPrefix(model.pacBaseURL), let local = model.pacContent(for: s.name) {
            sheet = SheetContent(title: "PAC file for \(s.name)", subtitle: urlString, text: local)
            return
        }
        guard let url = URL(string: urlString) else { return }
        Task {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [:]
            cfg.timeoutIntervalForRequest = 8
            let text: String
            do {
                let (data, _) = try await URLSession(configuration: cfg).data(from: url)
                text = String(decoding: data, as: UTF8.self)
            } catch {
                text = "Could not download the PAC file: \(error.localizedDescription)"
            }
            sheet = SheetContent(title: "PAC file for \(s.name)", subtitle: urlString, text: text)
        }
    }
}

private struct ServiceRow: View {
    let status: ServiceStatus
    let pacBaseURL: String
    let onImport: () -> Void
    let onShowPAC: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(status.name).font(.headline)
                if status.isPrimary { Badge("in use", color: .green) }
                if !status.enabled { Badge("disabled", color: .gray) }
                if status.autoProxyURL.hasPrefix(pacBaseURL) && status.autoProxyEnabled { Badge("managed", color: .blue) }
                Spacer()
                Text([status.bsdName, status.hardware].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if status.autoProxyEnabled || !status.autoProxyURL.isEmpty {
                    line("PAC", "\(status.autoProxyEnabled ? "on" : "off") — \(status.autoProxyURL.isEmpty ? "(no URL)" : status.autoProxyURL)")
                }
                if let h = status.http { line("HTTP", h.text) }
                if let h = status.https { line("HTTPS", h.text) }
                if let s = status.socks { line("SOCKS", s.text) }
                if !status.bypass.isEmpty { line("Bypass", status.bypass.joined(separator: ", ")) }
                if !status.autoProxyEnabled && !status.hasManualProxy { line("Proxy", "none — connects directly") }
            }
            .font(.callout)
            HStack {
                if status.hasManualProxy {
                    Button("Import as Profile", action: onImport)
                        .help("Create a profile that reproduces these manual proxy settings")
                }
                if !status.autoProxyURL.isEmpty {
                    Button("Show PAC File", action: onShowPAC)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(v).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }
}
