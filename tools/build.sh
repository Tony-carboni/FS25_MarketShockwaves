#!/usr/bin/env bash
# Package the mod into an installable zip.
#
#   ./tools/build.sh            -> build/FS25_MarketShockwaves.zip
#
# Copy the zip into:
#   Windows: %USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\
set -euo pipefail

cd "$(dirname "$0")/.."
MOD="FS25_MarketShockwaves"
OUT="build"

echo "== syntax check =="
for f in $(find "$MOD/scripts" -name '*.lua' | sort); do
    luac -p "$f" && echo "  ok  $f"
done

echo "== xml check =="
python3 - <<'PY'
import xml.etree.ElementTree as ET, glob, sys
bad = 0
for f in glob.glob("FS25_MarketShockwaves/**/*.xml", recursive=True):
    try:
        ET.parse(f); print(f"  ok  {f}")
    except Exception as e:
        print(f"  FAIL {f}: {e}"); bad = 1
sys.exit(bad)
PY

echo "== config validation =="
python3 tools/validate_config.py

# The hand-written docs quote facts that also live in the config - chain values,
# month weights, product lists, counts. This fails if any of them has drifted.
echo "== documentation audit =="
python3 tools/audit_docs.py | tail -2

# Regenerated on every build so they cannot fall behind the config. CI runs the
# same tools with --check, so a config change committed without a build is
# caught rather than silently shipping a stale reference.
echo "== generated docs =="
python3 tools/event_review.py -o docs/event-review.md
python3 tools/filltype_coverage.py -o docs/filltype-coverage.txt

echo "== model tests =="
lua tools/test_model.lua > /dev/null && echo "  all model tests passed"
lua tools/test_settings_menu.lua > /dev/null && echo "  all settings menu tests passed"

echo "== packaging =="
rm -rf "$OUT"; mkdir -p "$OUT"
# The zip must contain the mod's files at its ROOT (modDesc.xml at top level),
# not nested inside a folder, or the game will not recognise it.
# Only ship what the game needs. Dev notes and editor droppings stay out.
if command -v zip >/dev/null 2>&1; then
    ( cd "$MOD" && zip -qr "../$OUT/$MOD.zip" . \
        -x '*.DS_Store' '*.md' '*.bak' '*~' '.git*' )
else
    # Git Bash on Windows ships unzip but not zip. Same contents, same
    # exclusions, written with Python instead.
    python3 - "$MOD" "$OUT/$MOD.zip" <<'PY'
import fnmatch, os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
skip = ("*.DS_Store", "*.md", "*.bak", "*~", ".git*")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".git"))
        for name in sorted(files):
            if any(fnmatch.fnmatch(name, pat) for pat in skip):
                continue
            path = os.path.join(root, name)
            z.write(path, os.path.relpath(path, src).replace(os.sep, "/"))
PY
fi

echo
echo "built $OUT/$MOD.zip"
unzip -l "$OUT/$MOD.zip" | tail -n +4 | head -20
