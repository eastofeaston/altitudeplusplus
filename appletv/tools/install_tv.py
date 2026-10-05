#!/usr/bin/env python3
"""Build Altitude++ and install it on an Apple TV paired with this Mac.

    tools/install-tv.sh                    install (asks which Apple TV if several are paired)
    tools/install-tv.sh "Bedroom"          install on the Apple TV with that name
    tools/install-tv.sh --launch           open the app on the TV after installing
    tools/install-tv.sh --team ABCDE12345  sign with a specific Apple team (remembered)
    tools/install-tv.sh --list             show paired Apple TVs and signing teams

The first run saves your signing team and a bundle ID unique to it in
Config/Local.xcconfig (git-ignored). With a free Apple account the install
stops opening after 7 days; run this again after that to renew it.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCAL_CONFIG = ROOT / "Config" / "Local.xcconfig"
BUILD_DIR = ROOT / "build" / "device"
APP_PATH = BUILD_DIR / "Build" / "Products" / "Release-appletvos" / "AltitudePlusPlus.app"

PAIRING_HELP = """\
To pair an Apple TV with this Mac:
  1. Put the Apple TV and the Mac on the same network.
  2. On the Apple TV, open Settings > Remotes and Devices > Remote App and Devices,
     and stay on that screen.
  3. On the Mac, open Xcode > Window > Devices and Simulators, select the
     Apple TV under Discovered, click Pair, and enter the code from the TV."""

ACCOUNT_HELP = """\
Xcode isn't signed in to an Apple account. Open Xcode > Settings > Accounts,
click +, and sign in with your Apple ID. A free account works."""


def fail(message: str) -> None:
    print(f"\nerror: {message}", file=sys.stderr)
    sys.exit(1)


def choose(prompt: str, options: list[str], hint: str) -> int:
    """Index of the chosen option. Asks only when there is more than one."""
    if len(options) == 1:
        return 0
    if not sys.stdin.isatty():
        fail(f"{prompt} {hint}")
    print(prompt)
    for number, option in enumerate(options, 1):
        print(f"  {number}) {option}")
    while True:
        answer = input(f"Choose 1-{len(options)}: ").strip()
        if answer.isdigit() and 1 <= int(answer) <= len(options):
            return int(answer) - 1


# MARK: Signing team

def xcode_teams() -> list[dict]:
    """Teams for the Apple accounts signed in to Xcode."""
    result = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True)
    if result.returncode != 0:
        return []
    teams: dict[str, dict] = {}

    def walk(value):
        if isinstance(value, dict):
            if "teamID" in value:
                teams.setdefault(value["teamID"], value)
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(plistlib.loads(result.stdout))
    return list(teams.values())


def team_label(team: dict) -> str:
    label = f"{team.get('teamName', 'Unknown team')} ({team['teamID']})"
    return label + " - free, installs last 7 days" if team.get("isFreeProvisioningTeam") else label


def read_local_config() -> dict[str, str]:
    if not LOCAL_CONFIG.exists():
        return {}
    values = {}
    for line in LOCAL_CONFIG.read_text().splitlines():
        if "=" in line and not line.strip().startswith("//"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def configure_signing(requested_team: str | None) -> str:
    """Team ID to sign with, saving Config/Local.xcconfig when it changes."""
    config = read_local_config()
    if config.get("DEVELOPMENT_TEAM") and requested_team in (None, config["DEVELOPMENT_TEAM"]):
        return config["DEVELOPMENT_TEAM"]

    if requested_team:
        team_id = requested_team
    else:
        teams = xcode_teams()
        if not teams:
            fail(ACCOUNT_HELP)
        team_id = teams[choose("Which Apple team should sign the app?", [team_label(t) for t in teams],
                               "Pass --team TEAMID.")]["teamID"]

    # Bundle IDs are unique across all Apple accounts, so make one per team.
    bundle_id = f"com.altitudeplusplus.tv.{team_id.lower()}"
    LOCAL_CONFIG.write_text(
        "// Written by tools/install-tv.sh for your Apple account. Not committed.\n"
        f"DEVELOPMENT_TEAM = {team_id}\n"
        f"APP_BUNDLE_ID = {bundle_id}\n"
    )
    print(f"Saved signing team {team_id} (bundle ID {bundle_id}) to {LOCAL_CONFIG.relative_to(ROOT)}")
    return team_id


# MARK: Apple TV

def paired_apple_tvs() -> list[dict]:
    with tempfile.NamedTemporaryFile(suffix=".json") as output:
        result = subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", output.name],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            fail(f"couldn't list devices:\n{result.stderr.strip()}")
        devices = json.loads(Path(output.name).read_text())["result"]["devices"]

    tvs = []
    for device in devices:
        hardware = device.get("hardwareProperties", {})
        if hardware.get("platform") != "tvOS" or hardware.get("reality") != "physical":
            continue
        if device.get("connectionProperties", {}).get("pairingState") != "paired":
            continue
        tvs.append({
            "name": device.get("deviceProperties", {}).get("name", "Apple TV"),
            "identifier": device["identifier"],
            "udid": hardware.get("udid", device["identifier"]),
            "model": hardware.get("marketingName", "Apple TV"),
            "os": device.get("deviceProperties", {}).get("osVersionNumber", "?"),
        })
    return tvs


def tv_label(tv: dict) -> str:
    return f"{tv['name']} - {tv['model']}, tvOS {tv['os']}"


def select_apple_tv(requested: str | None) -> dict:
    tvs = paired_apple_tvs()
    if not tvs:
        fail(f"no Apple TV is paired with this Mac.\n\n{PAIRING_HELP}")
    if requested:
        wanted = requested.lower()
        matches = [tv for tv in tvs if wanted in (tv["name"].lower(), tv["identifier"].lower(), tv["udid"].lower())]
        if not matches:
            names = "\n".join(f"  {tv_label(tv)}" for tv in tvs)
            fail(f'no paired Apple TV called "{requested}". Paired Apple TVs:\n{names}')
        tvs = matches
    return tvs[choose("Which Apple TV?", [tv_label(tv) for tv in tvs], 'Pass the name, e.g. tools/install-tv.sh "Bedroom".')]


# MARK: Build and install

def build(tv: dict) -> None:
    if not shutil.which("xcodegen"):
        fail("XcodeGen isn't installed. Install it with: brew install xcodegen")
    print("Generating the Xcode project...")
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT, check=True)
    print(f"Building for {tv['name']} (this takes a minute the first time)...")
    result = subprocess.run([
        "xcodebuild", "-project", "AltitudePlusPlus.xcodeproj", "-scheme", "AltitudePlusPlus",
        "-configuration", "Release", "-destination", f"id={tv['udid']}",
        "-derivedDataPath", str(BUILD_DIR), "-allowProvisioningUpdates", "-quiet", "build",
    ], cwd=ROOT)
    if result.returncode != 0:
        fail("the build failed (see above). Signing problems are easiest to read in Xcode: "
             "run `xcodegen generate`, open AltitudePlusPlus.xcodeproj, and check the "
             "AltitudePlusPlus target's Signing & Capabilities tab.")


def install(tv: dict) -> None:
    print(f"Installing on {tv['name']}...")
    result = subprocess.run(
        ["xcrun", "devicectl", "device", "install", "app", "--device", tv["identifier"], str(APP_PATH)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        fail(f"install failed. Make sure {tv['name']} is on and awake.\n{result.stderr.strip()}")


def bundle_id() -> str:
    info = plistlib.loads((APP_PATH / "Info.plist").read_bytes())
    return info["CFBundleIdentifier"]


def launch(tv: dict) -> None:
    subprocess.run(
        ["xcrun", "devicectl", "device", "process", "launch", "--device", tv["identifier"], bundle_id()],
        capture_output=True,
    )


def signing_expiry() -> datetime | None:
    profile = APP_PATH / "embedded.mobileprovision"
    result = subprocess.run(["security", "cms", "-D", "-i", str(profile)], capture_output=True)
    if result.returncode != 0:
        return None
    expiry = plistlib.loads(result.stdout).get("ExpirationDate")
    # plistlib returns naive datetimes; profile dates are UTC.
    return expiry.replace(tzinfo=timezone.utc) if expiry else None


def list_everything() -> None:
    print("Signing teams in Xcode:")
    for team in xcode_teams() or []:
        print(f"  {team_label(team)}")
    if not xcode_teams():
        print("  (none)\n" + ACCOUNT_HELP)
    current = read_local_config().get("DEVELOPMENT_TEAM")
    if current:
        print(f"Saved team: {current} ({LOCAL_CONFIG.relative_to(ROOT)})")
    print("\nPaired Apple TVs:")
    tvs = paired_apple_tvs()
    for tv in tvs:
        print(f"  {tv_label(tv)}")
    if not tvs:
        print("  (none)\n" + PAIRING_HELP)


def main() -> None:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(
        prog="tools/install-tv.sh",
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="\n\n".join(__doc__.split("\n\n")[1:]),
    )
    parser.add_argument("device", nargs="?", help="Apple TV name or identifier (default: the only one, or ask)")
    parser.add_argument("--team", help="Apple team ID to sign with; saved for next time")
    parser.add_argument("--launch", action="store_true", help="open the app on the TV after installing")
    parser.add_argument("--list", action="store_true", help="show paired Apple TVs and signing teams, then exit")
    args = parser.parse_args()

    if args.list:
        list_everything()
        return

    team = configure_signing(args.team)
    tv = select_apple_tv(args.device)
    build(tv)
    install(tv)
    if args.launch:
        launch(tv)

    print(f"\nInstalled Altitude++ on {tv['name']}.")
    expiry = signing_expiry()
    if expiry:
        local = expiry.astimezone()
        print(f"Signed until {local:%a %b %-d at %-I:%M %p}.", end=" ")
        free = any(t.get("isFreeProvisioningTeam") for t in xcode_teams() if t.get("teamID") == team)
        if free:
            print("Free Apple accounts sign apps for 7 days; run this again after that to renew.")
        else:
            print("Run this again before then to renew.")


if __name__ == "__main__":
    main()
