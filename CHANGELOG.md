# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-09

First release. Built and verified on Windows 11 Home 25H2 (build 26200) with
Secure Boot enabled.

### Added

- Virtual display management: attach, detach, and rebuild the display topology
  around it through the CCD API, keeping exactly the screens you name.
- **Watchdog.** Four independent triggers - logon, resume from sleep, boot, and
  a five-minute timer - each checking that this machine has a picture at all,
  and acting only when it does not.
- **Interlock.** Removing the virtual display is refused while it is the only
  active picture, so a remote machine cannot be blinded with no way back.
- **Ownership detection.** Virtual displays belonging to Parsec, Quest Link,
  spacedesk and others are identified through the device tree, reported, and
  left alone.
- `vigil doctor`, checking each assumption separately and naming what fails.
  Prints no machine name, user name or serial.
- `vigil setup`, listing the displays this machine knows about and storing
  hardware ids rather than positions.
- Desktop shortcuts that carry elevation through Task Scheduler, so no UAC
  prompt appears on the machine whose screen has gone black.
- Configuration in `C:\ProgramData\Vigil\config.json` for topology, exclusions,
  watchdog triggers and the safety interlock.

### Notes on display behaviour

- Topology is applied with the modes already in use. Letting Windows re-derive
  them downgrades a cloned 2560x1440 monitor to 1024x768 and saves that choice
  to the display database, where it survives every reconnect.
- `clone` requires all kept displays to share one graphics adapter. Where they
  do not, Vigil keeps the current arrangement and logs why rather than failing
  with ERROR_INVALID_PARAMETER and leaving the exclusion list silently inert.
- A virtual display with no active path is recovered by re-attaching the device,
  not by asking Windows for a full extend topology - the latter also lights
  excluded displays and resets resolutions machine-wide.

### Notes

- The Amyuni usbmmidd_v2 driver is downloaded from the vendor at install time
  and verified WHQL-signed before use. It is not redistributed here; see
  docs/CREDITS.md.
- Every script is plain ASCII, enforced in CI. Windows PowerShell 5.1 reads a
  script without a byte-order mark using the system code page, and a single
  non-ASCII character breaks parsing on non-Latin locales.
