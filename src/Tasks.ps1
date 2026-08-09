<#
    Scheduled tasks and desktop shortcuts.

    Two things here are less obvious than they look.

    Elevation: attaching a display device needs administrator rights, so a
    plain shortcut would raise a UAC prompt every single time - and a UAC
    prompt is exactly what you cannot click when the screen you are trying to
    fix is the one that is black. A task registered with RunLevel Highest
    carries the elevation itself, and the shortcut merely asks Task Scheduler
    to run it. No prompt, no dialog to reach.

    Session: rebuilding the topology is a per-session call. A task running as
    SYSTEM would rearrange session 0, which nobody is looking at. So everything
    that touches topology runs as the interactive user; only the boot-time
    device attach runs as SYSTEM, because at that point there is no user yet.

    Windows: powershell.exe is a console application, so Task Scheduler gives
    it a visible conhost window and -WindowStyle Hidden only takes it away
    afterwards. Those few frames are enough to steal focus, and a five-minute
    watchdog then drops a fullscreen game to the desktop twelve times an hour.
    The tasks therefore go through a tiny WScript launcher, which starts
    PowerShell already hidden rather than hiding it after the fact.
#>

$script:VigilTaskFolder = '\Vigil'

$script:VigilTasks = @{
    On      = 'Vigil ON'
    Off     = 'Vigil OFF'
    Logon   = 'Vigil ensure (logon)'
    Resume  = 'Vigil ensure (resume)'
    Timer   = 'Vigil ensure (timer)'
    Startup = 'Vigil attach (startup)'
}

function Get-VigilTaskPath {
    param([Parameter(Mandatory)][string] $Name)
    "$script:VigilTaskFolder\$Name"
}

function Get-VigilLauncherPath {
    Join-Path (Get-VigilRoot) 'launch-hidden.vbs'
}

function Test-VigilScriptHost {
    <#
    .SYNOPSIS
        Is Windows Script Host allowed to run on this machine?
    .DESCRIPTION
        Managed machines sometimes switch it off by policy, and a disabled host
        fails silently: the task starts, exits, and the watchdog is dead while
        still looking installed. Checked so we can fall back instead.
    #>
    foreach ($root in 'HKLM:', 'HKCU:') {
        $key = Join-Path $root 'SOFTWARE\Microsoft\Windows Script Host\Settings'
        $settings = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $settings) { continue }
        # The key is normally there with no Enabled value at all, and reading a
        # property that does not exist is an error under Set-StrictMode 2.0.
        if ($settings.PSObject.Properties.Name -notcontains 'Enabled') { continue }
        if ([int]$settings.Enabled -eq 0) { return $false }
    }
    Test-Path (Join-Path $env:SystemRoot 'System32\wscript.exe')
}

function Install-VigilLauncher {
    <#
    .SYNOPSIS
        Write the windowless launcher next to the entry point.
    .DESCRIPTION
        Generated rather than shipped, so it always points at the installed
        copy and cannot drift away from it.
    #>
    [CmdletBinding()]
    param()

    # Single-quoted here-string: this is VBScript, and nothing in it should be
    # expanded by PowerShell on the way out.
    $body = @'
Option Explicit
' Vigil launcher - start a PowerShell command with no window, ever.
'
' Task Scheduler hands powershell.exe a visible console window, and
' -WindowStyle Hidden only removes it once the process is already up. wscript
' draws nothing of its own, and Run(..., 0, True) starts the child with the
' window hidden from the first frame, so nothing appears at all.
'
' Argument 0 is the PowerShell script; the rest are passed on to it. The exit
' code is propagated, so Task Scheduler still reports a real result.

Dim shell, cmd, i

If WScript.Arguments.Count < 1 Then WScript.Quit 87

Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " " & WScript.Arguments(i)
Next

WScript.Quit shell.Run(cmd, 0, True)
'@

    $path = Get-VigilLauncherPath
    Set-Content -LiteralPath $path -Value $body -Encoding ASCII
    $path
}

