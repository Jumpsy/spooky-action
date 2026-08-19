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

echo
echo "  Two things left, both of which need a browser:"
echo "    · Settings → Social preview → upload docs/img/og.jpg"
echo "    · Submit https://jumpsy.github.io/spooky-action/sitemap.xml"
echo "      to Google Search Console and Bing Webmaster Tools"
echo
