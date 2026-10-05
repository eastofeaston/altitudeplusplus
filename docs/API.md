# How Altitude+ works

Notes for building an Altitude+ client on any platform. Everything here comes from the public altitudeplus.com web client and was confirmed against a subscribed account in October 2026. `tools/probe.py` makes these calls from any computer with Python 3, so you can check them before writing app code.

Altitude+ runs on the ViewLift platform with Axinom DRM.

## Basics

- **REST and GraphQL base:** `https://altitude.api.viewlift.com` (GraphQL at `/graphql`)
- **Site:** `altitude`
- **API key:** every request sends `x-api-key: WX41iaJiOw7hJW8sNbDP5JpVwmjaH6t6y3xbQUsc`, the public key the website uses (`window.xApiKey`).
- **Auth:** send the raw JWT in `Authorization` with no `Bearer` prefix. Before sign-in, use an anonymous token.
- **24/7 channel:** content ID `a6967d3f-2501-47f1-a7db-92faf7f6872f`, channel ID `de0a3981-03fa-4104-bf95-87735ebe4a8a`. If these change, they're in the `/live-24x7` page data on altitudeplus.com (`window.page_data`).

## Device identity

ViewLift identifies the client in three places, and they don't all accept the same values:

| Where | Apple TV | Android TV / Fire TV | Web |
|---|---|---|---|
| GraphQL `EntitlementDevice` (sign-in, refresh, `platform`) | `ios_apple_tv` | `fire_tv` | `web_browser` |
| GraphQL `Device` (page layouts) | `APPLETV` | `FIRETV` | `WEB` |
| REST `deviceType` / `contentConsumption` | `ios_apple_tv` / `appleTv` | `fire_tv` / `fireTv` | `web_browser` / `web` |

There is no Android TV identity. `android_tv` isn't a valid `EntitlementDevice`, and Altitude has no `ANDROIDTV` page layout (that query returns `NoSuchKey`). Android-based clients should present as Fire TV, which works for sign-in, pages, and streams.

## Sign-in (email code)

1. **Anonymous token:** `GET /identity/anonymous-token?site=altitude&platform=<device>&deviceId=<install UUID>` returns `{authorizationToken}`.
2. **Send the code:** GraphQL with the anonymous token:

   ```graphql
   mutation ($site: String!, $device: EntitlementDevice!, $input: IdentityAuthOtpInitiateInput!) {
     identityAuthOtpInitiate(site: $site, device: $device, input: $input) { key }
   }
   ```

   `input` needs `email`, `deviceName`, and **`campaign`, `campaignSource`, `campaignMedium` (empty strings are fine)**. Without the campaign fields, the code is accepted later but validation fails server-side with `Request message serialization failure … Received undefined`. The Apple TV app also sends `deviceMetadata` (manufacturer, model, OS).
3. **Verify:** `identityAuthOtpValidate(site, key, otp)` returns `authorizationToken`, `refreshToken`, `userId`, `email`, and `isSubscribed`. The email has a 6-digit code (and a magic link).
4. **Refresh:** `identityRefreshToken(site, device, refreshToken)`, with REST `GET /identity/refresh/{refreshToken}` as a fallback.

## Location

Altitude+ checks the ZIP code against its broadcast territory. Send `latitude` and `longitude` on stream requests if you have them; otherwise the server uses the request's IP address.

`GET /geolocation?latitude=…&longitude=…` returns `postalcode` (from the coordinates when given) and `lookupMode`. Without coordinates it returns the IP-based result.

## Live stream

```
GET /v3/entitlement/linearchannel?id=<content ID>&channelId=<channel ID>&deviceType=…&contentConsumption=…&ssaiDisable=false&latitude=…&longitude=…
```

- **Errors** come back in the body with `errorCode`, e.g. `SVOD_TVE_SUBSCRIPTION_NOT_FOUND` (no subscription) or geo codes containing `GEO`.
- **Streams** are at `linearchannel.streamingInfo.videoAssets`, with one entry per DRM system:
  - `fairPlay`: HLS `url`, `certificateUrl`, `licenseUrl`, `licenseToken`, `completeskd`
  - `widevine`: DASH `url` (`master.mpd`), `licenseUrl`, `licenseToken`
  - `playReady`: DASH `url`, `licenseUrl`, `licenseToken`
