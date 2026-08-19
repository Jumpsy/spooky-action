#!/usr/bin/env bash
# Spooky Action — the exit. One command, and it is like it was never here.
#
# Uninstallers usually leave three things behind: a state directory nobody
# mentions, a symlink on your PATH, and a permission still ticked in System
# Settings. This removes all three, tells you exactly what it removed, and
# opens the settings pane for the one part macOS will not let a script do.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
home="${SPOOKY_HOME:-$HOME/.spooky}"
link="$HOME/.local/bin/spooky"
skill="$HOME/.claude/skills/spooky-action"

yes=0
for a in "$@"; do [ "$a" = "--yes" ] || [ "$a" = "-y" ] && yes=1; done

say()  { printf '\n  %s\n' "$*"; }
gone() { printf '  ✓ removed %s\n' "$*"; }
kept() { printf '  · %s\n' "$*"; }

say "Removing Spooky Action."
printf '\n  This will delete:\n'
[ -d "$home"      ] && printf '    %s\n' "$home  (settings, logs, built binaries)"
[ -d "$here/.venv" ] && printf '    %s\n' "$here/.venv"
[ -L "$link"      ] && printf '    %s\n' "$link"
[ -L "$skill"     ] && printf '    %s\n' "$skill  (the Claude Code skill)"
printf '    the overlay, if it is running\n'
printf '\n  It will NOT touch this folder itself, or anything you made with it.\n'

if [ "$yes" -eq 0 ]; then
  printf '\n  Go ahead? [y/N] '
  # /dev/tty exists even with no controlling terminal — it just fails to open —
  # so try the read itself rather than testing the file, and fall back to stdin
  # instead of hanging when there is no terminal at all.
  reply=""
  read -r reply 2>/dev/null < /dev/tty || read -r reply 2>/dev/null || reply=""
  case "$reply" in [yY]*) ;; *) say "Left everything alone."; exit 0 ;; esac
fi

echo ""

# ------------------------------------------------------------- stop it first
# Before deleting the binary out from under a running process, which leaves a
# glow on screen and nothing to turn it off with.
if [ -f "$home/control.json" ]; then
  pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$home/control.json" | head -1)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null && sleep 0.4
    kill -9 "$pid" 2>/dev/null
    gone "the running overlay"
  fi
fi
pkill -f 'spooky-presence' 2>/dev/null && gone "a stray overlay process"
pkill -f 'spooky-hands'    2>/dev/null && gone "a stray helper process"

# ------------------------------------------------------------------ the files
if [ -d "$home" ]; then rm -rf "$home" && gone "$home"; fi
if [ -L "$link" ]; then
  points_at="$(readlink "$link")"
  case "$points_at" in
    "$here"/*) rm -f "$link" && gone "$link" ;;
    *) kept "left $link alone — it points at $points_at, not this folder" ;;
  esac
elif [ -e "$link" ]; then
  kept "left $link alone — it is a real file, not our symlink"
fi
if [ -L "$skill" ]; then
  points_at="$(readlink "$skill")"
  case "$points_at" in
    "$here"/*) rm -f "$skill" && gone "$skill" ;;
    *) kept "left $skill alone — it points at $points_at, not this folder" ;;
  esac
elif [ -e "$skill" ]; then
  kept "left $skill alone — it is a real directory, not our symlink"
fi

if [ -d "$here/.venv" ]; then rm -rf "$here/.venv" && gone "$here/.venv"; fi

# Deliberately not running `pip3 uninstall` against your system Python. Ours
# lived in the venv above and is already gone; reaching any further could
# remove a copy somebody else installed on purpose. If you pip-installed it
# somewhere yourself, that is yours to remove.

# ------------------------------------------------------------- the permission
say "One thing a script cannot undo for you: the macOS permission."
echo "  Opening the pane now — switch OFF (or select and press −) the row for"
echo "  your terminal app, if nothing else you use needs it."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null

say "Done. To remove the last of it:"
printf '\n      rm -rf "%s"\n\n' "$here"
