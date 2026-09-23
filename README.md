# ProxyRouter

A macOS menu bar app that decides, **per destination**, where network traffic goes:
through a specific proxy, straight to the internet, or out of a specific network interface.

Rules are grouped into **profiles** that you switch on and off from the menu bar. Only the
networks you choose are changed, and everything is put back when a profile is turned off or
the app quits.

- Send `198.51.100.0/24` through a SOCKS5 proxy, `*.example.com` through an HTTP proxy, and
  everything else directly.
- Force a range out of a VPN tunnel or a second network adapter.
- See at a glance what proxy settings macOS is actually using right now.

Current version: **0.1.0** — see the [changelog](CHANGELOG.md).

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
- An administrator account for "Route via interface" rules and, on some systems, for
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
3. Under **Apply proxy rules to these networks**, tick the network you are connected to (it is
   marked **in use**).
4. Add or edit rules: destinations on the left, what to do with them below.
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
- Active profiles are remembered and turned back on the next time the app starts.

### Networks

Each profile has a list of network services (Wi-Fi, Ethernet, USB adapters, …). Proxy rules
are applied **only to the networks you tick**; all other networks keep their own settings.

macOS follows the proxy settings of the network that currently carries internet traffic.
That network is marked **in use**. If you move between Wi-Fi and Ethernet, tick both.

"Route via interface" rules are independent of this list; see [Actions](#actions).

### Rules

A rule reads as: *when the destination is … then …*.

- Rules are checked **from top to bottom** and the **first match decides**. Use the arrows to
  reorder them.
- A destination that matches no rule connects directly, as if the app were not running.
- Each rule can be switched off without deleting it.
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

Tick **If the proxy cannot be reached, connect directly instead** to fall back to a direct
connection when the proxy is down.

**Direct** — Connect without a proxy. Place a Direct rule **above** a broader rule to create
exceptions, for example: proxy `*.example.com`, but keep `login.example.com` direct.

**Route via interface** — Connect directly, but force the traffic out of a chosen network
interface such as a VPN tunnel (`utun…`) or a second adapter (`en…`). The app adds entries to
the system routing table:

- It asks for your administrator password when routes are added or removed.
- It applies to **every app**, including command-line tools.
- **Gateway** can be left empty: for tunnels the traffic is sent straight into the interface;
  for regular adapters the interface's own default gateway is detected.
- Works with IPs, ranges, CIDRs and exact host names. Host names are resolved once, when the
  rule is applied. Wildcard domains cannot become routes.
- When you edit route rules of an active profile, an **Apply Route Changes** button appears in
  the toolbar and menu, so you are not asked for your password on every keystroke.

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
for each ticked network. ProxyRouter serves it from a small web server bound to
`127.0.0.1` (not reachable from other machines) and points the network at it with
`networksetup -setautoproxyurl`. You can see the generated file with **Show PAC File** in the
profile editor.

**Route via interface rules** are applied with `route add` / `route delete`, batched into a
single administrator prompt.

**Restoring settings.** Before changing a network, ProxyRouter records its previous automatic
proxy setting. The record is written to disk first, so the original setting is restored:

- when the profile is turned off,
- when the app quits normally, is terminated (`kill`, Activity Monitor, logout), or
  interrupted (Ctrl+C),
- on the next launch, if the app was force-killed (`kill -9`) or crashed.

## What apps are affected

| | Proxy / Direct rules | Route via interface rules |
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
tick that network in the profile. Then check **Test an Address**. Remember that command-line
tools ignore PAC files.

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
