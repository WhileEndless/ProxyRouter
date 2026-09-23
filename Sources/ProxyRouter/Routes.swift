import Foundation

/// A single entry added to the system routing table
struct RouteEntry: Codable, Hashable, Identifiable {
    var network: String
    var prefix: Int
    var interface: String
    var gateway: String

    var id: String { "\(network)/\(prefix)" }

    private var destArgs: String { prefix == 32 ? "-host \(network)" : "-net \(network)/\(prefix)" }
    private var targetArgs: String { gateway.isEmpty ? "-interface \(interface)" : gateway }

    var addCommand: String { "/sbin/route -n add \(destArgs) \(targetArgs)" }
    var changeCommand: String { "/sbin/route -n change \(destArgs) \(targetArgs)" }
    var deleteCommand: String { "/sbin/route -n delete \(destArgs)" }

    var summary: String { "\(id) → " + (gateway.isEmpty ? interface : "\(gateway) (\(interface))") }
}

enum RoutePlanner {
    private static let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// Builds the desired route list from the "route via interface" rules of active profiles.
    /// Exact domain names are resolved to IPv4 at this moment.
    static func plan(_ profiles: [Profile], interfaces: [NetInterface]) -> (routes: [RouteEntry], warnings: [String]) {
        var routes: [RouteEntry] = []
        var seen = Set<String>()
        var warnings: [String] = []
        var gatewayCache: [String: String?] = [:]

        func add(_ net: UInt32, _ prefix: Int, _ iface: String, _ gw: String) {
            let e = RouteEntry(network: IPv4.format(net), prefix: prefix, interface: iface, gateway: gw)
            if seen.insert(e.id).inserted { routes.append(e) }
        }

        for p in profiles where p.isActive {
            for r in p.rules where r.enabled && r.action == .interface {
                let label = "\(p.name) / \(r.name.isEmpty ? "rule" : r.name)"
                let iface = r.interfaceName.trimmingCharacters(in: .whitespaces)
                guard !iface.isEmpty, iface.unicodeScalars.allSatisfy(safeChars.contains) else {
                    warnings.append("\(label): no interface selected")
                    continue
                }
                var gw = r.gateway.trimmingCharacters(in: .whitespaces)
                if !gw.isEmpty && IPv4.parse(gw) == nil {
                    warnings.append("\(label): invalid gateway \(gw)")
                    continue
                }
                if gw.isEmpty {
                    let ptp = interfaces.first { $0.name == iface }?.isPointToPoint
                        ?? (iface.hasPrefix("utun") || iface.hasPrefix("ppp") || iface.hasPrefix("ipsec"))
                    if !ptp {
                        if gatewayCache[iface] == nil { gatewayCache[iface] = .some(Interfaces.defaultGateway(for: iface)) }
                        if let found = gatewayCache[iface] ?? nil {
                            gw = found
                        } else {
                            warnings.append("\(label): no gateway found for \(iface), routing directly to the interface")
                        }
                    }
                }

                for t in r.parsedTargets {
                    guard let spec = t.spec else { continue }
                    switch spec {
                    case .ipRange(let lo, let hi):
                        for (net, prefix) in IPv4.cidrs(lo, hi) { add(net, prefix, iface, gw) }
                    case .host(let h):
                        let ips = DNS.resolveIPv4(h)
                        if ips.isEmpty { warnings.append("\(label): could not resolve \(h)") }
                        for ip in ips { if let v = IPv4.parse(ip) { add(v, 32, iface, gw) } }
                    case .any:
                        warnings.append("\(label): '*' is ignored for routes (the default route is never changed)")
                    case .domain, .pattern:
                        warnings.append("\(label): \(t.raw) — wildcard domains cannot be turned into routes")
                    }
                }
            }
        }
        return (routes, warnings)
    }
}
