# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-09-23

First public release.

### Added
- Menu bar app with profiles that can be turned on and off individually.
- Rules matching CIDRs, IP ranges, single IPs, exact host names, domains with subdomains,
  wildcards and "everything".
- Actions: HTTP / HTTPS / SOCKS5 / SOCKS4 proxy (each rule with its own server), direct
  connection, and routing through a chosen network interface.
- Per-network application of proxy rules through a generated PAC file served on 127.0.0.1.
- Current Status screen showing the system's proxy settings, each network's settings,
  routes, interfaces and an activity log; manual proxy settings can be imported as a profile.
- Test screen that shows which profile and rule would handle an address.
- Automatic restore of the original settings when a profile is turned off or the app quits,
  including termination by signal, with crash recovery on the next launch.
- Tolerant configuration loading so user data survives app updates.
- About window and version information.

[0.1.0]: https://github.com/WhileEndless/ProxyRouter/releases/tag/v0.1.0
