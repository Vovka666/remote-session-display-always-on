<#
    Telling virtual monitors apart.

    A real machine collects these: Parsec installs one, Quest Link installs
    "Meta Virtual Monitor", spacedesk installs another, and a dead HDMI cable
    leaves ghosts behind for months. Matching on the string "Default_Monitor"
    was good enough on one laptop and is wrong everywhere else.

    Vigil asks the device tree instead: every monitor has a parent display
    adapter, and the adapter's name says who owns it. That way Vigil manages
    only its own virtual display and reports the rest without touching them.
#>

# Display adapters known to present virtual monitors. The key is the owner id
# Vigil uses internally; the values are matched against the adapter name.
$script:VigilVirtualAdapters = [ordered]@{
    'amyuni'  = @('USB Mobile Monitor Virtual Display')
    'parsec'  = @('Parsec Virtual Display')
    'idd'     = @('IddSampleDriver', 'Virtual Display Driver', 'MTT Virtual Display')
    'meta'    = @('Meta Virtual Monitor', 'Oculus Virtual')
    'spacedesk' = @('spacedesk')
    'duet'    = @('Duet Display')
    'rdp'     = @('Remote Desktop Graphics', 'Microsoft Remote Display')
}

function Get-VigilMonitor {
    <#
    .SYNOPSIS
        Every monitor device, with the adapter behind it and who owns that
        adapter.
    .DESCRIPTION
        Status 'OK' means present. 'Unknown' means the device is remembered but
        not attached - an unplugged monitor or a TV that is switched off. Those
        ghosts are why counting monitors is not the same as counting pictures.
    #>
    [CmdletBinding()]
    param()

    $monitors = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue)
    foreach ($monitor in $monitors) {
        $adapterName = ''
        try {
            $parentId = (Get-PnpDeviceProperty -InstanceId $monitor.InstanceId `
                            -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
            if ($parentId) {
                $parent = Get-PnpDevice -InstanceId $parentId -ErrorAction SilentlyContinue
                if ($parent) { $adapterName = $parent.FriendlyName }
            }
        } catch {
            # Some systems refuse the property; the monitor is still reportable.
        }

        $owner = ''
        foreach ($key in $script:VigilVirtualAdapters.Keys) {
            foreach ($needle in $script:VigilVirtualAdapters[$key]) {
                if ($adapterName -and $adapterName -like "*$needle*") { $owner = $key; break }
            }
            if ($owner) { break }
        }

        [pscustomobject]@{
            InstanceId  = $monitor.InstanceId
            Name        = $monitor.FriendlyName
            Status      = $monitor.Status          # OK = attached, Unknown = ghost
            Present     = ($monitor.Status -eq 'OK')
            Adapter     = $adapterName
            IsVirtual   = [bool]$owner
            Owner       = $(if ($owner) { $owner } else { 'physical' })
        }
    }
}

function Get-VigilOwnMonitor {
    <#
    .SYNOPSIS
        The virtual monitors created by the backend Vigil manages.
    #>
    [CmdletBinding()]
    param([string] $Backend = 'amyuni')

    Get-VigilMonitor | Where-Object { $_.Owner -eq $Backend -and $_.Present }
}

function Get-VigilForeignVirtual {
    <#
    .SYNOPSIS
        Virtual monitors belonging to something else - Parsec, Quest Link,
        spacedesk. Reported so a confusing setup is visible, never touched.
    #>
    [CmdletBinding()]
    param([string] $Backend = 'amyuni')

    Get-VigilMonitor | Where-Object { $_.IsVirtual -and $_.Owner -ne $Backend -and $_.Present }
}

function Get-VigilSessionInfo {
    <#
    .SYNOPSIS
        What kind of session this is, and which remote-access hosts are installed.
    .DESCRIPTION
        The two are different questions and conflating them misleads. The
        session type is authoritative: real RDP opens its own session with its
        own display and needs nothing from Vigil, while Chrome Remote Desktop,
        Parsec and VNC attach to the physical console - which is exactly the
        session that goes dark when the last monitor does.

        A running remoting host only means the software is installed. It says
        nothing about whether anyone is connected right now, and Vigil does not
        pretend otherwise.
    #>
    [CmdletBinding()]
    param()

    $isRdp = ($env:SESSIONNAME -and $env:SESSIONNAME -like 'RDP-*')

    $hosts = @()
    if (Get-Process -Name 'remoting_host' -ErrorAction SilentlyContinue) { $hosts += 'chrome-remote-desktop' }
    if (Get-Process -Name 'parsecd' -ErrorAction SilentlyContinue)       { $hosts += 'parsec' }
    if (Get-Process -Name 'winvnc*', 'tvnserver' -ErrorAction SilentlyContinue) { $hosts += 'vnc' }
    if (Get-Process -Name 'AnyDesk' -ErrorAction SilentlyContinue)       { $hosts += 'anydesk' }
    if (Get-Process -Name 'TeamViewer_Service' -ErrorAction SilentlyContinue) { $hosts += 'teamviewer' }

    [pscustomobject]@{
        SessionName  = $env:SESSIONNAME
        SessionKind  = $(if ($isRdp) { 'rdp' } else { 'console' })
        RemoteHosts  = $hosts          # installed and running, not necessarily connected
        # RDP synthesises its own display; the console session is the one that
        # loses every picture when the monitors go away.
        NeedsVirtual = (-not $isRdp)
    }
}
