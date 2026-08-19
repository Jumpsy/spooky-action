"""Everything about how this looks and behaves, in one editable file.

The point is that changing it is a sentence, not a pull request. "Make the
borders yellow" should end with yellow borders about four seconds later, and
the running overlay should pick it up without being restarted — it watches
this file's timestamp and reloads.

Values live in ~/.spooky/config.json. Anything absent falls back to the
default here, so a hand-edited file with one key in it is perfectly valid.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from spooky import presence

COLOURS = ("yellow", "amber", "blue", "green", "red", "purple", "pink", "orange", "white")


@dataclass(frozen=True)
class Setting:
    key: str
    default: object
    kind: str          # colour | number | bool | choice
    blurb: str
    choices: tuple = ()


SETTINGS: tuple[Setting, ...] = (
    Setting("accent", "yellow", "colour",
            "Border, pointer and HUD colour while the agent is acting."),
    Setting("user_accent", "blue", "colour",
            "The colour it changes to the moment you take the screen back."),
    Setting("wash", 0.055, "number",
            "How strongly the whole screen is tinted, 0 to 0.4. Set 0 for edges only."),
    Setting("glow", True, "bool", "Draw the screen-edge glow at all."),
    Setting("pointer", True, "bool",
            "Draw the agent's pointer gliding to whatever it is about to press."),
    Setting("glide_seconds", 0.34, "number",
            "How long the pointer takes to travel. Raise it to follow along more easily."),
    Setting("idle_seconds", 2.0, "number",
            "How still you have to be before the agent gets the screen back."),
    Setting("linger_seconds", 1.4, "number",
            "How long the glow stays up after the last action, so a burst reads as one thing."),
    Setting("hud", "top", "choice",
            "Where the control bar sits when it is not pinned.",
            ("top", "bottom", "left", "right")),
    Setting("max_seconds", 14400.0, "number",
            "Hard stop for the overlay, so an orphaned one cannot glow all night."),
)



def path() -> Path:
    return presence.home() / "config.json"


def config() -> dict:
    """Stored values merged over the defaults."""
    out = {s.key: s.default for s in SETTINGS}
    try:
        out.update(json.loads(path().read_text()))
    except (OSError, ValueError):
        pass
    return out


def by_key(key: str) -> Setting:
    """Look one up by name. Raises KeyError with the near misses, because a
    typo is the common case and a bare KeyError does not help anyone fix it."""
    for s in SETTINGS:
        if s.key == key:
            return s
    close = [s.key for s in SETTINGS if key[:3] in s.key or s.key[:3] in key]
    raise KeyError(f"no setting called {key!r}"
                   + (f" — did you mean {', '.join(close)}?" if close else ""))


def coerce(setting: Setting, raw: object) -> object:
    """Turn whatever was typed on a command line into the right type.

    Being liberal here is deliberate — "yes", "on" and "true" all clearly mean
    the same thing, and refusing two of them teaches nothing.
    """
    if setting.kind == "bool":
        if isinstance(raw, bool):
            return raw
        if str(raw).lower() in ("1", "true", "yes", "on"):
            return True
        if str(raw).lower() in ("0", "false", "no", "off"):
            return False
        raise ValueError(f"{setting.key} is on or off, not {raw!r}")
    if setting.kind == "number":
        try:
            return float(raw)
        except (TypeError, ValueError):
            raise ValueError(f"{setting.key} takes a number, not {raw!r}") from None
    if setting.kind == "choice":
        if str(raw).lower() not in setting.choices:
            raise ValueError(f"{setting.key} is one of {', '.join(setting.choices)}")
        return str(raw).lower()
    if setting.kind == "colour":
        text = str(raw).strip().lower()
        if text in COLOURS:
            return text
        hexpart = text[1:] if text.startswith("#") else text
        if len(hexpart) == 6 and all(c in "0123456789abcdef" for c in hexpart):
            return "#" + hexpart
        raise ValueError(
            f"{raw!r} is not a colour I know — use one of {', '.join(COLOURS)} or a hex like #ffcc00"
        )
    return raw


def set_values(pairs: dict) -> dict:
    """Write settings and let the running overlay notice. Unknown keys are an
    error rather than a silent no-op, because a typo that does nothing is
    worse than one that complains."""
    current = {}
    try:
        current = json.loads(path().read_text())
    except (OSError, ValueError):
        pass
    for key, raw in pairs.items():
        current[key] = coerce(by_key(key), raw)
    path().write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
    return config()


def reset() -> dict:
    path().unlink(missing_ok=True)
    return config()
