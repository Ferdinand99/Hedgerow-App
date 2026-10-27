# Hedgerow-appen – Fase 2: fanene (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** En meny nederst (TabView) med fanene Oversikt · Monitorer · Feil · Oppdateringer · Innstillinger, der hver tjeneste kan utforskes med lister og detaljer – bare lesing (handlinger kommer i fase 3).

**Architecture:** Appen får en rot-`TabView`. Hver fane har sin egen `NavigationStack`. Datahentingen ligger i HedgerowCore som nye lesemetoder på de eksisterende klientene (`VoleClient`, `KestrelClient`, `WrenClient`) med egne, tolerante modelltyper, testet på Linux med fiksturer fra de ekte API-ene. Har brukeren flere tilkoblinger av samme type, får fanen en velger øverst.

**Tech Stack:** Swift 6, SwiftUI (iOS 18), HedgerowCore, Swift Testing.

**Spec:** docs/plans/design.md (seksjonene «Skjermer» og «Tilkobling og sikkerhet»).

## Global Constraints

- Alle fra fase 1 gjelder fortsatt (docs/plans/phase-1-foundation-ios.md, «Global Constraints»): https-eller-LAN, ingen omdirigering til annen vert, maks 2 MiB per svar, token bare i nøkkelringen, ingen tredjeparts-avhengigheter, norsk + engelsk i String Catalog med flertall.
- **Bare lesing** i fase 2. Ingen knapper som endrer noe på serverne (de kommer i fase 3 med Face ID).
- Eieren ønsker **meny nederst** i stedet for hamburgermenyen (2026-10-27).
- Store installasjoner (Tower: 88 containere, mange monitorer, mange KK-saker): lister pagineres eller begrenses, og første skjerm vises på under ~2 s.
- Les svarformatene fra appenes egen API-dokumentasjon: VV `Vigilant-Vole/src/api/v1/docs.rs`, KK `Keen Kestrel/src/api.rs`, Wren `Wise-Wren/src/api.rs` (søskenrepoer i `E:\GitHub Repos\`). Tolerant dekoding: bare feltene vi bruker, ukjente felt ignoreres.

## Review Focus

1. **Flere tilkoblinger av samme type** (to VV-er) – fanen må la brukeren velge, og ikke blande data fra to servere (Task 1).
2. **Tom tilstand** – ingen tilkobling av den typen: fanen viser «Legg til Vigilant Vole» i stedet for en tom liste (Task 1).
3. **Veldig mange elementer** (500 monitorer, 2000 saker, 88 targets) – listen lastes trinnvis og henger ikke (Task 2–4).
4. **Tekst fra serveren** (monitornavn, feilmeldinger, stack traces) er data, ikke formatering: vises som ren tekst, aldri som Markdown/lenker som åpnes automatisk (Task 2–4).
5. **Tilkoblingen forsvinner eller tokenet slutter å virke mens en fane er åpen** – fanen viser samme «Tokenet virker ikke» / «Får ikke kontakt» som Oversikt, ingen krasj (Task 1–4).

---

### Task 1: Meny nederst og fane-rammeverk

**Files:** Modify `Hedgerow/HedgerowApp.swift`, `Hedgerow/OverviewView.swift`, `Hedgerow/ConnectionsView.swift`; Create `Hedgerow/RootTabView.swift`, `Hedgerow/ServicePicker.swift`, `Hedgerow/ServiceStateViews.swift`; Test: `HedgerowCore/Tests/…/ServiceSelectionTests.swift`.

**Interfaces:**
- Produces: `enum AppTab: Hashable { case overview, monitors, issues, updates, settings }`; `RootTabView` med `@State var selection: AppTab`; i HedgerowCore `func connections(of kind: ServiceKind, in store: ConnectionStore) -> [Connection]` og `struct ServiceSelection` (husker valgt tilkobling per type i UserDefaults – bare tilkoblings-ID, aldri token).
- [ ] **Step 1:** Tester for `ServiceSelection`: velger første når ingenting er valgt; husker valg; faller tilbake når valgt tilkobling fjernes (Review Focus 1).
- [ ] **Step 2:** `RootTabView` med fem faner (SF Symbols: `square.grid.2x2`, `waveform.path.ecg`, `ladybug`, `arrow.triangle.2.circlepath`, `gearshape`), norsk/engelsk etiketter. Hamburgermenyen fjernes; «Tilkoblinger» flyttes inn i Innstillinger-fanen.
- [ ] **Step 3:** Trykk på et kort i Oversikt bytter til riktig fane med riktig tilkobling valgt.
- [ ] **Step 4:** `ServicePicker` (meny øverst i fanen når det finnes mer enn én tilkobling av typen) og felles tilstandsvisninger: tom (Review Focus 2), laster, «Får ikke kontakt», «Tokenet virker ikke» med «Bytt token» (Review Focus 5).
- [ ] **Step 5:** CI grønn. Commit `feat: bottom tab bar and per-service tabs`.

### Task 2: Monitorer (Vigilant Vole)

**Files:** Create `HedgerowCore/Sources/HedgerowCore/Clients/VoleModels.swift` (+ metoder i `Vole.swift`), `Hedgerow/MonitorsView.swift`, `Hedgerow/MonitorDetailView.swift`; Test: `VoleListTests.swift` + fiksturer.

**Interfaces:**
- Produces: `VoleClient.monitors() async throws -> [VoleMonitor]` (`id, name, kind, status, group?, responseMs?, paused, inMaintenance`), `VoleClient.monitor(id:) async throws -> VoleMonitorDetail` (siste hjerteslag, oppetid 24 t/30 d, siste hendelser maks 20).
- [ ] **Step 1:** Tester med fiksturer fra VV-dokumentasjonen: liste, grupper, 500 monitorer (Review Focus 3), detalj.
- [ ] **Step 2:** Implementer klientmetodene (bruk `/api/v1/monitors`, `/monitors/{id}`, `/monitors/{id}/uptime`, `/monitors/{id}/events` – sjekk parametere i docs.rs).
- [ ] **Step 3:** `MonitorsView`: seksjoner per gruppe (som VV), nede øverst, søk, status med symbol + tekst (ikke bare farge). `MonitorDetailView`: status, responstid, oppetid, hendelser.
- [ ] **Step 4:** CI grønn. Commit `feat: monitors tab`.

### Task 3: Feil (Keen Kestrel)

**Files:** Create `Clients/KestrelModels.swift` (+ metoder i `Kestrel.swift`), `Hedgerow/IssuesView.swift`, `Hedgerow/IssueDetailView.swift`; Test: `KestrelListTests.swift` + fiksturer.

**Interfaces:**
- Produces: `KestrelClient.projects() async throws -> [KestrelProject]` (med prosjektgruppe), `KestrelClient.issues(projectId:cursor:) async throws -> (issues: [KestrelIssue], next: String?)` (uløste, nyeste først), `KestrelClient.latestEvent(projectId:issueId:) async throws -> KestrelEvent` (tittel, nivå, release, miljø, stack som rader, tagger).
- [ ] **Step 1:** Tester: prosjekter med grupper, paginering med cursor (2000 saker, Review Focus 3), siste event med stack.
- [ ] **Step 2:** Implementer (bruk `next_cursor`; sjekk parametere i KK `src/api.rs`).
- [ ] **Step 3:** `IssuesView`: prosjektgrupper → prosjekter → saker (antall, sist sett), uendelig rulling. `IssueDetailView`: sammendrag + stack som monospace ren tekst (Review Focus 4), in-app-rammer uthevet.
- [ ] **Step 4:** CI grønn. Commit `feat: issues tab`.

### Task 4: Oppdateringer (Wise Wren)

**Files:** Create `Clients/WrenModels.swift` (+ metoder i `Wren.swift`), `Hedgerow/UpdatesView.swift`, `Hedgerow/RunDetailView.swift`; Test: `WrenListTests.swift` + fiksturer.

**Interfaces:**
- Produces: `WrenClient.servers() async throws -> [WrenServer]` (navn, agent online, modus), `WrenClient.updates() async throws -> [WrenTarget]` (server, navn, nåværende → ny versjon), `WrenClient.runs(limit:) async throws -> [WrenRun]`, `WrenClient.run(id:) async throws -> WrenRunDetail` (steg med status og logg-utdrag).
- [ ] **Step 1:** Tester: servere, 88 targets (Review Focus 3), kjøringer, kjøring med steg.
- [ ] **Step 2:** Implementer (sjekk parametere i Wren `src/api.rs`).
- [ ] **Step 3:** `UpdatesView`: seksjoner «Venter på godkjenning», «Planlagt», «Siste kjøringer»; servere med agentstatus. `RunDetailView`: steg med tidslinje, logg som ren tekst (Review Focus 4).
- [ ] **Step 4:** CI grønn. Commit `feat: updates tab`.
