# Hedgerow app – leftovers from the phase 2 and push reviews

> One task. Implement, test, commit, report.

**Goal:** Fix three small things the reviews deferred. No new screens, no server changes, still read-only.

## Global Constraints

The same as phase 2 (docs/plans/phase-2-tabs.md, «Global Constraints»): no third-party dependencies, the token only in the Keychain (no hash, copy or fingerprint of it in `@State`, UserDefaults or logs), server text as `Text(verbatim:)`, en + nb in the String Catalog with plurals.

---

### Task 1: Three leftovers

**1. Updates tab: sort by the server's mode** (`Hedgerow/UpdatesView.swift`, with the sorting logic in HedgerowCore so it is tested on Linux).
- Today every target with an update lands under «Venter på godkjenning» / "Waiting for approval", because `/updates` carries no mode.
- The tab already loads `/servers` (`WrenServer.mode`: approve, notify, auto). Join each target to its server by `serverId`.
- Sections, each shown only when it has rows, in this order:
  - «Venter på godkjenning» / "Waiting for approval": the server mode is `approve`.
  - «Oppdateres automatisk» / "Updates automatically": the mode is `auto`. Show the server's auto window in the footer if it is known.
  - «Tilgjengelige oppdateringer» / "Available updates": the mode is `notify`, or the server or its mode is unknown, including when `/servers` failed and fell back to empty.
- Keep the existing first-10 and "Show all N" behaviour per section. Add the section headers with counts to the catalog, with en and nb plurals.
- Test it in core: a mix of the three modes, an unknown server id, and an empty servers list (everything lands in "Available").

**2. Issues: stop the project counts when the screen goes away** (`Hedgerow/IssuesView.swift`, `IssueProjectsModel.countsTask`).
- Cancel `countsTask` when the project list disappears (`onDisappear`) and when the model is replaced (connection switch).
- When the screen appears again with fresh data and the counts are incomplete, start them again. Check that the existing `ticket.isCurrent` and `!Task.isCancelled` guards still hold.

**3. Token sheet: reload only when the token changed** (`Hedgerow/OverviewView.swift` and `Hedgerow/RootTabView.swift:116-130`).
- RootTabView compares `token.hashValue` kept in `@State`. The review asked for a cleaner way: give `ConnectionStore` (or the app model) a token-change counter, bumped whenever a token is saved or removed, and compare that counter before and after the sheet.
- Use the counter in both RootTabView and Overview's own token sheet. Overview reloads today on every dismissal, Cancel included.
- Remove the hash from `@State`. Add a core test that the counter changes on save and on remove, and does not change on a read.

**Verify:**
- `swift test` passes for HedgerowCore in swift:6.2 on LANBox.
- `swiftc -parse` passes on the changed app files.
- Push the branch `fix/review-leftovers` and get CI green.
- Commit `fix: updates sorted by server mode, cancelled project counts, token sheet reloads only on change` (or two or three conventional commits).
