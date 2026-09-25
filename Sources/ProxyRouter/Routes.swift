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

/// A problem found while turning a rule into routes
struct RouteWarning: Hashable, Identifiable {
    var ruleID: UUID
    var text: String
    var id: String { "\(ruleID)|\(text)" }
}

enum RoutePlanner {
    private static let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// Builds the desired route list from the rules of active profiles that send their traffic
    /// out through a chosen interface: the rule's targets, plus the proxy server when it is remote.
    /// Exact domain names are resolved to IPv4 at this moment.
    static func plan(_ profiles: [Profile], interfaces: [NetInterface]) -> (routes: [RouteEntry], warnings: [RouteWarning]) {
        var routes: [RouteEntry] = []
        var seen = Set<String>()
        var warnings: [RouteWarning] = []
        var gatewayCache: [String: String?] = [:]

        func add(_ net: UInt32, _ prefix: Int, _ iface: String, _ gw: String) {
            let e = RouteEntry(network: IPv4.format(net), prefix: prefix, interface: iface, gateway: gw)
            if seen.insert(e.id).inserted { routes.append(e) }
        }

        for p in profiles where p.isActive {
            let excludes = p.parsedExcludes.compactMap(\.spec)
            let excludedRanges: [(UInt32, UInt32)] = excludes.compactMap {
                if case .ipRange(let lo, let hi) = $0 { return (lo, hi) }
                return nil
            }
            func isExcluded(_ host: String, _ ip: UInt32?) -> Bool {
                excludes.contains { spec in
                    if case .ipRange = spec { return spec.matches(host: host, ip: ip) }
                    return spec.matches(host: host, ip: nil)
                }
            }

            for r in p.rules where r.enabled && r.usesInterface {
                func warn(_ text: String) { warnings.append(RouteWarning(ruleID: r.id, text: text)) }

                let iface = r.outInterface.trimmingCharacters(in: .whitespaces)
                guard iface.unicodeScalars.allSatisfy(safeChars.contains) else {
                    warn("Invalid interface name \(iface)")
                    continue
                }
                var gw = r.outGateway.trimmingCharacters(in: .whitespaces)
                if !gw.isEmpty && IPv4.parse(gw) == nil {
                    warn("Invalid gateway \(gw)")
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
                            warn("No gateway found for \(iface); sending straight into the interface")
                        }
                    }
                }

                // the proxy server itself, when the connection to it has to leave this Mac
                if r.action == .proxy && r.isProxyHostValid && !r.isLocalProxy {
                    let host = r.proxyHost.lowercased()
                    let ips = IPv4.parse(host) != nil ? [host] : DNS.resolveIPv4(host)
                    if ips.isEmpty { warn("Could not resolve the proxy server \(host)") }
                    for ip in ips { if let v = IPv4.parse(ip) { add(v, 32, iface, gw) } }
                }

                // the destinations (reached directly, or by a proxy running on this Mac);
                // the exclude list only concerns destinations
                if excludes.contains(.any) { continue }
                for pt in r.parsedTargets {
                    guard let spec = pt.spec else { continue }
                    switch spec {
                    case .ipRange(let lo, let hi):
                        for (a, b) in IPv4.subtract([(lo, hi)], excludedRanges) {
                            for (net, prefix) in IPv4.cidrs(a, b) { add(net, prefix, iface, gw) }
                        }
                    case .host(let h):
                        if isExcluded(h, nil) { continue }
                        let ips = DNS.resolveIPv4(h)
                        if ips.isEmpty { warn("Could not resolve \(h)") }
                        for ip in ips {
                            if let v = IPv4.parse(ip), !isExcluded(h, v) { add(v, 32, iface, gw) }
                        }
                    case .any:
                        warn("“*” gets no route; the default route is never changed")
                    case .domain, .pattern:
                        warn("\(pt.raw) gets no route; wildcard domains cannot become routes")
                    }
                }
            }
        }
        return (routes, warnings)
    }
}
