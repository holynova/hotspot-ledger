#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTFOLIO_DIR="${1:?Pass a clean portfolio checkout containing the committed hotspot-ledger/ site}"
[[ "$(git -C "$PORTFOLIO_DIR" branch --show-current)" == master ]]
[[ -z "$(git -C "$PORTFOLIO_DIR" status --porcelain --untracked-files=no)" ]]
diff -qr "$ROOT/site" "$PORTFOLIO_DIR/hotspot-ledger"
# Publish the tracked portfolio tree, matching the currently deployed root site.
# Do not implicitly include the unrelated, unpublished 6.8 GB gallery build.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
git -C "$PORTFOLIO_DIR" archive HEAD | tar -x -C "$STAGE"
cd "$PORTFOLIO_DIR"
npx --yes wrangler@4.128.0 deploy --config wrangler.jsonc --assets "$STAGE"
