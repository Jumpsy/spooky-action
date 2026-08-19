---
name: spooky-action
description: >
  MUST USE for anything that requires acting on the user's Mac: "click that",
  "open the file in X", "fill this form", "change that setting for me", "press
  the button", "switch tabs", "drive this app", or any step that needs a real
  application rather than a browser session.

  Also MUST USE before acting on a desktop screenshot — it lists what is
  actually pressable in an app, with a stable index for each thing, so the
  action targets the element rather than a coordinate that may have moved.

  It presses through the macOS accessibility layer: the user's cursor does not
  move, a drawn pointer shows where it is acting, and the moment the user
  touches their mouse the agent loses the screen and is told.

  NOT for: looking at a website's design, screenshots, or assets (that is the
  agent-eyes skill, if installed); anything on Windows or Linux.
metadata:
  openclaw:
    homepage: https://github.com/Jumpsy/spooky-action
---

# Spooky Action — hands on the Mac, without taking the mouse

Action at a distance: the button is pressed and no cursor ever travels there.
Input goes through `AXUIElement`, so it presses the *element*.

## The loop

**Read the tree, act by index, read it again.** Never act on a stale tree.

```bash
spooky apps                    # what is running, ● marks the focused one
spooky tree Safari             # every pressable thing, with its index
spooky press Safari 27 --expect "Sign in"
spooky tree Safari             # confirm what changed
```

`tree` is the ground truth, not a screenshot. A screenshot tells you what it
looks like; the tree tells you what it *is* — role, label, whether it is
enabled — and gives you the index to act on.

## Always pass `--expect`

```bash
spooky press Mail 14 --expect "Send"
```

`--expect` is the label the thing should still have. If the tree shifted
between reading and acting — a sheet appeared, a row loaded, a menu closed —
the action is refused (exit 65) instead of pressing whatever moved into slot
14. Pass it every single time. It costs nothing and it is the difference
between automation that can be left alone and automation that has to be
watched.

## The commands

```bash
spooky apps                          # running apps, focused one marked
spooky tree APP [--window N] [--max N]
spooky find APP "text" [--role AXButton]   # search by label
spooky press APP INDEX --expect "Label"
spooky type APP INDEX "text" --expect "Label"   # hands the field its value
spooky click APP "Label"             # press by label, if exactly one matches
spooky focus APP INDEX               # bring an app forward
spooky at X,Y                        # what is at this point, identified
```

Add `--json` to any of them when you want to parse rather than read.

## When nothing is exposed

Some things expose nothing to press — a canvas, a game, a custom-drawn view.
That is what `spooky real` is for, and it is deliberately a separate group:

```bash
spooky real click 640,480
spooky real type "hello"
spooky real key return
spooky real drag 100,100 400,400
spooky real scroll -5
```

This **borrows the user's cursor**. Every result comes back with
`"cursor_touched": true`. Say so when you use it, prefer `press` whenever the
element exists, and never reach for `real` just because reading the tree looked
like more work.

## The screen is shared

The user is sitting there. This is their machine.

```bash
spooky control       # who has the screen, and the recent handovers
spooky wait          # block until the agent has it back
spooky watch         # start the on-screen presence: pointer, glow, pause bar
```

- The instant the user moves their mouse, the agent loses the screen. Any
  command will tell you — **stop and wait**, do not retry in a loop.
- `spooky wait` blocks until control returns. That is the correct response to
  losing it.
- Say what you are about to press *before* pressing it.
- Never click through a confirmation dialog on the user's behalf unless that is
  exactly what they asked for.
- For anything destructive, irreversible, or outward-facing — sending,
  deleting, purchasing, posting — describe what you see and let them press it.

## Permissions

Acting needs Accessibility, granted per-application to whatever runs `spooky`.
`spooky doctor` reports it; `spooky setup` opens the pane, names the row to
tick, and proves the permission took by using it for real. When it is missing,
the error carries the exact fix — relay that instead of a generic failure.

## Seeing what you are acting on

Spooky Action reads the accessibility tree, not pixels. For actual screenshots
— of the screen, or of any website — that is
[Agent Eyes](https://github.com/Jumpsy/agent-eyes). The two are built to be
used together:

```bash
agent-eyes screen --grid       # see it
spooky tree Safari             # understand it
spooky press Safari 27         # act on it
```
