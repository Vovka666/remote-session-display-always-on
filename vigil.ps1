<#
.SYNOPSIS
    Vigil - keep a Windows machine from ever being without a display.

.DESCRIPTION
    Commands:
      status              what is lit right now, and what Windows remembers
      on                  attach the virtual display and rebuild the topology
      off                 remove it (refuses while it is the only picture)
      ensure              the watchdog: act only if there is no picture at all
      attach              attach the virtual device only, no topology change
      doctor              check every assumption and name what is wrong
      setup               choose which displays to keep, and write the config
      install             driver, tasks and shortcuts
      uninstall           remove tasks and shortcuts (the driver stays)
      config              show the configuration file
      log                 show the last lines of the log

.EXAMPLE
    .\vigil.ps1 status

.EXAMPLE
    .\vigil.ps1 install -ExcludeDisplay NCP004D

.EXAMPLE
    .\vigil.ps1 off -Force
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'on', 'off', 'ensure', 'attach', 'doctor', 'setup',
                 'install', 'uninstall', 'config', 'log', 'help', 'version')]
    [string] $Command = 'status',

    # install: leave these displays out of the topology (substring match on the
    # device path or the EDID name).
    [string[]] $ExcludeDisplay,

    # install: use an already downloaded usbmmidd_v2.zip instead of fetching it.
    [string] $FromZip,

    # off: proceed even if it would leave no picture. Only from the keyboard.
    [switch] $Force,

    # install: skip desktop shortcuts.
    [switch] $NoShortcuts,

    # log: how many lines.
    [int] $Tail = 40
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:VigilVersion = '1.0.0'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($part in 'Config', 'Display', 'Monitor', 'Driver', 'Actions', 'Tasks', 'Doctor') {
    $file = Join-Path $here "src\$part.ps1"
    if (-not (Test-Path $file)) { throw "missing component: $file" }
    . $file
}

function Assert-Elevated {
    param([string] $What)
    if (Test-VigilElevated) { return }
    throw ("'$What' needs administrator rights. Right-click PowerShell and " +
           "choose Run as administrator, or use the desktop shortcuts, which " +
           "carry elevation without prompting.")
}

