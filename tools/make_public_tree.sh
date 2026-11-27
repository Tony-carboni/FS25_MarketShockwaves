#!/usr/bin/env bash
# Build the tree to publish as the PUBLIC repository.
#
#   ./tools/make_public_tree.sh [DEST]        # default: ../FS25_MarketShockwaves
#
# This repository stays private and keeps the full development history. The
# public one carries ONE COMMIT PER RELEASE and nothing third-party, so no GIANTS
# data and no other modder's source is ever in public history.
#
# Two modes, chosen automatically:
#
#   FIRST PUBLISH   DEST does not exist -> git init, one squashed initial commit.
#                   Squashed rather than a deletion commit because deleting a file
#                   does not remove it from history.
#
#   EVERY RELEASE   DEST is an existing clone -> sync it to this tree and commit
#   AFTER           on top. A normal push, no force, so public history becomes a
#                   clean release log and previously published tags and releases
#                   stay exactly where they were.
#
# Re-initialising each time would need a force-push and rewrite public history on
# every release, which is why it does not do that.
#
# What is EXCLUDED and why:
#   reference/            GIANTS and DLC game data, plus another mod's source
#   build/                build output
#   .claude/              local agent settings
#
# Everything else ships: the mod, the tools, the tests, the CI, and the docs.
# The tools degrade gracefully with reference/ absent (they say so and skip the
# checks that need game data), which is verified below rather than assumed.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="$PWD"
# Named after the mod, matching the zip and the mod folder, because that is
# what someone arriving from KingMods expects to land on.
DEST="${1:-$PWD/../FS25_MarketShockwaves}"

echo "== preflight: the private tree must be clean and passing =="
if [ -n "$(git status --porcelain)" ]; then
    echo "  refusing: uncommitted changes. Commit first, so what is published"
    echo "  corresponds to a real commit in the private history."
    exit 1
fi
./tools/build.sh >/dev/null
echo "  ok — build, validation, doc audit and both suites pass"

MODE=init
if [ -d "$DEST/.git" ]; then
    MODE=update
    echo "== updating the existing public clone =="
    # Sync to whatever the remote has, via FETCH_HEAD rather than
    # refs/remotes/origin/main. A clone taken while the repo was still empty has
    # no remote-tracking ref for main, and reset --hard origin/main then fails
    # with "ambiguous argument". FETCH_HEAD is always valid after a fetch.
    if git -C "$DEST" fetch --quiet origin main 2>/dev/null; then
        git -C "$DEST" checkout --quiet -B main FETCH_HEAD
    else
        echo "  remote has no main yet — keeping the local branch"
        git -C "$DEST" checkout --quiet -B main
    fi
    # Clear the working tree but KEEP .git, so the next commit lands on top of
    # the published history instead of replacing it.
    find "$DEST" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
else
    echo "== first publish: creating $DEST =="
    mkdir -p "$DEST"
fi

echo "== copying tracked files =="
# Only git-tracked files, so nothing untracked or ignored can ride along.
git ls-files -z \
  | grep -zv '^reference/' \
  | grep -zv '^\.claude/' \
  | tar --null -cf - -T - \
  | tar -xf - -C "$DEST"

