# Changelog

Notable changes, newest first.

## Unreleased — first cut

Split out of [Agent Eyes](https://github.com/Jumpsy/agent-eyes), where this
started as the half that acts rather than the half that sees. They are separate
because plenty of people want one and not the other.

### Acting without a cursor

- Input through `AXUIElement` — it presses the *element*, not a pixel, so
  nothing is lost to a sheet that moved fourteen pixels between the screenshot
  and the click. Your cursor does not move, and every result says so.
- `spooky apps · tree · find · press · type · click · focus · at`.
- `--expect` refuses the action if the label at that index changed since the
  tree was read. That check is the difference between automation you can leave
  running and automation you have to babysit.
- The mechanism was verified against the shipped Codex binaries rather than
  assumed: `SkyComputerUseService` links the full `AXUIElement` family and
  contains zero mouse or keyboard event symbols.

### Being visible about it

- A drawn pointer glides to whatever is about to be pressed and pulses when it
  acts, so nothing ever happens without a visible approach to it first.
- Screen-edge glow for as long as the agent is driving, and only then. A screen
  at rest is a completely clean screen.
- A control bar with a pause button — at the top, draggable anywhere, and it
  remembers where you put it.

### Handing the screen back and forth

- Move your mouse and the agent loses the screen and is told immediately, not
  on its next screenshot. It is told again the moment control returns.
- `spooky control · pause · resume · wait`. The pause flag is the single truth,
  so the button on screen and the command can never disagree.
- A held lock expires on its own, so an agent that crashes mid-action cannot
  keep your screen.

### The honest fallback

- `spooky real click · type · key · drag · scroll` for things that expose
  nothing to press. A separate command group because it does borrow your
  cursor — it announces itself, puts the pointer back where it found it, and
  returns `cursor_touched: true`.

### Settings

- `spooky config` — colour, glow, pointer, glide time, idle threshold, HUD
  position. The running overlay reloads changes live.

### Getting in and out

- `./install.sh` — clone, run, done. The Swift helpers are compiled on your
  machine from the source in the repo; there is no prebuilt binary, because a
  prebuilt binary that reads your screen and drives your apps is exactly the
  thing nobody should run on trust.
- `./uninstall.sh` — removes the state directory, the venv, the symlink and any
  running overlay, then opens the Accessibility pane for the one part a script
  cannot undo. Leaving should be as easy as arriving.
- `spooky setup` opens each permission pane, names the row to tick, and proves
  the permission took by using it for real.

### Fixed

- Every real click on a second display arranged to the *left* of the main one
  went to the wrong place, and each one drifted further — cliclick reads a
  leading minus as a *relative* move, so `m:-800,300` means "800 pixels left of
  wherever you are", not "x = -800". Absolute negative coordinates need a `=`
  prefix. Found by the permission probe walking the pointer thousands of pixels
  off every screen.
- The permission probe moved the pointer 9 pixels to test it. macOS coalesces a
  warp that small into nothing — cliclick exits 0 and the pointer never moves —
  so a granted permission reported as denied, sending people to a settings pane
  with nothing to do on it. It steps 60 pixels now.
