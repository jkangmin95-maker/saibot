#!/bin/sh
# Rebuild public/app.css after changing classes in public/index.html.
# Tailwind 3.4.17 — same version previously loaded from the Play CDN.
set -e
cd "$(dirname "$0")/.."
npx --yes tailwindcss@3.4.17 \
  -c scripts/tailwind.app.config.js \
  -i scripts/app.tailwind.css \
  -o public/app.css \
  --minify
