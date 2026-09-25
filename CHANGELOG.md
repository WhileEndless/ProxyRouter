# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- "Out through" interface on every rule. Direct rules route their destinations through it;
  proxy rules route their destinations too (so a proxy running on this Mac connects to them
  through that interface) and, for a remote proxy, the proxy server as well.
- Per-profile **Exceptions** list: matching destinations skip the profile in the PAC file, in
  the Test screen and when routes are built; excluded IP ranges are cut out of route ranges.
- **Network in use** option (on by default, also for existing profiles): proxy rules are
  applied to whichever network macOS is using and follow it when the network changes. Fixed
  networks can still be added on top.
- Warning in the profile editor when "Network in use" is off and the network macOS is using
  is not selected.
- Route problems are shown under the rule they belong to; pending route changes can be applied
  from the profile editor.
- Picking an interface or switching a routed rule on/off in an active profile applies the
  routes right away. If the password prompt is cancelled, a persistent warning with a
  **Try Again** button is shown in the editor, sidebar, toolbar and menu bar.

### Changed
- "Route via interface" is no longer a separate action; existing rules become Direct rules with
  an "Out through" interface. Configurations are migrated automatically.
- Redesigned rule editor: labelled rows, gateway moved under a disclosure arrow; the list of
  specific networks is collapsed by default.
- Routes of profiles that are active at launch are applied right away instead of waiting as
  pending changes.

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
