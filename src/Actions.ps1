<#
    What Vigil actually does: on, off, and the watchdog.

    The one rule the whole tool is built around: never leave the machine with
    no picture. On a computer you are sitting at, a black screen is annoying.
    On a machine you reach only through Chrome Remote Desktop it is a lockout -
    the session has nothing to render, so there is no way to undo the mistake
    remotely. Every path below refuses rather than risk that.
#>

function Get-VigilState {
    <#
    .SYNOPSIS
        One picture of the situation: what is lit, what is virtual, what is real.
    #>
    [CmdletBinding()]
    param([hashtable] $Config = (Read-VigilConfig))

    $active = @(Get-VigilTarget -ActiveOnly)
    # One sweep of the device tree, filtered three ways.
    $all = @(Get-VigilMonitor)
    $own = @($all | Where-Object { $_.Owner -eq $Config.backend -and $_.Present })
    $foreign = @($all | Where-Object { $_.IsVirtual -and $_.Owner -ne $Config.backend -and $_.Present })

    # An active target is "virtual" when its device path belongs to one of our
    # virtual monitors. Matching on the path keeps this honest when several
    # virtual displays from different vendors are attached at once.
    $ownPaths = @()
    foreach ($monitor in $own) {
        # DISPLAY\DEFAULT_MONITOR\1&15ecd195&0&UID256 -> DEFAULT_MONITOR#1&15ecd195&0&UID256
        $ownPaths += ($monitor.InstanceId -replace '^DISPLAY\\', '' -replace '\\', '#')
    }

    $activeVirtual = @()
    $activeReal = @()
    foreach ($target in $active) {
        $isOurs = $false
        foreach ($needle in $ownPaths) {
            if ($needle -and $target.DevicePath -like "*$needle*") { $isOurs = $true }
        }
        if ($isOurs) { $activeVirtual += $target } else { $activeReal += $target }
    }

    [pscustomobject]@{
        ActiveTargets   = $active
        ActiveReal      = $activeReal
        ActiveVirtual   = $activeVirtual
        RealCount       = $activeReal.Count
        VirtualCount    = $activeVirtual.Count
        OwnMonitors     = $own
        ForeignVirtual  = $foreign
        AllMonitors     = $all
        HasPicture      = ($active.Count -gt 0)
        DriverInstalled = (Test-VigilDriverInstalled)
    }
}

function Invoke-VigilOn {
    <#
    .SYNOPSIS
        Bring the virtual display up and rebuild the topology around it.
    #>
    [CmdletBinding()]
    param([hashtable] $Config = (Read-VigilConfig))

    Write-VigilLog 'requested' -Tag 'ON'

    if (-not (Test-VigilDriverInstalled)) {
        Write-VigilLog 'driver is not registered - run: vigil install' -Tag 'ON'
        return [pscustomobject]@{ Succeeded = $false; Reason = 'driver-missing' }
    }

    $existing = @(Get-VigilOwnMonitor -Backend $Config.backend)
    if ($existing.Count -eq 0) {
        Write-VigilLog 'attaching a virtual monitor' -Tag 'ON'
        if (-not (Add-VigilVirtualDisplay -Config $Config)) {
            Write-VigilLog 'the monitor did not appear' -Tag 'ON'
            return [pscustomobject]@{ Succeeded = $false; Reason = 'attach-failed' }
        }
    } else {
        Write-VigilLog "virtual monitor already attached ($($existing.Count))" -Tag 'ON'
    }

    # The device can be attached while having no active path - after being
    # excluded once, or after Windows rearranged things. Filtering active paths
    # cannot bring it back, so the device is detached and attached again:
    # Windows lights a newly arrived monitor by itself.
    #
    # The blunt alternative, asking for a full extend topology, also works and
    # is much worse: it lights every display including the ones deliberately
    # excluded, and resets resolutions across the machine.
    $before = Get-VigilState -Config $Config
    if ($before.VirtualCount -eq 0) {
        Write-VigilLog 'virtual monitor is attached but dark - re-attaching it' -Tag 'ON'
        Remove-VigilVirtualDisplay -Config $Config | Out-Null
        Start-Sleep -Seconds 1
        if (-not (Add-VigilVirtualDisplay -Config $Config)) {
            Write-VigilLog 'the monitor did not come back' -Tag 'ON'
            return [pscustomobject]@{ Succeeded = $false; Reason = 'reattach-failed' }
        }
        Start-Sleep -Seconds 2
    }

    $result = Set-VigilTopology -Exclude $Config.exclude -Mode $Config.topology
    foreach ($line in ($result.Report -split "`n")) { if ($line.Trim()) { Write-VigilLog $line.TrimEnd() -Tag 'ON' } }
    Write-VigilLog "SetDisplayConfig rc=$($result.ResultCode) ($($result.Meaning))" -Tag 'ON'

    [pscustomobject]@{
        Succeeded = $result.Succeeded
        Reason    = $(if ($result.Succeeded) { 'ok' } else { "topology-rc-$($result.ResultCode)" })
        Report    = $result.Report
    }
}

