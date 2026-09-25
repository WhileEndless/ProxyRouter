import SwiftUI
import AppKit

@main
struct ProxyRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.routesNeedAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                .symbolRenderingMode(.hierarchical)
                .opacity(model.anyActive || model.routesNeedAttention ? 1 : 0.5)
        }

        Window("ProxyRouter", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 580)
        }
        .defaultSize(width: 1080, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app changes system settings, so it must never be killed without cleaning up.
        // Sudden/automatic termination would let macOS end it on SIGTERM without notice.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("ProxyRouter manages system proxy settings")
        // `kill`, Ctrl+C or a service manager would otherwise end the process without
        // applicationWillTerminate, leaving the system pointed at a PAC server that is gone.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.summaryLine)
        Divider()

        if model.profiles.isEmpty {
            Text("No profiles yet")
        }
        ForEach(model.profiles) { p in
            Toggle(p.name.isEmpty ? "Untitled profile" : p.name, isOn: Binding(
                get: { p.isActive },
                set: { model.setActive(p.id, $0) }
            ))
        }

        if model.routesNeedAttention {
            Divider()
            Label(model.routeIssue != nil ? "Routes are not applied" : "Route changes are waiting",
                  systemImage: "exclamationmark.triangle.fill")
            Button(model.routeIssue != nil ? "Try Again…" : "Apply Route Changes…") { model.applyNow() }
        }

        Divider()
        Button("Edit Profiles…") { open(nil) }
            .keyboardShortcut(",")
        Button("New Profile…") { open(.profile(model.addProfile())) }
        Button("Current System Status…") { open(.status) }
        Button("Test an Address…") { open(.test) }
        Divider()
        Button("Turn Off All Profiles") { model.deactivateAll() }
            .disabled(!model.anyActive)
        Button("Reapply Everything") { model.applyNow(force: true) }
        Divider()
        Button("About ProxyRouter") { AppInfo.showAboutPanel() }
        Button("Quit ProxyRouter") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ item: SidebarItem?) {
        if let item { model.selection = item }
        else if model.selection == nil, let first = model.profiles.first { model.selection = .profile(first.id) }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
