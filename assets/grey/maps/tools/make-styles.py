#!/usr/bin/env python3
"""Dire Wolf Security - build the offline styles, fonts and config for TileServer GL.

Takes the OpenMapTiles styles, sprites and font glyphs that install.sh fetched,
and makes them work with no internet:

  - every style points at the local tiles  (mbtiles://{openmaptiles})
  - every style points at local sprites    ({styleJsonFolder}/sprite)
  - every style points at local fonts      ({fontstack}/{range}.pbf)
  - every font a style asks for must exist on disk, or the build stops
  - no http:// or https:// address may be left in any style, or the build stops

Then it writes config.json for TileServer GL.

Usage (install.sh runs this for you):
  python3 make-styles.py --src DIR --fonts DIR --out MAPS_DIR \
      --style NAME [--style NAME ...] --tiles planet.mbtiles --attribution TEXT
  python3 make-styles.py --verify --out MAPS_DIR     (check only, change nothing)

Exit code 0 = good, 1 = a problem that would break the map offline.
License: CC BY-SA 4.0
"""
import argparse
import json
import os
import shutil
import sys

SPRITE_FILES = ["sprite.json", "sprite.png", "sprite@2x.json", "sprite@2x.png"]

# The fonts gh-pages branch names the patched Noto Sans "Klokantech Noto Sans ...".
# The styles ask for "Noto Sans ...". Copy one to the other.
FONT_ALIASES = {
    "Noto Sans Regular": "Klokantech Noto Sans Regular",
    "Noto Sans Bold": "Klokantech Noto Sans Bold",
    "Noto Sans Italic": "Klokantech Noto Sans Italic",
}

# Words that appear inside style expressions, not font names.
EXPRESSION_WORDS = {"literal", "step", "zoom", "match", "case", "get", "coalesce", "interpolate", "linear"}


def fail(msg, problems):
    problems.append(msg)
    print("  PROBLEM: " + msg)


def walk(node, fn):
    """Call fn(key, value) for every key in a nested JSON structure."""
    if isinstance(node, dict):
        for k, v in node.items():
            fn(k, v)
            walk(v, fn)
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)


def strings_in(value):
    out = []
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, list):
        for v in value:
            out.extend(strings_in(v))
    elif isinstance(value, dict):
        for v in value.values():
            out.extend(strings_in(v))
    return out


def fonts_used(style):
    found = set()

    def fn(k, v):
        if k == "text-font":
            for s in strings_in(v):
                if s not in EXPRESSION_WORDS:
                    found.add(s)
    walk(style.get("layers", []), fn)
    return found


def icons_used(style):
    found = set()

    def fn(k, v):
        if k == "icon-image":
            for s in strings_in(v):
                if "{" not in s and s not in EXPRESSION_WORDS and s:
                    found.add(s)
    walk(style.get("layers", []), fn)
    return found


def remote_urls(obj):
    found = []

    def fn(k, v):
        if isinstance(v, str) and ("http://" in v or "https://" in v):
            found.append("%s = %s" % (k, v))
    walk(obj, fn)
    return found


def check_font_dir(fonts_dir, name, problems):
    d = os.path.join(fonts_dir, name)
    if not os.path.isfile(os.path.join(d, "0-255.pbf")):
        fail("font '%s' is missing (%s/0-255.pbf)" % (name, d), problems)
        return False
    return True


def verify(out_dir, problems):
    """Check a finished MAPS_DIR. Changes nothing."""
    cfg_path = os.path.join(out_dir, "config.json")
    if not os.path.isfile(cfg_path):
        fail("no config.json in " + out_dir, problems)
        return
    cfg = json.load(open(cfg_path, encoding="utf-8"))
    paths = cfg.get("options", {}).get("paths", {})
    fonts_dir = os.path.join(out_dir, paths.get("fonts", "fonts"))
    styles_dir = os.path.join(out_dir, paths.get("styles", "styles"))
    data_dir = os.path.join(out_dir, paths.get("mbtiles", "data"))

    for key, d in cfg.get("data", {}).items():
        f = os.path.join(data_dir, d.get("mbtiles", ""))
        if os.path.isfile(f):
            print("  ok   data '%s': %s (%.1f GB)" % (key, f, os.path.getsize(f) / 1e9))
        else:
            fail("data '%s' file not found: %s" % (key, f), problems)

    for name, s in cfg.get("styles", {}).items():
        sp = os.path.join(styles_dir, s["style"])
        if not os.path.isfile(sp):
            fail("style '%s' file not found: %s" % (name, sp), problems)
            continue
        style = json.load(open(sp, encoding="utf-8"))
        urls = remote_urls(style)
        for u in urls:
            fail("style '%s' still points at the internet: %s" % (name, u), problems)
        sdir = os.path.dirname(sp)
        for f in SPRITE_FILES:
            if not os.path.isfile(os.path.join(sdir, f)):
                fail("style '%s' sprite file missing: %s" % (name, f), problems)
        fonts = fonts_used(style)
        bad = [f for f in sorted(fonts) if not check_font_dir(fonts_dir, f, problems)]
        icons = icons_used(style)
        missing_icons = []
        sj = os.path.join(sdir, "sprite.json")
        if os.path.isfile(sj):
            sprite = json.load(open(sj, encoding="utf-8"))
            missing_icons = sorted(i for i in icons if i not in sprite)
        if missing_icons:
            # A missing icon draws nothing; the map still works. Warn only.
            print("  warn style '%s': %d icon names not in sprite (first few: %s)"
                  % (name, len(missing_icons), ", ".join(missing_icons[:5])))
        if not urls and not bad:
            print("  ok   style '%s': %d fonts, %d icons, offline-clean" % (name, len(fonts), len(icons)))

    cfg_urls = [u for u in remote_urls(cfg) if "attribution" not in u.split(" = ")[0]]
    for u in cfg_urls:
        fail("config.json points at the internet: " + u, problems)


