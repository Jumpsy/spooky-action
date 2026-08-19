"""The agent's own mouse and keyboard — which are neither, and that is why it
works.

Nothing here moves your cursor or synthesises a click. Every action goes
through the macOS accessibility layer: the button is asked to press itself,
the text field is handed its new value. Your pointer stays where you left it,
in whatever window you were using, and the two of you can work at the same
time without fighting over one mouse.

What you *see* is a painted pointer gliding to the target and pulsing when it
acts. That is the honest part of the illusion: the agent really is acting
there, it just does not need a cursor to do it. Watching it travel is the
difference between following along and having things happen at you.

The Swift binary next door does the accessibility work. This module is the
part that makes it visible, checks who owns the screen first, and falls back
gracefully when an app has no accessibility support worth the name.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from spooky import presence

BINARY = "spooky-hands"
SOURCE = Path(__file__).parent / "overlay" / "Hands.swift"


def binary() -> Path:
    return presence.home() / "bin" / BINARY


def build(force: bool = False) -> Path:
    """Compile once, from source sitting right there in the repo.

    Same reasoning as the overlay: a prebuilt binary that reads your screen and
    drives your apps is exactly the thing nobody should run on trust."""
    out = binary()
    if out.exists() and not force and out.stat().st_mtime >= SOURCE.stat().st_mtime:
        return out
    if not shutil.which("swiftc"):
        raise RuntimeError(
            "swiftc is missing — run `xcode-select --install`, then try again"
        )
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-o", str(out), str(SOURCE)], check=True)
    return out


class Refused(Exception):
    """The accessibility layer said no. Carries the hint, which usually says
    what to try instead rather than just what failed."""

    def __init__(self, payload: dict):
        self.payload = payload
        super().__init__(payload.get("error", "refused"))

    @property
    def hint(self) -> str:
        return self.payload.get("hint", "")


def run(*args: str) -> dict:
    proc = subprocess.run([str(build()), *args], capture_output=True, text=True, timeout=60)
    try:
        out = json.loads(proc.stdout or "{}")
    except ValueError:
        raise Refused({"error": proc.stderr.strip() or "the accessibility helper said nothing"})
    if not out.get("ok", False):
        raise Refused(out)
    return out


# --------------------------------------------------------------------------
# looking


def apps() -> list[dict]:
    return run("apps")["apps"]


def tree(app: str, *, window: int | None = None, limit: int = 500) -> dict:
    args = ["tree", "--app", app, "--max", str(limit)]
    if window is not None:
        args += ["--window", str(window)]
    return run(*args)


def find(app: str, text: str, *, role: str | None = None) -> list[dict]:
    """Every element whose label contains `text`. The usual way in: read this,
    pick one, act on its index."""
    needle = text.lower()
    hits = []
    for el in tree(app)["elements"]:
        if role and el.get("role") != role:
            continue
        if needle in (el.get("label") or "").lower():
            hits.append(el)
    return hits


# --------------------------------------------------------------------------
# acting


def _centre(element: dict) -> tuple[float, float] | None:
    box = element.get("frame") or {}
    if not box or box.get("w", 0) <= 0:
        return None
    return box["x"] + box["w"] / 2, box["y"] + box["h"] / 2


def _show(element: dict, *, click: bool, label: str) -> None:
    if (point := _centre(element)) is None:
        return
    presence.point_to(point[0], point[1], label=label, click=click)


def press(app: str, index: int, *, expect: str | None = None,
          action: str | None = None, show: bool = True) -> dict:
    """Press an element by its index in `tree`.

    `expect` is worth passing every time. It re-checks the label before acting,
    so a window that reshuffled between reading the tree and acting on it fails
    loudly instead of pressing whatever slid into that slot.
    """
    with presence.hold(f"Pressing {expect or f'element {index}'}"):
        target = None
        if show:
            elements = tree(app)["elements"]
            if index < len(elements):
                target = elements[index]
                _show(target, click=True, label=expect or target.get("label") or "")
        args = ["press", "--app", app, "--index", str(index)]
        if expect:
            args += ["--expect", expect]
        if action:
            args += ["--action", action]
        result = run(*args)
        result["seen_at"] = _centre(target) if target else None
        return result


def type_into(app: str, index: int, text: str, *, expect: str | None = None,
              show: bool = True) -> dict:
    """Put text into a field by handing it the value directly."""
    with presence.hold(f"Typing into {expect or f'element {index}'}"):
        if show:
            elements = tree(app)["elements"]
            if index < len(elements):
                _show(elements[index], click=True,
                      label=(expect or elements[index].get("label") or "typing"))
        args = ["set", "--app", app, "--index", str(index), "--text", text]
        if expect:
            args += ["--expect", expect]
        return run(*args)


def focus(app: str, index: int | None = None) -> dict:
    args = ["focus", "--app", app]
    if index is not None:
        args += ["--index", str(index)]
    presence.touch()
    return run(*args)


def at(x: float, y: float) -> dict:
    """What is under this screen position — looked up, not pointed at."""
    return run("at", "--x", str(x), "--y", str(y))


def click_text(app: str, text: str, *, role: str | None = None) -> dict:
    """The convenient one: find a control by its label and press it.

    Refuses when the label is ambiguous rather than picking the first match —
    two buttons called "Delete" is exactly the case where guessing is worst.
    """
    hits = find(app, text, role=role)
    pressable = [h for h in hits if h.get("actions")]
    if not pressable:
        raise Refused({
            "error": f"nothing in {app} labelled {text!r} can be pressed",
            "hint": "run `spooky tree --app " + app + "` to see the real labels",
        })
    if len(pressable) > 1:
        labels = ", ".join(f"{h['index']}:{h.get('label')}" for h in pressable[:6])
        raise Refused({
            "error": f"{len(pressable)} elements in {app} match {text!r}",
            "hint": f"press one by index instead — {labels}",
        })
    return press(app, pressable[0]["index"], expect=pressable[0].get("label"))
