# Hedgerow app – minimal push (iOS) Implementation Plan

> **For agentic workers:** one task. Implement, test, commit, report.

**Goal:** The app can turn on notifications, register this device with Postal Pigeon (`https://pigeon.hedgerow.tools`) and show the device id, so the owner can send a test push to the owner's phone with `admin send-test`. No server (VV, KK, Wren) sends pushes yet; handles for servers come later.

**Spec:** Postal Pigeon API `E:\GitHub Repos\Hedgerow-Relay\docs\api.md` – sections "Conventions", "Devices and handles (the app)" and "What the push contains". Design background: `E:\GitHub Repos\Hedgerow-Relay\docs\design.md`.

## Global Constraints

- All phase 1–2 constraints still hold (docs/plans/phase-2-tabs.md, «Global Constraints»): no third-party dependencies, secrets only in the Keychain, en + nb in the String Catalog.
- The relay is fixed: `https://pigeon.hedgerow.tools` (one constant in HedgerowCore). https only; no redirect to another host; small response cap (64 KiB is plenty).
- `device_id` (`hrd_…`) is not secret; `manage_key` (`hrm_…`) is. Both are kept in the Keychain, **this device only, not synced** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync), separate from connection tokens. The manage key and the APNs device token are never logged, never shown, never put in UserDefaults.
- Environment: `sandbox` for `DEBUG` builds (run from Xcode), `production` otherwise (TestFlight / App Store).
- Read-only toward VV/KK/Wren – this task touches no server but the relay.

## Review Focus

1. Re-registration: APNs gives a new token, or the relay answers `404` to `PUT` (record gone) → register again (`POST`), replace the stored ids. No crash, no duplicate records piling up.
2. Turning notifications off → `DELETE /v1/devices/{id}`, then clear the Keychain items, even if the DELETE fails (offline): local state must say "off".
3. User denies the permission, or later disables it in iOS Settings → the toggle shows off with a short explanation and a button to open iOS Settings; no registration attempt.
4. Relay errors (`429` with `Retry-After`, `503`, offline) → a calm status line ("Couldn't reach the push service, will try again"), retry on next launch; no alert spam.
5. Keep-alive: `PUT` at most once a day on launch (store the last date, not a secret, in UserDefaults is fine).

---

### Task 1: Notifications on/off with Postal Pigeon registration

**Files:** Create `HedgerowCore/Sources/HedgerowCore/Clients/Pigeon.swift` (+ tests `HedgerowCore/Tests/HedgerowCoreTests/PigeonTests.swift`), `Hedgerow/PushController.swift` (app side: permission, APNs registration, app delegate glue, foreground presentation), `Hedgerow/NotificationsSection.swift` (Settings UI); Modify `project.yml` (entitlement `aps-environment: development` – Xcode's automatic signing switches it to production for archives), `Hedgerow/HedgerowApp.swift` (`@UIApplicationDelegateAdaptor`), the Settings tab view, `Hedgerow/Localizable.xcstrings`.

**Interfaces (HedgerowCore):**
- `struct PigeonRegistration: Codable, Sendable, Equatable { deviceId: String; manageKey: String }`
- `struct PigeonClient` with an injectable transport like the other clients: `register(app: "hedgerow", environment:, token: Data) async throws -> PigeonRegistration` (`POST /v1/devices`, token as lowercase hex), `update(_:token:environment:) async throws` (`PUT`, maps `404` to `PigeonError.gone`), `remove(_:) async throws` (`DELETE`, `404` counts as success).
- `enum PigeonError: Error, Equatable { gone, rateLimited(retryAfter: Int?), unavailable, invalidCredentials, unexpected }` mapped from the API's status codes / error codes.
- A small store for `PigeonRegistration` in the Keychain (this device only) plus `func needsKeepAlive(lastSent: Date?, now: Date) -> Bool` (once a day).

- [ ] **Step 1:** Tests for `PigeonClient` with a fake transport: request method/path/headers/body for each call (hex token, `Authorization: Bearer hrm_…` on PUT/DELETE, `Content-Type: application/json`, body under 2 KiB); `201` decoding; `404` on PUT → `.gone`; `404` on DELETE → success; `429` with `Retry-After` → `.rateLimited(60)`; `503` → `.unavailable`; `401` → `.invalidCredentials`; non-https base URL refused; a redirect to another host refused; `needsKeepAlive` boundaries.
- [ ] **Step 2:** Implement the core part. Reuse `HTTP.swift`'s transport/safety where it fits (it may be GET-only today – extend it carefully rather than bypassing its https / same-host / size checks).
- [ ] **Step 3:** App side. `PushController` (`@MainActor @Observable`):
  - **Toggle on:** request authorization (alert, sound, badge). If granted, call `registerForRemoteNotifications`. On `didRegisterForRemoteNotificationsWithDeviceToken`: with no stored registration, `register` and store the result. With a stored one, `update` when the token changed or a keep-alive is due. On `.gone`, register again.
  - **Toggle off:** `remove`, then clear the stored registration and call `unregisterForRemoteNotifications`.
  - **Launch:** if enabled, re-register for remote notifications. The token callback does the keep-alive.
  - **Foreground:** the `UNUserNotificationCenterDelegate` presents banner and sound.
  - **Delivery:** handle `didReceiveRemoteNotification` for `sync` pushes by calling the completion handler with `.noData`. Do nothing else yet.
- [ ] **Step 4:** Settings → section "Notifications" / "Varsler":
  - toggle;
  - status line: off / asking / registered / denied, with an "Open Settings" button / error;
  - when registered, the **device id** in monospaced text with `.textSelection(.enabled)` and a footer "Used to send a test notification from the push service." (`hrd_` is not secret).
  - Add the push texts the relay references: `HR_PUSH_TITLE` = "Hedgerow" and `HR_PUSH_BODY` = "Something needs your attention" / "Noe trenger oppmerksomheten din" to the String Catalog. These are loc-keys, so they must exist in the compiled Localizable.strings.
- [ ] **Step 5:** `swift test` (swift:6.2 on LANBox) and CI green (iOS Simulator build + core tests). Commit `feat: notifications with Postal Pigeon registration`. Push the branch `feat/push-minimal`; no PR.

**Owner's device test afterwards (for the report):**
1. Run `git pull && xcodegen generate`, then run on the phone from Xcode (sandbox).
2. Go to Settings → Varsler, turn it on, then copy the `hrd_…` id.
3. On the VPS, run `docker compose exec postal-pigeon postal-pigeon admin send-test --device hrd_…`.
