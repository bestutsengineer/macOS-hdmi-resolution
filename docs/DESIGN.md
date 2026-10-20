# Design and maintenance notes

For anyone changing `hdmi-resolution` for macOS. The README covers what it
does and how to use it; this covers how it works, how it differs from the
[Linux original](https://github.com/bestutsengineer/hdmi-resolution), and how
to change it without breaking it.

## Files

| In the repository | Installed as | Role |
|---|---|---|
| `Sources/HDMIResolutionCore/` | part of the app | The rules, config, state and menu model. No display API. |
| `Sources/hdmi-resolution/` | `~/Applications/HDMI Resolution.app` | The menu bar app and the Quartz backend. Also provides `status` and `list-displays`. |
| `launchd/…hdmi-resolution.plist` | `~/Library/LaunchAgents/` | Login agent, graphical sessions only. |
| `config.example` | `~/.config/hdmi-resolution/config` | Settings; copied only if no config exists. |
| `Tests/` | not installed | Test suite, simulated display system, EDID fixtures. |

Runtime state, in `~/.local/state/hdmi-resolution/`:

| File | Meaning |
|---|---|
| `baseline-mode` | The laptop screen mode the user last chose: width, height, refresh rate, backing scale; tab-separated. |
| `pending-mode` | Exists only while a restore is owed, i.e. from the moment mirroring starts with the rule on. |
| `displays/<key>.baseline`, `displays/<key>.pending` | The same two things for an external display. |
| `lock` | Held by the running app, so a second copy exits. |
| `switched-off` | The displays the app has switched off, one `<id> <name>` per line. |

The log is `~/Library/Logs/hdmi-resolution.log`, one old copy kept.

Three environment variables redirect all of this, for trying a second copy by
hand without touching the real one: `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and
`HDMI_RESOLUTION_LOG`. Do not set them for the login agent.

What maps to what:

| Linux original | macOS port |
|---|---|
| `kscreen-doctor -j` | `QuartzBackend.snapshot()` |
| `kscreen-doctor output.…` | `QuartzBackend.apply()`, one display configuration transaction |
| watching `kwinoutputconfig.json` / `xrandr` | `CGDisplayRegisterReconfigurationCallback` |
| systemd user service | launchd login agent |
| journal | log file |
| `hdmi-resolution-tui` (whiptail) | menu bar item |
| `/sys/class/drm/…/edid` | the `EDID` property in the I/O Registry |

## How it works

### Trigger

macOS calls the app back whenever the display configuration changes. One
change arrives as many calls, so the app waits until they have stopped for a
second (`App.quietPeriod`) and then runs one pass. Nothing runs on a timer.
While the screens sleep no pass is run; one is run on waking if it was owed.

A pass also runs at start, and after every choice in the menu.

### Snapshot and layout

On each pass `Engine.refreshSnapshot` asks the backend once and
`LayoutFacts` classifies the layout. Every later decision in that pass reads
the same facts, so the rules never see two different states.

| State | Meaning | What the rules do |
|---|---|---|
| `no-display` | Laptop screen on, no enabled external display | Restore if owed; otherwise track the user's modes |
| `extend` | Laptop screen on, external display(s), none mirroring it | Same, then the extend rule |
| `mirror` | An external display mirrors the laptop screen and the mirror rule applies | Mirror rule |
| `mirror-manual` | Mirroring, but the rule is off (master switch, or every mirroring display is excluded) | Nothing at all |
| `panel-off` | Laptop screen absent or off (lid closed) | Nothing at all |
| `unknown` | The backend gave no answer | Nothing at all |

Definitions, in `Model.swift`:

- **Panel**: the display Quartz calls built-in.
- **External display**: any other online display that is active or part of a
  mirror set.
- **Mirroring**: the display's mirror source is the panel, or the other way
  round, or both sit at the same position. A mirrored display is reported at
  its source's position, which is what catches a set with three members.
- **Logical size**: the size the display occupies in the desktop, which is
  what `CGDisplayBounds` reports. Rotation and HiDPI are already in it.
- **Mode size**: width and height in points, the size System Settings calls
  "looks like". `scale` is 2 for a HiDPI mode.

### Mirror rule

This is where macOS differs most from Plasma on Wayland, and why the port
follows the original's X11 behaviour rather than its Wayland behaviour.

A macOS mirror set shows **one desktop, in the mode of the display the others
mirror**. That display is what System Settings calls "Optimise for". So there
is no such thing as giving only the laptop screen a mode while it mirrors:
the target has to go to the display that leads the set.

`applyMirrorMode`, on entering `mirror`:

1. The members of the set are the panel and every display mirroring it. The
   *source* is the member the others mirror.
2. The *driver* is the first of source, panel, other members that offers a
   mode of the target size. No driver: log it and change nothing.
3. If the driver is not the source, the set is turned round so that every
   member mirrors the driver. If the driver is not at the target mode, it is
   set. Both go into one transaction. Nothing to do: log "already at".

A MacBook screen is 16:10 and offers no 16:9 mode of its own, so on a MacBook
the driver is always the external display. A built-in 16:9 screen is its own
driver.

"Of its own" matters. While a display is part of a mirror set, macOS adds
modes to its list, flagged `kDisplayModeValidForMirroringFlag`
(`DisplayMode.mirrorOnly`):

- On an external display they are extra HiDPI sizes, such as 1920x1080 and
  2560x1440 at scale 2 on a 2560x1440 monitor. They can be chosen, and are
  preferred, because the Retina laptop screen shows the same desktop.
- On the laptop screen there is one: the size the set runs at, or last ran
  at. macOS refuses to switch the screen to it.

So a display can lead only if it has a mode of the target size that is not
mirror-only (`Output.offers`). The mode it is then given may be a mirror-only
one. Should macOS refuse that, the display's own mode of that size is tried,
then the next display: one attempt each, in a fixed order, and none again
until mirror mode is next entered.

Two kinds of state file make the restore reliable:

- A `baseline` is updated whenever the mode is the user's to choose: in
  `no-display` and `extend`, when nothing is owed.
- A `pending` is written from the baseline on entering `mirror`, just before
  anything is changed. It is deleted once the restore is done or found to be
  unnecessary.

The restore is driven by the pending files, not by remembering the previous
layout. Any pass in `no-display` or `extend` that finds one puts the mode
back (`restoreOrTrack`). That covers a restart while mirrored, a display
unplugged while mirrored, and the rule being switched off while mirrored.
macOS usually puts the modes back itself when mirroring ends; the app then
logs "already back in place" and clears the files without touching anything.

While anything mirrors the panel, no mode is tracked as the user's, and with
the rule off nothing is restored either: macOS chose those modes, and pulling
a display out of the shared size would break the mirror.

Modes are stored as width, height, refresh rate and scale, and looked up
afresh every time, because macOS renumbers mode ids. A file with three fields,
as the Linux original writes, is understood and matches either scale.

### Extend rule

`Engine.placement` computes the target from logical sizes exactly as the
original does: the wider of the two starts at x = 0, the narrower is centred
against it, the display sits on top and the panel directly below.

Then comes a macOS addition. macOS anchors its coordinates at the main
display, the one at `0,0` with the menu bar, and a display moved to `0,0`
*becomes* the main display. So the result is shifted so that the main display
stays exactly where it is.

Which display is main is remembered (`mainKey`) while the screens are
extended, and that one is kept main when extend mode starts again. This
matters after mirroring: the mirror rule makes the set follow the external
display, which makes that display main, and it could stay main afterwards.
With the laptop screen alone nothing is noted, since it is main of necessity.

Worked example: a 2560x1440 monitor and a laptop screen that looks like
1680x1050 and is the main display. The original's answer is monitor at `0,0`,
panel at `440,1440`. Shifted so the panel stays at `0,0`: monitor at
`-440,-1440`.

`placeExtendedDisplay` applies it in two cases only:

1. Extend mode has just started with this display (the "signature", display
   name plus display key, differs from the previous pass).
2. The layout is still the one the app made, but the target has moved (a
   resolution or rotation change).

"Still the one the app made" differs from the original. Plasma keeps an
output where it is when its mode changes; macOS moves a display that changes
size, to keep the arrangement free of gaps and overlaps. On real hardware a
monitor centred at `-440,-1440` ended up at `-240,-720` after a few
resolution changes in System Settings, and the first version took that for
the user dragging it. So positions are compared only when no size changed;
after a size change the layout counts as the app's if it was the app's in the
pass before.

If the positions differ from what the app applied without a size change, the
user has moved the screens, and the app stays out until extend mode next
starts. A failed apply is logged and not retried.

The rule can be switched off per display (`extend_off_display`), like the
mirror rule.

### Display identity and labels

- Key: `edid:<md5>` of the display's EDID, the same value the original
  computes, so one config file works on both systems. A display with no
  readable EDID gets `uuid:<uuid>`, the identifier macOS derives for it, and
  failing that `connector:<name>`.
- Quartz gives a display's vendor, product and serial number but not its
  EDID. The I/O Registry has the EDID, on the node of the port
  (`IOPortTransportStateDisplayPort` on Apple silicon). `RegistryEDID` walks
  the registry for every `EDID` or `IODisplayEDID` property and matches a
  block to a display by those three numbers.
- The registry lags behind Quartz. A second after a monitor is plugged in,
  Quartz lists it and the registry does not yet hold its EDID. A key that
  changed from `uuid:` to `edid:` between two passes would lose the display's
  settings and state, so `QuartzBackend.edids` waits, up to five seconds, the
  first time a real external display has none, and remembers every EDID it
  has seen for the rest of the run.
- Model: the EDID monitor-name descriptor; without one, the three-letter
  vendor code and product number; without an EDID, the name macOS shows.
- Connector kind, from the port node's transport: DisplayPort is
  `USB-C/DisplayPort`, HDMI is `HDMI`.
- Output names are `display-<n>`, n being the Quartz display id. They are
  only for the log; nothing is stored by name unless there is no other key.

### Menu

`MenuModel` holds everything the menu shows about the rules and returns the
config each choice leads to; `App.menuNeedsUpdate` only draws it, freshly
each time the menu opens. A rule choice is saved and `Engine.start()` is
called, which is the original's "Save and restart service" in one step.

Top level: Display Mode, Resolution, Display Settings…; then one submenu per
rule, each with its master switch and per-display switches; then Options.

**Display Mode** (`Arrangements`) works out the current arrangement from a
snapshot and the changes that lead to another, all in one transaction:

| To | Changes |
|---|---|
| Extend | switch every display on; take every display out of its mirror set |
| Mirror | switch every display on; every external display mirrors the laptop screen |
| Built-in Display Only | out of any mirror set; switch every external display off |
| External Displays Only | switch external displays on; out of any mirror set; switch the laptop screen off |

Virtual displays are left out, and nothing is offered with the lid closed.
Switching a display on or off uses `CGSConfigureDisplayEnabled`, which is not
public; `DisplaySwitch` looks it up at run time. After switching a screen off
the app asks whether to keep it, and goes back after 15 seconds without an
answer. Displays it switched off are listed in `switched-off` in the state
directory, so they can be switched on again even if macOS stops listing them,
and the menu bar item stays while there are any.

**Resolution** (`Output.resolutions`) lists, per display, what System
Settings lists. For the laptop screen macOS publishes that list: the window
server's `scale-resolutions`, HiDPI backing sizes. For an external display it
publishes nothing, and no flag marks the sizes System Settings picks. The
list is rebuilt: modes of the display's own shape (within 1%), from half its
width to its full width, that are common sizes (`CommonSizes`) or its native
size, in their HiDPI form where one exists, plus the size in use. For a
DELL U2713H that gives exactly what System Settings showed. "All Resolutions"
lists one entry per size and scale. Choosing applies the mode directly; the
rules then see it like any other change.

The menu bar item exists while `MenuModel.showsMenuBarItem` is true: a real
external display is connected (any display other than the panel and virtual
ones, mirrored and switched-off ones included), the app has a display
switched off, or `always_show_menu_bar` is on.

### Config

`Config.parse` reads the file line by line and takes only lines that are
exactly one known setting. Nothing from the file is ever executed. `save`
writes the same format through a temporary file and a rename. Three things
are added to the original's format, and the original ignores them with a
warning: `uuid:` keys, `extend_off_display` and `always_show_menu_bar`.

## What was observed on real hardware, and what is assumed

Observed on an M1 MacBook (2560x1600) with a 2560x1440 monitor on USB-C,
macOS 26.2, with mirroring switched on and off from macOS itself:

- When mirroring is switched on, the set follows the laptop screen, also the
  second time, after the app had made it follow the monitor.
- Un-mirroring the leader and pointing the laptop screen at the monitor, plus
  a new mode for the monitor, is accepted as one transaction
  (`output.display-1.mirror.display-2 output.display-2.mode.38`), and the
  desktop on both screens then has the target size.
- The monitor can be given a mirror-only HiDPI mode both while it is being
  made the leader and when it already leads.
- The laptop screen's mirror-only mode is refused. This is the bug the first
  version had: mirroring was switched on a second time, the laptop screen
  listed the previous size of the set, and the app tried to switch the screen.
- macOS does **not** put the modes back when mirroring ends. Both screens
  were still at the mirrored size, and the app restored both in one
  transaction (`output.display-1.mode.4 output.display-2.mode.28`).
- macOS does restore the *arrangement* of a known monitor, so after a
  re-plug the extend rule finds it "already above and centred".
- Mode ids are different while mirrored: the monitor's 71 modes instead of 58.
- A pass that follows the app's own change does nothing.
- Changing a monitor's resolution in System Settings moves it: centred at
  `-440,-1440` as 2560x1440, it was at `-240,-720` as 1280x720.
- macOS publishes the laptop screen's resolution list (`scale-resolutions`)
  but nothing like it for the monitor, and the private per-mode flags do not
  mark System Settings' choices either.

Not run on hardware yet: the Display Mode and Resolution menus, and the
re-centring after a resolution change. The resolution lists were compared
with the real displays without switching anything.

`MockBackend` models all of that. What it still assumes, untested on hardware:

1. A built-in 16:9 screen (an iMac's) that offers the target can be switched
   while it leads the set.
2. A set of three members can be turned round the same way as a set of two.
3. 1K and 4K displays behave as the 2K one did. Their mode lists in the tests
   are made up from what such displays usually offer.

The engine does not depend on what macOS reports for a display that is
mirroring another one, nor on whether macOS restores anything by itself.

When something goes wrong on real hardware, the log has what is needed: on
entering mirror mode one line says which display the set follows and every
member's mode, and a refused change is followed by a `macOS:` line naming the
call that failed and its error code.

## Trust boundaries

| Input | Trusted? | Handling |
|---|---|---|
| Config file | User-owned, but treated as data | Exact line forms only; never executed |
| State files | User-owned | Mode files validated as three or four numbers before use; `switched-off` only as `<id>` and `display-<id>` |
| Display configuration | From macOS | Read through Quartz |
| Monitor name (EDID) | **Untrusted**, supplied by the monitor | Printable ASCII only, length-capped, only ever shown as text |
| Display name from macOS | Derived from the monitor | Same treatment |
| Display keys | Derived | Checked against a fixed form before they become part of a file name or a config line |

## Changing it safely

1. Edit the sources.
2. `swift test`
3. `bash install.sh`, then read `~/Library/Logs/hdmi-resolution.log`.

### The test suite

`RuleTestCase` gives every test a temporary config and state directory and a
`MockBackend`. `start` runs the engine on an initial display state, `change`
replaces the state as macOS would, and both then call `settle`: one pass for
the change and one more for every change the engine itself made, until it
does nothing. A rule that kept re-applying fails there.

It covers: placement for 1K, 2K and 4K displays, wider, narrower, rotated and
odd-sized ones, with either display as the main one; every case where
placement must not happen; the hands-off and re-centre behaviour; mirror
detection in all three forms; every supported display against every target
with the set following either member; restore after unplug, restart, lid
close and renumbered mode ids; the per-display and master switches; refused
and unanswered backend calls; a runaway loop; shell code and junk in the
config; a monitor name that looks like a command-line option; a display key
containing a path; display labels; and every menu entry.

To add a case, copy an existing one. States are built with `laptop(…)` and
`monitor(…)`; `Modes` has the mode lists, taken from real hardware where
possible.

Fixtures: `dell-p2723de.edid` is a real monitor EDID with the serial number
blanked. `no-name-lg.edid` and `hostile-name.edid` are synthetic. All three
come from the original.

### Things that will bite

- **Nothing on a timer.** A pass per change, after the quiet period. Anything
  that polls the display system competes with macOS's own handling of a change.
- **No retry loops.** Every change the app makes comes back as a display
  configuration change and wakes it again. Anything that re-applies on every
  pass becomes an endless loop of flashing screens. Each action is tied to a
  transition or to a file that the action itself removes. `Engine.apply` also
  refuses to make more than ten changes in thirty seconds, as a last resort.
- **Never move a display to `0,0`** unless it is the main display, or was the
  main display while extended. It would take the menu bar with it.
- **A changed size moves the display.** Never compare positions across a
  size change; see "Extend rule".
- **Never switch the last screen off.** `Arrangements` only switches the
  laptop screen off while an external display is on, and back. Keep the
  confirmation with its time limit for anything that switches a screen off.
- **Never store mode ids.** They change between hotplugs.
- **Refresh the snapshot after changing a mode.** The extend rule runs later
  in the same pass and needs the new sizes.
- **Do not track a baseline while a restore is owed**, and never while
  anything mirrors the panel. The mode on screen is not the user's then.
- **The same-position mirror test** means the extend rule must never put two
  displays at the same coordinates. It cannot today, since the panel is
  always below the display.
- **A mode in the list is not always a mode the display can be switched to.**
  See "Mirror rule". Decide who leads a mirror set with `Output.offers`, never
  with `mode(width:height:)` alone.
- **Do not key anything on a display before its EDID is known.** See "Display
  identity and labels".
- **"Menu bar item shown" in the log does not mean it is on screen.** macOS
  puts a new item at the far left, and a menu bar manager (Ice, Bartender)
  hides what is there. To see where an item really is, look at
  `statusItem.button?.window?.frame`: a large negative x is a hidden section.
  The item has an `autosaveName` so that the place the user drags it to is
  remembered.
- **Keep the display API out of `HDMIResolutionCore`.** Everything in it is
  tested; what is in the app target is not.
- **A change in the menu restarts the rules**, and a start counts as extend
  mode starting, so the placement is applied again.
- **`status` run from a shell reads `XDG_CONFIG_HOME`** from that shell. The
  login agent does not see it; if you set it to something unusual, the two
  read different files.
