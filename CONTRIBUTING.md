# Contributing

Vigil is small on purpose. Most useful changes are small too.

## Before anything else

Read [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). Several things in this
codebase look wrong until you know why they are that way, and the document
exists so nobody has to rediscover them.

## Running from a clone

```powershell
git clone https://github.com/Vovka666/vigil.git
cd vigil
.\vigil.cmd status
.\vigil.cmd doctor
```

Nothing to install first. Windows PowerShell 5.1 ships with Windows.

Anything that attaches or detaches a display needs an administrator prompt.

## House rules

- **Plain ASCII in `.ps1` files.** Enforced in CI. Windows PowerShell 5.1 reads
  a script without a byte-order mark using the system code page, so one em dash
  in a comment breaks the file for anyone on a non-Latin locale, with a parse
  error pointing at the wrong line.
- **Windows PowerShell 5.1 syntax.** No ternaries, no `??`, nothing that needs
  PowerShell 7. The point is that it runs on an untouched machine.
- **No dependencies.** Not a module from the gallery, not a helper binary.
- **Never leave the machine without a picture.** Any new path that changes the
  topology must be unable to end with zero active displays. This is the rule the
  whole tool exists to keep.
- **Read the truth, not a convenient approximation.** `QueryDisplayConfig`, not
  `EnumDisplayDevices`; the device tree, not a substring of a monitor name.
- **Touch only our own virtual display.** Other software installs its own; those
  are reported and left alone.
- **Report, do not guess.** If Vigil cannot determine something, say so. A wrong
  answer about displays is discovered remotely, at the worst possible moment.

## Testing

There is no unit test suite, and mocking would not help: every interesting
behaviour is an assumption about how Windows and a third-party driver behave.
What a change actually needs:

```powershell
vigil doctor      every layer against a live machine
vigil status      before and after
```

If you touched the topology code, test the case that matters:

1. `vigil on`, confirm the intended displays are lit and no others.
2. `vigil off` **with only the virtual display active** - it must refuse.
3. Switch a real monitor on, `vigil off` again - it must proceed.

If you touched the watchdog, run the task the way Task Scheduler does rather
than from your shell, because the principal and session differ:

```powershell
schtasks /run /tn "\Vigil\Vigil ensure (timer)"
vigil log
```

Say in the pull request which Windows build you tested on. Display behaviour
varies more between builds than anything else here.

## Adding another virtual display backend

`src/Driver.ps1` is a seam. A backend needs four things:

- detect whether its driver is registered
- attach a virtual monitor
- detach one
- identify its monitors in the device tree, by adapter name in
  `src/Monitor.ps1`

Nothing above that layer should need changing. Parsec VDD and IddSampleDriver
are the obvious candidates - both offer resolutions and refresh rates Amyuni's
driver does not.

## Reporting a problem

Open an issue with the output of `vigil doctor`. It deliberately prints no
machine name, user name or serial, so it is safe to paste as-is.

Please say what you connect with - Chrome Remote Desktop, Parsec, VNC, AnyDesk -
and whether the machine has a monitor physically attached. Those two facts
determine which half of the tool is involved.

## Scope

In scope: making sure a display exists, and controlling which displays form the
desktop.

Out of scope unless it clearly earns its place: anything adding a dependency, a
background service, telemetry, or a second thing to configure. Window and icon
layout restoration is a real problem and a genuinely hard one - it belongs in
its own project rather than bolted onto this one.
