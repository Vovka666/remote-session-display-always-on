# Credits and third-party software

## Amyuni usbmmidd_v2

The virtual display itself is not Vigil's work. It comes from the **USB Mobile
Monitor Virtual Display** driver by **Amyuni Technologies Inc.**

- <https://www.amyuni.com>
- Package: <https://www.amyuni.com/downloads/usbmmidd_v2.zip>

Vigil orchestrates that driver: it installs it, attaches and detaches monitors,
and builds the display topology around them. Without Amyuni's driver there is
nothing to orchestrate, and this acknowledgement is required by their licence.

**Vigil ships none of their files.** `vigil install` downloads the package from
the vendor's own URL and verifies that the driver catalogue is signed by
"Microsoft Windows Hardware Compatibility Publisher" before registering it. Two
reasons:

1. What you install is the genuine, current, WHQL-signed driver — not a copy of
   unknown age sitting in a GitHub repository.
2. Redistributing someone else's signed driver in a third-party project invites
   questions nobody needs to answer.

The licence, reproduced from `License.txt` in the package:

> Copyright 2014-2021 Amyuni Technologies Inc.
> <https://www.amyuni.com>
>
> This software is provided 'as-is', without any express or implied warranty. In
> no event will the authors be held liable for any damages arising from the use
> of this software. By using this software, you accept to be prompted with an
> advertisement page which is not always under the control of the author. A
> fully commercial version is available for users who do not wish to see those
> advertisements.
>
> Permission is granted to anyone to use this software for any purpose subject
> to the following restrictions:
>
> 1. The origin of this software must not be misrepresented; you must not claim
>    that you wrote the original software. If you use this software in a
>    product, an acknowledgment in the product documentation would be required.
> 2. Altered versions must be plainly marked as such, and must not be
>    misrepresented as being the original software.
> 3. This notice may not be removed or altered from any distribution.

Vigil does not alter the package in any way.

**Vigil is not affiliated with, endorsed by, or supported by Amyuni
Technologies.** Problems with Vigil belong in Vigil's issue tracker, not theirs.

## Other virtual display drivers

Vigil recognises these by their display adapter name so it can report them and
leave them alone. It does not install, manage or interfere with any of them.

| Software | Adapter |
|---|---|
| Parsec | Parsec Virtual Display Adapter |
| IddSampleDriver / Virtual Display Driver | IddSampleDriver, Virtual Display Driver, MTT Virtual Display |
| Meta Quest Link | Meta Virtual Monitor |
| spacedesk | spacedesk |
| Duet Display | Duet Display |

If you use one of these and would rather Vigil drove it instead of Amyuni's,
the backend is a seam and a pull request is welcome — see
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Windows APIs

The topology work uses the Connecting and Configuring Displays (CCD) API:
`QueryDisplayConfig`, `SetDisplayConfig`, `DisplayConfigGetDeviceInfo`,
documented by Microsoft. No undocumented calls are used.

## Trademarks

Windows is a trademark of Microsoft Corporation. Chrome Remote Desktop is a
product of Google LLC. Parsec, AnyDesk, TeamViewer, spacedesk, Duet Display and
Meta Quest are trademarks of their respective owners. Vigil is not affiliated
with any of them; they are named only to say what it does and does not touch.
