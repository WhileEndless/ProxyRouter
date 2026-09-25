import Foundation
import SystemConfiguration

// MARK: - IPv4 helpers

enum IPv4 {
    /// "a.b.c.d" -> host byte order
    static func parse(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    static func format(_ v: UInt32) -> String {
        "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }

    /// Splits [lo, hi] into the smallest set of CIDR blocks
    static func cidrs(_ lo: UInt32, _ hi: UInt32) -> [(UInt32, Int)] {
        var out: [(UInt32, Int)] = []
        var start = UInt64(lo)
        let end = UInt64(hi)
        while start <= end {
            var bits = start == 0 ? 32 : min(32, start.trailingZeroBitCount)
            while bits > 0 && start + (UInt64(1) << UInt64(bits)) - 1 > end { bits -= 1 }
            out.append((UInt32(start), 32 - bits))
            start += UInt64(1) << UInt64(bits)
        }
        return out
    }

    /// Removes the `excluded` ranges from `ranges`
    static func subtract(_ ranges: [(UInt32, UInt32)], _ excluded: [(UInt32, UInt32)]) -> [(UInt32, UInt32)] {
        var out = ranges
        for (elo, ehi) in excluded {
            out = out.flatMap { (lo, hi) -> [(UInt32, UInt32)] in
                if ehi < lo || elo > hi { return [(lo, hi)] }
                var parts: [(UInt32, UInt32)] = []
                if elo > lo { parts.append((lo, elo - 1)) }
                if ehi < hi { parts.append((ehi + 1, hi)) }
                return parts
            }
        }
        return out
    }
}

enum DNS {
    static func resolveIPv4(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }

        var out: [String] = []
        var p = res
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    let s = String(cString: buf)
                    if !out.contains(s) { out.append(s) }
                }
            }
            p = ai.pointee.ai_next
        }
        return out
    }
}

// MARK: - Interfaces

struct NetInterface: Identifiable, Hashable {
    var name: String
    var addresses: [String]
    var isUp: Bool
    var isPointToPoint: Bool
    var serviceName: String?

    var id: String { name }

    var label: String {
        var s = name
        if let serviceName { s += " — \(serviceName)" }
        if !addresses.isEmpty { s += " (\(addresses.joined(separator: ", ")))" }
        return s
    }
}

enum Interfaces {
    static func list() -> [NetInterface] {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0 else { return [] }
        defer { freeifaddrs(ptr) }

        var map: [String: NetInterface] = [:]
        var order: [String] = []
        var p = ptr
        while let ifa = p {
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = Int32(ifa.pointee.ifa_flags)
            if map[name] == nil {
                map[name] = NetInterface(name: name, addresses: [],
                                         isUp: flags & IFF_UP != 0,
                                         isPointToPoint: flags & IFF_POINTOPOINT != 0)
                order.append(name)
            }
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    map[name]?.addresses.append(String(cString: buf))
                }
            }
            p = ifa.pointee.ifa_next
        }
        // interfaces with an IPv4 address first; loopback excluded
        return order.compactMap { map[$0] }
            .filter { $0.name != "lo0" && $0.isUp }
            .sorted { ($0.addresses.isEmpty ? 1 : 0, $0.name) < ($1.addresses.isEmpty ? 1 : 0, $1.name) }
    }

    /// Default gateway scoped to the given interface
    static func defaultGateway(for iface: String) -> String? {
        let r = Shell.run("/sbin/route", ["-n", "get", "-ifscope", iface, "default"])
        guard r.status == 0 else { return nil }
        for line in r.out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                let g = t.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                return IPv4.parse(g) != nil ? g : nil
            }
        }
        return nil
    }
}

// MARK: - Shell

enum Shell {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
        var userCancelled: Bool { err.contains("-128") || err.localizedCaseInsensitiveContains("cancel") }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return Result(status: -1, out: "", err: "\(error)") }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: od, as: UTF8.self),
                      err: String(decoding: ed, as: UTF8.self))
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs the commands behind a single administrator password prompt.
    static func runPrivileged(_ commands: [String]) -> Result {
        let script = commands.joined(separator: "; ")
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}

enum NetworkSetup {
    static let bin = "/usr/sbin/networksetup"

    /// networksetup often exits 0 even on failure, so check the output too
    static func run(_ args: [String]) -> Bool {
        let r = Shell.run(bin, args)
        let text = (r.out + r.err).lowercased()
        return r.ok && !text.contains("error") && !text.contains("requires admin")
    }

    static func shellLine(_ args: [String]) -> String {
        ([bin] + args).map(Shell.quote).joined(separator: " ")
    }
}

// MARK: - Reading system state (SystemConfiguration, no privileges needed)

struct ProxyEndpoint: Hashable {
    var host: String
    var port: Int
    var text: String { "\(host):\(port)" }
}

