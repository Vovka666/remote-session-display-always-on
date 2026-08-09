# How it works

Everything here was established on real machines. Where something cost hours to
work out, it is written down as such, because the next person will hit it too.

## The shape of the problem

Windows composes a desktop for the display targets it currently has. Remove
them all and there is nothing to compose onto: it falls back to a minimal
surface, drags every window into the corner, and remote-desktop tools capture
that. Give it one display it cannot lose and the whole class of symptoms —
wrong resolution, misplaced cursor, keyboard going nowhere — disappears at once.

So Vigil does two things: make sure a display exists, and control which displays
form the desktop.

## Reading the display configuration

Use `QueryDisplayConfig` (the CCD API). Nothing else is trustworthy.

`EnumDisplayDevices` **lies in clone mode**. When several monitors show the same
picture there is exactly one active *source*, and it reports itself as "Generic
Non-PnP Monitor" rather than naming the real screens. Reading that as "the
virtual display driver stopped working on this Windows build" is an easy and
expensive mistake — it sent the original investigation off replacing a driver
that was working perfectly.

`QueryDisplayConfig` enumerates targets, so every connector appears with its
device path and EDID name.

Two things surprise people about its output:

- **One physical monitor can appear several times.** Windows remembers many
  source/target pairings. Anything user-facing must collapse by device path.
- **Resolution is not in the path.** It lives in the source *mode*, as the
  first two DWORDs of a 48-byte union, reachable through `src.modeInfoIdx`.

`src/Display.ps1` wraps all of this.

## Writing it back

`DisplaySwitch.exe /clone` is not usable. It duplicates onto **everything**
present, including the laptop panel you were specifically trying to leave dark,
and it has no way to be selective.

An exact topology comes only from `SetDisplayConfig` with a supplied path array:

1. Query the active paths.
2. Drop the ones matching the exclusion list.
3. Set `modeInfoIdx` to `0xFFFFFFFF` on both source and target so Windows picks
   suitable modes itself.
4. Set `DISPLAYCONFIG_PATH_ACTIVE` on what remains.
5. Apply with `SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES`.

For a clone, give every kept path the **same source** — one source driving many
targets is precisely what clone mode is.

If the exclusion list would leave nothing active, Vigil refuses and returns
`-999` rather than applying it.

## The virtual display

The backend is Amyuni's usbmmidd_v2, an indirect display driver (IDD).

- `deviceinstaller64 install usbmmidd.inf usbmmidd` registers it. Once.
- `deviceinstaller64 enableidd 1` attaches a monitor. Up to four.
- `deviceinstaller64 enableidd 0` detaches one — call it once per monitor.

Worth knowing:

- **It works on Windows 11**, including 25H2 with Secure Boot enabled, despite
  the vendor's instructions saying "Windows 10 Only". The driver is WHQL-signed
  by "Microsoft Windows Hardware Compatibility Publisher", which is why.
- **Judge the signature by `usbmmidd.cat`, not by `deviceinstaller64.exe`.** The
  helper executable is unsigned, as command line tools often are. Checking the
  wrong file reports every healthy installation as suspect.
- **Attaching is not instant.** Windows takes a second or two to enumerate the
  new monitor, and a topology call made too early will not see it. Vigil polls
  for up to six seconds.
- **The resolution list lives in the registry**, not in the driver — see
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-picture-is-there-but-the-resolution-is-wrong).
  Editing the `.inf` to change it invalidates the signature.

Vigil ships none of these files. `install` downloads the package from the
vendor's own URL, so what lands on the machine is current and genuine, and this
repository does not redistribute someone else's signed driver.

The backend is a seam: everything above it says "add a virtual display" and
"remove one". Parsec VDD or IddSampleDriver can be added later without touching
the rest.

## Telling virtual displays apart

Matching monitor names against the string `Default_Monitor` works on one
machine and misleads everywhere else. Real machines accumulate virtual displays:
Parsec installs one, Quest Link installs "Meta Virtual Monitor", spacedesk
installs another.

Vigil asks the device tree instead. Every monitor has a parent display adapter
(`DEVPKEY_Device_Parent`), and the adapter's name identifies who owns it. So
Vigil manages only its own, reports the others, and touches none of them.

The same query separates attached monitors from ghosts. A monitor with status
`Unknown` is remembered but not connected — an unplugged screen, or a TV that is
switched off. They linger for months. Counting monitors is not the same as
counting pictures, which is why every decision Vigil makes is based on active
*paths*, not on device count.

## Elevation, without a prompt you cannot click

Attaching a display device needs administrator rights. A plain shortcut would
raise a UAC prompt every time — and a UAC prompt is exactly what you cannot
click when the screen you are fixing is the black one.

So the elevation lives in Task Scheduler: tasks are registered with
`RunLevel Highest`, and the desktop shortcuts merely ask Task Scheduler to run
them. No prompt, nothing to reach.

## Sessions

Rebuilding topology is a **per-session** call. A task running as SYSTEM would
rearrange session 0, which nobody is looking at.

So everything that touches topology runs as the interactive user. The single
exception is the boot-time task, which runs as SYSTEM and only *attaches* the
device — at that point nobody has signed in, and attaching is session
independent.

This is also why Remote Desktop is out of scope. RDP creates its own session
with its own synthetic display. Chrome Remote Desktop, Parsec, VNC and AnyDesk
attach to the console session — the one that loses every picture when the
monitors go away.

## The watchdog

`vigil ensure` is deliberately dull. It looks at the active paths; if anything
is lit, it logs that and exits. It acts only when the count is zero.

Four triggers, because each covers a case the others miss:

| Trigger | Case |
|---|---|
| logon, delayed 40 s | signing in after boot; the delay lets the GPU driver settle |
| resume from sleep | waking re-enumerates outputs and drops what is not physically there |
| startup, as SYSTEM | a headless machine before anyone signs in |
| every 5 minutes | everything else, honestly |

The timer is not elegant, and it is the one that catches the case nobody
predicted — a monitor switched off at the wall, a KVM changing input, a cable
knocked loose.

## The interlock

`vigil off` refuses while the virtual display is the only active picture.

This is the single most important behaviour in the tool. Removing it leaves the
machine rendering nothing; on a machine reached only over the network, there is
then no way to undo it remotely. The check counts *real* active targets, and
`-Force` exists for people sitting at the keyboard.

## Layout

```
vigil.ps1          CLI entry point
vigil.cmd          convenience wrapper
src/Config.ps1     configuration, logging, elevation check
src/Display.ps1    CCD API: read topology, write topology
src/Monitor.ps1    device tree: who owns which virtual monitor, session kind
src/Driver.ps1     the backend: download, register, attach, detach
src/Actions.ps1    on / off / ensure, and the status screen
src/Tasks.ps1      scheduled tasks and shortcuts
src/Doctor.ps1     diagnostics
```

Dependency direction is one way: `Actions` uses `Display`, `Monitor` and
`Driver`; all of them use `Config`. Nothing depends on `Doctor` or the CLI.

## A note on encoding

Every `.ps1` here is plain ASCII, and the CI enforces it.

Windows PowerShell 5.1 reads a script without a byte-order mark using the
**system code page**, not UTF-8. On a Russian or Greek machine an em dash in a
comment becomes three bytes, one of which is a quote character, and the script
stops parsing with an error pointing at the wrong line entirely. Sticking to
ASCII removes the failure mode for everyone.
