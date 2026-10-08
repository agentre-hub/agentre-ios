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

This single command runs every test in the repository: all package test targets, the app-hosted Keychain tests, and the mainline UI flow (`AgentreUITests`, below).

```bash
rm -rf /tmp/agentre-dd && git submodule update --init && xcodegen generate && xcodebuild test -project Agentre.xcodeproj -scheme Agentre -derivedDataPath /tmp/agentre-dd -destination 'platform=iOS Simulator,name=iPhone 17' -collect-test-diagnostics never DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR
```

- `-derivedDataPath` points at a directory the command has just deleted, so every run builds from scratch.
  Reusing a build directory has been observed not to pick up newly added `.xcstrings` files, which gives false reds and can just as well give false greens.

- `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` makes importing a module that `Package.swift` does not declare a build error.
  Without it, an incremental Xcode build can quietly resolve an undeclared module that happens to be built already.
- `-collect-test-diagnostics never` matters because, on a test failure, xcodebuild otherwise runs `simctl diagnose` for up to ten minutes before exiting.

CI (`.github/workflows/test.yml`) runs this command in two halves on GitHub's `xcode-27` runner:
the `unit` job (`-skip-testing:AgentreUITests`, about 6 minutes) on every pull request and every push to `main`,
and the `ui` job (`-only-testing:AgentreUITests`, about 23 minutes) only on pushes to `main` and on manual runs (`gh workflow run test --ref <branch>`).
The runner's simulator is set to English (United States), so a test that passes on a Chinese-language Mac can still fail there.

## Mainline UI flow (`AgentreUITests`)

An XCUITest target drives the real Debug build of the app against a fake agentre-server and a fake relay that the test process itself serves on `127.0.0.1`, on a port the system picks.
Nothing leaves the Mac: no network, account or real machine is needed, and runs are repeatable.

- The fake answers the REST endpoints the app calls (device flow, account, devices and revoke, workspace, engine catalog) and `/v1/relay/client` as a real WebSocket: envelopes, per-channel `auth.account` handshake, and a fake agentred on a `machine:` channel.
  The fake agentred copies agentred where the app depends on it: `runtime.setPermissionMode` with no running turn answers "no active turn", and every `runtime.run` records its `permission_mode`.
  An endpoint or wire method the fake does not know fails the test.
- The app is pointed at the fake server by a launch argument (`-serverAddress <url>`, read through the UserDefaults argument domain).
- The flow, each step asserted on screen: the login screen shows that server address → sign in by device flow (the browser opening the verification page is the approval) → choose the appearance on the Me page → Machines → machine detail, save a conversation to the phone → it is in Messages → new conversation, send → the approval card's three buttons sit in one right-aligned row → Allow Once → switch the permission mode between turns and send again (the next `runtime.run` carries it) → go to the background while the machine finishes the turn and the relay drops the channels and the connection → back in the foreground the open conversation shows the reply and the just-sent message → revoke this device → login screen.
- It runs four times: Simplified Chinese and English (launch arguments `-AppleLanguages` / `-AppleLocale`) × light and dark (the app's own appearance setting).
  The launch arguments `-displayLanguage system -displayAppearance system` reset the in-app language and appearance, which earlier manual runs may have saved on the simulator and which would otherwise override `-AppleLanguages`.
- On-screen copy is read from the app's own string catalogs, which `project.yml` compiles into the test bundle.

Run it alone (about two minutes per combination):

```bash
rm -rf /tmp/agentre-dd && xcodegen generate && xcodebuild test -project Agentre.xcodeproj -scheme Agentre -derivedDataPath /tmp/agentre-dd -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AgentreUITests -resultBundlePath /tmp/agentre-ui.xcresult -collect-test-diagnostics never DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR
```

Add `-only-testing:AgentreUITests/MainlineUITests/testMainlineEnglishDark` (or another combination) to run one combination.
Every step leaves a screenshot, named `<language>-<appearance> <step>`, as an attachment in the result bundle; a failing step also attaches the accessibility tree.
Without `-resultBundlePath` (as in the full-suite command) the result bundle lands in `<derivedDataPath>/Logs/Test/`.
Export them with:

```bash
xcrun xcresulttool export attachments --path /tmp/agentre-ui.xcresult --output-path /tmp/agentre-ui-shots
```

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
