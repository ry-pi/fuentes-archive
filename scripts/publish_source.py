#!/usr/bin/env python3
"""Build the SideStore/AltStore source JSON.

Reads sidestore/apps.json (hand-edited metadata; newest version first) and
writes a finished source to the given output path:
  * adds identifier + sourceURL
  * points each version at its own versioned GitHub Release asset
  * fills the real IPA size (bytes) for every version that has a release
  * drops versions that have no published release
Usage: publish_source.py OUT.json [--ipa PATH --version V --build B]
"""
import json, subprocess, sys, os, argparse

REPO = "ry-pi/fuentes-archive"
SOURCE_URL = f"https://raw.githubusercontent.com/{REPO}/source/apps.json"
ASSET = "FuentesArchive-unsigned.ipa"

def tag(v, b):
    return f"v{v}-{b}"

def release_size(t):
    try:
        out = subprocess.run(["gh", "release", "view", t, "-R", REPO, "--json", "assets"],
                             capture_output=True, text=True, check=True).stdout
        for a in json.loads(out)["assets"]:
            if a["name"] == ASSET:
                return a["size"]
    except subprocess.CalledProcessError:
        pass
    return None

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--ipa"); ap.add_argument("--version"); ap.add_argument("--build")
a = ap.parse_args()

src = json.load(open("sidestore/apps.json"))
src["identifier"] = "io.github.ry-pi.fuentes-archive"
src["sourceURL"] = SOURCE_URL
for app in src["apps"]:
    kept = []
    for v in app["versions"]:
        t = tag(v["version"], v["buildVersion"])
        if a.ipa and v["version"] == a.version and v["buildVersion"] == a.build:
            size = os.path.getsize(a.ipa)
        else:
            size = release_size(t)
        if size is None:
            print(f"skip {t}: no release", file=sys.stderr)
            continue
        v["size"] = size
        v["downloadURL"] = f"https://github.com/{REPO}/releases/download/{t}/{ASSET}"
        kept.append(v)
    app["versions"] = kept
    if kept:  # legacy top-level fields some clients still read
        app["version"] = kept[0]["version"]
        app["versionDate"] = kept[0]["date"]
        app["downloadURL"] = kept[0]["downloadURL"]
        app["size"] = kept[0]["size"]
json.dump(src, open(a.out, "w"), indent=2)
open(a.out, "a").write("\n")
print(json.dumps(src["apps"][0]["versions"], indent=1))