echo "== verifying nothing third-party leaked =="
FAIL=0
# Any file naming a fill type wholesale is game data, not our config.
while IFS= read -r -d '' f; do
    case "$f" in
        */config/events.xml|*/config/forecasts.xml|*/l10n/*|*docs/filltype-coverage.txt|*tools/*) continue ;;
    esac
    if grep -lq '<fillType name=' "$f" 2>/dev/null; then
        echo "  LEAK  $f contains fill type definitions"; FAIL=1
    fi
done < <(find "$DEST" -type f -name '*.xml' -print0)

for forbidden in reference marketdynamics fillTypes_basegame gcp_fillTypes gcp_modDesc; do
    if find "$DEST" -name "*${forbidden}*" -print -quit | grep -q .; then
        echo "  LEAK  something named '$forbidden' is present"; FAIL=1
    fi
done

test -f "$DEST/LICENSE" || { echo "  MISSING LICENSE"; FAIL=1; }
grep -q 'CC BY-NC-ND' "$DEST/LICENSE" || { echo "  LICENSE is not the chosen one"; FAIL=1; }
[ "$FAIL" -eq 0 ] || { echo "aborting"; exit 1; }
echo "  ok — no game data, no third-party source, licence present"

echo "== verifying the tools still work without reference/ =="
( cd "$DEST"
  python3 tools/validate_config.py >/dev/null
  python3 tools/validate_forecasts.py >/dev/null
  python3 tools/audit_docs.py >/dev/null
  python3 tools/event_review.py -o docs/event-review.md --check >/dev/null
  python3 tools/filltype_coverage.py -o docs/filltype-coverage.txt --check >/dev/null
  lua tools/test_model.lua >/dev/null
  lua tools/test_settings_menu.lua >/dev/null
  lua tools/test_forecast.lua >/dev/null )
echo "  ok — validation, audit, freshness checks and both suites pass with no game data"

VERSION=$(grep -oP '(?<=<version>)[^<]+' FS25_MarketShockwaves/modDesc.xml)
SRC_COMMIT=$(git rev-parse --short HEAD)

if [ "$MODE" = init ]; then
    echo "== creating the initial squashed commit =="
    ( cd "$DEST" && git init -q -b main )
    SUBJECT="Market Shockwaves $VERSION"
    BODY="A global economy mod for Farming Simulator 25. Market events move prices
along a curve that builds, holds and corrects when the new harvest lands, and
those shocks ripple down the production chain.

17 events across 6 categories, an in-game settings menu, mutual exclusion of
mirrored events, and savegame persistence. Singleplayer.

Licensed CC BY-NC-ND 4.0. Ships no GIANTS game data and edits no fillTypes.xml.

Squashed from the private development repository at $SRC_COMMIT; that history is
not published because it contains third-party reference material used during
development."
else
    echo "== committing on top of the published history =="
    SUBJECT="Release $VERSION"
    BODY="Snapshot of the private development repository at $SRC_COMMIT.

Built and verified before publishing: config validation, documentation audit,
and both offline test suites."
fi

( cd "$DEST"
  git add -A
  if git diff --cached --quiet; then
      echo "  nothing changed since the last publish — no commit made"
  else
      git -c user.name="Tony_Carboni" -c user.email="toon.budeners@gmail.com" \
          commit -q -m "$SUBJECT" -m "$BODY"
      echo "  committed: $SUBJECT"
  fi )

if [ "$MODE" = update ]; then
cat <<EOF

Public tree updated: $DEST
  version $VERSION, from $SRC_COMMIT
  $(cd "$DEST" && git ls-files | wc -l) files

To publish:

  cd "$DEST"
  git push origin main          # a normal push; history is not rewritten

Then cut the release. Either tag it:

  git tag v$VERSION
  git push origin v$VERSION

or, if pushing a tag ref is not available, run the release workflow manually with
version $VERSION — it creates the tag itself at the commit being built:

  Actions -> release -> Run workflow -> version = $VERSION

The download page stays the same, so KingMods never needs updating:
  https://github.com/Tony-carboni/FS25_MarketShockwaves/releases
EOF
else
cat <<EOF

Public tree ready: $DEST
  version $VERSION, squashed from $SRC_COMMIT
  $(cd "$DEST" && git ls-files | wc -l) files

To publish:

  1. Create an EMPTY PUBLIC repo named FS25_MarketShockwaves on GitHub.
     No README, no licence, no .gitignore — this tree has all three, and
     GitHub's versions would collide on the first push.

  2. cd "$DEST"
     git remote add origin git@github.com:Tony-carboni/FS25_MarketShockwaves.git
     git push -u origin main

  3. Tag it, which triggers .github/workflows/release.yml to build and attach
     FS25_MarketShockwaves.zip as a pre-release:

     git tag v$VERSION
     git push origin v$VERSION

  4. The download link for KingMods is then:
     https://github.com/Tony-carboni/FS25_MarketShockwaves/releases

     NOT .../releases/latest/download/... — GitHub's "latest" EXCLUDES
     prereleases, so that 404s while the beta is marked as one. The
     /releases index always lists the newest first, prerelease included,
     and never needs changing between versions.

From now on this script runs in UPDATE mode against that clone: it commits on top
rather than re-initialising, so no release ever rewrites public history.
EOF
fi
