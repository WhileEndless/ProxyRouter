import Foundation

// MARK: - Proxy / action types

enum ProxyKind: String, Codable, CaseIterable, Identifiable {
    case http, https, socks5, socks4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http: "HTTP"
        case .https: "HTTPS"
        case .socks5: "SOCKS5"
        case .socks4: "SOCKS4"
        }
    }

    /// Keyword used in the PAC return value
    var pacKeyword: String {
        switch self {
        case .http: "PROXY"
        case .https: "HTTPS"
        case .socks5: "SOCKS5"
        case .socks4: "SOCKS"
        }
    }
}

enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case proxy, direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .proxy: "Proxy"
        case .direct: "Direct"
        }
    }
}

// MARK: - Rule / profile

struct Rule: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var name = ""
    /// One target per line (or comma separated): CIDR, IP range, IP, domain, *.domain, wildcard
    var targets = ""
    var action: RuleAction = .proxy
    var proxyKind: ProxyKind = .http
    var proxyHost = "127.0.0.1"
    var proxyPort = 8080
    var fallbackDirect = false
    /// Network interface the matching traffic leaves through (empty = system default).
    /// Turned into routes for the targets and, for a remote proxy, for the proxy server.
    var outInterface = ""
    /// Next hop for those routes (empty = detected automatically)
    var outGateway = ""

    var usesInterface: Bool { !outInterface.isEmpty }

    /// true when the proxy server runs on this Mac, so it connects to the targets itself
    var isLocalProxy: Bool {
        let h = proxyHost.lowercased()
        return h == "localhost" || (IPv4.parse(h).map { $0 >> 24 == 127 } ?? false)
    }

    var parsedTargets: [ParsedTarget] { TargetSpec.parseList(targets) }

    var isProxyHostValid: Bool {
        !proxyHost.isEmpty && proxyHost.unicodeScalars.allSatisfy(TargetSpec.hostChars.contains)
            && (1...65535).contains(proxyPort)
    }

    /// Value this rule returns from FindProxyForURL
    var pacResult: String {
        switch action {
        case .proxy: "\(proxyKind.pacKeyword) \(proxyHost):\(proxyPort)" + (fallbackDirect ? "; DIRECT" : "")
        case .direct: "DIRECT"
        }
    }

    var actionSummary: String {
        let base = switch action {
        case .proxy: "\(proxyKind.label) \(proxyHost):\(proxyPort)"
        case .direct: "DIRECT"
        }
        return base + (usesInterface ? ", out through \(outInterface)" : "")
    }
}

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var isActive = false
    /// Also apply the PAC to whichever network macOS is using at the moment (followed on changes)
    var followPrimary = true
    /// Network services the PAC is applied to (networksetup names)
    var services: [String] = []
    var rules: [Rule] = []
    /// Destinations the profile never applies to (same syntax as rule targets)
    var excludes = ""

    var parsedExcludes: [ParsedTarget] { TargetSpec.parseList(excludes) }

    /// The exclusion that matches the destination, if any
    func exclusion(host: String, ip: () -> UInt32?) -> TargetSpec? {
        parsedExcludes.compactMap(\.spec).first { spec in
            if case .ipRange = spec { return spec.matches(host: host, ip: ip()) }
            return spec.matches(host: host, ip: nil)
        }
    }
}

struct AppSettings: Codable, Equatable {
    var pacPort = 18089
    var restoreOnQuit = true
    var removeRoutesOnQuit = true
}

struct ConfigFile: Codable {
    static let currentVersion = 1

    var version = ConfigFile.currentVersion
    var profiles: [Profile]
    var settings: AppSettings
}

// MARK: - Tolerant decoding
//
// The user's config must survive app updates: missing keys fall back to defaults,
// unknown enum values fall back to defaults, and a single unreadable profile or rule
// is skipped instead of discarding the whole file.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func lenientArray<T: Decodable>(_ key: Key) -> [T] {
        guard var arr = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [T] = []
        while !arr.isAtEnd {
            if let v = try? arr.decode(T.self) { out.append(v) } else { _ = try? arr.decode(SkipValue.self) }
        }
        return out
    }
}

private struct SkipValue: Decodable {
    init(from decoder: Decoder) throws {}
}

extension ConfigFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: c.value(.version, ConfigFile.currentVersion),
                  profiles: c.lenientArray(.profiles),
                  settings: c.value(.settings, AppSettings()))
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.init(pacPort: c.value(.pacPort, d.pacPort),
                  restoreOnQuit: c.value(.restoreOnQuit, d.restoreOnQuit),
                  removeRoutesOnQuit: c.value(.removeRoutesOnQuit, d.removeRoutesOnQuit))
    }
}

extension Profile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.value(.id, UUID()),
                  name: c.value(.name, "Untitled"),
                  isActive: c.value(.isActive, false),
                  followPrimary: c.value(.followPrimary, true),
                  services: c.value(.services, []),
                  rules: c.lenientArray(.rules),
                  excludes: c.value(.excludes, ""))
    }
}

