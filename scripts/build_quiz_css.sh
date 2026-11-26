#!/bin/sh
# Rebuild public/quiz.css after changing classes in public/quiz.html.
# Same Tailwind version as app.css (3.4.17); compiled so quiz.html loads no third-party script.
set -e
cd "$(dirname "$0")/.."
npx --yes tailwindcss@3.4.17 -i scripts/quiz.tailwind.css -o public/quiz.css --content ./public/quiz.html --minify
