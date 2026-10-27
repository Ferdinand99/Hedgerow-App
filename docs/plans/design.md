---
tags: [plan, hedgerow, ios, hedgerow-app]
status: avklart – plan neste
dato: 2026-10-27
---

# 📱 Design – Hedgerow-appen


## 🎯 Hva og hvorfor

En native app for **iOS og Android**, **Hedgerow**, der du ser og styrer alle dine Hedgerow-servere fra mobilen: er noe nede (VV), har det kommet nye feil eller krasj (KK), og venter det oppdateringer du kan godkjenne (Wren). I stedet for tre nettsider i Safari får du **én oversikt** og varsler som lenker rett til riktig sted.

**Mål**
- Én **Oversikt**-skjerm som svarer på «er alt i orden?» på ett sekund.
- De vanligste handlingene uten å åpne nettsiden: godkjenne en oppdatering, sette en monitor på pause, løse en feil.
- Fungerer med **hvem som helst sin** selvhostede VV/KK/Wren (ikke bare eierens), så den kan ligge i App Store.
- Trygg: tokens i nøkkelringen, skrivehandlinger bekreftes med Face ID.

**Ikke-mål (v1)**
- Ikke en full kopi av webgrensesnittene (oppsett, brukere, kanaler, innstillinger blir på nettsiden).
- Ingen egen server eller konto hos Hedgerow – appen snakker bare med brukerens egne servere.
- Ikke Nimble Newt (skrivebordsapp) og ikke Faithful Ferret (egen app).

**Anti-mål (feil selv om det virker)**
- Appen lagrer eller sender data om brukerens servere noe annet sted enn til serverne selv.
- En mistet telefon gir noen skrivetilgang uten Face ID.

---

## 🧭 Skjermer (v1)

| Fane | Innhold | Handlinger |
| --- | --- | --- |
| **Oversikt** | Én kort per tilkoblet tjeneste: VV (antall nede/oppe, aktive hendelser), KK (nye/uløste feil siste 24 t, crash-free per prosjekt), Wren (ventende oppdateringer, kjøringer pågår/feilet). Rødt/gult/grønt øverst. | Trykk → riktig fane |
| **Monitorer** (VV) | Liste med status og responstid, grupper som i VV, søk. Monitor-detalj: graf, siste hendelser. | Pause/fortsett, start vedlikehold |
| **Feil** (KK) | Prosjekter (med prosjektgrupper), saker sortert etter siste/antall. Sak-detalj: siste event med stack, tagger, releaser. | Løs, ignorer |
| **Oppdateringer** (Wren) | Servere → targets med ny versjon, planlagte og siste kjøringer med steg. | Godkjenn, planlegg, avbryt, rull tilbake |
| **Innstillinger** | Tilkoblinger (legg til/fjern), Face ID-krav, varsler, om appen. | |

**Widgets** (*Claudes valg*, v1): en liten «alt i orden?»-widget og en medium med de tre tjenestene.

---

## 🔌 Tilkobling og sikkerhet

- **Legg til en tjeneste:** adresse + API-token. Enklest via **QR-kode** fra nettsiden (se «Endringer på serverne»), ellers lim inn.
- Appen sjekker selv hvilken app adressen er (VV/KK/Wren) og hvilken rolle tokenet har.
- **Tokens i nøkkelringen** (kun denne enheten, `ThisDeviceOnly`), aldri i iCloud-backup.
- **Lesetoken anbefales** som standard. Med skrivetoken kreves **Face ID/Touch ID** før hver skrivehandling (*Claudes valg*).
- Bare **https** (unntak: lokale adresser på LAN, som Wren-agenten).
- Ingen tredjeparts-SDK-er som ser serverdata. Appens egen bruksstatistikk/krasj går til **eierens** Keen Kestrel via KestrelKit/sentry-cocoa – **av/på i innstillinger**, og sender aldri serverinnhold.

---

## 🔔 Varsler

