# ProxyRouter

A macOS menu bar app that decides, **per destination**, where network traffic goes:
through a specific proxy, straight to the internet, or out of a specific network interface.

Rules are grouped into **profiles** that you switch on and off from the menu bar. Proxy
settings follow the network you are connected to, and everything is put back when a profile
is turned off or the app quits.

- Send `198.51.100.0/24` through a SOCKS5 proxy, `*.example.com` through an HTTP proxy, and
  everything else directly.
- Force a range out of a VPN tunnel or a second network adapter — directly, or through a
  proxy running on your Mac.
- Keep specific addresses out of a profile with an exception list.
- See at a glance what proxy settings macOS is actually using right now.

Current version: **0.2.0** — see the [changelog](CHANGELOG.md).

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [User guide](#user-guide)
  - [Profiles](#profiles)
  - [Networks](#networks)
  - [Rules](#rules)
  - [Destination syntax](#destination-syntax)
  - [Actions](#actions)
  - [Out through (interface)](#out-through-interface)
  - [Current Status](#current-status)
  - [Test an Address](#test-an-address)
  - [Settings](#settings)
- [How it works](#how-it-works)
- [What apps are affected](#what-apps-are-affected)
- [Data and privacy](#data-and-privacy)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)
- [Contributing](#contributing)
- [License](#license)

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ or the Xcode command line tools (to build from source)
- An administrator account for rules with an "Out through" interface and, on some systems, for
  changing proxy settings

## Installation

ProxyRouter is distributed as source code. Build it yourself:

```sh
git clone https://github.com/WhileEndless/ProxyRouter.git
cd ProxyRouter
./build.sh
```

This creates `build/ProxyRouter.app`. Start it with:

```sh
open build/ProxyRouter.app
```

or copy it to `/Applications` first. The app is signed ad hoc, so macOS may ask you to
confirm the first launch (right-click the app → **Open**).

ProxyRouter lives in the **menu bar** (the branch icon) and has no Dock icon.

## Quick start

1. Click the menu bar icon → **Edit Profiles…**.
2. On first launch an example profile, *Example: Google via local proxy*, is created. It sends
   some Google address ranges to an HTTP proxy at `127.0.0.1:8080`. Edit it or create
   your own profile with **+**.
3. Leave **Network in use** on under **Proxy settings are applied to**; the rules then follow
   whichever network you are connected to.
4. Add or edit rules: enter the destinations, choose **Proxy** or **Direct**, and optionally
   an interface under **Out through**.
5. Turn the profile on with its switch — in the sidebar, in the editor, or from the menu bar.
6. Open **Test an Address** and type a URL or IP to confirm which rule handles it.

To turn everything off, choose **Turn Off All Profiles** in the menu bar menu.

## User guide

### Profiles

A profile is a named list of rules plus the networks it applies to.

- Turn profiles on and off from the menu bar menu or with the switch in the sidebar.
- Several profiles can be active at once. Their **order in the sidebar** is their priority:
  drag profiles to reorder them. When two profiles match the same destination, the one
  higher in the list wins.
- Right-click a profile to duplicate or delete it.
- Active profiles are remembered and turned back on the next time the app starts. Their
  routes are added again at that point (you may be asked for your password).
- **Exceptions** is a per-profile exclude list, using the same
  [destination syntax](#destination-syntax) as rules. Matching destinations skip every rule
  of the profile and fall through to the next active profile, or connect directly. Excluded
  IP ranges are also cut out of route ranges, so `198.51.100.0/24` with `198.51.100.64/26`
  excluded adds routes for everything in `198.51.100.0/24` except that block.

### Networks

macOS only follows the proxy settings of the network that currently carries internet traffic
(marked **in use**). Proxy rules therefore have to be applied to that network.

- **Network in use** (on by default) applies the profile to whichever network macOS is using
  and follows it automatically when you switch between Wi-Fi, Ethernet and other networks.
  The previous network gets its own settings back.
- **Also apply to specific networks** adds fixed networks on top of that. Turn **Network in
  use** off to apply the profile only to the networks you pick; the editor then warns you when
  the network in use is not among them.

This setting only decides whose **proxy settings** are changed. It does not choose where
traffic leaves the Mac; that is the [Out through](#out-through-interface) setting of each rule.

### Rules

A rule reads as: *when the destination is … then …*.

- Rules are checked **from top to bottom** and the **first match decides**. Use the arrows to
  reorder them.
- A destination that matches no rule connects directly, as if the app were not running.
- Each rule can be switched off without deleting it.
- Each rule has an **action** ([Proxy or Direct](#actions)) and, optionally, an interface its
  traffic leaves through ([Out through](#out-through-interface)).
- Lines that cannot be understood are shown in red and ignored. Below the editor, the app
  shows how it interpreted each valid line.

### Destination syntax

Enter one destination per line (commas also work). Text after `#` is a comment.

| You write | Matches |
|---|---|
| `142.250.0.0/15` | Any IP in the CIDR block |
| `216.58.192.0 - 216.58.223.255` | Any IP in the range (inclusive). `–` and `—` also work |
| `8.8.8.8` | That single IP |
| `mail.google.com` | Exactly that host name |
| `*.google.com` or `.google.com` | `google.com` **and** every subdomain |
| `*cdn*`, `api-?.example.com` | Wildcards: `*` any text, `?` one character |
| `*` | Everything |

When a host name is visited and a rule contains IP ranges, the host name is resolved in DNS
to check whether its address falls in the range. Domain checks run first, so DNS is only
used when needed.

### Actions

**Proxy** — Send the connection through a proxy server. Each rule has its own server, so
different destinations can use different proxies.

| Type | Use for |
|---|---|
| HTTP | Regular HTTP proxies (most common) |
| HTTPS | Proxies you connect to over TLS |
| SOCKS5 | SOCKS version 5 proxies, e.g. `ssh -D` |
| SOCKS4 | Older SOCKS proxies |

Tick **Connect directly if the proxy is unreachable** to fall back to a direct connection
when the proxy is down.

**Direct** — Connect without a proxy. Place a Direct rule **above** a broader rule to create
exceptions, for example: proxy `*.example.com`, but keep `login.example.com` direct.

### Out through (interface)

Every rule, Proxy or Direct, can force its traffic out of a chosen network interface such as a
VPN tunnel (`utun…`) or a second adapter (`en…`). Leave it on **System default** to use the
Mac's normal route. What gets a route depends on the action:

| Action | Routed through the interface |
|---|---|
| Direct | The rule's destinations |
| Proxy on this Mac (`127.x.x.x`, `localhost`) | The rule's destinations, since the local proxy connects to them itself |
| Proxy elsewhere | The proxy server **and** the rule's destinations (used by the direct fallback) |

For example, a rule for `203.0.113.0/24` that uses an HTTP proxy running on this Mac, with
**Out through** set to a USB adapter, sends browser traffic to the local proxy, and the
proxy's own connections to `203.0.113.x` leave through the USB adapter.

The app adds entries to the system routing table:

- Routes are added when the profile is turned on and removed when it is turned off, when the
  app quits, and on the next launch after a crash.
- It asks for your administrator password when routes are added or removed.
- It applies to **every app**, including command-line tools.
- **Gateway** (under the disclosure arrow) can almost always stay empty: for tunnels the
  traffic is sent straight into the interface, and for regular adapters the interface's own
  router is detected.
- Works with IPs, ranges, CIDRs and exact host names. Host names are resolved once, when the
  rule is applied. Wildcard domains cannot become routes.
- The password is asked right away when you turn a profile on, pick an interface, or switch a
  routed rule on or off. Typing in destinations or the gateway does not ask on every
  keystroke; an **Apply Now** button appears instead.
- If you cancel the password prompt (or a route command fails), a red ⚠︎ warning stays in the
  profile editor, next to the profile in the sidebar, in the toolbar and on the menu bar icon
  until you click **Try Again** and the routes are applied.
- Problems (for example a wildcard domain, which cannot become a route) are shown under the
  rule.

### Current Status

A read-only view of the system:

- **What macOS is using right now** — the effective proxy configuration.
- **Proxy settings of each network** — PAC, HTTP, HTTPS and SOCKS settings and bypass lists.
  A blue **managed** badge means the network currently gets its rules from ProxyRouter.
  - **Import as Profile** turns proxy settings entered by hand in System Settings into a
    profile.
  - **Show PAC File** displays the PAC file a network is using.
- **Routes added by this app**, plus **Show Full Routing Table**.
- **Network interfaces** with their IPv4 addresses.
- **Activity** — a log of what the app changed and any errors.

### Test an Address

Type a URL, host name or IP to see which profile and rule would handle it, what the PAC file
returns, and — if DNS was needed — the resolved IP. Nothing is sent to the address itself.

### Settings

- **Built-in PAC server** — the local port the PAC files are served from (default `18089`).
  Change it only if another program uses that port.
- **When the app quits** — restore the original proxy settings (on by default) and remove
  added routes (on by default).
- **Open at login**.
- **Show Configuration File in Finder**.
- **About** — version, license and source code link. The About window is also available
  from the menu bar menu.

## How it works

**Proxy and Direct rules** are compiled into a
[PAC file](https://developer.mozilla.org/en-US/docs/Web/HTTP/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file)
for each network a profile applies to. ProxyRouter serves it from a small web server bound to
`127.0.0.1` (not reachable from other machines) and points the network at it with
`networksetup -setautoproxyurl`. You can see the generated file with **Show PAC File** in the
profile editor.

**Interface routes** are applied with `route add` / `route delete`, batched into a
single administrator prompt.

**Restoring settings.** Before changing a network, ProxyRouter records its previous automatic
proxy setting. The record is written to disk first, so the original setting is restored:

- when the profile is turned off,
- when the app quits normally, is terminated (`kill`, Activity Monitor, logout), or
  interrupted (Ctrl+C),
- on the next launch, if the app was force-killed (`kill -9`) or crashed.

## What apps are affected

| | Proxy / Direct rules | Interface routes ("Out through") |
|---|---|---|
| Safari, Chrome, most Mac apps | ✅ | ✅ |
| Apps with their own proxy settings (e.g. Firefox set to "No proxy") | ❌ | ✅ |
| `curl`, `git`, `ssh` and most command-line tools | ❌ (they ignore PAC files) | ✅ |

Per-app routing is not possible without Apple's NetworkExtension framework, which requires a
paid developer account and a special entitlement.

## Data and privacy

- Configuration: `~/Library/Application Support/ProxyRouter/config.json`
- Record of system changes (used for restoring): `runtime.json` in the same folder
- ProxyRouter has no telemetry, no analytics and makes no network connections of its own
  except DNS lookups for your rules and downloading a PAC file when you ask it to show one.

The configuration format is forward compatible: missing or unknown fields fall back to
defaults, and a single damaged profile is skipped rather than discarding the file. If the
file cannot be parsed at all it is left untouched and a copy is kept as
`config.unreadable.json`.

## Troubleshooting

**Traffic does not go through the proxy.**
Check **Current Status**: the network marked *in use* should also be marked *managed*. If not,
turn **Network in use** on in the profile (ticking a network only changes that network's proxy
settings; macOS ignores them while another network is in use). Then check **Test an Address**.
Remember that command-line tools ignore PAC files.

**Routes work but the proxy does not (or the other way round).**
They are independent: the proxy depends on the network the profile is applied to, the routes
on the **Out through** interface. Check both in the profile editor.

**A red ⚠︎ warning is shown.**
Route changes were not applied, usually because the password prompt was cancelled. Click
**Try Again** in the profile editor, the toolbar or the menu bar menu.

**The change does not take effect in the browser.**
Browsers cache proxy decisions for open connections. Open a new tab or restart the browser.
In Chrome, `chrome://net-internals/#proxy` shows the PAC file in use.

**"Could not start the PAC server".**
Another program uses the port. Pick a different port in **Settings**.

**I am asked for my password.**
Route changes always need administrator rights. Changing proxy settings needs them on some
systems; the app then asks once per change.

**Internet stopped working after the app was force-quit.**
Start ProxyRouter again and it restores the previous settings. Or turn the proxy off
manually:

```sh
networksetup -setautoproxystate "Wi-Fi" off
```

## Uninstalling

1. Choose **Turn Off All Profiles**, then **Quit ProxyRouter** from the menu bar menu.
2. Delete `ProxyRouter.app`.
3. Optionally delete `~/Library/Application Support/ProxyRouter/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout, guidelines and how to test a
change.

## License

Copyright © 2026 WhileEndless

ProxyRouter is free software: you can redistribute it and/or modify it under the terms of
the GNU Affero General Public License as published by the Free Software Foundation, version 3.
See [LICENSE](LICENSE) for the full text.
