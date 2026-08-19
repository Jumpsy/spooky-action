#!/usr/bin/env bash
# The parts of a GitHub repo that live outside the files.
#
# Description, topics, homepage and social preview are what GitHub search and
# every link unfurl actually read — and none of them are in git. Run this once
# after the repo exists, and again whenever the pitch changes.
#
#   gh auth login && ./.github/repo-settings.sh

set -euo pipefail
repo="${1:-Jumpsy/spooky-action}"

gh repo edit "$repo" \
  --description "Computer use on a Mac for any AI agent. It presses the button, not a pixel — through the accessibility layer, so your cursor never moves. Watch it work, and take the screen back by moving your mouse." \
  --homepage "https://jumpsy.github.io/spooky-action/" \
  --enable-issues --enable-discussions --enable-wiki=false

# Topics are GitHub's own keywords. Twenty is the cap; these are the twenty
# somebody would actually type when looking for this.
gh repo edit "$repo" \
  --add-topic macos \
  --add-topic computer-use \
  --add-topic ai-agent \
  --add-topic accessibility \
  --add-topic accessibility-api \
  --add-topic automation \
  --add-topic desktop-automation \
  --add-topic gui-automation \
  --add-topic claude \
  --add-topic claude-code \
  --add-topic anthropic \
  --add-topic llm-agent \
  --add-topic agentic-ai \
  --add-topic mcp \
  --add-topic swift \
  --add-topic python \
  --add-topic cli \
  --add-topic macos-automation \
  --add-topic human-in-the-loop \
  --add-topic ai-safety

# GitHub Pages, served straight out of docs/ on main.
gh api -X POST "repos/$repo/pages" \
  -f "source[branch]=main" -f "source[path]=/docs" 2>/dev/null ||
  gh api -X PUT "repos/$repo/pages" -f "source[branch]=main" -f "source[path]=/docs"

# IndexNow — tells Bing, Yandex and the rest that the page exists. No account,
# no dashboard; the key file next to the site is the whole proof of ownership.
key=$(ls docs/*.txt 2>/dev/null | grep -E '/[0-9a-f]{32}\.txt$' | head -1)
if [ -n "$key" ]; then
  name=$(basename "$key" .txt)
  curl -sS -X POST https://api.indexnow.org/indexnow \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d '{"host":"jumpsy.github.io","key":"'"$name"'",
         "keyLocation":"https://jumpsy.github.io/spooky-action/'"$name"'.txt",
         "urlList":["https://jumpsy.github.io/spooky-action/"]}' \
    -o /dev/null -w '  indexnow: %{http_code}\n'
fi

echo
echo "  One thing left, and it needs a browser — GitHub has no API for it:"
echo "    · Settings → Social preview → upload docs/img/og.jpg"
echo
echo "  Google Search Console is already verified for jumpsy.github.io via"
echo "  docs/google470bab5cdf5e9d3a.html. Do not delete that file. If you"
echo "  forked this, replace it with your own and submit sitemap.xml there."
echo
