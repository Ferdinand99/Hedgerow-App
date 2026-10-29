# Security review, October 2026

Date: 29 October 2026. Covers the Hedgerow iOS app on `main` at `914529e` (version 0.2.0, build 5): the app, the
Notification Service Extension and the `HedgerowCore` package.

## Method and limits

This was a read-only source review. It was not an external audit and it was not done by a professional security
firm. The reviewer read the code, traced each candidate finding to the lines that cause it, tried to refute it, and
rated it. Nothing was built for iOS and nothing was run on a device or a simulator: this review had no macOS. The
`HedgerowCore` tests were run on Linux (378 tests, all passing) with the changes in this branch. The app and
extension targets, the generated Xcode project, the Info.plist and the entitlements were read from `project.yml`
and the sources only; what Xcode produces from them was not inspected. Statements about iOS behaviour (Keychain
classes, ATS, file protection) are from documentation and experience, not from a test on a phone.

Treat this as one careful review, not as a guarantee.

## Scope

- Where tokens are stored and how they are shared with the extension (Keychain class, access group, backups).
- TLS and the http policy, including the ATS settings.
- The push path: payload parsing, the fetch behind a `ref`, rendering of the text, tap handling, thread identifier.
- URL handling, logging, data at rest, the privacy manifests, entitlements, dependencies and CI.
- Phase 3 (actions with Face ID): only what exists in the code.

The attackers considered: a hostile or compromised Hedgerow server (the user adds it, but its answers are untrusted
input), a network attacker on the path to a server, someone who can send pushes (the relay or Apple), and someone
who holds a locked or backed-up phone.

Held up in review: tokens only in the Keychain with `ThisDeviceOnly` and no iCloud sync; no token in
`UserDefaults`, in the connection file or in any log (the app has no `os_log`, `print` or `NSLog` call at all);
an ephemeral URL session with no cache, cookies or credential storage; one gate (`isAllowedBaseURL`) checked before
every request, with strict handling of non-canonical IP forms, userinfo and look-alike hostnames; redirects only
within the same scheme, host and port; response caps (2 MiB, 64 KiB for push); a push payload that is never acted on
beyond a registry lookup, with `tag` and `ref` limited to 64 characters of `A-Za-z0-9_-` before they reach a URL; notification
text set as plain strings after control and bidi characters are removed and length is cut; ids placed in request
paths are integers and cursors are percent-encoded; no URL scheme, Universal Link, `onOpenURL`, `openURL`, web view
or `Link` anywhere, so a server-provided URL is never opened; server text rendered with `Text(verbatim:)`; no
third-party dependency.

## Findings

No High or Medium finding. Fixes are in the pull request `fix: security review findings`.

| ID | Severity | Title | Status |
|---|---|---|---|
| HA-01 | Low-Medium | App Transport Security is switched off for the whole app | Partly fixed: TLS 1.2 floor added. Open: narrow the exception (needs a device test) |
| HA-02 | Low | A server that keeps sending slowly holds a request for days | Fixed |
| HA-03 | Low | Tokens stay in the Keychain after the app is deleted or its data is lost | Open |
| HA-04 | Low | Plain http to a LAN name is a one-line footer; the names can be spoofed on a hostile network | Accepted, with a suggestion |
| HA-05 | Low | The relay manage key sits in the access group the extension also has | Open |
| HA-06 | Low | Connection list and tag registry: default protection class, included in backups | Accepted |
| HA-07 | Low | Tokens are readable whenever the phone has been unlocked once | Accepted |
| HA-08 | Info | Privacy manifests declare no collected data although the APNs token goes to the developer's relay | Open, for the owner |
| HA-09 | Info | No app lock; phase 3 (Face ID) is not in the code, and a plan for it | n/a |
| HA-10 | Info | CI: unpinned `brew install xcodegen`; no Dependabot for the Actions | Open |
| HA-11 | Info | Lock screen and app switcher show server text | Accepted |

### What was changed

- **HA-01 (partly).** `NSAllowsArbitraryLoads` is on, which turns ATS off for every connection, https ones
  included. The reason is documented in `project.yml`: ATS cannot express the app's own list of LAN names (`.lan`,
  `.home.arpa`, `.internal`, `.ts.net`, CGNAT addresses), and `HedgerowHTTP` checks the real rule before every
  request, so no code path sends a token over http to a public host. The relay address is a fixed https URL. What ATS
  would still add is a TLS floor and forward secrecy for https connections, so `HedgerowHTTP.defaultSession` now
  sets `tlsMinimumSupportedProtocolVersion = .TLSv12` (covered by a test on macOS). Certificate errors are not
  overridden anywhere: there is no `URLSessionDelegate` that answers a server-trust challenge, so a self-signed or
  expired certificate fails the connection. There is no pinning.
- **HA-02.** The request timeout (15 seconds) only counts silence between two pieces of data. A server dripping one
  byte every 14 seconds could keep a call, and the screen waiting for it, open until the 7-day resource timeout, and
  only the Add sheet and the extension had their own deadline. `HedgerowHTTP.exchange` now gives the whole exchange
  twice its timeout (30 seconds by default) and reports a miss as `unreachable`. The extension keeps its own,
  shorter 10 second limit. A test with a transport that never answers covers it.

## Accepted and open items

