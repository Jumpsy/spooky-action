<h1 align="center">👻 Spooky Action</h1>

<p align="center"><strong>Your agent acts at a distance. Your cursor never moves.</strong></p>

<p align="center">
Computer use on a Mac for any AI agent — Claude Code, an SDK loop, a script,
whatever you have. It presses the button, not a pixel. You watch it happen, and
you can take the screen back at any moment by moving your mouse.
</p>

```bash
git clone https://github.com/Jumpsy/spooky-action.git
cd spooky-action && ./install.sh
```

---

## The problem with computer use

Every desktop-automation tool works the same way: it takes your cursor, warps it
to a coordinate, and synthesizes a click. Which means three things are true at
once, and all three are bad.

**You cannot use your computer while it works.** Your pointer is not yours. Move
it and you fight the agent for it.

**It clicks coordinates, so it clicks the wrong thing.** A screenshot goes to a
model, the model says "the Save button is at 840, 612", and by the time the
click lands the sheet has moved fourteen pixels. Now something else has been
pressed and nobody knows what.

**You cannot tell what it did.** A click is a click. There is no record of what
was actually hit.

## What this does instead

It goes through the macOS accessibility layer — the same tree a screen reader
uses. Elements have identities, so it presses *the element*:

```bash
spooky tree Safari
```

```
    12  Button           Reload                                    Press
    13  TextField        Address and Search                        Confirm
    27  Button           Save                                      Press
```

```bash
spooky press Safari 27 --expect "Save"
```

```
  ✓ pressed Save — your cursor did not move
```

`--expect` is the safety net. If the label at index 27 changed between reading
the tree and pressing it, it refuses rather than pressing whatever moved into
place. That single check is the difference between automation you can leave
running and automation you have to babysit.

> This is how Codex does computer use on a Mac. That is not a guess — the
> shipped binaries were checked. `SkyComputerUseService` links the whole
> `AXUIElement` family and contains zero mouse or keyboard event symbols. Its
> on-screen cursor is drawn, not moved.

## You can see it happen

Invisible automation is worse than none. So there is a visible presence, and it
only appears while something is actually acting:

- **A drawn pointer** glides across the screen to whatever is about to be
  pressed, and pulses when it acts. Nothing happens without a visible approach
  to it first. It is drawn — it is not your cursor.
- **The screen edges glow** for as long as the agent is driving, then stop. A
  screen at rest is a completely clean screen.
- **A control bar** sits at the top with a pause button. Drag it anywhere; it
  remembers where you put it.

## Move your mouse and it stops

```bash
spooky control      # who has the screen right now
spooky pause        # take it back
spooky resume
```

The instant you touch your mouse, the agent loses the screen and is told
**immediately** — not on its next screenshot. That word matters. An agent that
finds out it lost the screen by looking at a screenshot afterwards has already
typed into your document.

It gets the screen back once you have been still for a couple of seconds, and it
is told that too. The glow turns your colour while you hold it.

A held lock expires on its own, so an agent that crashes mid-action cannot keep
your screen.

## Change anything

```bash
spooky config                        # every setting, in plain English
spooky config accent=yellow wash=0   # yellow, no screen tint
spooky config pointer=off hud=left
spooky config glide_seconds=1.2      # slow the pointer down to follow it
spooky config --reset
```

The running overlay picks it up live. No restart.

## When nothing is exposed to press

A canvas, a game, an old Java app — some things offer the accessibility layer
nothing. There is a fallback, and it is deliberately a separate command group,
because it *does* borrow your cursor:

```bash
spooky real click 840,612
spooky real type "hello"
spooky real key return
```

It announces itself, puts your pointer back where it found it, and every result
it returns says `cursor_touched: true`. The moment a tool stops distinguishing
between "I pressed the button" and "I took your mouse", you stop being able to
trust either.

## Every command

| | |
|---|---|
| `spooky apps` | what it can act on |
| `spooky tree APP` | what is on screen, with indices |
| `spooky find APP TEXT` | search an app's screen by label |
| `spooky press APP N` | press by index |
| `spooky type APP N TEXT` | put text in a field |
| `spooky click APP LABEL` | press by label, if exactly one matches |
| `spooky focus APP` | bring an app forward |
| `spooky at X,Y` | what is at this point — identified, not guessed |
| `spooky control` / `pause` / `resume` / `wait` | who has the screen |
| `spooky watch` | start or stop the on-screen presence |
| `spooky config` | change anything |
| `spooky setup` / `doctor` | permissions and health |
| `spooky real ...` | the fallback that does take your cursor |

Everything takes `--json`, and everything exits **75** with a concrete
suggestion when it needs you — a handoff, not a failure.

## Setup is not a paragraph of directions

```bash
spooky setup
```

It does not tell you to go find System Settings. It opens the exact pane, names
the one row to tick, waits, and then proves the permission took by using it for
real. If it did not take, it says so and stays on that pane.

## Changed your mind?

```bash
./uninstall.sh
```

Removes the state directory, the venv, the symlink, and any running overlay —
then opens the Accessibility pane so you can untick the permission, which is the
one part a script cannot do for you. It tells you exactly what it removed.

You should be able to leave as easily as you arrived. If you use this once and
decide it is not for you, that should take ten seconds and leave nothing behind.

## Eyes to go with the hands

Spooky Action acts. It does not see — no screenshots, no vision, no web.
[**Agent Eyes**](https://github.com/Jumpsy/agent-eyes) is the other half:
screenshots an agent can actually look at, design systems pulled out of the live
CSSOM, local vision models so a screenshot costs you nothing.

They are separate on purpose. Plenty of people want one and not the other.

## Requirements

macOS, Python 3.10+, and Xcode command line tools (`xcode-select --install`) —
the two Swift helpers are compiled on your machine from the source in this repo.
There is no prebuilt binary, because a prebuilt binary that reads your screen
and drives your apps is exactly the thing nobody should run on trust.

## Status

Early. Building in the open — see [CHANGELOG.md](CHANGELOG.md).

## License

MIT
