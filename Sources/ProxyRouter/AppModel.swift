import Foundation
import SwiftUI
import ServiceManagement
import Network

enum SidebarItem: Hashable {
    case profile(UUID)
    case status
    case test
    case settings
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let isError: Bool
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var profiles: [Profile] = [] { didSet { profilesChanged() } }
    @Published var settings = AppSettings() { didSet { if !isLoading { scheduleSave() } } }
    @Published var selection: SidebarItem?

    @Published private(set) var services: [ServiceStatus] = []
    @Published private(set) var interfaces: [NetInterface] = []
    @Published private(set) var effectiveProxy: [String] = []
    @Published private(set) var appliedRoutes: [RouteEntry] = []
    @Published private(set) var routeWarnings: [RouteWarning] = []
    @Published private(set) var routesPending = false
    /// Why the last route change did not go through (password prompt cancelled, route command failed)
    @Published private(set) var routeIssue: String?
    @Published private(set) var busy = false
    @Published private(set) var log: [LogLine] = []
    @Published var serverRunning = false

    private var runtime = RuntimeState()
    private let server = PACServer()
    private var appliedPAC: [String: String] = [:]
    private var revision = Int(Date().timeIntervalSince1970)
    private var isLoading = false
    private var isShuttingDown = false
    /// true when config.json existed but could not be parsed; the file is then never overwritten
    private var configUnreadable = false
    private var saveTask: Task<Void, Never>?
    private var applyDebounce: Task<Void, Never>?
    private var applyChain: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var networkChangeTask: Task<Void, Never>?

    var anyActive: Bool { profiles.contains { $0.isActive } }
    /// Routes on the system do not match the rules (not applied yet, or permission refused)
    var routesNeedAttention: Bool { routesPending || routeIssue != nil }

    /// true when the profile has routed rules and the routes are not in the state they should be
    func routesNeedAttention(_ p: Profile) -> Bool {
        routesNeedAttention && p.rules.contains { $0.enabled && $0.usesInterface }
    }
    var pacBaseURL: String { "http://127.0.0.1:\(settings.pacPort)" }
    var primaryService: ServiceStatus? { services.first { $0.isPrimary } }

    var summaryLine: String {
        let n = profiles.filter(\.isActive).count
        var s = n == 0 ? "No active profiles" : (n == 1 ? "1 profile active" : "\(n) profiles active")
        if !appliedRoutes.isEmpty { s += " · \(appliedRoutes.count) route\(appliedRoutes.count == 1 ? "" : "s")" }
        return s
    }

    // MARK: - Files

    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ProxyRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var configURL: URL { supportDir.appendingPathComponent("config.json") }
    private static var runtimeURL: URL { supportDir.appendingPathComponent("runtime.json") }

    // MARK: - Lifecycle

