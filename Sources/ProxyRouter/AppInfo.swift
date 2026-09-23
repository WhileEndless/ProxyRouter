import AppKit

enum AppInfo {
    static let name = "ProxyRouter"
    static let repository = URL(string: "https://github.com/WhileEndless/ProxyRouter")!
    static let license = "GNU Affero General Public License v3.0"
    static let copyright = "Copyright © 2026 WhileEndless"

    /// Marketing version from Info.plist, e.g. "0.1.0" ("dev" when run outside the app bundle)
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    @MainActor
    static func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: "Routes traffic per destination through proxies, directly, or out of a chosen network interface.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(
            string: repository.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repository]
        ))
        credits.append(NSAttributedString(
            string: "\nLicensed under the \(license).",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .applicationVersion: version,
            .version: "build \(build)",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ])
    }
}
