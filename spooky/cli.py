"""Spooky Action, at the command line."""
from __future__ import annotations

import json
import subprocess
import sys
import time

import click

from spooky import __version__, hands, permissions, pointer, presence, settings

EXIT_NEEDS_YOU = 75          # not a failure — a handoff


def _out(data: dict, as_json: bool, line: str = "") -> None:
    click.echo(json.dumps(data, indent=2) if as_json else (line or json.dumps(data)))


def _refused(exc: Exception, as_json: bool) -> None:
    payload = getattr(exc, "payload", None) or {"error": str(exc)}
    hint = payload.get("hint") or getattr(exc, "hint", "") or ""
    if as_json:
        click.echo(json.dumps({"status": "needs_you", "reason": payload.get("error", str(exc)),
                               "what_to_do": hint}, indent=2))
    else:
        click.echo(f"\n  {payload.get('error', exc)}")
        if hint:
            click.echo(f"  → {hint}")
        click.echo("")
    sys.exit(EXIT_NEEDS_YOU)


@click.group(context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(__version__, prog_name="spooky")
def main() -> None:
    """Give an AI agent hands on your Mac — without giving it your mouse."""


# --------------------------------------------------------------------- seeing

@main.command()
@click.option("--json", "as_json", is_flag=True)
def apps(as_json):
    """What it can act on right now."""
    try:
        rows = hands.apps()
    except Exception as exc:
        _refused(exc, as_json)
    if as_json:
        click.echo(json.dumps(rows, indent=2))
        return
    click.echo("")
    for a in rows:
        mark = "●" if a.get("frontmost") else " "
        click.echo(f"  {mark} {a['name']:<28} {a['windows']} window(s)")
    click.echo("")


@main.command()
@click.argument("app")
@click.option("--window", type=int, help="Which window, if not the focused one.")
@click.option("--max", "limit", type=int, default=500)
@click.option("--json", "as_json", is_flag=True)
def tree(app, window, limit, as_json):
    """What is on screen in an app, with the index for acting on each thing."""
    try:
        out = hands.tree(app, window=window, limit=limit)
    except Exception as exc:
        _refused(exc, as_json)
    if as_json:
        click.echo(json.dumps(out, indent=2))
        return
    click.echo(f"\n  {out['app']} — {out['window']} ({out['count']} elements)\n")
    for el in out["elements"]:
        acts = ",".join(a.replace("AX", "") for a in el.get("actions", []))
        click.echo(f"  {el['index']:>3}  {el['role'].replace('AX',''):<16} "
                   f"{(el.get('label') or '')[:44]:<46} {acts}")
    click.echo("")


@main.command()
@click.argument("app")
@click.argument("text")
@click.option("--role", help="Narrow to one role, e.g. AXButton.")
@click.option("--json", "as_json", is_flag=True)
def find(app, text, role, as_json):
    """Search an app's screen for something by label."""
    try:
        out = hands.find(app, text, role=role)
    except Exception as exc:
        _refused(exc, as_json)
    if as_json:
        click.echo(json.dumps(out, indent=2))
        return
    click.echo("")
    for el in out:
        click.echo(f"  {el['index']:>3}  {el['role'].replace('AX',''):<16} {el.get('label') or ''}")
    click.echo("" if out else "  nothing matched\n")


# --------------------------------------------------------------------- acting

@main.command()
@click.argument("app")
@click.argument("index", type=int)
@click.option("--expect", help="The label it should still have. Pass it — it is the safety net.")
@click.option("--action", help="A specific AX action, if not the default press.")
@click.option("--json", "as_json", is_flag=True)
def press(app, index, expect, action, as_json):
    """Press something by index. The pointer glides there first, so you see it."""
    try:
        out = hands.press(app, index, expect=expect, action=action)
    except Exception as exc:
        _refused(exc, as_json)
    _out(out, as_json, f"  ✓ pressed {out.get('label') or out.get('role')} "
                       f"— your cursor did not move")


@main.command("type")
@click.argument("app")
@click.argument("index", type=int)
@click.argument("text")
@click.option("--expect")
@click.option("--json", "as_json", is_flag=True)
def type_cmd(app, index, text, expect, as_json):
    """Put text into a field by handing it the value."""
    try:
        out = hands.type_into(app, index, text, expect=expect)
    except Exception as exc:
        _refused(exc, as_json)
    _out(out, as_json, f"  ✓ {out.get('chars', len(text))} characters in")


@main.command()
@click.argument("app")
@click.argument("label")
@click.option("--role")
@click.option("--json", "as_json", is_flag=True)
def click_cmd(app, label, role, as_json):
    """Press the thing with this label — if exactly one thing has it."""
    try:
        out = hands.click_text(app, label, role=role)
    except Exception as exc:
        _refused(exc, as_json)
    _out(out, as_json, f"  ✓ pressed {out.get('label')}")


main.add_command(click_cmd, name="click")


@main.command()
@click.argument("app")
@click.option("--index", type=int, help="Also focus one element inside it.")
@click.option("--json", "as_json", is_flag=True)
def focus(app, index, as_json):
    """Bring an app forward."""
    try:
        out = hands.focus(app, index=index)
    except Exception as exc:
        _refused(exc, as_json)
    _out(out, as_json, f"  ✓ {app} is frontmost")


@main.command()
@click.argument("coords")
@click.option("--json", "as_json", is_flag=True)
def at(coords, as_json):
    """What is at X,Y — identified, not guessed from pixels."""
    x, y = (int(v) for v in coords.split(",")[:2])
    try:
        out = hands.at(x, y)
    except Exception as exc:
        _refused(exc, as_json)
    _out(out, as_json, f"  {out.get('role', '?')}  {out.get('label') or ''}")


# ------------------------------------------------- the path that does take it

@main.group()
def real():
    """The fallback for things nothing exposes: real clicks and real keys.

    This one does borrow your cursor. It is a separate command group for that
    reason, and it puts the pointer back where it found it.
    """


@real.command("click")
@click.argument("coords")
@click.option("--button", type=click.Choice(["left", "right", "middle"]), default="left")
@click.option("--double", is_flag=True)
@click.option("--leave-it", is_flag=True, help="Do not put the cursor back.")
def real_click(coords, button, double, leave_it):
    """Click at X,Y with the real cursor."""
    x, y = (int(v) for v in coords.split(",")[:2])
    try:
        click.echo(json.dumps(pointer.click(x, y, button=button, double=double,
                                            put_back=not leave_it)))
    except pointer.NoPointer as exc:
        _refused(exc, False)


@real.command("type")
@click.argument("text")
def real_type(text):
    """Type real keystrokes into whatever has focus."""
    try:
        click.echo(json.dumps(pointer.type_text(text)))
    except pointer.NoPointer as exc:
        _refused(exc, False)


@real.command("key")
@click.argument("name")
@click.option("--times", type=int, default=1)
def real_key(name, times):
    """Press a key: return, esc, tab, arrow-down, ..."""
    try:
        click.echo(json.dumps(pointer.key(name, times=times)))
    except pointer.NoPointer as exc:
        _refused(exc, False)


@real.command("drag")
@click.argument("start")
@click.argument("end")
def real_drag(start, end):
    """Drag from X,Y to X,Y."""
    x1, y1 = (int(v) for v in start.split(",")[:2])
    x2, y2 = (int(v) for v in end.split(",")[:2])
    try:
        click.echo(json.dumps(pointer.drag(x1, y1, x2, y2)))
    except pointer.NoPointer as exc:
        _refused(exc, False)


@real.command("scroll")
@click.argument("amount", type=int)
def real_scroll(amount):
    """Scroll the thing under the pointer."""
    try:
        click.echo(json.dumps(pointer.scroll(amount)))
    except pointer.NoPointer as exc:
        _refused(exc, False)


# ------------------------------------------------------ who has the screen

@main.command()
@click.option("--json", "as_json", is_flag=True)
def control(as_json):
    """Who has the screen right now, and the recent handovers."""
    state = presence.state()
    verdict = presence.check()
    if as_json:
        click.echo(json.dumps({"state": state,
                               "verdict": {"allowed": verdict.allowed,
                                           "holder": verdict.holder,
                                           "message": verdict.message},
                               "events": presence.events()}, indent=2))
        return
    click.echo(f"\n  {verdict.message}")
    click.echo(f"  overlay: {'running' if presence.running() else 'not running'}"
               f" · {state.get('screens', '?')} display(s) · HUD {state.get('hud', '?')}\n")
    for e in presence.events(limit=6):
        click.echo(f"    {e['holder']:<7} {e['why']}")
    click.echo("")


@main.command()
def pause():
    """Take the screen back. The agent stops until you resume."""
    (presence.home() / presence.PAUSED).write_text("1")
    click.echo("  Paused. The agent has no access until you resume.")


@main.command()
def resume():
    """Hand the screen back to the agent."""
    (presence.home() / presence.PAUSED).unlink(missing_ok=True)
    click.echo("  Resumed.")


@main.command()
@click.option("--seconds", type=float, default=120.0)
def wait(seconds):
    """Block until the agent has the screen. For scripts, and for agents."""
    verdict = presence.wait_for_screen(timeout=seconds)
    click.echo(f"  {verdict.message}")
    sys.exit(0 if verdict.allowed else EXIT_NEEDS_YOU)


@main.command()
@click.option("--stop", is_flag=True, help="Take the overlay down.")
def watch(stop):
    """Start (or stop) the on-screen presence: pointer, glow, control bar."""
    if stop:
        presence.stop()
        click.echo("  Overlay stopped.")
        return
    presence.start("Spooky Action")
    time.sleep(0.4)
    click.echo("  Overlay running. It only draws while something is acting.")


# ------------------------------------------------------------------ settings

@main.command()
@click.argument("pairs", nargs=-1)
@click.option("--reset", is_flag=True, help="Back to defaults.")
@click.option("--json", "as_json", is_flag=True)
def config(pairs, reset, as_json):
    """Show or change settings: `spooky config accent=yellow pointer=off`."""
    if reset:
        current = settings.reset()
    elif pairs:
        try:
            current = settings.set_values(dict(p.split("=", 1) for p in pairs))
        except (ValueError, KeyError) as exc:
            # str() on a KeyError wraps the message in quotes. Nobody wants to
            # read their own error message in quotation marks.
            click.echo(f"\n  {exc.args[0] if exc.args else exc}\n")
            sys.exit(2)
    else:
        current = settings.config()

    if as_json:
        click.echo(json.dumps(current, indent=2))
        return
    click.echo("")
    for s in settings.SETTINGS:
        click.echo(f"  {s.key:<16} {str(current[s.key]):<10} {s.blurb}")
    click.echo(f"\n  Stored in {settings.path()} — the overlay reloads it live.\n")


# ------------------------------------------------------------ setup + doctor

@main.command()
@click.option("--json", "as_json", is_flag=True)
def doctor(as_json):
    """What works on this machine right now."""
    perms = permissions.status()
    report = {
        "permissions": perms,
        "swift": permissions.test_swift()[0],
        "hands_built": hands.binary().exists(),
        "overlay_built": presence.binary().exists(),
        "overlay_running": presence.running(),
        "real_clicks": pointer.available(),
        "home": str(presence.home()),
    }
    report["ready"] = perms["all_granted"] and report["hands_built"]
    if as_json:
        click.echo(json.dumps(report, indent=2))
        return
    ok = lambda b: "✓" if b else "·"
    click.echo("")
    for p in perms["permissions"]:
        tail = " (optional)" if p["optional"] else ""
        click.echo(f"  {p['title']:<22} {ok(p['granted'])} {p['detail']}{tail}")
    click.echo(f"  {'hands':<22} {ok(report['hands_built'])} accessibility helper built")
    click.echo(f"  {'presence':<22} {ok(report['overlay_built'])} overlay built"
               f"{' and running' if report['overlay_running'] else ''}")
    click.echo(f"  {'cliclick':<22} {ok(report['real_clicks'])} installed — the "
               f"fallback for things nothing exposes")
    click.echo("")
    if not report["ready"]:
        click.echo("  Run `spooky setup` — it opens the right pane and checks the fix took.\n")


@main.command()
@click.option("--json", "as_json", is_flag=True)
def setup(as_json):
    """Grant what it needs — one pane at a time, verified as you go."""
    app = permissions.host_app()
    outstanding = []
    click.echo(f"\n  Setting up Spooky Action for {app}.\n")

    for step in permissions.steps():
        granted, detail = step.check()
        if granted:
            click.echo(f"  ✓ {step.title} — {detail}")
            continue

        click.echo(f"\n  {step.title}")
        click.echo(f"    Why: {step.why}")
        permissions.open_pane(step.anchor)
        click.echo(f"    {step.action}")
        click.echo("    Waiting for it to take…", nl=False)

        for _ in range(60):                       # two minutes, checked live
            time.sleep(2)
            granted, detail = step.check()
            if granted:
                click.echo(f"\r    ✓ {step.title} — {detail}          ")
                break
            click.echo(".", nl=False)
        else:
            click.echo("")
            if step.optional:
                click.echo(f"    · skipped — {detail}. Everything else still works.")
            else:
                click.echo(f"    Still not through: {detail}")
                click.echo(f"    {permissions.restart_hint(app)}")
                outstanding.append(step.title)

    if permissions.test_swift()[0]:
        try:
            hands.build()
            presence.build()
            click.echo("\n  ✓ built the accessibility helper and the overlay")
        except Exception as exc:
            click.echo(f"\n  Could not build: {str(exc)[:160]}")
            outstanding.append("build")
    else:
        click.echo("\n  No swiftc — run `xcode-select --install`, then `spooky setup` again.")
        outstanding.append("swiftc")

    click.echo("")
    if outstanding:
        click.echo(f"  Still to go: {', '.join(outstanding)}.")
        click.echo("  Everything else works now — `spooky doctor` shows what.\n")
        sys.exit(EXIT_NEEDS_YOU)
    click.echo("  All set. Try `spooky apps`.\n")


@main.command()
@click.option("--yes", is_flag=True, help="Do not ask.")
def uninstall(yes):
    """Remove everything Spooky Action ever wrote."""
    from pathlib import Path
    here = Path(__file__).resolve().parent.parent / "uninstall.sh"
    if not here.exists():
        click.echo(f"\n  Delete {presence.home()} and this folder. That is all of it.\n")
        return
    subprocess.run(["bash", str(here), *(["--yes"] if yes else [])], check=False)


if __name__ == "__main__":
    main()