switch ($Command) {

    'version' { "vigil $script:VigilVersion" }

    'help' { Get-Help $MyInvocation.MyCommand.Path -Detailed }

    'status' { Format-VigilStatus }

    'doctor' { Format-VigilDoctor -Report (Invoke-VigilDoctor) }

    'on' {
        Assert-Elevated -What 'on'
        $result = Invoke-VigilOn
        if ($result.Succeeded) { 'Virtual display is up.' }
        else { Write-Warning "Could not bring it up: $($result.Reason)"; exit 1 }
    }

    'off' {
        Assert-Elevated -What 'off'
        $result = Invoke-VigilOff -Force:$Force
        if ($result.Succeeded) {
            'Virtual display removed.'
        } else {
            # Deliberately loud: this is the interlock that stops a remote
            # session from going dark with no way back.
            Write-Warning $(if ($result.PSObject.Properties.Name -contains 'Message') { $result.Message } else { $result.Reason })
            exit 1
        }
    }

    'ensure' {
        $result = Invoke-VigilEnsure
        if ($result.Acted) { "No display was active - brought the virtual one up ($($result.Reason))." }
        else { 'A display is already active; nothing to do.' }
    }

    'attach' {
        # Device-level only. Used by the boot-time task, which runs before any
        # user session exists and therefore cannot touch topology.
        $config = Read-VigilConfig
        if (@(Get-VigilOwnMonitor -Backend $config.backend).Count -gt 0) {
            Write-VigilLog 'virtual monitor already attached' -Tag 'BOOT'
            'Already attached.'
        } else {
            Write-VigilLog 'attaching at boot' -Tag 'BOOT'
            $ok = Add-VigilVirtualDisplay -Config $config
            Write-VigilLog $(if ($ok) { 'attached' } else { 'attach failed' }) -Tag 'BOOT'
            if ($ok) { 'Attached.' } else { Write-Warning 'Attach failed.'; exit 1 }
        }
    }

    'config' {
        $path = Get-VigilConfigPath
        if (Test-Path $path) { "# $path"; Get-Content $path -Raw }
        else { "No config file yet. Defaults are in use; run 'vigil setup' to write one.`n# would be: $path" }
    }

    'log' {
        $path = Get-VigilLogPath
        if (Test-Path $path) { Get-Content $path -Tail $Tail }
        else { "No log yet: $path" }
    }

    'setup' {
        # Interactive: the exclusion list is the one setting nobody can guess
        # for you, because only you know which panel should stay dark.
        $config = Read-VigilConfig
        $targets = @(Get-VigilTarget | Sort-Object -Property DevicePath -Unique)

        Write-Host ''
        Write-Host 'Displays this machine knows about:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $targets.Count; $i++) {
            $target = $targets[$i]
            $name = if ($target.FriendlyName) { $target.FriendlyName } else { '(no EDID name)' }
            $mark = if ($target.Active) { 'lit' } else { '   ' }
            Write-Host ("  [{0}] {1}  {2,-28} {3}" -f $i, $mark, $name, $target.DevicePath)
        }
        Write-Host ''
        Write-Host 'Enter the numbers of displays to EXCLUDE from the topology,'
        Write-Host 'comma separated - typically a laptop panel you keep dark.'
        Write-Host 'Press Enter to exclude none.'
        $answer = Read-Host 'Exclude'

        $exclude = @()
        if ($answer.Trim()) {
            foreach ($piece in $answer.Split(',')) {
                $index = 0
                if ([int]::TryParse($piece.Trim(), [ref]$index) -and $index -ge 0 -and $index -lt $targets.Count) {
                    # Store the hardware id, not the index: indexes move around
                    # as monitors are plugged and unplugged.
                    $path = $targets[$index].DevicePath
                    if ($path -match 'DISPLAY#([^#]+)#') { $exclude += $Matches[1] }
                }
            }
        }
        $config.exclude = $exclude
        $written = Write-VigilConfig -Config $config
        Write-Host ''
        Write-Host ("Excluding: " + $(if ($exclude) { $exclude -join ', ' } else { '(nothing)' })) -ForegroundColor Green
        Write-Host "Written to $written"
    }

    'install' {
        Assert-Elevated -What 'install'
        $config = Read-VigilConfig
        if ($ExcludeDisplay) { $config.exclude = @($ExcludeDisplay) }

        Write-Host 'Installing Vigil' -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path (Get-VigilRoot) | Out-Null

        # The scheduled tasks call a fixed path, so the entry point and its
        # components live under ProgramData rather than wherever the repository
        # happened to be cloned.
        Copy-Item (Join-Path $here 'vigil.ps1') (Get-VigilRoot) -Force
        $srcTarget = Join-Path (Get-VigilRoot) 'src'
        New-Item -ItemType Directory -Force -Path $srcTarget | Out-Null
        Copy-Item (Join-Path $here 'src\*.ps1') $srcTarget -Force
        Write-Host ("  [ok] installed to " + (Get-VigilRoot))

        Install-VigilDriverFiles -Config $config -FromZip $FromZip | Out-Null
        Write-Host '  [ok] driver package in place'

        Install-VigilDriver -Config $config | Out-Null
        Write-Host '  [ok] driver registered'

        Write-VigilConfig -Config $config | Out-Null
        Write-Host '  [ok] configuration written'

        $tasks = @(Install-VigilTask -Config $config)
        Write-Host ("  [ok] {0} scheduled tasks" -f $tasks.Count)

        if (-not $NoShortcuts) {
            $links = @(New-VigilShortcut)
            Write-Host ("  [ok] {0} desktop shortcuts" -f $links.Count)
        }

        Write-Host ''
        Write-Host 'Done. Next:' -ForegroundColor Green
        Write-Host '  vigil doctor    check everything'
        Write-Host '  vigil on        bring the virtual display up now'
    }

    'uninstall' {
        Assert-Elevated -What 'uninstall'
        $removedTasks = @(Uninstall-VigilTask)
        $removedLinks = @(Remove-VigilShortcut)
        Write-Host ("Removed {0} tasks and {1} shortcuts." -f $removedTasks.Count, $removedLinks.Count)
        Write-Host 'The display driver and C:\ProgramData\Vigil were left in place.'
        Write-Host 'To remove the driver as well:'
        Write-Host ('  {0} stop usbmmidd' -f (Get-VigilDeviceInstaller -Config (Read-VigilConfig)))
        Write-Host ('  {0} remove usbmmidd' -f (Get-VigilDeviceInstaller -Config (Read-VigilConfig)))
    }
}
