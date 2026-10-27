# macOS-hdmi-resolution

Two display rules for Mac laptops, with a menu bar item to control them and
to switch display mode and resolution. A port of
[hdmi-resolution](https://github.com/bestutsengineer/hdmi-resolution), which
does the same for KDE Plasma.

| Rule | When it acts | What it does |
|---|---|---|
| **Mirror rule** | An external display mirrors the laptop screen | Switches the mirrored desktop to a target mode (1920x1080 by default). When mirroring ends, the screens return to the modes you had before. |
| **Extend rule** | Exactly one external display is extended | Places that display above the laptop screen, horizontally centred. |

<img width="274" height="291" alt="image" src="https://github.com/user-attachments/assets/4be8543b-8cfb-4ee0-b47a-2371d07699d6" />

Both work with any connector: HDMI, USB-C / DisplayPort and docks, and with
1K (1920x1080), 2K (2560x1440) and 4K (3840x2160) displays. The name is
historical; the first version only handled HDMI.

Everything runs as your own user. Nothing is installed system-wide and nothing
needs root or a privacy permission.

## Why

- A high-resolution laptop screen mirrored to a 1080p projector gives a poor
  picture on one of the two. Running the mirrored desktop in the projector's
  mode fixes that, and it should undo itself afterwards.
- macOS puts a newly connected display to the right. If your monitor sits
  above the laptop, you re-arrange it for every new display.

## Requirements

- macOS 13 or later (developed and tested on macOS 26.2, Apple silicon)
- Xcode or the Command Line Tools, to build it (`swift`)
- Nothing at run time

## Install

```bash
git clone https://github.com/bestutsengineer/macOS-hdmi-resolution.git
cd macOS-hdmi-resolution
bash install.sh
```

This builds `HDMI Resolution.app`, copies it to `~/Applications`, installs and
starts a per-user login agent, links the command to `~/.local/bin`, and
creates `~/.config/hdmi-resolution/config` if you do not have one. To remove
it again: `bash uninstall.sh`.

macOS shows a "Background Items Added" notification the first time; that is
the login agent.

## Use

While an external display is connected, a displays icon is in the menu bar.
It disappears when the last one is unplugged, unless "Always show in menu
bar" is switched on.

With a menu bar manager such as Ice or Bartender, a new item starts in the
manager's hidden section. Drag it out once (hold Command) and macOS remembers
the place.

```
Display Rules (hdmi-resolution)
Layout: extend
──────────────────────────────────────────
Display Mode: Extend                     ▸   ✓ Extend
                                               Mirror
                                               Built-in Display Only
                                               External Displays Only
Resolution                               ▸   DELL U2713H              ▸   2560 × 1440 (Default)
                                             Built-in Retina Display  ▸   2048 × 1152
Display Settings…                                                       ✓ 1920 × 1080
──────────────────────────────────────────                                1600 × 900
Mirror Rule: ON                          ▸                                1280 × 720 (HiDPI)
Extend Rule (Above, Centred): ON         ▸                                ───────────
──────────────────────────────────────────                                All Resolutions  ▸
Options                                  ▸
Quit Display Rules
```

| Menu entry | Meaning |
|---|---|
| **Display Mode** | Extend, Mirror, Built-in Display Only or External Displays Only, as Plasma's display switcher offers them. |
| **Resolution** | One list per display, the sizes System Settings lists for it; "All Resolutions" has every mode, as "Show all resolutions" does. In extend mode only: while mirroring, the mirror rule's target decides. |
| **Display Settings…** | Opens System Settings > Displays. |
| **Mirror Rule** ▸ On for All Displays | Master switch for the mirror rule |
| ▸ Mirrored Target | Mode used while mirroring: 1080p (1K), 1440p (2K), 2160p (4K) or 720p. A size none of the connected displays offers is marked. |
| ▸ Per Display | One entry per display; unticked ones are left alone when mirroring |
| ▸ Restore User Mode | Explanation only; restoring is always on |
| **Extend Rule** ▸ On for All Displays | Master switch for the extend rule |
| ▸ Per Display | One entry per display; unticked ones are left where macOS puts them |
| **Options** ▸ Always Show in Menu Bar | Keeps the icon when no external display is connected, so the rules can be changed beforehand |
| ▸ Open Log, Reload Config File | The log; and for after editing the config by hand |

Displays with a rule switched off stay listed while unplugged.

**Display modes.** Extend and Mirror are what System Settings offers too.
Switching a screen off, for the other two, is not: macOS has no public way to
do it. The app uses the call display tools such as displayplacer use, and asks
whether to keep the result. Without an answer within 15 seconds it goes back,
so a screen that does not come back as expected cannot leave you stuck. The
menu bar item stays while the app has a display switched off, so it can be
switched on again.

**Resolutions.** For the laptop screen the list is the one macOS publishes.
For other displays it is rebuilt as System Settings shows it: the common
sizes of the display's shape from half its width up, in their HiDPI form
where there is one. A resolution chosen here is your own mode, as one chosen
in System Settings is, and the extend rule centres the display for it.

Hover over an entry for its explanation. A choice is saved at once and the
rules start afresh with it.

```bash
hdmi-resolution status              # what the app sees right now
hdmi-resolution list-displays       # one line per external display, with its key
tail -f ~/Library/Logs/hdmi-resolution.log                                  # what it did and why
launchctl kickstart -k gui/$(id -u)/com.github.bestutsengineer.hdmi-resolution   # restart it
```

## Behaviour in detail

**Mirror rule**

- It only acts in mirror mode. Extended layouts never have their resolution
  changed.
- The modes to return to are whatever you had selected before mirroring. They
  are not hardcoded.
- It can be switched off for individual displays. A display is recognised by
  its EDID, so the setting follows the monitor to any port. New displays start
  switched on.

**How the mirror rule is done on macOS**

macOS mirrors differently from Plasma, and the rule adapts, in the way the
original adapts to X11:

- A mirror set shows one desktop, in the mode of the display the others
  mirror ("Optimise for" in System Settings). The target is therefore given
  to that display, and every screen in the set shows it.
- A MacBook screen is 16:10 and offers no 16:9 mode of its own. When it leads
  the set, the set is turned round to follow the external display, which then
  runs the target; the laptop screen shows the same desktop, scaled. A
  built-in screen that does offer the target (an iMac's) is switched itself.
- A size is often offered twice, plain and HiDPI. The HiDPI one is used when
  there is one, so the Retina laptop screen and a 4K display stay sharp.
  While mirroring, macOS offers HiDPI sizes a monitor does not have otherwise.
- If no display in the set offers the target, nothing is changed and the log
  says so. A 2560x1440 monitor cannot do 3840x2160.
- A display the app changed is put back when mirroring ends: to the mode it
  last had in extend mode, or else to the size macOS mirrored at. The laptop
  screen is put back to your own mode, whoever changed it.
- With the rule switched off, a mirrored layout is left exactly as macOS made
  it. Switching the rule off while mirroring restores your modes when
  mirroring ends, not at once.

**Extend rule**

- It is applied each time extend mode starts: plugging in, leaving mirror
  mode, logging in, changing a setting in the menu.
- After that you can drag the screens elsewhere in System Settings. That
  layout is kept until extend mode next starts.
- While the layout is still the one the app made, it re-centres after a
  resolution or rotation change, from System Settings or from the menu.
  macOS moves a display that changes size; that is not taken for you
  dragging it.
- The main display, the one with the menu bar, stays the main display: the
  one that was main the last time the screens were extended, even if macOS
  made the other one main while mirroring.
- It can be switched off for individual displays, like the mirror rule.
- It does nothing with two or more external displays, with the lid closed, or
  when the only other display is a virtual one (AirPlay, Sidecar).

## Configuration

`~/.config/hdmi-resolution/config`, normally written by the menu. It is the
same file, in the same format, as the Linux original uses, and a display has
the same key on both systems:

```
enabled=1
target_width=1920
target_height=1080
extend_top_center=1
always_show_menu_bar=0
auto_off_display=edid:0123456789abcdef0123456789abcdef Example Monitor [HDMI]
extend_off_display=edid:0123456789abcdef0123456789abcdef Example Monitor [HDMI]
```

| Setting | Meaning |
|---|---|
| `enabled` | Mirror rule master switch, `1` or `0` |
| `target_width`, `target_height` | Mode used while mirroring, as System Settings names it ("looks like"). Any size a display in the mirror set offers works, not only the four in the menu. |
| `extend_top_center` | Extend rule, `1` or `0` |
| `extend_off_display` | One line per display excluded from the extend rule, in the same form as `auto_off_display`. Not in the Linux original. |
| `always_show_menu_bar` | `1` keeps the menu bar item when no external display is connected; `0`, the default, shows it only while one is. Not in the Linux original, which ignores the line. |
| `auto_off_display` | One line per display excluded from the mirror rule: its key, then a label. `hdmi-resolution status` prints the key of each connected display. |

The file is read as data, not executed. A line that is not exactly one of
these settings is ignored and reported in the log. A missing setting keeps its
default (both rules on, 1920x1080). After editing it by hand, choose "Reload
Config File" in the menu, or restart the app with the `launchctl` line above.

## Limitations

- **Tried on one combination of hardware**: an M1 MacBook (2560x1600) with a
  2560x1440 monitor on USB-C, macOS 26.2. There, both rules, the restore and
  the menu's rule settings have run for real. 1K and 4K displays, a built-in
  16:9 screen and sets of three are covered only by the simulated display
  system in the test suite. See [docs/DESIGN.md](docs/DESIGN.md) for what was
  observed and what is still assumed.
- **Not yet run on hardware:** the Display Mode and Resolution menus, and
  the extend rule re-centring after a resolution change. The resolution lists
  were checked against the real displays, without switching.
- Built-in Display Only and External Displays Only use a macOS call that is
  not public. If a future macOS drops it, those two are greyed out.
- System Settings does not say how it picks the resolutions it lists for an
  external display. The app's list matched it for the monitor it was tried
  with; for another it may differ by a size or two.
- The extend rule handles one external display. With more, the layout is left
  to macOS.
- USB-C displays use DisplayPort signalling, so both are labelled
  `USB-C/DisplayPort`, also behind an HDMI adapter.
- The app is signed for the Mac it is built on and is not notarised. Build it
  where it runs.
- Telling virtual displays from real ones uses a description of the display
  that macOS does not document. If a future macOS drops it, the extend rule
  would also place an AirPlay or Sidecar display.

## Security notes

- Runs entirely as the logged-in user: no root, no privacy permission, no
  network access.
- It only reads the display configuration and sets a mode, a position, the
  direction of a mirror set, or whether a display is on. From `status` it
  also runs `launchctl print`, which only reads.
- The config and state files are parsed as data and validated; nothing in them
  is executed.
- Monitor names come from the monitor's own EDID and are therefore untrusted.
  They are reduced to printable ASCII, capped in length, and only ever shown
  as text. A display key is checked before it is used in a file name.

## Development

```bash
swift test                    # the rules against a simulated display system
bash scripts/build-app.sh     # build/HDMI Resolution.app
```

The suite takes a second and never touches real displays, settings or the
login agent. How it works, the design constraints and the things that will
bite when you change it are in [docs/DESIGN.md](docs/DESIGN.md).

Before committing, enable the pre-commit hook. It runs
[gitleaks](https://github.com/gitleaks/gitleaks) on the staged changes and
refuses a commit whose author address is not a GitHub noreply address, since
GitHub publishes the author address of every commit:

```bash
brew install gitleaks
git config core.hooksPath .githooks
git config user.email "<id>+<username>@users.noreply.github.com"
```

With the [pre-commit](https://pre-commit.com) framework instead:
`pre-commit install` uses `.pre-commit-config.yaml`. `.gitleaks.toml` tells
gitleaks that display keys (`edid:<md5>`) are identifiers, not secrets.

## License

MIT, see [LICENSE](LICENSE).

The three EDID files in `Tests/HDMIResolutionCoreTests/Fixtures` come from the
Linux original, also MIT licensed. `dell-p2723de.edid` is a real monitor's
EDID with the serial number blanked; the other two are synthetic.
