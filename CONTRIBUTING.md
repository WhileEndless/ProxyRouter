# Contributing to ProxyRouter

Thanks for taking the time to help. This document explains how the project is organised
and what is expected from a change.

## Development setup

- macOS 14 or later
- Xcode 15 or later (or the matching command line tools), Swift 5.9+

```sh
git clone https://github.com/WhileEndless/ProxyRouter.git
cd ProxyRouter
swift build            # debug build, quick compile check
./build.sh             # release build, creates build/ProxyRouter.app
open build/ProxyRouter.app
```

There is no Xcode project; the app is a plain Swift package. `build.sh` wraps the release
binary into an `.app` bundle with `Resources/Info.plist` and signs it ad hoc.

## Code layout

| File | Responsibility |
|---|---|
| `Sources/ProxyRouter/ProxyRouterApp.swift` | App entry point, menu bar menu, signal handling |
| `Sources/ProxyRouter/AppModel.swift` | State, persistence, applying and restoring settings |
| `Sources/ProxyRouter/Models.swift` | Profiles, rules, target parsing, tolerant decoding |
| `Sources/ProxyRouter/PAC.swift` | PAC generation, the local PAC server, the test evaluator |
| `Sources/ProxyRouter/Routes.swift` | Planning routes for "Route via interface" rules |
| `Sources/ProxyRouter/System.swift` | IPv4 helpers, DNS, interfaces, shell and SystemConfiguration access |
| `Sources/ProxyRouter/AppInfo.swift` | Name, version, license and the About window |
| `Sources/ProxyRouter/Views/` | SwiftUI screens |

## Guidelines

### Never lose user data
- The configuration file belongs to the user. Never overwrite it with defaults.
- New fields must have defaults and be decoded with `c.value(.key, default)` in the
  `init(from:)` extensions in `Models.swift`, so older files keep loading.
- The example profile is only created on the very first launch.
- If you change the meaning of an existing field, bump `ConfigFile.currentVersion` and
  migrate old values explicitly.

### Always be able to undo system changes
- Every change to system settings must be recorded in `RuntimeState` **before** it is made,
  so it can be restored on quit, after a signal, or after a crash on the next launch.
- Only touch the networks the user selected. Never change settings globally.
- Keep privileged operations to a minimum and batch them into a single password prompt.

### Keep the PAC file and the test screen in sync
- `PACGenerator` and `Evaluator` implement the same matching rules. Change both together
  and check the result with the Test screen.

### User interface
- All user-facing text is in English and should explain what will happen, not just name
  the setting.
- Prefer clear descriptions in section footers over tooltips for important behaviour.

### Privacy
- Do not commit personal data: local paths, host names, internal IP ranges, company or
  customer names, credentials. Use documentation ranges (`192.0.2.0/24`,
  `198.51.100.0/24`, `203.0.113.0/24`) or well-known public addresses in examples.

## Testing a change

There is no automated test suite yet. Before opening a pull request:

1. `swift build` compiles without warnings.
2. Create a profile, turn it on, and confirm on **Current Status** that the chosen network
   is marked *managed*.
3. Use **Test an Address** to check matching for IPs, ranges and domains.
4. Quit the app from the menu and with `kill <pid>`; the network must return to its
   previous proxy settings.
5. If you touched routes: add a "Route via interface" rule, apply it, check
   `netstat -rn -f inet`, then turn the profile off and confirm the route is gone.

## Commits and releases

- Keep commits focused and describe *why* in the message.
- Versions follow Semantic Versioning. To release, update `CFBundleShortVersionString`
  and `CFBundleVersion` in `Resources/Info.plist`, add an entry to `CHANGELOG.md`, and tag
  the commit as `vX.Y.Z`.

## License

By contributing you agree that your contributions are licensed under the
GNU Affero General Public License v3.0, the same license as the project.
