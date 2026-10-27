<p align="center">
  <img src="site/assets/hedgerow-mark.svg" alt="Hedgerow-App" width="160">
</p>

<h1 align="center">Hedgerow-App</h1>

<p align="center"><strong>One native app for iPhone, iPad and Android that brings your self-hosted Vigilant Vole, Keen Kestrel and Wise Wren servers together. Is everything OK? Check in a second.</strong></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/status-in%20development-8fbf7f.svg" alt="Status: in development">
  <a href="https://hedgerow.tools/Hedgerow-App/"><img src="https://img.shields.io/badge/website-hedgerow.tools%2FHedgerow--App-black.svg" alt="Website"></a>
</p>

> **Status: in development, phase 1.** The work has started on the foundation: connecting to your servers and the
> Overview screen. **There is nothing to install yet, and there is no release date.**

Hedgerow-App ("Hedgerow") is a mobile app for the [Hedgerow](https://hedgerow.tools/) family of small self-hosted
apps. Instead of three web pages in a browser, you get one place that answers "is everything OK?", plus the few
actions you most often need on the go.

It works with **your own** servers, whoever runs them. There is no Hedgerow account and no cloud service in between.

## What it does

The app has an Overview and one tab for each service:

| Screen | Service | What you see | Quick actions |
|---|---|---|---|
| **Overview** | All of them | One card per connected service, with red, yellow and green at the top: monitors down, new errors, updates waiting. | Tap a card to jump to its tab. |
| **Monitors** | [Vigilant Vole](https://hedgerow.tools/Vigilant-Vole/) (uptime monitoring) | Monitors with status and response time, groups as in Vole, search, and a detail view with a chart and recent incidents. | Pause or resume a monitor, start maintenance. |
| **Issues** | [Keen Kestrel](https://hedgerow.tools/Keen-Kestrel/) (error tracking and analytics) | Projects and issues, sorted by latest or count, with the latest event, stack trace, tags and release. | Resolve or ignore an issue. |
| **Updates** | [Wise Wren](https://hedgerow.tools/Wise-Wren/) (container updates) | Servers and the targets with a newer version, scheduled and recent runs with their steps. | Approve, schedule, cancel or roll back an update. |
| **Settings** | | Connections, biometric confirmation, notifications and an About page. | |

You do not need all three services. Connect the ones you run and the app shows those.

Hedgerow is deliberately not a copy of the web interfaces. Setup, users, notification channels and other settings stay
on the websites.

## How it works

### Connections

- You add a service with its **address and an API token**. Hedgerow checks which app is behind the address and what
  the token is allowed to do.
- Later you will also be able to add a service by **scanning a QR code** from the token page on the server, which
  creates a token with the role and expiry you choose.
- The app talks to your servers over their existing **REST API v1**. Any current release of Vigilant Vole, Keen Kestrel
  or Wise Wren works.

### Security

- **Your servers only.** The app sends requests to the servers you added and nowhere else. No Hedgerow account, no
  relay of your data, and no third-party SDK that sees server data.
- **Tokens stay on the device.** They are stored in the iOS Keychain or the Android Keystore, for this device only,
  and are never included in backups.
- **Read-only tokens are recommended.** With a token that can write, every write action (pause, resolve, approve,
  roll back) is confirmed with Face ID, Touch ID or your device's biometrics first, so a lost phone cannot change
  things.
- **https only.** The exception is addresses on your local network, for example a Wise Wren agent on a LAN. Hedgerow
  does not follow redirects with your token attached.

### Notifications and widgets

- **First version:** the app refreshes when you open it, when you pull down, and in the background when the system
  allows it, and shows local notifications for changes. No extra server is needed, but it is not instant.
- **Later:** push notifications. On iOS they go through a Hedgerow push relay; on Android through
  [UnifiedPush](https://unifiedpush.org/), without Google Play services. A push only says that something happened.
  It never carries secrets.
- **Widgets:** a small "is everything OK?" widget and a medium one with the three services.

## Platforms

| Platform | Requirement | How you get it |
|---|---|---|
| **iPhone and iPad** | iOS 18 or later | TestFlight first, the App Store later. |
| **Android** | Android 10 or later | An APK from the [GitHub releases](https://github.com/Ferdinand99/Hedgerow-App/releases), not Google Play. The app can update itself: it downloads the new APK, checks its signature and asks you to confirm the install. |

The app is native on both platforms (SwiftUI on iOS, Jetpack Compose on Android) and is available in English and
Norwegian.

## Roadmap

The phases are the order of work, not cuts in scope, and there are no dates:

1. **Foundation** (now): connect a service by pasting a token, and an Overview with real data.
2. **The tabs:** Monitors, Issues and Updates, read-only.
3. **Actions:** pause, resolve, approve and roll back, confirmed with biometrics.
4. **QR connection:** "Connect the Hedgerow app" on the token page of each server.
5. **Widgets and background refresh,** with local notifications.
6. **Android:** the same screens, with APK releases and in-app updates.
7. **TestFlight,** with the App Store later.
8. **Push notifications** on iOS and Android.

## Contributing

Hedgerow-App is not open for code contributions yet. When it is, a contributor licence agreement (CLA) will be
required. Until then, issues and ideas are welcome on the
[issue tracker](https://github.com/Ferdinand99/Hedgerow-App/issues). Please report security problems privately
through GitHub's private vulnerability reporting for this repository, not in a public issue.

Hedgerow-App is part of [Hedgerow](https://hedgerow.tools/), with [Vigilant Vole](https://hedgerow.tools/Vigilant-Vole/),
[Keen Kestrel](https://hedgerow.tools/Keen-Kestrel/) and [Wise Wren](https://hedgerow.tools/Wise-Wren/). The website is
at [hedgerow.tools/Hedgerow-App](https://hedgerow.tools/Hedgerow-App/).

## License

[GNU AGPL-3.0-only](LICENSE)