struct ServiceStatus: Identifiable, Hashable {
    var id: String
    var name: String
    var bsdName: String
    var hardware: String
    var enabled: Bool
    var isPrimary: Bool
    var autoProxyEnabled: Bool
    var autoProxyURL: String
    var http: ProxyEndpoint?
    var https: ProxyEndpoint?
    var socks: ProxyEndpoint?
    var bypass: [String]
    var excludeSimple: Bool

    var hasManualProxy: Bool { http != nil || https != nil || socks != nil }
}

enum SystemReader {
    static func services() -> [ServiceStatus] {
        guard let prefs = SCPreferencesCreate(nil, "ProxyRouter" as CFString, nil),
              let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }

        var order: [String] = []
        if let set = SCNetworkSetCopyCurrent(prefs), let o = SCNetworkSetGetServiceOrder(set) as? [String] {
            order = o
        }
        let primary = primaryServiceID()

        let list: [ServiceStatus] = all.compactMap { svc in
            guard let idCF = SCNetworkServiceGetServiceID(svc), let nameCF = SCNetworkServiceGetName(svc) else { return nil }
            let id = idCF as String
            var bsd = "", hw = ""
            if let iface = SCNetworkServiceGetInterface(svc) {
                bsd = (SCNetworkInterfaceGetBSDName(iface) as String?) ?? ""
                hw = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? ""
            }
            var cfg: [String: Any] = [:]
            if let proto = SCNetworkServiceCopyProtocol(svc, kSCNetworkProtocolTypeProxies),
               let c = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] {
                cfg = c
            }
            func int(_ k: CFString) -> Int { (cfg[k as String] as? NSNumber)?.intValue ?? 0 }
            func str(_ k: CFString) -> String { cfg[k as String] as? String ?? "" }
            func ep(_ en: CFString, _ h: CFString, _ p: CFString) -> ProxyEndpoint? {
                int(en) != 0 && !str(h).isEmpty ? ProxyEndpoint(host: str(h), port: int(p)) : nil
            }
            return ServiceStatus(
                id: id,
                name: nameCF as String,
                bsdName: bsd,
                hardware: hw,
                enabled: SCNetworkServiceGetEnabled(svc),
                isPrimary: id == primary,
                autoProxyEnabled: int(kSCPropNetProxiesProxyAutoConfigEnable) != 0,
                autoProxyURL: str(kSCPropNetProxiesProxyAutoConfigURLString),
                http: ep(kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort),
                https: ep(kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort),
                socks: ep(kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort),
                bypass: cfg[kSCPropNetProxiesExceptionsList as String] as? [String] ?? [],
                excludeSimple: int(kSCPropNetProxiesExcludeSimpleHostnames) != 0
            )
        }
        return list.sorted {
            (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max)
        }
    }

    static func primaryServiceID() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "ProxyRouter" as CFString, nil, nil),
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return v["PrimaryService"] as? String
    }

    /// Proxy configuration the system is actually using right now (same as scutil --proxy)
    static func effectiveProxySummary() -> [String] {
        guard let d = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return ["Could not be read"] }
        func int(_ k: CFString) -> Int { (d[k as String] as? NSNumber)?.intValue ?? 0 }
        func str(_ k: CFString) -> String { d[k as String] as? String ?? "" }
        var out: [String] = []
        if int(kSCPropNetProxiesProxyAutoConfigEnable) != 0 {
            out.append("Automatic proxy (PAC): \(str(kSCPropNetProxiesProxyAutoConfigURLString))")
        }
        if int(kSCPropNetProxiesProxyAutoDiscoveryEnable) != 0 { out.append("Auto proxy discovery (WPAD): on") }
        if int(kSCPropNetProxiesHTTPEnable) != 0 {
            out.append("HTTP: \(str(kSCPropNetProxiesHTTPProxy)):\(int(kSCPropNetProxiesHTTPPort))")
        }
        if int(kSCPropNetProxiesHTTPSEnable) != 0 {
            out.append("HTTPS: \(str(kSCPropNetProxiesHTTPSProxy)):\(int(kSCPropNetProxiesHTTPSPort))")
        }
        if int(kSCPropNetProxiesSOCKSEnable) != 0 {
            out.append("SOCKS: \(str(kSCPropNetProxiesSOCKSProxy)):\(int(kSCPropNetProxiesSOCKSPort))")
        }
        if let ex = d[kSCPropNetProxiesExceptionsList as String] as? [String], !ex.isEmpty {
            out.append("Bypassed: \(ex.joined(separator: ", "))")
        }
        return out.isEmpty ? ["No proxy — all traffic goes direct"] : out
    }

    static func routingTable() -> String {
        Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).out
    }
}
