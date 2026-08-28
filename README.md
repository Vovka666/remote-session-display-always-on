<div align="center">

# Vigil

**Something is always watching your screen. Literally.**

Keeps a Windows machine from ever being without a display, so remote sessions
land on a proper desktop instead of a 1024×768 fallback with the mouse in the
wrong place.

For anyone who reaches a PC through Chrome Remote Desktop, Parsec, VNC or
AnyDesk — and switches the monitor off, or never had one plugged in.

</div>

---

## The problem

Windows only has a desktop if something is connected to look at it. Take the
monitors away and it does not carry on quietly — it collapses.

- **Turn the monitor off at home** and, depending on the cable, Windows may
  drop that output entirely. The desktop shrinks to a fallback resolution, every
  window is dragged into the top-left corner, and that is what you connect to
  from work.
- **A machine with no monitor at all** — a server in a cupboard, a spare PC
  under the desk — often has no usable desktop for a remote tool to capture.
  The picture is tiny, or the cursor lands nowhere near where you clicked, or
  the keyboard goes somewhere else entirely.
- **Waking from sleep** re-enumerates the GPU outputs. Anything not physically
  present at that instant is simply gone.

The fix is well known: give Windows a monitor that cannot be unplugged. A
virtual display driver presents one, and everything behaves again.

Doing that reliably is where it gets fiddly, and Vigil is the fiddly part done
once, properly.

## What Vigil does

- **Attaches a virtual display** and rebuilds the display topology around it —
  precisely, keeping the screens you name and leaving out the ones you do not
  (a laptop's own panel, usually).
- **Watches.** At logon, on resume from sleep, at boot and on a timer, it checks
  that this machine has a picture at all. If it does, Vigil does nothing. If it
  does not, it fixes that before you notice.
- **Refuses to blind you.** Removing the virtual display is blocked while it is
  the only thing rendering. Without that interlock, one click on a headless
  machine locks you out until somebody walks over to it.
- **Leaves other people's virtual displays alone.** Parsec, Quest Link and
  spacedesk all install their own; Vigil identifies them through the device
  tree, reports them, and never touches them.
- **Says what is wrong.** `vigil doctor` checks each assumption separately and
  names the one that fails.

No dependencies. Windows PowerShell 5.1 is already on your machine.

## Install

```powershell
git clone https://github.com/Vovka666/remote-session-display-always-on.git
cd remote-session-display-always-on
.\vigil.cmd install
```

Run it from an **administrator** PowerShell — attaching a display device needs
elevation. It fetches the virtual display driver from the vendor, registers it,
writes the configuration, creates the scheduled tasks and puts two shortcuts on
the desktop.

Then:

```powershell
.\vigil.cmd doctor     # check everything
.\vigil.cmd setup      # choose which displays to keep
.\vigil.cmd on         # bring the virtual display up now
```

No internet on the machine? Download
[usbmmidd_v2.zip](https://www.amyuni.com/downloads/usbmmidd_v2.zip) elsewhere and
point at it:

```powershell
.\vigil.cmd install -FromZip D:\usbmmidd_v2.zip
```

## Use

```
vigil status      what is lit right now, and what Windows remembers
vigil on          attach the virtual display and rebuild the topology
vigil off         remove it (refuses while it is the only picture)
vigil ensure      the watchdog: act only if there is no picture at all
vigil doctor      check every assumption and name what is wrong
vigil setup       choose which displays to keep out of the topology
vigil log         recent activity
```

The two desktop shortcuts run **Virtual display ON** and **OFF** without a UAC
prompt. That is not a shortcut in the other sense: a prompt you cannot click is
useless on the very machine whose screen has gone black, so the elevation lives
in the scheduled task instead.

```
> vigil status

Vigil - display status
============================================================
Active displays: 3  (real 2, virtual 1)

  [real   ] DELL S2722DC                 2560x1440 @ 75Hz
  [virtual] (no EDID name)               2560x1440 @ 60Hz
  [real   ] LG ULTRAWIDE                 2560x1080 @ 60Hz

Remembered but not attached (2):
  - Generic Monitor (Q70A)

Session: console   remote hosts installed: chrome-remote-desktop
```

## Configuration

`C:\ProgramData\Vigil\config.json`, written by `vigil setup` and safe to edit
by hand.

```json
{
  "topology": "preserve",
  "exclude": ["NCP004D"],
  "watchdog": {
    "enabled": true,
    "onLogon": true,
    "logonDelaySeconds": 40,
    "onResume": true,
    "everyMinutes": 5
  },
  "safety": { "refuseIfOnlyDisplay": true }
}
```

| Setting | What it decides |
|---|---|
| `topology` | `preserve` — keep the arrangement Windows already has, minus the excluded displays, at the resolutions they already use. Works everywhere, and the default. `clone` — additionally give every kept display one shared source so they show the same desktop; only possible while they are on one graphics adapter, and Vigil falls back to `preserve` and logs why when they are not. |
| `exclude` | Substrings matched against a display's hardware id and EDID name. Anything matching stays out of the topology. `vigil setup` fills this in for you. |
| `watchdog` | When to check that a picture exists. Every trigger is independent; turn off the ones you do not want. |
| `safety.refuseIfOnlyDisplay` | Keep this on unless you are always sitting at the machine. |

Nothing is guessed at run time. Every machine's display setup has its own
history, and a tool that tries to infer intent gets it wrong in a way you only
discover remotely.

## How it works

Two Windows details do the heavy lifting, and both are easy to get wrong.

**Reading the truth.** `EnumDisplayDevices` lies in clone mode: several
monitors showing one picture means exactly one active *source*, reported as
"Generic Non-PnP Monitor". That reads as "the virtual display is broken" when
nothing is wrong — a diagnosis that cost real hours before this project existed.
Vigil uses `QueryDisplayConfig`, which enumerates every target and tells the
truth.

**Writing it back.** `DisplaySwitch.exe /clone` duplicates onto everything,
including the laptop panel you were trying to leave dark; it cannot be selective.
An exact topology only comes from handing `SetDisplayConfig` the precise set of
paths to keep - along with the modes they are already using. Blanking the mode
indices and letting Windows re-derive them looks harmless and is not: it picks
conservatively, and a 2560x1440 monitor cloned with a virtual one lands on
1024x768. Worse, that choice is saved and comes back on every reconnect.

Details, including everything learned about the virtual display driver, are in
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## When it does not work

Every Windows install has its own accumulated history of drivers, dead monitors
and half-removed remote-desktop software. `vigil doctor` exists for exactly
that, and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) has a section per
failure — including the ones Vigil cannot fix on its own, such as a remote
client asking for a resolution the virtual monitor does not offer.

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11. The driver is documented as "Windows 10 only" and works fine on 11, including 25H2 with Secure Boot on |
| Rights | Administrator, to attach a display device |
| Session | The **console** session. Remote Desktop creates its own session with its own display and needs none of this |

## Credits

The virtual display comes from **Amyuni Technologies**' usbmmidd_v2 driver,
used under its own licence. Vigil is not affiliated with Amyuni, ships none of
their files, and downloads the package from their site so what you install is
the genuine signed driver. See [docs/CREDITS.md](docs/CREDITS.md).

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with Google, Amyuni Technologies, or any remote desktop vendor.
