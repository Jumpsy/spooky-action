#!/usr/bin/env bash
# Spooky Action — clone, run this, done.
#
# Everything lands in a virtualenv inside this folder and a state directory at
# ~/.spooky. Nothing else on your machine is touched, and ./uninstall.sh
# removes both.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

say() { printf '\n  %s\n' "$*"; }
ok()  { printf '  ✓ %s\n' "$*"; }

say "Spooky Action"

if [ "$(uname)" != "Darwin" ]; then
  say "This is macOS only — it works through the macOS accessibility layer."
  exit 1
fi

# ---------------------------------------------------------------- python
python=""
for c in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$c" >/dev/null 2>&1 &&
     "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)'; then
    python="$c"; break
  fi
done
if [ -z "$python" ]; then
  say "Needs Python 3.10 or newer, and I could not find one."
  say "  brew install python@3.12"
  exit 1
fi
ok "$($python -V)"

# ---------------------------------------------------------------- venv
if [ ! -x .venv/bin/python ]; then "$python" -m venv .venv; fi
# A venv made by uv (or with --without-pip) has no pip in it. Put one there
# rather than failing, and only start over if even that will not work.
.venv/bin/python -m pip --version >/dev/null 2>&1 ||
  .venv/bin/python -m ensurepip --upgrade >/dev/null 2>&1 || true
if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  say "Rebuilding the virtualenv — the one here has no pip."
  rm -rf .venv && "$python" -m venv .venv
fi
.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet -e .
ok "spooky installed"

# ---------------------------------------------------------------- swift
# Compiled here, from the source sitting in this folder. A prebuilt binary that
# reads your screen and drives your apps is the exact thing nobody should run
# on trust — so there isn't one.
if command -v swiftc >/dev/null 2>&1; then
  .venv/bin/python -c 'from spooky import hands, presence; hands.build(); presence.build()' \
    && ok "built the accessibility helper and the overlay, from source" \
    || { say "Build failed. Try again after: xcode-select --install"; exit 1; }
else
  say "No swiftc. Run  xcode-select --install  then ./install.sh again."
  exit 1
fi

# ---------------------------------------------------------------- skill
# Claude Code reads skills out of ~/.claude/skills. A symlink rather than a
# copy, so the skill is whatever this checkout says it is — including after a
# git pull, and including gone after ./uninstall.sh.
skills="$HOME/.claude/skills"
if [ -d "$HOME/.claude" ]; then
  mkdir -p "$skills"
  target="$skills/spooky-action"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    say "Left $target alone — something is already there that is not our symlink."
  else
    ln -sfn "$here/spooky/skill" "$target"
    ok "skill linked into ~/.claude/skills — Claude Code picks it up next start"
  fi
fi

# ---------------------------------------------------------------- shortcut
mkdir -p "$HOME/.local/bin"
ln -sf "$here/.venv/bin/spooky" "$HOME/.local/bin/spooky"
ok "spooky linked into ~/.local/bin"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) say "Add this to your shell profile so \`spooky\` works anywhere:"
     printf '\n      export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac

say "Next:"
printf '\n      spooky setup     grant Accessibility — it opens the pane and checks the fix took\n'
printf '      spooky apps      what it can act on\n'
printf '      spooky doctor    what works right now\n'
printf '\n  Changed your mind? ./uninstall.sh removes all of it.\n\n'