- **ATS (HA-01), open.** The narrower setting is to remove `NSAllowsArbitraryLoads` and keep
  `NSAllowsLocalNetworking`, and add `NSExceptionDomains` entries with `NSIncludesSubdomains` and
  `NSExceptionAllowsInsecureHTTPLoads` for `lan`, `home.arpa`, `internal` and `ts.net`. It was not done here because
  it cannot be checked without a device: a wrong entry would stop http to those names from working, and whether iOS
  accepts a bare top-level domain as an exception key (and exempts private IP literals, including 100.64.0.0/10) should be seen
  on a phone first. The in-app gate stays in any case.
- **Tokens after reinstall (HA-03), open.** Keychain items survive deleting the app, while the connection list (which
  holds the ids that locate the tokens) is deleted with the App Group container. A token for a removed install stays in the
  Keychain with no screen that can remove it.
  "Reset connections" already clears them, but only for a damaged file. A clean-up that deletes tokens
  whose id is not in the list is simple, but it deletes secrets, so it was not added without a device to test the
  start-up cases (a background launch before the first unlock reads an empty list). If it is built, it should run
  only when the list was read from an existing file.
- **Plain http (HA-04), accepted.** A user can add `http://nas.lan` or `http://10.0.0.5`. The warning is the footer in
  the Add sheet ("Plain http is only accepted for addresses on your own network"), and after that nothing in the
  list marks the connection as unencrypted. On a hostile Wi-Fi network a name such as `nas.local` or `nas.lan` can be
  answered by someone else, and the token travels in clear text to them. This is inherent in allowing LAN http.
  Suggested: an "unencrypted" label on such connections, and a recommendation of a read-only token (already in the
  footer).
- **Relay manage key (HA-05), open.** The key (`hrm_…`) is in a Keychain item in the shared access group. The
  extension does not compile the code that reads it, but the entitlement lets any code in the extension read it. It
  can register or revoke handles of this device at the relay, not read pushes. A separate access group for the app
  only would isolate it.
- **Files (HA-06), accepted.** `connections.json` (names, URLs, product kinds, connection ids) and `push-tags.json`
  (tags, ids, no handle, no secret) are written atomically with the default protection class (complete until first
  user authentication, which the extension needs). They are included in device backups. Excluding them would also
  drop the list on a restore to a new phone, where the tokens are not restored anyway (`ThisDeviceOnly`).
  The content is an inventory of the user's servers and nothing that authenticates.
- **Keychain class (HA-07), accepted.** `AfterFirstUnlockThisDeviceOnly` is needed so the extension can read a
  token on a locked phone. The cost is that tokens are not protected by the lock screen after the first unlock;
  they are excluded from backups and other devices.
- **Privacy manifests (HA-08), open.** Both manifests declare `UserDefaults` with `CA92.1` and no collected data. The
  app sends the APNs device token to the developer's own relay (`pigeon.hedgerow.tools`) and keeps a manage key
  from it. Whether that has to be declared as a data type in the manifest and in the App Store privacy label (device
  id, not linked, not used for tracking, app functionality) is the owner's decision with the label in App Store
  Connect. No other required-reason API is used (no file timestamps, disk space or boot time calls were found).
  Third-party SDK manifests do not apply: there is no third-party SDK.
- **Phase 3 and Face ID (HA-09), no code.** There is no `LocalAuthentication` use and no screen that changes a
  server: the only writes are the push registrations (`PushRoutes`, `Pigeon`). `HedgerowHTTP.post` is public and is
  not called by the UI yet. Notes for when actions are built: a Face ID check in the UI is only an app-level gate,
  because the token itself is readable after the first unlock; for write tokens a separate Keychain item with
  `SecAccessControl` (`.userPresence`) is the stronger design, and then the extension must not need that item; the
  confirmation should show what will change, per action, with the connection name; and the app has no lock for the
  read screens today, so a phone that is unlocked shows server state.
- **CI (HA-10).** Actions are pinned by commit SHA and the workflow has `contents: read`, which is good. The macOS job
  installs XcodeGen with `brew install xcodegen`, an unpinned tool built into the job that builds the app. There is
  no `dependabot.yml`, so the pinned Action SHAs are not updated. No secrets are used in CI.
- **Lock screen (HA-11), accepted.** The extension puts server text (monitor names, error titles) in the notification
  and in the thread, and iOS shows it on the lock screen according to the user's setting. The app does not hide its
  screens in the app switcher.
- **Entitlements.** `aps-environment`, the one App Group and the one Keychain access group, for the app and for the
  extension. Nothing broader (no associated domains, no network-extension, no iCloud). The checked-in value of
  `aps-environment` is `development`; Xcode's automatic signing changes it for archives.
- **Dependencies.** `HedgerowCore` has no dependencies. The app uses only Apple frameworks.

## Not covered

- Everything that needs a build: the actual Info.plist and entitlements after XcodeGen and signing, the Keychain
  behaviour on a device, ATS behaviour, file protection classes, and the extension's memory use.
- The servers (Vigilant Vole, Keen Kestrel, Wise Wren) and the shared vole-kit, and the Postal Pigeon relay. Their
  reviews are in their own repositories.
- The website in `site/` beyond a search for dangerous patterns (none found), and the GitHub Pages deployment.
- Localisation, accessibility and visual design.
- Dynamic testing of any kind: no proxy, no fuzzing of the payload parser or the JSON decoders.

## Notes for the owner

- The behaviour changes are small: an exchange with a server now ends after 30 seconds at the latest (it could
  run longer before, with data still arriving), and https connections need TLS 1.2 or newer.
- The build number was not changed.
