#!/usr/bin/env python3
"""Exercise the Altitude+ API calls the tvOS app makes, from a Mac.

    python3 tools/probe.py                  # anonymous checks: token, location, guide
    python3 tools/probe.py login EMAIL      # email OTP sign-in (same flow as the app)
    python3 tools/probe.py verify CODE      # finish a login started without a terminal
    python3 tools/probe.py live [--profile appletv|firetv|web]
                                            # live channel entitlement, redacted

Tokens are saved to ~/.config/altitudeplusplus/probe-session.json (mode 600).
Output shortens tokens so it is safe to paste into a chat or issue.
Standard library only.
"""

import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SITE = "altitude"
API = "https://altitude.api.viewlift.com"
API_KEY = "WX41iaJiOw7hJW8sNbDP5JpVwmjaH6t6y3xbQUsc"
LIVE_ID = "a6967d3f-2501-47f1-a7db-92faf7f6872f"
CHANNEL_ID = "de0a3981-03fa-4104-bf95-87735ebe4a8a"
SESSION_PATH = os.path.expanduser("~/.config/altitudeplusplus/probe-session.json")
PENDING_PATH = os.path.expanduser("~/.config/altitudeplusplus/probe-pending.json")
DEVICE_ID_PATH = os.path.expanduser("~/.config/altitudeplusplus/probe-device-id")
PROFILES = {
    "appletv": ("ios_apple_tv", "appleTv"),
    # Altitude+ has no Android TV identity in GraphQL or page layouts; Android
    # devices (including Android TV ports) should present as Fire TV.
    "firetv": ("fire_tv", "fireTv"),
    "web": ("web_browser", "web"),
}
SECRET_KEYS = {"licenseToken", "authorizationToken", "refreshToken", "token"}


def request(method, path, token=None, query=None, body=None, raw=False):
    url = path if path.startswith("http") else API + path
    if query:
        url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
    headers = {"x-api-key": API_KEY, "Accept": "application/json"}
    if token:
        headers["Authorization"] = token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = resp.read()
            status = resp.status
    except urllib.error.HTTPError as err:
        payload = err.read()
        status = err.code
    if raw:
        return status, payload
    try:
        return status, json.loads(payload or b"null")
    except ValueError:
        return status, payload.decode(errors="replace")


def graphql(query, variables, token):
    status, body = request("POST", "/graphql", token=token, body={"query": query, "variables": variables})
    if isinstance(body, dict) and body.get("errors"):
        err = body["errors"][0]
        code = (err.get("extensions") or {}).get("code")
        sys.exit(f"GraphQL error ({code}): {err.get('message')}")
    return body["data"]


def device_id():
    try:
        with open(DEVICE_ID_PATH) as fh:
            return fh.read().strip()
    except FileNotFoundError:
        import uuid
        value = str(uuid.uuid4())
        os.makedirs(os.path.dirname(DEVICE_ID_PATH), exist_ok=True)
        with open(DEVICE_ID_PATH, "w") as fh:
            fh.write(value)
        return value


def anonymous_token(profile="appletv"):
    status, body = request("GET", "/identity/anonymous-token",
                           query={"site": SITE, "platform": PROFILES[profile][0], "deviceId": device_id()})
    if status != 200:
        sys.exit(f"anonymous-token failed: HTTP {status} {body}")
    return body["authorizationToken"]


def jwt_payload(token):
    part = token.split(".")[1]
    part += "=" * (-len(part) % 4)
    return json.loads(base64.urlsafe_b64decode(part))


