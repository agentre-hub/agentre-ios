# agentre-ios

This is the native iOS client for Agentre: SwiftUI and `@Observable`, Swift 6 language mode, iOS 26.0 deployment target.
The design is in [`docs/specs/2026-09-18-agentre-ios-scaffold.md`](docs/specs/2026-09-18-agentre-ios-scaffold.md).

## Setup

You need Xcode 27 with an iOS 27 simulator runtime, plus `xcodegen`.

```bash
git submodule update --init      # Vendor/agentre: the pinned wire protocol (AgentreWire)
xcodegen generate                # Agentre.xcodeproj is generated from project.yml and is not committed
```

No Apple team is configured (`DEVELOPMENT_TEAM` is left unset), so builds and tests target the iOS Simulator.

## Full test suite

This single command runs every test in the repository: all package test targets plus the app-hosted Keychain tests.

```bash
rm -rf /tmp/agentre-dd && git submodule update --init && xcodegen generate && xcodebuild test -project Agentre.xcodeproj -scheme Agentre -derivedDataPath /tmp/agentre-dd -destination 'platform=iOS Simulator,name=iPhone 17' -collect-test-diagnostics never DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR
```

- `-derivedDataPath` points at a directory the command has just deleted, so every run builds from scratch.
  Reusing a build directory has been observed not to pick up newly added `.xcstrings` files, which gives false reds and can just as well give false greens.

- `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` makes importing a module that `Package.swift` does not declare a build error.
  Without it, an incremental Xcode build can quietly resolve an undeclared module that happens to be built already.
- `-collect-test-diagnostics never` matters because, on a test failure, xcodebuild otherwise runs `simctl diagnose` for up to ten minutes before exiting.

## Layout

All the code lives in the local package `AgentreKit` (`Package.swift`). The app target (`Sources/AgentreApp`) only assembles it.

| Module | Depends on | Holds |
|---|---|---|
| `AgentreDomain` | — | models, observable state, repository and port **protocols** |
| `AgentreDesign` | — | colour tokens (light + dark), `Button.hitTarget()` |
| `AgentreREST` | Domain | agentre-server HTTP clients |
| `AgentreRelay` | Domain, AgentreWire | relay client |
| `AgentreStore` | Domain, AgentreWire | Keychain, local persistence |
| `AgentreUI` | Domain, Design | screens, one directory per feature |
| `AgentreTestSupport` | Domain, Design | shared test helpers (fake HTTP, hit-target assertion); only test targets use it |

`Package.swift` and `project.yml` are frozen. A feature writes only inside its own directories.

## Conventions

- **Strings**: each feature keeps its own table at `Sources/AgentreUI/<Feature>/<Feature>.xcstrings`, with `en` and `zh-Hans`.
  SwiftPM picks up a new table without any manifest change.
  Reference strings as `Text("key", tableName: "<Feature>", bundle: .module)`.
  Never build a sentence by concatenating strings.
- **Colour**: always use `.token(.name)` (or `ColorToken.name.uiColor` in UIKit). No literal or system colours in view code.
- **Tap targets**: every tappable `Button` gets `.hitTarget()`, which makes its hit region at least 44×44pt.
  Per-screen tests call `assertHitTargets(_:)` from `AgentreTestSupport`, which also fails when two tap targets overlap.
- **Servers**: the default is `https://app.agentrehub.com`.
  The plaintext-HTTP and local-network exception for the dev server (`http://docker.local:8443`) exists only in Debug builds (`Sources/AgentreApp/Debug-Info.plist`).
