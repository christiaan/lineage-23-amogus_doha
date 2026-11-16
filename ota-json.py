#!/usr/bin/env python3
"""Write the Updater app's OTA feed for a released build (doha_android#80).

Usage: ./ota-json.py ZIP TAG [--repo OWNER/REPO] [--no-check] [-o FILE]

ZIP is the release zip (lineage-<version>-<date>-<type>-<device>.zip) and
TAG the GitHub release it's attached to. Prints the feed, or writes it to
FILE: a JSON list with one entry, in the format of LineageOS 24.0's
Updater (packages/apps/Updater README.md). Commit it as <device>.json on
the ota branch of the release repo, which is where build.sh's UPDATER_URI
points.

Only the newest build is listed: the Updater hides every build that isn't
newer than the running one, so older entries would never show.

Unless --no-check is given, the script asks GitHub for the asset first and
refuses to write a feed whose URL doesn't serve a file of the zip's size,
so upload the zip to the release before running it.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request
import zipfile

NAME = re.compile(r"^lineage-(?P<version>[0-9.]+)-(?P<date>\d{8})-(?P<type>[A-Z]+)-(?P<device>[a-z0-9_]+)\.zip$")


def metadata(zf):
    props = {}
    for line in zf.read("META-INF/com/android/metadata").decode().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            props[key] = value
    return props


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def remote_size(url):
    # urllib follows the 302 to release-assets.githubusercontent.com, the
    # way the Updater's download client and update_engine do.
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "ota-json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return int(resp.headers["Content-Length"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("zip")
    ap.add_argument("tag")
    ap.add_argument("--repo", default="christiaan/lineage-23-amogus_doha")
    ap.add_argument("--no-check", action="store_true", help="don't check the asset URL")
    ap.add_argument("-o", "--output")
    args = ap.parse_args()

    filename = os.path.basename(args.zip)
    m = NAME.match(filename)
    if not m:
        sys.exit(f"{filename}: not a lineage-<version>-<date>-<type>-<device>.zip name"
                 " (-adbkey test builds must never be released)")

    with zipfile.ZipFile(args.zip) as zf:
        meta = metadata(zf)
    if meta.get("ota-type") != "AB":
        sys.exit(f"{filename}: ota-type is {meta.get('ota-type')}, expected AB")

    size = os.path.getsize(args.zip)
    url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{filename}"
    if not args.no_check:
        try:
            served = remote_size(url)
        except OSError as e:
            sys.exit(f"{url}: {e} (upload the zip to release {args.tag} first)")
        if served != size:
            sys.exit(f"{url} serves {served} bytes, {args.zip} has {size}")

    entry = {
        # Compared with ro.build.date.utc: only newer builds are offered.
        "datetime": int(meta["post-timestamp"]),
        "files": [{
            "filename": filename,
            "os_patch_level": meta["post-security-patch-level"],
            # The Updater treats a missing value as 0 and hides the build
            # as "older than current Android version".
            "os_sdk_level": int(meta["post-sdk-level"]),
            # Lets the Updater stream the payload (range requests) instead
            # of downloading the zip first, when that's enabled.
            "ota_property_files": meta["ota-property-files"],
            "sha256": sha256(args.zip),
            "size": size,
            "url": url,
        }],
        # Compared, ignoring case, with ro.lineage.releasetype.
        "type": m["type"],
        "version": m["version"],
    }
    text = json.dumps([entry], indent=2) + "\n"
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