| Fase | Hvordan | Merknad |
| --- | --- | --- |
| **v1** | Appen henter status når den åpnes, ved «dra for å oppdatere», og i bakgrunnen (iOS Background App Refresh, ca. hvert 15.–30. minutt etter iOS sitt skjønn). Lokale varsler ved endringer. | Ingen server nødvendig, men ikke umiddelbart |
| **v2** | **Push**: iOS via et felles **Hedgerow push-relé** (APNs) på eierens VPS – samme relé som Faithful Ferret skal bruke; Android via **UnifiedPush** (f.eks. ntfy), uten Google Play-tjenester. VV/KK/Wren sender «noe skjedde»-signal til reléet, som varsler appen. | Krever en liten endring i hver app + reléet. Innholdet i varselet er bare «sjekk appen» eller en kort tittel, aldri hemmeligheter |

---

## 🛠️ Endringer på serverne (små, i vole-kit + hver app)

1. **«Koble til Hedgerow-appen»** på token-siden: lager et token med valgt rolle og utløp, og viser en **QR-kode** (adresse + token) som appen skanner. *Claudes valg:* ligger i vole-kit, så alle tre får den samtidig.
2. **Et lite «status»-endepunkt** per app som svarer med akkurat det Oversikt trenger i ett kall (kan bygges på dagens API v1 om det er raskt nok – avgjøres i planen).
3. (v2) Push-registrering og signal til reléet.

---

## 🧰 Teknisk

| | |
| --- | --- |
| **Plattform** | iPhone og iPad, **iOS 18+**, og **Android 10+** (*Claudes valg*). macOS-utgave senere. |
| **Android** (eier) | APK lastes ned fra **GitHub Releases** (ikke Google Play), og appen **oppdaterer seg selv**: sjekker siste release, laster ned APK, sjekker signatur og sjekksum, og ber brukeren bekrefte installasjonen. Signeringsnøkkelen er den viktigste hemmeligheten – lagres offline og i GitHub-environment, aldri i logger. |
| **Språk** | iOS: Swift 6, SwiftUI. Android: Kotlin, Jetpack Compose (*Claudes valg*: to native apper med samme skjermer, fordi appen er en ren API-klient med lite felles logikk). Så få avhengigheter som mulig. |
| **Data** | Mellomlagring av siste status (for widgets og rask oppstart) i appgruppen; tokens i nøkkelringen. |
| **Oversettelser** | Norsk og engelsk i v1 (*Claudes valg*); flere senere. |
| **Repo** | Nytt repo, f.eks. `Ferdinand99/Hedgerow-App` (eieren oppretter). |
| **Bygg/test** | iOS bygges på eierens Mac (Xcode) og i CI (macOS-jobb). Android bygges i Docker på LANBox og i CI; eieren tester på sin Android-telefon. |
| **Widgets** | iOS: WidgetKit. Android: Glance-widgets. |

---

## ✅ Avklart av eieren (2026-10-27)

1. **Lisens:** GNU AGPL-3.0-only med **CLA** for eksterne bidrag (som Faithful Ferret; App Store/TestFlight er greit fordi eieren eier koden).
2. **Distribusjon iOS:** **TestFlight** først (bare eieren), App Store senere.
3. **Repo:** `Ferdinand99/Hedgerow-App`.
4. **Android** er med (APK fra GitHub Releases, oppdatering i appen).

---

## 🗺️ Faser (forslag)

| # | Fase | Ferdig når |
| --- | --- | --- |
| 1 | **Grunnmur** | Legg til tilkobling (lim inn token), Oversikt med ekte data fra VV/KK/Wren |
| 2 | **Fanene** | Monitorer, Feil, Oppdateringer med lesing |
| 3 | **Handlinger** | Pause/løs/godkjenn/rull tilbake med Face ID-bekreftelse |
| 4 | **QR-tilkobling** | «Koble til Hedgerow-appen» i vole-kit, release av VV/KK/Wren |
| 5 | **Widgets + bakgrunnsoppdatering** | Lokale varsler, widgets |
| 6 | **Android-appen** | Samme skjermer i Kotlin/Compose, APK i GitHub Releases, oppdatering i appen med signaturkontroll |
| 7 | **TestFlight** (App Store senere) | Personvernetikett, ikon, skjermbilder |
| 8 | **Push (v2)** | Hedgerow push-relé (iOS) og UnifiedPush (Android), felles med Faithful Ferret |
