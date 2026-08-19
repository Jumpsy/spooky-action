"""The fallback that does borrow your cursor — and says so every time.

Almost everything on a Mac can be pressed through the accessibility layer
without a cursor going anywhere. Almost. A canvas, a game, a custom-drawn view,
a Java app from 2009 — these expose nothing to press, and the only way in is a
real click at a real coordinate, which means moving your actual pointer.

So this exists, and it is deliberately the awkward path: you have to ask for it
by name, it announces itself, it puts your pointer back where it found it, and
every result it hands back says `cursor_touched: true`. The moment a tool stops
distinguishing between "I pressed the button" and "I took your mouse", the
person watching stops being able to trust either.
"""
from __future__ import annotations

import shutil
import subprocess

from spooky import presence


class NoPointer(Exception):
    """cliclick is missing, or macOS has not granted the permission."""

    def __init__(self, message: str, hint: str = ""):
        super().__init__(message)
        self.hint = hint


def available() -> bool:
    return shutil.which("cliclick") is not None


def _cliclick(args: list[str]) -> str:
    if not available():
        raise NoPointer(
            "cliclick is not installed",
            "brew install cliclick — it is the only way to reach things the "
            "accessibility layer cannot see",
        )
    p = subprocess.run(["cliclick", *args], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise NoPointer(
            f"cliclick failed: {(p.stderr or p.stdout).strip()[:160]}",
            "run `spooky setup` — if this is a permissions problem it opens the "
            "right pane and checks that the fix took",
        )
    return p.stdout.strip()


def _at(x: int, y: int) -> str:
    """Format a coordinate pair the way cliclick actually reads them.

    cliclick treats a leading "-" as *relative*: `m:-60,500` moves the pointer
    sixty pixels left of wherever it happens to be, not to x = -60. On a single
    display that never comes up, because there are no negative coordinates. Put
    a second display to the left of the main one and every x on it is negative —
    so every click lands somewhere else, and each one drifts further, until the
    pointer is thousands of pixels off any screen. The "=" prefix is cliclick's
    own way of saying "this negative number is absolute".
    """
    fmt = lambda v: f"={v}" if v < 0 else str(v)
    return f"{fmt(x)},{fmt(y)}"


def where() -> tuple[int, int] | None:
    try:
        x, y = _cliclick(["p"]).split(",")[:2]
        return int(x), int(y)
    except NoPointer:
        raise
    except Exception:
        return None


def click(x: int, y: int, *, button: str = "left", double: bool = False,
          put_back: bool = True, label: str = "") -> dict:
    """Click at a coordinate with the real cursor, then put it back.

    `put_back` matters more than it looks. Someone who left their pointer over
    a tooltip, a hover menu, a drop target, comes back to a screen that reads
    the same as they left it.
    """
    verb = {"left": "dc" if double else "c", "right": "rc", "middle": "mc"}.get(button, "c")
    with presence.hold(label or f"clicking at {x},{y} — borrowing your cursor"):
        presence.point_to(x, y, label=label or "real click", click=True)
        origin = where() if put_back else None
        _cliclick([f"{verb}:{_at(x, y)}"])
        if origin and origin != (x, y):
            _cliclick([f"m:{_at(*origin)}"])
    return {"action": "click", "at": [x, y], "button": button, "double": double,
            "cursor_touched": True, "cursor_restored": bool(put_back)}


def move(x: int, y: int) -> dict:
    with presence.hold(f"moving to {x},{y}"):
        presence.point_to(x, y, label="move")
        _cliclick([f"m:{_at(x, y)}"])
    return {"action": "move", "at": [x, y], "cursor_touched": True}


def drag(x1: int, y1: int, x2: int, y2: int) -> dict:
    with presence.hold("dragging"):
        presence.point_to(x1, y1, label="drag from")
        _cliclick([f"dd:{_at(x1, y1)}"])
        presence.point_to(x2, y2, label="drag to")
        _cliclick([f"du:{_at(x2, y2)}"])
    return {"action": "drag", "from": [x1, y1], "to": [x2, y2], "cursor_touched": True}


def type_text(text: str) -> dict:
    """Type real keystrokes into whatever is focused.

    Needed for editors that only respond to keys — a code editor will ignore a
    value handed to it through the accessibility layer and keep whatever was
    there. This does not move the pointer, but it does go wherever focus is,
    so it is worth being sure about focus first.
    """
    with presence.hold(f"typing {len(text)} characters"):
        _cliclick([f"t:{text}"])
    return {"action": "type", "chars": len(text), "cursor_touched": False,
            "went_to": "whatever had keyboard focus"}


def key(name: str, *, times: int = 1) -> dict:
    with presence.hold(f"pressing {name}"):
        for _ in range(max(1, times)):
            _cliclick([f"kp:{name}"])
    return {"action": "key", "key": name, "times": times, "cursor_touched": False}


def scroll(amount: int) -> dict:
    with presence.hold(f"scrolling {amount}"):
        _cliclick([f"w:{amount}"])
    return {"action": "scroll", "amount": amount, "cursor_touched": False}