function Invoke-VigilOff {
    <#
    .SYNOPSIS
        Take the virtual display away - for example before plugging a TV in.
    .DESCRIPTION
        Blocked while the virtual display is the only thing showing a picture.
        That interlock is the difference between a tidy-up and losing access to
        the machine until someone walks over to it.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Config = (Read-VigilConfig),
        [switch] $Force
    )

    Write-VigilLog 'requested' -Tag 'OFF'
    $state = Get-VigilState -Config $Config
    Write-VigilLog "real displays lit: $($state.RealCount)" -Tag 'OFF'

    if ($state.RealCount -le 0 -and $Config.safety.refuseIfOnlyDisplay -and -not $Force) {
        Write-VigilLog 'REFUSED: the virtual display is the only picture' -Tag 'OFF'
        return [pscustomobject]@{
            Succeeded = $false
            Reason    = 'would-leave-no-display'
            Message   = 'The virtual display is the only active picture. Switch a real monitor on first, or pass -Force if you are sitting at the machine.'
        }
    }

    $removed = Remove-VigilVirtualDisplay -Config $Config
    Write-VigilLog $(if ($removed) { 'removed' } else { 'some virtual monitors remain' }) -Tag 'OFF'

    [pscustomobject]@{
        Succeeded = $removed
        Reason    = $(if ($removed) { 'ok' } else { 'detach-incomplete' })
    }
}

function Invoke-VigilEnsure {
    <#
    .SYNOPSIS
        The watchdog: guarantee this machine has a display, and do nothing if
        it already does.
    .DESCRIPTION
        Runs at logon, on resume from sleep and on a timer. It is deliberately
        quiet and idempotent - most of the time it looks, finds a picture, and
        exits without touching anything.

        It intervenes in the case that actually hurts: no active display at all.
        That is a server with nothing plugged in, a laptop whose lid closed
        while docked, a monitor switched off at the wall, or a GPU that dropped
        every output coming out of sleep. Windows responds to all of these by
        collapsing to a tiny fallback desktop and shuffling every window into
        the corner - if it renders at all.
    #>
    [CmdletBinding()]
    param([hashtable] $Config = (Read-VigilConfig))

    $state = Get-VigilState -Config $Config

    if ($state.ActiveTargets.Count -gt 0) {
        # Something is lit. Nothing to do, and saying so keeps the log useful.
        Write-VigilLog ("picture present (real $($state.RealCount), virtual $($state.VirtualCount)) - nothing to do") -Tag 'ENSURE'
        return [pscustomobject]@{ Acted = $false; Reason = 'already-has-picture' }
    }

    Write-VigilLog 'NO active display - bringing the virtual one up' -Tag 'ENSURE'
    $result = Invoke-VigilOn -Config $Config

    [pscustomobject]@{
        Acted     = $true
        Succeeded = $result.Succeeded
        Reason    = $result.Reason
    }
}

function Format-VigilStatus {
    <#
    .SYNOPSIS
        The human-readable status screen.
    #>
    [CmdletBinding()]
    param([hashtable] $Config = (Read-VigilConfig))

    $state = Get-VigilState -Config $Config
    $session = Get-VigilSessionInfo
    $lines = @()

    $lines += 'Vigil - display status'
    $lines += ('=' * 60)

    if (-not $state.HasPicture) {
        $lines += 'NO ACTIVE DISPLAY - this machine is rendering nothing right now.'
        $lines += 'Run: vigil on'
    } else {
        $lines += "Active displays: $($state.ActiveTargets.Count)  (real $($state.RealCount), virtual $($state.VirtualCount))"
    }
    $lines += ''

    # Several CCD paths can point at one physical target; collapse them so the
    # list reads like the back of the machine rather than like an API dump.
    $seen = @{}
    foreach ($target in $state.ActiveTargets) {
        if ($seen.ContainsKey($target.DevicePath)) { continue }
        $seen[$target.DevicePath] = $true
        $isVirtual = $state.ActiveVirtual | Where-Object { $_.DevicePath -eq $target.DevicePath }
        $kind = if ($isVirtual) { 'virtual' } else { 'real   ' }
        $name = if ($target.FriendlyName) { $target.FriendlyName } else { '(no EDID name)' }
        $mode = if ($target.Width) { "$($target.Width)x$($target.Height) @ $($target.RefreshHz)Hz" } else { '-' }
        $lines += ("  [{0}] {1,-28} {2}" -f $kind, $name, $mode)
    }

    $ghosts = @($state.AllMonitors | Where-Object { -not $_.Present })
    if ($ghosts.Count -gt 0) {
        $lines += ''
        $lines += "Remembered but not attached ($($ghosts.Count)):"
        foreach ($ghost in $ghosts) { $lines += ("  - {0}" -f $ghost.Name) }
    }

    if ($state.ForeignVirtual.Count -gt 0) {
        $lines += ''
        $lines += 'Virtual displays owned by other software (left alone):'
        foreach ($other in $state.ForeignVirtual) { $lines += ("  - {0} [{1}]" -f $other.Adapter, $other.Owner) }
    }

    $lines += ''
    $lines += ("Session: {0}   remote hosts installed: {1}" -f $session.SessionKind,
               $(if ($session.RemoteHosts) { $session.RemoteHosts -join ', ' } else { 'none detected' }))
    if ($Config.exclude.Count -gt 0) {
        $lines += ("Excluded from the topology: {0}" -f ($Config.exclude -join ', '))
    }
    $lines -join "`n"
}