- **Ignore the copies under `linearchannel.channels[]`.** Each has a placeholder `videoAssets` with blank (`" "`) license URLs.
- **The license token** is `altitude|<JWT>`, valid for about 12 hours, and tied to the requesting IP and device type. Fetch it on the device that plays the stream.
- **The stream** has 6-second segments, 8 variants, key rotation (new key IDs over time, all served with the same token), and a DVR window of several hours.

## On-demand

**Rows** come from the GraphQL `page` query for `/avalanche` or `/nuggets`, with `includeContent: true`. Video rows are `CuratedTrayModule` and `GeneratedTrayModule`; each item has `gist { id title description imageGist { r16x9 } }` and, on `Video`, `runtime` and `publishDate`. Load more of a row with `modules: [<row id>]` and `next: <cursor>`. Thumbnails resize on request with `?impolicy=resize&w=640`.

**Playback:** `GET /entitlement/video/status?id=<video id>&deviceType=…&contentConsumption=…&latitude=…&longitude=…` returns streams at `video.streamingInfo.videoAssets`.

- Clips (recaps, features, news, press conferences) are **unencrypted** HLS in `hls`.
- Full game replays and postgame shows are **DRM**, with the same `fairPlay` / `widevine` / `playReady` entries as live.

## DRM

All three license URLs are ViewLift proxies in front of Axinom (`/v1/license/{fairplay,widevine,playready}/acquire`). Each takes the raw license request body with the token in an `X-AxDRM-Message` header, and returns the raw license.

- **Apple platforms (FairPlay):** download the certificate from `certificateUrl`. The content ID for the SPC is everything after `skd://` in the key URI (a `keyId:IV` pair). POST the raw SPC to `licenseUrl` with `X-AxDRM-Message: <licenseToken>` and pass the raw CKC back to AVFoundation. See `appletv/AltitudePlusPlus/Playback/FairPlayKeyDelivery.swift`.
- **Android (Widevine):** play the DASH `url` with the platform's Widevine support (Media3 ExoPlayer's DRM configuration), sending `X-AxDRM-Message: <licenseToken>` as a license request header to `licenseUrl`. Not built or tested yet.

This project doesn't bypass encryption. Protected streams are decrypted only inside the platform's DRM module, using licenses Altitude+ issues to the signed-in account, as in the official apps. Ports should keep it that way: no key extraction and no handling of decrypted video.

## Guide

The 24/7 channel's guide is public XMLTV, with no auth:

```
https://altitude-cached.api.viewlift.com/v4/content/epg/de0a3981-03fa-4104-bf95-87735ebe4a8a/tv.xml?meta=…
```

The full URL, including the `meta` parameter, is `AltitudeConfig.epgURL` in the Apple TV app. Programs have `title`, `sub-title`, `desc`, `category`, `icon`, and `sub-type` (`Sports event` for games), with `start` and `stop` in `yyyyMMddHHmmss Z`.

## Checking the API: `tools/probe.py`

```sh
python3 tools/probe.py                          # anonymous: token, location, signed-out entitlement
python3 tools/probe.py login you@example.com    # prompts for the emailed code
python3 tools/probe.py verify 123456            # finish a login started without a terminal
python3 tools/probe.py live                     # live entitlement as Apple TV
python3 tools/probe.py live --profile firetv     # ... as Fire TV (the identity for Android ports)
python3 tools/probe.py live --profile web       # ... as a web browser
python3 tools/probe.py live --dump              # full response, tokens shortened
```

`live` lists the DRM entries returned, summarizes the Widevine and FairPlay entries, checks that the FairPlay certificate downloads, and reads the HLS playlist's `KEYFORMAT`. It never requests a license. Its session is saved in `~/.config/altitudeplusplus/`; delete that folder to sign it out.
