# Apple TV development

Everything here is relative to the `appletv` folder.

## Project layout

```
AltitudePlusPlus/           the tvOS app (SwiftUI)
  App/                      entry point, AppModel (app state, starting playback)
  Auth/                     email-code sign-in, token refresh, Keychain storage
  Config/                   AltitudeConfig: site name, public API key, channel IDs
  Guide/                    XMLTV guide parsing (Now / Up Next)
  Location/                 Core Location and Altitude's geolocation lookup
  Networking/               ViewLift REST and GraphQL client, loose JSON type
  OnDemand/                 team page rows and paging
  Playback/                 entitlement → stream, FairPlay key delivery, player session
  Views/                    screens
  Resources/                Info.plist, asset catalog (icon, Top Shelf)
AltitudePlusPlusUITests/    remote-control focus tests
Config/                     Signing.xcconfig, plus your git-ignored Local.xcconfig
tools/                      install-tv.sh (installer)
docs/screenshots/           README screenshots
project.yml                 XcodeGen project definition
```

The Xcode project is generated and not committed. Run `xcodegen generate` after pulling, or after adding or removing files.

## Signing

`project.yml` reads the team and bundle ID from `Config/Signing.xcconfig`, which includes `Config/Local.xcconfig` if it exists. `tools/install-tv.sh` writes that file on first run:

```
DEVELOPMENT_TEAM = ABCDE12345
APP_BUNDLE_ID = com.altitudeplusplus.tv.abcde12345
```

Bundle IDs are unique across every Apple account, so each team gets its own. Create the file by hand to build from Xcode without the script. Don't set `DEVELOPMENT_TEAM` or `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, because target settings there override the xcconfig.

## How it talks to Altitude+

The API (sign-in, location, streams, DRM, guide) is documented for every platform in [docs/API.md](../docs/API.md). In this app:

- `AltitudePlusPlus/Config/AltitudeConfig.swift`: site, API key, channel IDs, guide URL, device identity
- `AltitudePlusPlus/Auth/AuthService.swift`: email-code sign-in and token refresh
- `AltitudePlusPlus/Playback/StreamResolver.swift`: live and on-demand entitlement requests, and picking the FairPlay or plain HLS stream
- `AltitudePlusPlus/Playback/FairPlayKeyDelivery.swift`: the certificate, SPC, and CKC exchange
- `AltitudePlusPlus/OnDemand/OnDemandStore.swift`: team page rows and paging

## Simulator and debug options

FairPlay doesn't work in the Simulator. The app checks for this before starting FairPlay content (creating a FairPlay session there aborts the app) and shows a message. Unencrypted clips play normally.

Debug builds accept these launch arguments (Product → Scheme → Edit Scheme → Arguments):

- `-previewHome`: skip sign-in so the screens can be laid out without an account.
- `-tab avalanche` / `-tab nuggets` / `-tab settings`: open on that tab.
- `-playVideo <videoId>`: start an on-demand video instead of the live channel (needs a signed-in session).
- `-previewError` (with `-previewHome`): show a sample playback error on the Live tab.
- `-favoriteTeam nuggets`: override the saved team order for one launch (standard UserDefaults argument).

## UI tests

`AltitudePlusPlusUITests` drives the remote and checks focus: Watch Live ↔ tab bar (including on a page taller than the screen), team rows ↔ tab bar, the bottom of Settings ↔ tab bar, and the team order setting. The tests use `-previewHome`, so they need no account.

```sh
xcodegen generate
xcodebuild test -scheme AltitudePlusPlus -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

With the Xcode 27 beta, `xcodebuild test` can sit for about 10 minutes after the tests finish before it exits. The results are already in the log by then.

A recurring tvOS issue these tests cover: the tab bar only comes back when a scroll view is at its very top. If nothing above the first focusable item can take focus, returning to it can leave the page part-scrolled and the tabs unreachable. The Live tab, Settings, and Diagnostics scroll to the top when their first focusable item gains focus.

## Checking the API

`../tools/probe.py` makes the same calls as the app from a Mac, which is quicker than deploying when something changes upstream. See [docs/API.md](../docs/API.md#checking-the-api-toolsprobepy).
