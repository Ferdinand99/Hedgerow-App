---
tags: [plan, hedgerow-app, ios, fase-1]
status: til gjennomgang
dato: 2026-10-27
---

# Hedgerow-appen – Fase 1: grunnmur (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** En iOS-app der man kan legge til tilkoblinger (adresse + API-token) til VV, KK og Wren, og se en ekte **Oversikt** over alle tre.

**Architecture:** SwiftUI-app + en egen Swift Package `HedgerowCore` (nettverk, modeller, nøkkelring, tjenestegjenkjenning) som kan testes med `swift test` uten simulator. Ingen avhengigheter. Hver tjeneste får en klient (`VoleClient`, `KestrelClient`, `WrenClient`) bak en felles `ServiceClient`-protokoll; Oversikt bygger kort fra `ServiceSummary`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, URLSession, Security.framework (Keychain), Swift Testing, iOS 18.

**Spec:** docs/plans/design.md

## Global Constraints

- iOS 18+, iPhone og iPad. Swift 6 språkmodus, ingen tredjeparts-avhengigheter.
- Lisens GNU AGPL-3.0-only; CLA for eksterne bidrag (ikke satt opp ennå – README sier at bidrag ikke er åpne).
- Tokens bare i nøkkelringen med `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, aldri i UserDefaults, logger eller backup.
- Bare `https`, unntatt verter på LAN (loopback, RFC1918, link-local, `.local`, `.lan`, `.home.arpa`, `.internal`, Tailscale 100.64.0.0/10 og `.ts.net`) – samme liste som Wren-agenten.
- Ingen omdirigering til en annen vert (tokenet skal aldri følge med); svar over 2 MiB avvises.
- Norsk og engelsk (String Catalog). Ingen analyse/krasjrapportering i fase 1.
- Commits: conventional commits, ingen attribusjonslinjer. Bygges på eierens Mac (Xcode) og i CI (macOS-runner); `HedgerowCore` testes også på Linux i Docker på LANBox.

## Review Focus

1. **Feil type tjeneste eller ingen Hedgerow-app på adressen** (f.eks. Pangolin-innlogging som svarer 200 med HTML) – må gi «Fant ingen Hedgerow-app her», ikke krasj eller tomt kort (Task 2).
2. **Token uten tilgang / utløpt token (401/403)** – kortet viser «Tokenet virker ikke» med knapp for å bytte token, ikke en generell feil (Task 3).
3. **En av tre tjenester er nede** – Oversikt viser de andre som normalt og den nede som «Får ikke kontakt (sist sett …)» (Task 5).
4. **Store installasjoner** (Tower: 88 containere, mange monitorer) – Oversikt laster på under ~2 s og lister ikke alt (Task 4/5).
5. **http til en offentlig adresse** – avvises med forklaring før noe sendes (Task 2).

---

## Filstruktur

```text
Hedgerow-App/
├── LICENSE (AGPL-3.0)  README.md  .gitignore
├── HedgerowCore/                       # Swift Package
│   ├── Package.swift
│   ├── Sources/HedgerowCore/
│   │   ├── Connection.swift            # Connection, ServiceKind, ConnectionStore
│   │   ├── Keychain.swift              # TokenVault
│   │   ├── HTTP.swift                  # HedgerowHTTP (https-regel, størrelsesgrense, ingen redirect)
│   │   ├── Detect.swift                # ServiceDetector (OpenAPI info.title)
│   │   ├── Summary.swift               # ServiceSummary, Health
│   │   ├── Clients/Vole.swift  Kestrel.swift  Wren.swift
│   └── Tests/HedgerowCoreTests/  (+ Fixtures/*.json)
├── Hedgerow/                           # Xcode app target
│   ├── HedgerowApp.swift  OverviewView.swift  ConnectionsView.swift  AddConnectionView.swift
│   └── Localizable.xcstrings
└── .github/workflows/ci.yml            # swift test (Linux) + xcodebuild (macOS)
```

---

### Task 1: Repo, pakke og CI

**Files:** Create `HedgerowCore/Package.swift`, `Hedgerow.xcodeproj` (app target «Hedgerow», bundle id `tools.hedgerow.app` – *Claudes valg*), `.github/workflows/ci.yml`, `README.md`, `.gitignore`.

- [ ] **Step 1:** `Package.swift` med `swift-tools-version: 6.0`, plattformer iOS 18 / macOS 15, mål `HedgerowCore` + testmål.
- [ ] **Step 2:** Xcode-prosjektet beskrives i `project.yml` (**XcodeGen**, *Claudes valg*: det kan skrives og vurderes som tekst uten Mac; `Hedgerow.xcodeproj` er gitignored og lages med `xcodegen generate`). App-målet avhenger av den lokale pakken; tom `ContentView` som viser «Hedgerow».
- [ ] **Step 3:** CI: jobb 1 `swift test` i `swift:6.2`-container på `ubuntu-latest`; jobb 2 på `macos-15`: `brew install xcodegen && xcodegen generate && xcodebuild build -scheme Hedgerow -destination 'generic/platform=iOS Simulator'`. **[eier]** På Macen: `brew install xcodegen`, deretter `xcodegen generate` før Xcode åpnes.
- [ ] **Step 4:** README: hva appen er, status «under utvikling», lisens AGPL-3.0, bidrag ikke åpne ennå (CLA kommer).
- [ ] **Step 5:** Commit `chore: scaffold app, core package and CI`.

### Task 2: HTTP-regler og tjenestegjenkjenning

**Files:** Create `HTTP.swift`, `Detect.swift`, `Connection.swift`; Test `HTTPTests.swift`, `DetectTests.swift`, fixtures `openapi-vole.json`, `openapi-kestrel.json`, `openapi-wren.json`, `pangolin-login.html`.

**Interfaces:**
- Produces:
  - `enum ServiceKind: String, Codable, Sendable { case vole, kestrel, wren }`
  - `struct Connection: Codable, Identifiable, Sendable { let id: UUID; var name: String; var baseURL: URL; var kind: ServiceKind }`
  - `func isAllowedBaseURL(_ url: URL) -> Bool` (https, eller http til LAN-vert etter lista i Global Constraints)
  - `struct HedgerowHTTP: Sendable { init(token: String?, session: URLSession = .shared); func get<T: Decodable>(_ path: String, from base: URL) async throws -> T; func post(_ path: String, to base: URL, body: Data?) async throws -> Data }` – `Authorization: Bearer`, maks 2 MiB, avviser redirect til annen vert, kaster `HedgerowError`
  - `enum HedgerowError: Error, Equatable { case notHedgerow, unauthorized, forbidden, unreachable(String), badResponse(Int), tooLarge, insecureURL }`
  - `struct ServiceDetector { func detect(_ base: URL) async throws -> ServiceKind }` – leser `GET /api/v1/openapi.json`, `info.title` = «Vigilant Vole» / «Keen Kestrel» / «Wise Wren»; HTML eller annen tittel → `.notHedgerow`

- [ ] **Step 1: Feilende tester:**
  - `allowsHttpsAndLanHttpOnly`: `https://vole.example.com` ✓, `http://10.0.3.26:3001` ✓, `http://wren.ts.net` ✓, `http://100.100.1.1` ✓, `http://vole.example.com` ✗, `http://100.128.0.1` ✗.
  - `detectsEachProduct`: hver OpenAPI-fikstur gir riktig `ServiceKind`.
  - `htmlLoginPageIsNotHedgerow`: `pangolin-login.html` med status 200 → `.notHedgerow` (Review Focus 1).
  - `mapsStatusCodes`: 401 → `.unauthorized`, 403 → `.forbidden`, 502 → `.badResponse(502)`.
  - `refusesBodiesOver2MiB` og `refusesCrossHostRedirect` (med `URLProtocol`-stub; Apple-only test merkes `#if canImport(Darwin)`).
- [ ] **Step 2:** Kjør `swift test` → FAIL.
- [ ] **Step 3:** Implementer. Redirect-avvisning via `URLSessionTaskDelegate` (`willPerformHTTPRedirection` → `nil` hvis annen vert).
- [ ] **Step 4:** `swift test` → PASS. **Step 5:** Commit `feat(core): HTTP rules and service detection`.

### Task 3: Tilkoblinger og nøkkelring

**Files:** Create `Keychain.swift`, utvid `Connection.swift` med `ConnectionStore`; Test `ConnectionStoreTests.swift`.

**Interfaces:**
- Consumes: `Connection`, `ServiceDetector`, `isAllowedBaseURL` (Task 2)
- Produces:
  - `protocol TokenVault: Sendable { func save(_ token: String, for id: UUID) throws; func token(for id: UUID) throws -> String?; func delete(for id: UUID) throws }` med `KeychainVault` (Security.framework, `ThisDeviceOnly`) og `InMemoryVault` (tester/Linux)
  - `@MainActor final class ConnectionStore: ObservableObject { var connections: [Connection]; func add(url: URL, token: String, name: String?) async throws -> Connection; func remove(_ id: UUID) throws; func replaceToken(_ id: UUID, token: String) throws }` – lagrer `[Connection]` (uten token) som JSON i app-gruppens container
- [ ] **Step 1: Feilende tester:** `addDetectsKindAndStoresTokenSeparately` (token ligger bare i vault, ikke i JSON-fila), `removeDeletesToken`, `addRefusesInsecureURL` (Review Focus 5), `addRejectsUnauthorizedToken` (detect OK, men et viewer-kall gir 401 → `.unauthorized`, ingenting lagres; Review Focus 2).
- [ ] **Step 2–4:** FAIL → implementer → PASS.
- [ ] **Step 5:** Commit `feat(core): connections stored with tokens in the keychain`.

### Task 4: Klienter og sammendrag per tjeneste

**Files:** Create `Summary.swift`, `Clients/Vole.swift`, `Clients/Kestrel.swift`, `Clients/Wren.swift`; Test `SummaryTests.swift` + fixtures fra de ekte API-ene (hent eksempelsvar fra hver app sin `/api-docs`/OpenAPI-eksempler).

**Interfaces:**
- Consumes: `HedgerowHTTP` (Task 2)
- Produces:
  - `enum Health: Sendable { case ok, warning, critical, unknown }`
  - `struct ServiceSummary: Sendable { let kind: ServiceKind; let health: Health; let headline: String; let details: [String]; let fetchedAt: Date }`
  - `protocol ServiceClient: Sendable { func summary() async throws -> ServiceSummary }`
  - `VoleClient`: `GET /api/v1/monitors` → antall nede/oppe/på pause; `critical` hvis noen er nede.
  - `KestrelClient`: `GET /api/v1/projects`, så `GET /api/v1/projects/{id}/issues?query=is:unresolved&per_page=1` per prosjekt (maks 20 prosjekter) → uløste saker og nye siste 24 t; `warning` ved nye.
  - `WrenClient`: `GET /api/v1/updates` + `GET /api/v1/runs?limit=10` → ventende oppdateringer, kjøringer som pågår/feilet; `warning` ved ventende, `critical` ved feilet siste døgn.
  - Les eksakt svarformat i hver app sin API-dokumentasjon (VV `src/api/v1/docs.rs`, KK `src/api.rs`, Wren `src/api.rs`) og bruk eksemplene som fikstur.
- [ ] **Step 1: Feilende tester:** én per klient med fikstur → forventet `health` og `headline` (f.eks. VV: 2 av 40 nede → `.critical`, «2 nede»); `largeInventoryIsSummarised` (500 monitorer / 88 targets → `details` maks 5 linjer; Review Focus 4).
- [ ] **Step 2–4:** FAIL → implementer → PASS. **Step 5:** Commit `feat(core): summaries for Vole, Kestrel and Wren`.

### Task 5: Oversikt og «Legg til» i appen

**Files:** Create `OverviewView.swift`, `ConnectionsView.swift`, `AddConnectionView.swift`, `Localizable.xcstrings`; Modify `HedgerowApp.swift`.

**Interfaces:**
- Consumes: `ConnectionStore` (Task 3), `ServiceClient`/`ServiceSummary` (Task 4)
- Produces: `OverviewModel` (`@MainActor @Observable`) med `refresh() async`, som henter alle sammendrag parallelt (`TaskGroup`) med 10 s timeout per tjeneste.

- [ ] **Step 1:** Oversikt: ett kort per tilkobling med farge etter `health`, overskrift og detaljer; «dra for å oppdatere»; tom tilstand med «Legg til en tjeneste».
- [ ] **Step 2:** En nede tjeneste viser «Får ikke kontakt (sist sett …)» og påvirker ikke de andre (Review Focus 3); 401/403 viser «Tokenet virker ikke» + «Bytt token».
- [ ] **Step 3:** Legg til: felt for adresse, token (SecureField) og valgfritt navn; «Koble til» kjører `ConnectionStore.add`; feil vises på norsk/engelsk.
- [ ] **Step 4:** Tilkoblinger: liste, sveip for å fjerne (fjerner token).
- [ ] **Step 5:** Bygg i CI (macOS) grønt. **[eier]** Kjør i simulator eller på iPhone mot egne VV/KK/Wren med et **lesetoken**, sjekk Review Focus 1–5 for hånd.
- [ ] **Step 6:** Commit `feat: overview and connections`. Første TestFlight-bygg er fase 7, ikke her.

---

**Neste faser** (egen plan hver): 2 fanene, 3 handlinger med Face ID, 4 QR-tilkobling i vole-kit, 5 widgets og bakgrunnsoppdatering, 6 Android, 7 TestFlight, 8 push.
