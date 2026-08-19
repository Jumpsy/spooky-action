"""Permissions, walked through — not recited.

The usual advice is a paragraph: "go to System Settings, then Privacy &
Security, then Accessibility, find your terminal, tick it, restart it." That
paragraph is where most installs die.

So this does not give directions. It opens the exact pane, names the one row to
tick, waits, and then *proves* the permission took by using it for real. If it
did not take, it says so and stays on that pane. Only when a permission
actually works does it move on.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass

from spooky import hands, pointer

PANE = "x-apple.systempreferences:com.apple.preference.security?"

TERMINAL_NAMES = {
    "Apple_Terminal": "Terminal",
    "iTerm.app": "iTerm",
    "vscode": "Visual Studio Code (or Code Helper)",
    "ghostty": "Ghostty",
    "WarpTerminal": "Warp",
    "Hyper": "Hyper",
    "WezTerm": "WezTerm",
    "Alacritty": "Alacritty",
    "kitty": "kitty",
}


def host_app() -> str:
    """Which app the user has to tick. Naming it removes the only real guesswork."""
    tp = os.environ.get("TERM_PROGRAM", "")
    if tp in TERMINAL_NAMES:
        return TERMINAL_NAMES[tp]
    if tp:
        return tp.replace("_", " ")
    return "your terminal app"


def open_pane(anchor: str) -> bool:
    try:
        subprocess.run(["open", PANE + anchor], capture_output=True, timeout=15)
        return True
    except Exception:
        return False


# ------------------------------------------------------------------ the tests

def test_accessibility() -> tuple[bool, str]:
    """Ask the accessibility layer itself. It is the thing being granted."""
    try:
        out = hands.run("trusted")
    except Exception as exc:
        return False, str(exc)[:160]
    if out.get("trusted"):
        return True, "the accessibility layer answers"
    return False, "macOS is not letting this process read the screen's contents"


def test_pointer() -> tuple[bool, str]:
    """Optional. Only needed for the things nothing exposes to press.

    Retried, not sampled once. macOS silently drops a cursor warp that follows
    too soon after another — cliclick still exits 0, the pointer just does not
    move. Believing that would report "denied" for a permission already granted
    and send someone to a pane with nothing to do on it, which is exactly the
    experience this module exists to remove.
    """
    if not pointer.available():
        return False, "cliclick is not installed (brew install cliclick)"
    try:
        start = pointer.where()
        if not start:
            return False, "could not read the cursor position"
        # A big step, not a small one. macOS coalesces a warp of a few pixels
        # into nothing at all — cliclick still exits 0 and the pointer never
        # moves, which reads as "permission denied" for a permission that is
        # perfectly fine. Sixty pixels always lands.
        step = -60 if start[0] > 300 else 60
        target = start[0] + step
        moved = False
        for _ in range(3):
            pointer._cliclick([f"m:{pointer._at(target, start[1])}"])
            for _ in range(6):
                time.sleep(0.12)
                now = pointer.where()
                if now and abs(now[0] - target) <= 1:
                    moved = True
                    break
            if moved:
                break
            time.sleep(0.35)      # let the suppression window lapse, then retry
        pointer._cliclick([f"m:{pointer._at(*start)}"])
        return (True, "moved the pointer and put it back") if moved else \
               (False, "the pointer did not move")
    except Exception as exc:
        return False, str(exc)[:160]


def test_swift() -> tuple[bool, str]:
    if shutil.which("swiftc"):
        return True, "swiftc is here"
    return False, "no swiftc — run `xcode-select --install`"


@dataclass
class Step:
    key: str
    title: str
    anchor: str
    why: str
    action: str
    test: object
    optional: bool = False

    def check(self) -> tuple[bool, str]:
        return self.test()


def steps() -> list[Step]:
    app = host_app()
    return [
        Step(
            key="accessibility",
            title="Accessibility",
            anchor="Privacy_Accessibility",
            why="this is the whole thing — it lets Spooky read what is on screen "
                "and press it, without going anywhere near your cursor",
            action=f"In the list that just opened, switch ON the row for “{app}”. "
                   f"If it is not listed, click + and add it.",
            test=test_accessibility,
        ),
        Step(
            key="pointer",
            title="Real clicks (optional)",
            anchor="Privacy_Accessibility",
            why="only for the handful of things that expose nothing to press — a "
                "canvas, a game, an old Java app. Skip it and everything else "
                "still works",
            action=f"Same pane, same row for “{app}”. If it is already on, this "
                   f"just needs `brew install cliclick`.",
            test=test_pointer,
            optional=True,
        ),
    ]


def status() -> dict:
    """What is granted right now, without touching anything."""
    out = []
    for s in steps():
        ok, detail = s.check()
        out.append({"key": s.key, "title": s.title, "granted": ok, "detail": detail,
                    "why": s.why, "optional": s.optional})
    return {"app": host_app(),
            "all_granted": all(x["granted"] for x in out if not x["optional"]),
            "permissions": out}


def restart_hint(app: str) -> str:
    return (f"macOS only applies this to programs started *after* you tick it. "
            f"Quit {app} completely (⌘Q, not just the window) and open it again, "
            f"then run `spooky setup` — it picks up where it left off.")
