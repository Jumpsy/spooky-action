"""Shared control of one screen — who has it, and how each side finds out.

Two participants, one mouse, and neither should have to guess. The agent
takes the screen by holding a lock; you take it back by touching the mouse.
The moment either happens, both sides are told: you get the border and a
notification, the agent gets a refusal it can actually read instead of a
click that silently lands in the wrong window.

The important word is *instantly*. An agent that discovers it lost the screen
by looking at a screenshot afterwards has already typed into your document.
So `hold()` checks before every action and `wait_for_screen()` returns the
moment stillness gives it back, usually inside a tenth of a second.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


BINARY = "spooky-presence"
SOURCE = Path(__file__).parent / "overlay" / "Presence.swift"


def home() -> Path:
    d = Path(os.environ.get("SPOOKY_HOME", Path.home() / ".spooky"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def _f(name: str) -> Path:
    return home() / name


LOCK = "agent-input.lock"
STAMP = "agent-input.stamp"
STATE = "control.json"
EVENTS = "control-events.jsonl"
PAUSED = "paused.flag"
SESSION = "session.json"
LABEL = "label"


# --------------------------------------------------------------------------
# the daemon


def binary() -> Path:
    return home() / "bin" / BINARY


def build(force: bool = False) -> Path:
    """Compile the overlay. Takes about eight seconds, once.

    Shipping a prebuilt binary would mean shipping something unsigned that
    watches input events — reasonably, people would not run it. Building from
    the .swift file next door means anyone can read what they are about to
    trust, and swiftc is already on any Mac with the command line tools.
    """
    out = binary()
    if out.exists() and not force and out.stat().st_mtime >= SOURCE.stat().st_mtime:
        return out
    if not shutil.which("swiftc"):
        raise RuntimeError(
            "swiftc is missing — install Xcode command line tools with "
            "`xcode-select --install`, then run this again"
        )
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-o", str(out), str(SOURCE)], check=True)
    return out


def running() -> int | None:
    try:
        pid = json.loads(_f(STATE).read_text()).get("pid")
    except (OSError, ValueError):
        return None
    try:
        os.kill(int(pid), 0)
    except (OSError, TypeError, ValueError):
        return None
    return int(pid)


def start(label: str = "Spooky Action is acting", *, idle: float = 2.0) -> int:
    """Bring the overlay up. Idempotent — a second call finds the first one."""
    existing = running()
    if existing:
        return existing
    exe = build()
    _f(EVENTS).touch()
    subprocess.Popen(
        [str(exe), "--label", label, "--idle", str(idle)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    for _ in range(60):                      # it writes control.json on launch
        time.sleep(0.05)
        if running():
            break
    return running() or 0


def stop() -> bool:
    pid = running()
    if not pid:
        return False
    with contextlib.suppress(OSError):
        os.kill(pid, 15)
    return True


def state() -> dict:
    try:
        return json.loads(_f(STATE).read_text())
    except (OSError, ValueError):
        return {"holder": "idle", "paused": False, "running": False}


def paused() -> bool:
    return _f(PAUSED).exists()


# --------------------------------------------------------------------------
# who has the screen right now


@dataclass
class Verdict:
    allowed: bool
    holder: str
    message: str

    def as_dict(self) -> dict:
        return {"allowed": self.allowed, "holder": self.holder, "message": self.message}


def check() -> Verdict:
    """Ask, before acting, whether acting is allowed.

    The wording is deliberate. An agent that reads "denied" tends to retry; an
    agent that reads "the user has the screen, it comes back on its own" tends
    to wait, which is the correct behaviour and the polite one.
    """
    if paused():
        return Verdict(False, "paused",
                       "Paused from the on-screen controls. You do not have the screen "
                       "until the user presses play — do not work around it.")
    s = state()
    holder = s.get("holder", "idle")
    if holder == "user":
        return Verdict(False, "user",
                       "The user took control. Give one second — the screen comes back "
                       "automatically once they have been still.")
    return Verdict(True, holder, "The screen is yours.")


def wait_for_screen(timeout: float = 120.0, *, notify_user: bool = True) -> Verdict:
    """Block until control returns, then say so — to both sides.

    Polling at 20Hz rather than watching the file: kqueue on a file this small
    is not meaningfully faster, and this keeps the dependency list at zero.
    """
    if (first := check()).allowed:
        return first
    if notify_user and first.holder == "user":
        note("Spooky Action is waiting", "It paused mid-task and will pick up when you stop.")
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.05)
        if (v := check()).allowed:
            if notify_user:
                note("Spooky Action resumed", "Picking the task back up.")
            return v
    return Verdict(False, check().holder,
                   f"Still not mine after {timeout:.0f}s — ask the user before trying again.")


# --------------------------------------------------------------------------
# the drawn pointer
#
# The agent has no cursor — it acts through the accessibility layer, so
# nothing moves on screen unless we draw it. Which would mean buttons
# depressing themselves out of nowhere. So before each action the agent says
# where it is about to act, a painted pointer glides there, and only then does
# the action fire. You get to see it coming.


POINTER = "pointer.json"


def point_to(x: float, y: float, *, label: str = "", click: bool = False,
             settle: bool = True) -> None:
    """Send the drawn pointer to a screen position, in Quartz coordinates.

    `settle` waits out the glide so the caller can act *after* the pointer has
    visibly arrived. Skipping the wait is what makes an agent look like it is
    clicking in one place while pointing at another.
    """
    payload = {"x": float(x), "y": float(y), "label": label[:60],
               "action": "click" if click else "move", "at": time.time()}
    tmp = _f(POINTER + ".tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(_f(POINTER))
    if settle:
        time.sleep(glide_seconds() + (0.18 if click else 0.04))


def hide_pointer() -> None:
    tmp = _f(POINTER + ".tmp")
    tmp.write_text(json.dumps({"action": "hide", "at": time.time()}))
    tmp.replace(_f(POINTER))


def glide_seconds() -> float:
    """However long the user has told the pointer to take."""
    try:
        return float(json.loads((home() / "config.json").read_text())
                     .get("glide_seconds", 0.34))
    except (OSError, ValueError, TypeError):
        return 0.34


def note(title: str, body: str) -> None:
    """A real Notification Centre banner. Best effort; never fatal."""
    script = f'display notification {json.dumps(body)} with title {json.dumps(title)}'
    with contextlib.suppress(Exception):
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=5)


def events(since: float = 0.0, limit: int = 50) -> list[dict]:
    """Every handover, newest last. What the agent reads to narrate itself."""
    try:
        lines = _f(EVENTS).read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in lines[-500:]:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("at", 0) > since:
            out.append(e)
    return out[-limit:]


# --------------------------------------------------------------------------
# holding the screen


# --------------------------------------------------------------------------
# a run, which the agent opens and closes itself
#
# One press is not a task. An agent filling in a form does a dozen of them
# with thinking in between, and if the glow tracked each one it would blink
# on and off all the way down the form — which looks like a fault, and teaches
# you to stop looking at it. So the agent says when it starts and when it is
# done, and the screen shows one continuous run in between.
#
# The run does not weaken the handover. It keeps the glow up; the lock, which
# is the thing that decides whether a movement was yours, is still taken and
# released around each individual action. Touch the mouse mid-run and it is
# your screen that instant.


def begin(label: str = "Spooky Action is working", *, seconds: float = 900.0,
          wait: bool = True) -> Verdict:
    """Open a run. Pair it with `end()` — or let the expiry close it for you."""
    start(label)
    verdict = wait_for_screen() if wait else check()
    if not verdict.allowed:
        raise PermissionError(verdict.message)
    payload = {"label": label[:60], "until": time.time() + seconds,
               "pid": os.getpid(), "at": time.time()}
    tmp = _f(SESSION + ".tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(_f(SESSION))
    set_label(label)
    return verdict


def session() -> dict | None:
    """The open run, if there is one and it has not expired."""
    try:
        s = json.loads(_f(SESSION).read_text())
    except (OSError, ValueError):
        return None
    return s if float(s.get("until", 0)) > time.time() else None


def end() -> bool:
    """Close the run and give the screen back. Safe to call twice."""
    was = session() is not None
    for name in (SESSION, LOCK):
        _f(name).unlink(missing_ok=True)
    _f(STAMP).touch()
    set_label("")
    return was


def set_label(text: str) -> None:
    """Retitle the pill mid-run, so it says what is happening now."""
    _f(LABEL).write_text(text[:60])


@contextlib.contextmanager
def run_session(label: str = "Spooky Action is working", *, seconds: float = 900.0):
    """`begin` and `end` as a block, for callers that can hold one."""
    begin(label, seconds=seconds)
    try:
        yield
    finally:
        end()


@contextlib.contextmanager
def hold(label: str = "Spooky Action is acting", *, seconds: float = 30.0, wait: bool = True):
    """Take the screen for one batch of actions, and give it straight back.

    Everything inside this block is marked as the agent's own, which is what
    keeps the agent's own clicks from being mistaken for a human hand. The
    lock carries an expiry rather than being released purely on exit, so a
    crashed agent cannot leave the screen locked — the worst case is that the
    glow stays up for `seconds` and then clears itself.
    """
    if session() is None:
        start(label)
        set_label(label)
    verdict = wait_for_screen() if wait else check()
    if not verdict.allowed:
        raise PermissionError(verdict.message)

    lock, stamp = _f(LOCK), _f(STAMP)
    lock.write_text(str(time.time() + seconds))
    stamp.touch()
    try:
        yield verdict
    finally:
        with contextlib.suppress(OSError):
            lock.unlink()
        stamp.touch()          # keeps the last action from looking like a hand


def touch() -> None:
    """Mark a single action outside a batch as the agent's own.

    Brings the overlay up first. The stamp only decides *who* an action
    belonged to; without something on screen to colour, marking it changes
    nothing anyone can see.
    """
    start()
    _f(STAMP).touch()