def build(args, problems):
    out = args.out
    fonts_out = os.path.join(out, "fonts")
    styles_out = os.path.join(out, "styles")
    os.makedirs(fonts_out, exist_ok=True)
    os.makedirs(styles_out, exist_ok=True)
    os.makedirs(os.path.join(out, "data"), exist_ok=True)

    # Fonts: copy every font folder, then add the Noto Sans aliases.
    print("Fonts from " + args.fonts)
    count = 0
    for entry in sorted(os.listdir(args.fonts)):
        src = os.path.join(args.fonts, entry)
        if os.path.isdir(src) and os.path.isfile(os.path.join(src, "0-255.pbf")):
            dst = os.path.join(fonts_out, entry)
            if os.path.isdir(dst):
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
            count += 1
    for alias, real in FONT_ALIASES.items():
        src = os.path.join(fonts_out, real)
        dst = os.path.join(fonts_out, alias)
        if os.path.isdir(src) and not os.path.isdir(dst):
            shutil.copytree(src, dst)
            print("  alias '%s' -> copy of '%s'" % (alias, real))
    print("  %d font folders copied" % count)

    styles_cfg = {}
    for name in args.style:
        print("Style " + name)
        repo = os.path.join(args.src, name)
        sprites = os.path.join(args.src, name + "-sprites")
        style = json.load(open(os.path.join(repo, "style.json"), encoding="utf-8"))
        style["sources"] = {"openmaptiles": {"type": "vector", "url": "mbtiles://{openmaptiles}"}}
        style["sprite"] = "{styleJsonFolder}/sprite"
        style["glyphs"] = "{fontstack}/{range}.pbf"
        # Some styles carry an editor key or a MapTiler key in metadata. Drop remote bits.
        meta = style.get("metadata", {})
        for k in list(meta.keys()):
            if isinstance(meta[k], str) and ("http://" in meta[k] or "https://" in meta[k]):
                del meta[k]
        sdir = os.path.join(styles_out, name)
        os.makedirs(sdir, exist_ok=True)
        with open(os.path.join(sdir, "style.json"), "w", encoding="utf-8") as f:
            json.dump(style, f, indent=2, ensure_ascii=False)
        for fn in SPRITE_FILES:
            src = os.path.join(sprites, fn)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(sdir, fn))
            else:
                fail("style '%s': sprite file %s not fetched" % (name, fn), problems)
        lic = os.path.join(repo, "LICENSE.md")
        if os.path.isfile(lic):
            shutil.copy2(lic, os.path.join(sdir, "LICENSE.md"))
        styles_cfg[name] = {
            "style": name + "/style.json",
            "serve_rendered": True,
            "serve_data": True,
            "tilejson": {"attribution": args.attribution},
        }

    cfg = {
        "options": {
            "paths": {"root": "", "fonts": "fonts", "styles": "styles", "mbtiles": "data"},
            "serveAllFonts": True,
            "serveStaticMaps": True,
            "maxScaleFactor": 2,
            "tileMargin": 0,
        },
        "styles": styles_cfg,
        "data": {"openmaptiles": {"mbtiles": args.tiles}},
    }
    with open(os.path.join(out, "config.json"), "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print("Wrote " + os.path.join(out, "config.json"))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--src", help="folder with <style>/ and <style>-sprites/ checkouts")
    p.add_argument("--fonts", help="folder of font glyph folders (fonts gh-pages checkout)")
    p.add_argument("--out", required=True, help="MAPS_DIR, for example /srv/maps")
    p.add_argument("--style", action="append", default=[], help="style name (repeat)")
    p.add_argument("--tiles", default="planet.mbtiles")
    p.add_argument("--attribution", default="&copy; OpenMapTiles &copy; OpenStreetMap contributors")
    p.add_argument("--verify", action="store_true", help="check only")
    args = p.parse_args()

    problems = []
    if not args.verify:
        if not (args.src and args.fonts and args.style):
            p.error("--src, --fonts and at least one --style are needed to build")
        build(args, problems)
    print("Checking " + args.out)
    verify(args.out, problems)
    if problems:
        print("\n%d problem(s). The map will not work offline until they are fixed." % len(problems))
        sys.exit(1)
    print("\nAll checks passed.")


if __name__ == "__main__":
    main()