def redact(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key in SECRET_KEYS and isinstance(item, str):
                out[key] = f"{item[:8]}…({len(item)} chars)"
            elif key == "plans":
                out[key] = "<omitted>"
            else:
                out[key] = redact(item)
        return out
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def find(value, key):
    if isinstance(value, dict):
        if value.get(key) is not None:
            return value[key]
        for item in value.values():
            hit = find(item, key)
            if hit is not None:
                return hit
    elif isinstance(value, list):
        for item in value:
            hit = find(item, key)
            if hit is not None:
                return hit
    return None


def load_session():
    try:
        with open(SESSION_PATH) as fh:
            return json.load(fh)
    except FileNotFoundError:
        sys.exit("Not signed in. Run: python3 tools/probe.py login you@example.com")


def write_private(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(value, fh)


def save_session(session):
    write_private(SESSION_PATH, session)


def user_token(profile):
    session = load_session()
    if jwt_payload(session["authorizationToken"]).get("exp", 0) - time.time() > 300:
        return session["authorizationToken"]
    data = graphql(
        "mutation ($site: String!, $device: EntitlementDevice!, $refreshToken: String!) {"
        " identityRefreshToken(site: $site, device: $device, refreshToken: $refreshToken)"
        " { authorizationToken refreshToken } }",
        {"site": SITE, "device": PROFILES[profile][0], "refreshToken": session["refreshToken"]},
        session["authorizationToken"],
    )["identityRefreshToken"]
    session.update(data)
    save_session(session)
    print("(refreshed user token)")
    return session["authorizationToken"]


def cmd_anonymous(_args):
    token = anonymous_token()
    claims = jwt_payload(token)
    print(f"anonymous token OK · IP {claims.get('ipaddress')} · zip {claims.get('postalcode')} · {claims.get('countryCode')}")
    _, geo = request("GET", "/geolocation", token=token)
    print(f"geolocation: {geo.get('cityname')} {geo.get('postalcode')} ({geo.get('lookupMode')})")
    _, body = request("GET", "/v3/entitlement/linearchannel", token=token, query={
        "id": LIVE_ID, "channelId": CHANNEL_ID, "deviceType": "ios_apple_tv", "contentConsumption": "appleTv",
    })
    print(f"live channel (signed out): {body.get('errorCode')} · locationZip {body.get('locationZip')}")


def cmd_login(args):
    profile_device = PROFILES[args.profile][0]
    token = anonymous_token(args.profile)
    # Validation copies these from the initiate request into string fields
    # server-side; leaving any out makes the validate step fail after the code
    # is accepted. The website always sends the campaign fields, even empty.
    key = graphql(
        "mutation ($site: String!, $device: EntitlementDevice!, $input: IdentityAuthOtpInitiateInput!) {"
        " identityAuthOtpInitiate(site: $site, device: $device, input: $input) { key } }",
        {"site": SITE, "device": profile_device,
         "input": {
             "email": args.email,
             "deviceName": "Altitude++ probe",
             "campaign": "", "campaignSource": "", "campaignMedium": "",
             "deviceMetadata": {
                 "manufacturerName": "Apple", "modelName": "AppleTV", "osName": "tvOS",
                 "osVersion": "26.0", "manufacturingYear": "", "serialNumber": device_id(),
                 "userAgent": "AltitudePlusPlus/0.1",
             },
         }},
        token,
    )["identityAuthOtpInitiate"]["key"]
    if not sys.stdin.isatty():
        write_private(PENDING_PATH, {"email": args.email, "key": key, "anon": token})
        print(f"Code sent to {args.email}. Finish with: python3 tools/probe.py verify CODE")
        return
    code = input(f"Code emailed to {args.email}: ").strip()
    finish_login(args.email, key, code, token)


def cmd_verify(args):
    try:
        with open(PENDING_PATH) as fh:
            pending = json.load(fh)
    except FileNotFoundError:
        sys.exit("No login in progress. Run: python3 tools/probe.py login you@example.com")
    finish_login(pending["email"], pending["key"], args.code.strip(), pending["anon"])
    os.remove(PENDING_PATH)


def finish_login(email, key, code, token):
    result = graphql(
        "mutation ($site: String!, $key: String, $otp: String) {"
        " identityAuthOtpValidate(site: $site, key: $key, otp: $otp)"
        " { userId refreshToken email authorizationToken isSubscribed } }",
        {"site": SITE, "key": key, "otp": code},
        token,
    )["identityAuthOtpValidate"]
    save_session(result)
    print(f"Signed in as {result.get('email')} · subscribed: {result.get('isSubscribed')}")
    print(f"Session saved to {SESSION_PATH}")


def cmd_live(args):
    device_type, consumption = PROFILES[args.profile]
    token = user_token(args.profile)
    query = {"id": LIVE_ID, "channelId": CHANNEL_ID, "deviceType": device_type,
             "contentConsumption": consumption, "ssaiDisable": "false"}
    if args.lat is not None and args.lon is not None:
        query.update(latitude=str(args.lat), longitude=str(args.lon))
    status, body = request("GET", "/v3/entitlement/linearchannel", token=token, query=query)
    print(f"HTTP {status} · profile {device_type}/{consumption}")

    if not isinstance(body, dict):
        sys.exit(f"Unexpected body: {str(body)[:300]}")
    if body.get("errorCode"):
        print(f"errorCode: {body['errorCode']} · {body.get('errorMessage')} · zip {body.get('locationZip')}")
        return

    # Same lookup as the app: `linearchannel.streamingInfo.videoAssets`. The copies
    # under `linearchannel.channels[]` are placeholders with blank license URLs.
    assets = ((body.get("linearchannel") or {}).get("streamingInfo") or {}).get("videoAssets") \
        or find(body, "videoAssets") or {}
    print("videoAssets keys:", sorted(k for k, v in assets.items() if isinstance(v, dict)))

    widevine = assets.get("widevine") or {}
    if (widevine.get("url") or "").strip():
        print(f"widevine: url host {urllib.parse.urlparse(widevine['url']).netloc} "
              f"({urllib.parse.urlparse(widevine['url']).path.rsplit('/', 1)[-1]})")
        print(f"  licenseUrl     {(widevine.get('licenseUrl') or '').strip()}")
        print(f"  licenseToken   {'present' if (widevine.get('licenseToken') or '').strip() else 'MISSING'}")
    entry = assets.get("fairPlayCmaf") or assets.get("fairPlay")
    if not entry:
        print("No FairPlay entry. Full (redacted) response:")
        print(json.dumps(redact(body), indent=2)[:6000])
        return

    which = "fairPlayCmaf" if assets.get("fairPlayCmaf") else "fairPlay"
    print(f"{which}: url host {urllib.parse.urlparse(entry.get('url', '')).netloc}")
    print(f"  certificateUrl {entry.get('certificateUrl')}")
    print(f"  licenseUrl     {entry.get('licenseUrl')}")
    token = (entry.get("licenseToken") or "").strip()
    if "|" in token:
        claims = jwt_payload(token.split("|", 1)[1])
        hours = (claims.get("exp", 0) - time.time()) / 3600
        print(f"  licenseToken   present · valid {hours:.1f} h · key rotation {claims.get('drmKeyRotationEnabled')}")
    else:
        print(f"  licenseToken   {'present' if token else 'MISSING'}")

    status, cert = request("GET", entry["certificateUrl"], raw=True)
    print(f"  certificate    HTTP {status}, {len(cert)} bytes")

    status, playlist = request("GET", entry["url"], raw=True)
    text = playlist.decode(errors="replace")
    keys = set(re.findall(r'KEYFORMAT="([^"]+)"', text))
    variants = re.findall(r"^[^#\s].*$", text, re.M)
    if not keys and variants:
        # Key tags live in the media playlists; look at the first one.
        media_url = urllib.parse.urljoin(entry["url"], variants[0])
        _, media = request("GET", media_url, raw=True)
        keys = set(re.findall(r'KEYFORMAT="([^"]+)"', media.decode(errors="replace")))
    print(f"  master playlist HTTP {status}, {len(variants)} variants, key formats: {sorted(keys) or 'none found'}")
    print("\nIf the key format is com.apple.streamingkeydelivery, the tvOS app's FairPlay path matches.")
    if args.dump:
        print(json.dumps(redact(body), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    login = sub.add_parser("login")
    login.add_argument("email")
    login.add_argument("--profile", choices=PROFILES, default="appletv")
    verify = sub.add_parser("verify")
    verify.add_argument("code")
    live = sub.add_parser("live")
    live.add_argument("--profile", choices=PROFILES, default="appletv")
    live.add_argument("--web", dest="profile", action="store_const", const="web")
    live.add_argument("--lat", type=float)
    live.add_argument("--lon", type=float)
    live.add_argument("--dump", action="store_true", help="print the full redacted response")
    args = parser.parse_args()

    if args.command == "login":
        cmd_login(args)
    elif args.command == "verify":
        cmd_verify(args)
    elif args.command == "live":
        cmd_live(args)
    else:
        cmd_anonymous(args)


if __name__ == "__main__":
    main()
