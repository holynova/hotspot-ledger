#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTFOLIO_DIR="${1:?Pass the clean portfolio checkout containing the committed hotspot-ledger/ site}"
[[ "$(git -C "$PORTFOLIO_DIR" branch --show-current)" == master ]]
[[ -z "$(git -C "$PORTFOLIO_DIR" status --porcelain --untracked-files=no)" ]]
diff -qr "$ROOT/site" "$PORTFOLIO_DIR/hotspot-ledger"
cd "$PORTFOLIO_DIR"
node scripts/stage-cloudflare.mjs "${GALLERY_DIST:?Set GALLERY_DIST to the verified xiaosang-gallery production dist}"
npx --yes wrangler@4.128.0 deploy --config wrangler.jsonc
