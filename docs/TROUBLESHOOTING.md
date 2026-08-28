# When it does not work

Start here:

```powershell
vigil doctor
```

Every heading below matches one line of that report, plus the problems that
come from outside Vigil entirely. Each says what is happening, what still
works, and what to do.

---

## `[FAIL] driver files - not found`

**Means.** The driver package is not in Vigil's folder.

**Still works.** `status` and `doctor`. Nothing that attaches or detaches a
display.

**Fix.** `vigil install`. If the machine has no internet, download
[usbmmidd_v2.zip](https://www.amyuni.com/downloads/usbmmidd_v2.zip) elsewhere and
run `vigil install -FromZip D:\usbmmidd_v2.zip`.

Already have the package unpacked somewhere? Point at it instead of downloading
a second copy — set `driverPath` in `C:\ProgramData\Vigil\config.json`.

---

## `[FAIL] driver registered - not installed`

**Means.** The files are there but Windows has not accepted the driver.

**Usually.** The install was not elevated. Run it from an administrator
PowerShell.

**Otherwise.** Something blocked the driver. Check, in this order:

- **Secure Boot is not the problem.** The package is WHQL-signed by "Microsoft
  Windows Hardware Compatibility Publisher"; `vigil doctor` prints exactly that.
  If it prints anything else, you did not get the genuine package — delete
  `C:\ProgramData\Vigil\driver` and install again.
- **Memory integrity** (Core Isolation, in Windows Security → Device security)
  refuses drivers it does not like. Turning it off is a real security decision;
  make it deliberately.
- **Managed machines.** Group policy can block driver installation outright, and
  no amount of clicking gets around it.

---

## `[FAIL] displays - NO active display at all`

**Means.** Right now this machine is rendering nothing. This is the situation
Vigil exists to prevent, and if you can read this message you are lucky enough
to still have a way in.

**Fix.** `vigil on`. Then work out why the watchdog did not: `vigil log` shows
each check it made.

---

## `[warn] exclusions - these match no display`

**Means.** You excluded something that does not exist on this machine, so the
exclusion does nothing.

**Why it matters.** It is silent. The panel you meant to keep dark stays lit,
and nothing says why.

**Fix.** `vigil setup` and pick from the list. It stores hardware ids rather
than positions, because positions change every time something is unplugged.

---

## `[warn] session - this is a Remote Desktop session`

**Means.** You are inside RDP, which creates its own session with its own
synthetic display.

**What to do.** Probably nothing — RDP does not need Vigil. Chrome Remote
Desktop, Parsec, VNC and AnyDesk are different: they attach to the *console*
session, the one that goes dark when the last monitor does. If you use both,
install Vigil for the console session and ignore this warning while inside RDP.

---

## `[warn] scheduled tasks - last run failed`

**Fix.** `vigil log` first — the watchdog records every run. Common causes:

- The account that installed Vigil changed its password, and the tasks now fail
  to start. Re-run `vigil install`.
- Vigil was cloned to a folder that has since moved. The tasks call
  `C:\ProgramData\Vigil\vigil.ps1`, which `install` puts there; re-run it.

Result code `267011` is not a failure — it means "has not run yet".

---

## The picture is there but the resolution is wrong

The virtual monitor offers a fixed list of resolutions:

```
1024x768   1360x768   1440x900   1600x900   1600x1200
1920x1080 (default)   1920x1200  2560x1440  3840x2160
```

If your remote client's screen is not close to one of these, you get black
bars or a blurry scale.

The list lives in the registry, up to ten entries:

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\usbmmIdd\Parameters\Monitors
```

Values are named `0` to `9`; the `(Default)` value picks the startup resolution.
Add what you need, then remove and re-attach the virtual display so the new
list is read:

```powershell
vigil off
vigil on
```

`vigil doctor` shows the current list. Do not edit `usbmmidd.inf` to do this —
changing that file invalidates the driver signature and Windows will refuse to
load it.

---

## The cursor is in the wrong place, or clicks land elsewhere

Almost always more than one desktop: the remote tool is capturing one display
while you are looking at another. `vigil status` shows how many are active.

Set `"topology": "clone"` so every display shows the same desktop, then
`vigil on`. With one desktop there is nowhere else for the cursor to be.

Clone needs every kept display to be on one graphics adapter. On a laptop with
an integrated GPU, a discrete GPU and a virtual display driver they usually are
not, and Vigil says so in the log rather than failing. Exclude displays until
what remains shares an adapter - `vigil status` is grouped so you can see which
do.

---

## A monitor dropped to 1024x768

Windows re-derives modes whenever it is allowed to, and it chooses
conservatively - especially for a real monitor sharing a source with a virtual
one. Vigil asks for the current modes to be kept and only lets Windows choose if
the hardware refuses; the log says which happened:

```
MODE  kept current resolutions
MODE  exact modes refused (rc=87), letting Windows choose
```

If you see the second line and a resolution changed, set it back in Windows
display settings once. That writes the new choice to Windows' display database,
and it will be preserved from then on.

## Windows rearranged all my windows

That is what happens when a display disappears: everything is pulled onto
whatever is left. Vigil prevents the *cause* — it keeps a display present — but
it does not remember where your windows were, and cannot put them back.

If it already happened, `vigil on` restores a sane desktop; the window positions
are gone.

---

## Two virtual displays appeared

Vigil attaches one. If you see two, something else attached the other — Parsec
and Quest Link both do. `vigil status` lists them under "Virtual displays owned
by other software", and Vigil never touches those.

To remove the extra one, use whatever created it. If it really is a second
Vigil display (an old script calling the driver directly, perhaps), `vigil off`
removes all of them.

---

## `off` refuses to run

Deliberate. The virtual display is the only thing rendering, so removing it
would leave no picture at all — on a remote machine, that is a lockout until
someone walks over.

Switch a real monitor on first. If you are sitting at the machine and know what
you are doing, `vigil off -Force`.

To disable the interlock permanently, set `safety.refuseIfOnlyDisplay` to
`false`. Think about it first: the day it saves you is the day you have already
forgotten it exists.

---

## Nothing happens after resume from sleep

The resume trigger fires on event 1 from `Microsoft-Windows-Power-Troubleshooter`,
which Windows logs on wake. Some machines log it late, or not at all after a
modern-standby wake.

The timer trigger is the backstop — by default it checks every five minutes.
Lower it if waking is your usual case:

```json
"watchdog": { "everyMinutes": 2 }
```

then `vigil install` to re-register the tasks.

---

## Still stuck

Open an issue with `vigil doctor` attached. It prints no machine name, user
name or serial, so it is safe to paste as-is.

<https://github.com/Vovka666/remote-session-display-always-on/issues>