extension Rule {
    /// Keys written by 0.1.0, where "route via interface" was a separate action
    private enum LegacyKeys: String, CodingKey {
        case action, interfaceName, gateway, proxyInterface, proxyGateway
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Rule()
        self.init(id: c.value(.id, UUID()),
                  enabled: c.value(.enabled, d.enabled),
                  name: c.value(.name, d.name),
                  targets: c.value(.targets, d.targets),
                  action: d.action,
                  proxyKind: c.value(.proxyKind, d.proxyKind),
                  proxyHost: c.value(.proxyHost, d.proxyHost),
                  proxyPort: c.value(.proxyPort, d.proxyPort),
                  fallbackDirect: c.value(.fallbackDirect, d.fallbackDirect),
                  outInterface: c.value(.outInterface, d.outInterface),
                  outGateway: c.value(.outGateway, d.outGateway))

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let rawAction = legacy.value(.action, "")
        action = RuleAction(rawValue: rawAction) ?? (rawAction == "interface" ? .direct : d.action)
        guard !c.contains(.outInterface) else { return }
        // Old configs: only "interface" rules (and proxy rules with proxyInterface) used an interface;
        // interfaceName left over on other rules was ignored, so it must not start routing now.
        if rawAction == "interface" {
            outInterface = legacy.value(.interfaceName, "")
            outGateway = legacy.value(.gateway, "")
        } else if action == .proxy {
            outInterface = legacy.value(.proxyInterface, "")
            outGateway = legacy.value(.proxyGateway, "")
        }
    }
}

/// Record of what the app changed on the system (persisted so it can be undone after a crash)
struct RuntimeState: Codable {
    struct AutoProxySnapshot: Codable, Hashable {
        var url: String
        var enabled: Bool
    }
    /// service name -> automatic proxy setting before the app took over
    var originals: [String: AutoProxySnapshot] = [:]
    var appliedRoutes: [RouteEntry] = []
}

// MARK: - Target parsing

struct ParsedTarget: Hashable {
    var raw: String
    var spec: TargetSpec?
    var error: String?
}

enum TargetSpec: Hashable {
    case any
    case ipRange(UInt32, UInt32)
    case host(String)
    case domain(String)   // the domain itself + all subdomains
    case pattern(String)  // shExpMatch wildcard

    static let hostChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
    private static let patternChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._*?")

    var description: String {
        switch self {
        case .any: return "everything (*)"
        case .ipRange(let lo, let hi):
            let blocks = IPv4.cidrs(lo, hi)
            if blocks.count == 1 { return "\(IPv4.format(blocks[0].0))/\(blocks[0].1)" }
            return "\(IPv4.format(lo)) – \(IPv4.format(hi))"
        case .host(let h): return h
        case .domain(let d): return "*.\(d)"
        case .pattern(let p): return p
        }
    }

    func matches(host: String, ip: UInt32?) -> Bool {
        switch self {
        case .any: return true
        case .host(let h): return host == h
        case .domain(let d): return host == d || host.hasSuffix("." + d)
        case .pattern(let p): return fnmatch(p, host, 0) == 0
        case .ipRange(let lo, let hi):
            guard let ip else { return false }
            return ip >= lo && ip <= hi
        }
    }

    static func parseList(_ text: String) -> [ParsedTarget] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { line -> String in
                var s = String(line)
                if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .map(parse)
    }

    static func parse(_ input: String) -> ParsedTarget {
        func ok(_ spec: TargetSpec) -> ParsedTarget { ParsedTarget(raw: input, spec: spec) }
        func fail(_ msg: String) -> ParsedTarget { ParsedTarget(raw: input, error: msg) }

        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")

        if s == "*" { return ok(.any) }

        if let slash = s.firstIndex(of: "/") {
            let ipPart = s[..<slash].trimmingCharacters(in: .whitespaces)
            let bitsPart = s[s.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            guard let ip = IPv4.parse(ipPart), let bits = Int(bitsPart), (0...32).contains(bits) else {
                return fail("Invalid CIDR (expected e.g. 192.0.2.0/24)")
            }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
            return ok(.ipRange(ip & mask, (ip & mask) | ~mask))
        }

        if s.contains("-") {
            let parts = s.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let a = IPv4.parse(parts[0]), let b = IPv4.parse(parts[1]) {
                return ok(.ipRange(min(a, b), max(a, b)))
            }
        }

        if let ip = IPv4.parse(s) { return ok(.ipRange(ip, ip)) }

        if s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == " " }) {
            return fail("Invalid IP address or range")
        }
        guard s.unicodeScalars.allSatisfy(patternChars.contains) else {
            return fail("Unsupported characters — expected an IP, CIDR, IP range or domain")
        }

        let hasWildcard = { (x: String) in x.contains("*") || x.contains("?") }
        if s.hasPrefix("*.") {
            let rest = String(s.dropFirst(2))
            if !rest.isEmpty && !hasWildcard(rest) { return ok(.domain(rest)) }
        }
        if s.hasPrefix("."), s.count > 1 {
            let rest = String(s.dropFirst())
            if !hasWildcard(rest) { return ok(.domain(rest)) }
        }
        if hasWildcard(s) { return ok(.pattern(s)) }
        return ok(.host(s))
    }
}