function New-VigilAction {
    param([Parameter(Mandatory)][string] $Command)

    $entry = Join-Path (Get-VigilRoot) 'vigil.ps1'
    $launcher = Get-VigilLauncherPath

    if ((Test-Path $launcher) -and (Test-VigilScriptHost)) {
        return New-ScheduledTaskAction -Execute 'wscript.exe' `
            -Argument ('//B //Nologo "{0}" "{1}" {2}' -f $launcher, $entry, $Command)
    }

    # A watchdog that blinks is still better than one that cannot start.
    New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" {1}' -f $entry, $Command)
}

function Register-VigilTask {
    <#
    .SYNOPSIS
        Create or replace one task, always with the same principal rules.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Command,
        [object[]] $Triggers = @(),
        [switch] $AsSystem,
        [string] $Description = ''
    )

    $action = New-VigilAction -Command $Command

    if ($AsSystem) {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
                        -LogonType Interactive -RunLevel Highest
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                    -MultipleInstances IgnoreNew
    # A watchdog that gives up because the network is not ready would be no
    # watchdog at all.
    $settings.RunOnlyIfNetworkAvailable = $false
    $settings.DisallowStartIfOnBatteries = $false

    $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Description $Description
    if ($Triggers.Count -gt 0) { $task.Triggers = $Triggers }

    Register-ScheduledTask -TaskName $Name -TaskPath $script:VigilTaskFolder -InputObject $task -Force | Out-Null
    Get-VigilTaskPath -Name $Name
}

function New-VigilResumeTrigger {
    <#
    .SYNOPSIS
        Fire when Windows comes back from sleep.
    .DESCRIPTION
        Power-Troubleshooter event 1 is logged on every resume. Waking is one of
        the reliable ways to end up with no display: the GPU re-enumerates
        outputs and anything that was not physically present is simply gone.
    #>
    $class = Get-CimClass -ClassName MSFT_TaskEventTrigger `
                -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
    $trigger = New-CimInstance -CimClass $class -ClientOnly
    $trigger.Subscription = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>
'@
    $trigger.Enabled = $true
    $trigger.Delay = 'PT20S'      # let the GPU finish re-enumerating outputs
    $trigger
}

function Install-VigilTask {
    <#
    .SYNOPSIS
        Register every task the configuration asks for.
    #>
    [CmdletBinding()]
    param([hashtable] $Config = (Read-VigilConfig))

    $created = @()

    # Before any task is registered: New-VigilAction points at this file, and
    # falls back to a plain PowerShell action if it is not there.
    Install-VigilLauncher | Out-Null

    $created += Register-VigilTask -Name $script:VigilTasks.On -Command 'on' `
                    -Description 'Bring the virtual display up and rebuild the topology.'
    $created += Register-VigilTask -Name $script:VigilTasks.Off -Command 'off' `
                    -Description 'Remove the virtual display (refuses if it is the only picture).'

    if ($Config.watchdog.enabled) {
        if ($Config.watchdog.onLogon) {
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $trigger.Delay = ('PT{0}S' -f [int]$Config.watchdog.logonDelaySeconds)
            $created += Register-VigilTask -Name $script:VigilTasks.Logon -Command 'ensure' -Triggers @($trigger) `
                            -Description 'Make sure a display exists after signing in.'
        }

        if ($Config.watchdog.onResume) {
            try {
                $created += Register-VigilTask -Name $script:VigilTasks.Resume -Command 'ensure' `
                                -Triggers @(New-VigilResumeTrigger) `
                                -Description 'Make sure a display exists after waking from sleep.'
            } catch {
                Write-VigilLog "resume trigger unavailable: $($_.Exception.Message)" -Tag 'INST'
            }
        }

        if ([int]$Config.watchdog.everyMinutes -gt 0) {
            $minutes = [int]$Config.watchdog.everyMinutes
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                          -RepetitionInterval (New-TimeSpan -Minutes $minutes)
            $created += Register-VigilTask -Name $script:VigilTasks.Timer -Command 'ensure' -Triggers @($trigger) `
                            -Description "Check every $minutes minutes that a display exists."
        }

        # Boot-time attach runs as SYSTEM: at that point nobody is signed in,
        # and a machine with no display can otherwise be awkward to reach.
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT45S'
        $created += Register-VigilTask -Name $script:VigilTasks.Startup -Command 'attach' -Triggers @($trigger) `
                        -AsSystem -Description 'Attach the virtual display at boot, before anyone signs in.'
    }

    $created
}

function Uninstall-VigilTask {
    [CmdletBinding()]
    param()

    $removed = @()
    foreach ($name in $script:VigilTasks.Values) {
        $task = Get-ScheduledTask -TaskName $name -TaskPath "$script:VigilTaskFolder\" -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $name -TaskPath "$script:VigilTaskFolder\" -Confirm:$false
            $removed += $name
        }
    }
    $removed
}

function Get-VigilTaskState {
    [CmdletBinding()]
    param()

    foreach ($key in $script:VigilTasks.Keys) {
        $name = $script:VigilTasks[$key]
        $task = Get-ScheduledTask -TaskName $name -TaskPath "$script:VigilTaskFolder\" -ErrorAction SilentlyContinue
        $info = if ($task) { Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue } else { $null }
        [pscustomobject]@{
            Key       = $key
            Name      = $name
            Installed = [bool]$task
            State     = $(if ($task) { [string]$task.State } else { '-' })
            LastRun   = $(if ($info) { $info.LastRunTime } else { $null })
            LastResult = $(if ($info) { $info.LastTaskResult } else { $null })
        }
    }
}

function New-VigilShortcut {
    <#
    .SYNOPSIS
        Desktop shortcuts that run the elevated tasks without a UAC prompt.
    #>
    [CmdletBinding()]
    param([string] $Folder = [Environment]::GetFolderPath('Desktop'))

    $shell = New-Object -ComObject WScript.Shell
    $made = @()

    foreach ($pair in @(
        @{ File = 'Virtual display ON.lnk';  Task = $script:VigilTasks.On;  Note = 'Turn the virtual display on' },
        @{ File = 'Virtual display OFF.lnk'; Task = $script:VigilTasks.Off; Note = 'Turn the virtual display off' }
    )) {
        $path = Join-Path $Folder $pair.File
        $link = $shell.CreateShortcut($path)
        $link.TargetPath = "$env:SystemRoot\System32\schtasks.exe"
        $link.Arguments = ('/run /tn "{0}"' -f (Get-VigilTaskPath -Name $pair.Task))
        $link.WorkingDirectory = Get-VigilRoot
        $link.Description = $pair.Note
        $link.IconLocation = "$env:SystemRoot\System32\DisplaySwitch.exe,0"
        $link.Save()
        $made += $path
    }
    $made
}

function Remove-VigilShortcut {
    [CmdletBinding()]
    param([string] $Folder = [Environment]::GetFolderPath('Desktop'))

    $removed = @()
    foreach ($file in @('Virtual display ON.lnk', 'Virtual display OFF.lnk')) {
        $path = Join-Path $Folder $file
        if (Test-Path $path) { Remove-Item $path -Force; $removed += $path }
    }
    $removed
}