    func start() {
        // The example profile is only created on the very first launch. Once a config file
        // exists it belongs to the user, even if they deleted every profile in it.
        let isFirstLaunch = !FileManager.default.fileExists(atPath: Self.configURL.path)
        isLoading = true
        loadConfig()
        loadRuntime()
        isLoading = false
        appliedRoutes = runtime.appliedRoutes

        server.onEvent = { [weak self] msg in Task { @MainActor in self?.addLog(msg, error: true) } }
        startServer()

        // follow Wi-Fi / Ethernet / VPN changes so "network in use" profiles move with it
        pathMonitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.networkChanged() } }
        pathMonitor.start(queue: DispatchQueue(label: "proxyrouter.path"))

        Task {
            await refreshStatus()
            if isFirstLaunch { createSampleProfile() }
            // routes of profiles that are already on are added right away instead of waiting as pending
            enqueueApply(routes: anyActive)
        }
    }

    func shutdown() {
        isShuttingDown = true
        pathMonitor.cancel()
        networkChangeTask?.cancel()
        applyDebounce?.cancel()
        flushSave()
        guard settings.restoreOnQuit else { return }

        var failed: [[String]] = []
        for (svc, o) in runtime.originals {
            for cmd in restoreCommands(svc, o) where !NetworkSetup.run(cmd) { failed.append(cmd) }
        }
        if !failed.isEmpty { _ = Shell.runPrivileged(failed.map(NetworkSetup.shellLine)) }
        runtime.originals = [:]

        if settings.removeRoutesOnQuit && !runtime.appliedRoutes.isEmpty {
            let r = Shell.runPrivileged(runtime.appliedRoutes.map { "\($0.deleteCommand) >/dev/null 2>&1" } + ["true"])
            if r.ok { runtime.appliedRoutes = [] }
        }
        saveRuntime()
    }

    func startServer() {
        do {
            try server.start(port: settings.pacPort)
            serverRunning = true
            addLog("PAC server listening on \(pacBaseURL)")
        } catch {
            serverRunning = false
            addLog("Could not start the PAC server on port \(settings.pacPort): \(error)", error: true)
        }
    }

    func restartServer() {
        // the port changed, so every service needs a fresh PAC URL
        startServer()
        appliedPAC = [:]
        enqueueApply(routes: false)
    }

    // MARK: - Profile operations

    func binding(for id: UUID) -> Binding<Profile>? {
        guard profiles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.profiles.first { $0.id == id } ?? Profile(name: "") },
            set: { new in
                if let i = self.profiles.firstIndex(where: { $0.id == id }) { self.profiles[i] = new }
            }
        )
    }

    func update(_ id: UUID, _ change: (inout Profile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[i])
    }

    func setActive(_ id: UUID, _ on: Bool) {
        update(id) { $0.isActive = on }
        applyNow()
    }

    /// A rule of an active profile started or stopped using an interface: try the routes right
    /// away (asks for the password) instead of leaving them pending
    func routingChanged(in id: UUID) {
        guard profiles.first(where: { $0.id == id })?.isActive == true else { return }
        applyNow()
    }

    func deactivateAll() {
        for i in profiles.indices { profiles[i].isActive = false }
        applyNow()
    }

    @discardableResult
    func addProfile() -> UUID {
        var p = Profile(name: "New Profile")
        p.rules = [Rule()]
        profiles.append(p)
        selection = .profile(p.id)
        return p.id
    }

    func duplicate(_ id: UUID) {
        guard var p = profiles.first(where: { $0.id == id }) else { return }
        p.id = UUID()
        p.name += " copy"
        p.isActive = false
        p.rules = p.rules.map { var r = $0; r.id = UUID(); return r }
        profiles.append(p)
        selection = .profile(p.id)
    }

    func delete(_ id: UUID) {
        let wasActive = profiles.first { $0.id == id }?.isActive ?? false
        profiles.removeAll { $0.id == id }
        if selection == .profile(id) { selection = profiles.first.map { .profile($0.id) } }
        if wasActive { applyNow() }
    }

    private func createSampleProfile() {
        var p = Profile(name: "Example: Google via local proxy")
        var r = Rule()
        r.name = "Google ranges"
        r.targets = "142.250.0.0/15\n172.217.0.0/16\n216.58.192.0 - 216.58.223.255\n8.8.8.8\n*.google.com"
        p.rules = [r]
        profiles = [p]
        selection = .profile(p.id)
    }

    /// Turns manually configured system proxy settings into a profile
    func importProfile(from st: ServiceStatus) {
        var p = Profile(name: "Imported from \(st.name)")
        p.services = [st.name]
        p.followPrimary = false
        let bypass = st.bypass.joined(separator: "\n")
        if !bypass.isEmpty {
            var r = Rule()
            r.name = "Bypassed hosts"
            r.action = .direct
            r.targets = bypass
            p.rules.append(r)
        }
        func proxyRule(_ name: String, _ kind: ProxyKind, _ ep: ProxyEndpoint) -> Rule {
            var r = Rule()
            r.name = name
            r.targets = "*"
            r.proxyKind = kind
            r.proxyHost = ep.host
            r.proxyPort = ep.port
            return r
        }
        if let h = st.http ?? st.https { p.rules.append(proxyRule("All traffic", .http, h)) }
        else if let s = st.socks { p.rules.append(proxyRule("All traffic", .socks5, s)) }
        profiles.append(p)
        selection = .profile(p.id)
        addLog("Imported the proxy settings of \(st.name) as a new profile")
    }

    // MARK: - Applying

    private func profilesChanged() {
        guard !isLoading else { return }
        scheduleSave()
        applyDebounce?.cancel()
        applyDebounce = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            enqueueApply(routes: false)
        }
    }

    /// Apply PAC and routes now (asks for the admin password if routes change)
    func applyNow(force: Bool = false) {
        applyDebounce?.cancel()
        enqueueApply(routes: true, force: force)
    }

    private func enqueueApply(routes: Bool, force: Bool = false) {
        let previous = applyChain
        applyChain = Task {
            await previous?.value
            await performApply(routes: routes, force: force)
        }
    }

    func pacPath(for service: String) -> String {
        let slug = service.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
        return "/pac/\(slug).pac"
    }

    /// Whether the profile's proxy rules are applied to the given network service
    func appliesTo(_ p: Profile, service: String) -> Bool {
        p.services.contains(service) || (p.followPrimary && primaryService?.name == service)
    }

    func pacContent(for service: String) -> String? {
        let ps = profiles.filter { $0.isActive && appliesTo($0, service: service) }
        return ps.isEmpty ? nil : PACGenerator.generate(profiles: ps, title: service)
    }

    private func restoreCommands(_ svc: String, _ o: RuntimeState.AutoProxySnapshot) -> [[String]] {
        var cmds: [[String]] = []
        if !o.url.isEmpty { cmds.append(["-setautoproxyurl", svc, o.url]) }
        cmds.append(["-setautoproxystate", svc, o.enabled ? "on" : "off"])
        return cmds
    }

    private func performApply(routes includeRoutes: Bool, force: Bool) async {
        guard !isShuttingDown else { return }
        busy = true
        defer { busy = false }
        if services.isEmpty { await refreshStatus() }

        // 1) PAC content per network service
        var desired: [String: String] = [:]
        for st in services {
            if let pac = pacContent(for: st.name) { desired[st.name] = pac }
        }
        var files: [String: String] = [:]
        for (svc, pac) in desired { files[pacPath(for: svc)] = pac }
        server.update(files)

        // 2) networksetup commands
        var cmds: [[String]] = []
        for svc in desired.keys.sorted() {
            let st = services.first { $0.name == svc }
            let url = pacBaseURL + pacPath(for: svc)
            let pointsToUs = (st?.autoProxyEnabled ?? false) && (st?.autoProxyURL.hasPrefix(url) ?? false)
            if !force && pointsToUs && appliedPAC[svc] == desired[svc] { continue }

            if runtime.originals[svc] == nil {
                let ours = st?.autoProxyURL.hasPrefix("http://127.0.0.1:") == true && st?.autoProxyURL.contains("/pac/") == true
                runtime.originals[svc] = ours
                    ? .init(url: "", enabled: false)
                    : .init(url: st?.autoProxyURL ?? "", enabled: st?.autoProxyEnabled ?? false)
            }
            revision += 1
            // the ?v= parameter makes macOS drop its cached copy of the PAC file
            cmds.append(["-setautoproxyurl", svc, "\(url)?v=\(revision)"])
            cmds.append(["-setautoproxystate", svc, "on"])
            appliedPAC[svc] = desired[svc]
            addLog("\(svc): proxy rules applied")
        }
        for svc in runtime.originals.keys.sorted() where desired[svc] == nil {
            cmds += restoreCommands(svc, runtime.originals[svc]!)
            runtime.originals[svc] = nil
            appliedPAC[svc] = nil
            addLog("\(svc): previous proxy settings restored")
        }
        saveRuntime()
        guard !isShuttingDown else { return }
        if !cmds.isEmpty { await runNetworkSetup(cmds) }

        // 3) Routes
        let active = profiles.filter(\.isActive)
        let ifs = interfaces
        let plan = await Task.detached { RoutePlanner.plan(active, interfaces: ifs) }.value
        guard !isShuttingDown else { return }
        routeWarnings = plan.warnings
        let want = Set(plan.routes), have = Set(runtime.appliedRoutes)
        if want == have && !(force && !want.isEmpty) {
            routesPending = false
            routeIssue = nil
        } else if includeRoutes {
            await applyRoutes(remove: have.subtracting(want), add: force ? want : want.subtracting(have), final: plan.routes)
        } else {
            routesPending = true
        }

        await refreshStatus()
    }

    private func runNetworkSetup(_ cmds: [[String]]) async {
        let failed = await Task.detached { cmds.filter { !NetworkSetup.run($0) } }.value
        guard !failed.isEmpty else { return }
        addLog("Changing proxy settings needs administrator rights, asking for the password")
        let lines = failed.map(NetworkSetup.shellLine)
        let r = await Task.detached { Shell.runPrivileged(lines) }.value
        if !r.ok { addLog("Could not change proxy settings: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))", error: true) }
    }

    private func applyRoutes(remove: Set<RouteEntry>, add: Set<RouteEntry>, final: [RouteEntry]) async {
        var sh = ["fail=0"]
        sh += remove.map { "\($0.deleteCommand) >/dev/null 2>&1" }
        sh += add.map { "{ \($0.addCommand) >/dev/null 2>&1 || \($0.changeCommand) >/dev/null 2>&1 || fail=1; }" }
        sh.append("exit $fail")
        let r = await Task.detached { Shell.runPrivileged(sh) }.value
        if r.userCancelled {
            routesPending = true
            routeIssue = "Administrator permission was not given, so the routes were not changed."
            addLog("Route changes were cancelled (no password entered)", error: true)
            return
        }
        runtime.appliedRoutes = final
        appliedRoutes = final
        routesPending = false
        saveRuntime()
        if r.ok {
            routeIssue = nil
            addLog("Routes updated: \(add.count) added, \(remove.count) removed")
        } else {
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            routeIssue = "Some routes could not be added" + (err.isEmpty ? "." : ": \(err)")
            addLog("Some routes could not be added: \(err)", error: true)
        }
    }

    private func networkChanged() {
        guard !isShuttingDown else { return }
        networkChangeTask?.cancel()
        networkChangeTask = Task {
            // several events arrive while a network comes up; act once it has settled
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !isShuttingDown else { return }
            let before = primaryService?.name
            await refreshStatus()
            let now = primaryService?.name
            guard now != before else { return }
            addLog("Network in use is now \(now ?? "none")")
            enqueueApply(routes: false)
        }
    }

    func refreshStatus() async {
        let (svcs, ifs, eff) = await Task.detached {
            (SystemReader.services(), Interfaces.list(), SystemReader.effectiveProxySummary())
        }.value
        services = svcs
        interfaces = ifs.map { i in
            var i = i
            i.serviceName = svcs.first { $0.bsdName == i.name }?.name
            return i
        }
        effectiveProxy = eff
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                addLog("Could not change the launch-at-login setting: \(error.localizedDescription)", error: true)
            }
            objectWillChange.send()
        }
    }

    // MARK: - Persistence

    private func loadConfig() {
        guard let data = try? Data(contentsOf: Self.configURL) else { return }
        do {
            let cfg = try JSONDecoder().decode(ConfigFile.self, from: data)
            profiles = cfg.profiles
            settings = cfg.settings
            if cfg.version > ConfigFile.currentVersion {
                addLog("config.json was written by a newer version of the app; unknown settings are ignored", error: true)
            }
        } catch {
            // Not valid JSON at all. Keep the user's file untouched and work in memory only.
            configUnreadable = true
            let backup = Self.configURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: Self.configURL, to: backup)
            }
            addLog("config.json could not be read. It was left untouched (copy: \(backup.lastPathComponent)); changes made now will not be saved until it is fixed or removed.", error: true)
        }
    }

    private func loadRuntime() {
        guard let data = try? Data(contentsOf: Self.runtimeURL),
              let rt = try? JSONDecoder().decode(RuntimeState.self, from: data) else { return }
        runtime = rt
    }

    private func saveRuntime() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(runtime) { try? data.write(to: Self.runtimeURL, options: .atomic) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    private func flushSave() {
        guard !configUnreadable else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(ConfigFile(profiles: profiles, settings: settings)) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }

    /// "Profile / rule" label for messages about a rule
    func ruleLabel(_ ruleID: UUID) -> String {
        for p in profiles {
            if let i = p.rules.firstIndex(where: { $0.id == ruleID }) {
                let r = p.rules[i]
                return "\(p.name) / \(r.name.isEmpty ? "rule #\(i + 1)" : r.name)"
            }
        }
        return "Rule"
    }

    func addLog(_ text: String, error: Bool = false) {
        log.append(LogLine(text: text, isError: error))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}
