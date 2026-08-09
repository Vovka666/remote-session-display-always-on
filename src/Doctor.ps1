<#
    Diagnostics.

    "It doesn't work on my machine" is the only bug report this kind of tool
    ever gets, because every Windows install has its own history of drivers,
    dead monitors and half-removed remote-desktop software. `vigil doctor`
    checks each assumption separately and names the one that is wrong, so a
    report arrives already diagnosed.

    Nothing personal is printed: no machine name, no user name, no serial.
#>

$script:VigilOk   = 'ok'
$script:VigilWarn = 'warn'
$script:VigilFail = 'fail'

function New-VigilReport {
    $report = [pscustomobject]@{ Checks = New-Object System.Collections.ArrayList }
    $report | Add-Member -MemberType ScriptMethod -Name Add -Value {
        param([string] $Status, [string] $Name, [string] $Detail = '')
        [void]$this.Checks.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    }
    $report | Add-Member -MemberType ScriptProperty -Name Worst -Value {
        if ($this.Checks | Where-Object { $_.Status -eq 'fail' }) { return 'fail' }
        if ($this.Checks | Where-Object { $_.Status -eq 'warn' }) { return 'warn' }
        'ok'
    }
    $report
}

function Invoke-VigilDoctor {
    [CmdletBinding()]
    param([hashtable] $Config = (Read-VigilConfig))

    $report = New-VigilReport

    # -- Windows -------------------------------------------------------------
    $os = Get-CimInstance Win32_OperatingSystem
    $report.Add($script:VigilOk, 'windows', ("{0} build {1}, PowerShell {2}" -f
        $os.Caption.Trim(), $os.BuildNumber, $PSVersionTable.PSVersion))

    if ([Environment]::Is64BitOperatingSystem -eq $false) {
        $report.Add($script:VigilWarn, 'architecture',
            '32-bit Windows: the backend ships a 32-bit installer, but this combination is untested')
    }

    # -- driver signing environment ------------------------------------------
    $secureBoot = 'unknown'
    try { $secureBoot = [string](Confirm-SecureBootUEFI) } catch { $secureBoot = 'not applicable (legacy BIOS)' }
    $testSigning = (bcdedit /enum '{current}' 2>$null | Select-String 'testsigning\s+Yes') -ne $null
    $report.Add($script:VigilOk, 'driver signing',
        ("Secure Boot: {0}   test signing: {1}" -f $secureBoot, $(if ($testSigning) { 'ON' } else { 'off' })))

    # -- elevation -----------------------------------------------------------
    if (Test-VigilElevated) {
        $report.Add($script:VigilOk, 'elevation', 'running as administrator')
    } else {
        $report.Add($script:VigilWarn, 'elevation',
            'not elevated - status works, but attaching or removing a display does not. The installed shortcuts handle this for you.')
    }

    # -- session -------------------------------------------------------------
    $session = Get-VigilSessionInfo
    if ($session.SessionKind -eq 'rdp') {
        $report.Add($script:VigilWarn, 'session',
            'this is a Remote Desktop session, which brings its own display - Vigil is for the console session that RDP does not use')
    } else {
        $report.Add($script:VigilOk, 'session',
            ("console session; remote hosts installed: {0}" -f
             $(if ($session.RemoteHosts) { $session.RemoteHosts -join ', ' } else { 'none detected' })))
    }

    # -- the backend ---------------------------------------------------------
    $installer = Get-VigilDeviceInstaller -Config $Config
    if (-not $installer) {
        # Status still works without these; attaching and detaching does not.
        # Anyone who already unpacked the package somewhere can point at it
        # instead of downloading a second copy.
        $report.Add($script:VigilFail, 'driver files',
            ("not found in {0}`n        run: vigil install   (or set driverPath in {1} to an existing copy)" -f
             (Get-VigilDriverPath -Config $Config), (Get-VigilConfigPath)))
    } else {
        $signature = Get-VigilDriverSignature -Config $Config
        $status = $(if ($signature.Status -eq 'Valid') { $script:VigilOk } else { $script:VigilWarn })
        $report.Add($status, 'driver files',
            ("{0}`n        catalogue signature: {1} / {2}" -f $installer, $signature.Status, $signature.Signer))
    }

    if (Test-VigilDriverInstalled) {
        $report.Add($script:VigilOk, 'driver registered', 'the virtual display adapter is present in the device tree')
    } else {
        $report.Add($script:VigilFail, 'driver registered',
            'the virtual display adapter is not installed - run: vigil install')
    }

    # -- displays ------------------------------------------------------------
    $state = Get-VigilState -Config $Config
    if ($state.ActiveTargets.Count -eq 0) {
        $report.Add($script:VigilFail, 'displays',
            'NO active display at all - this is the situation Vigil exists to prevent. Run: vigil on')
    } else {
        $report.Add($script:VigilOk, 'displays',
            ("{0} active (real {1}, virtual {2})" -f $state.ActiveTargets.Count, $state.RealCount, $state.VirtualCount))
    }

    if ($state.VirtualCount -eq 0 -and $state.RealCount -eq 1) {
        $report.Add($script:VigilWarn, 'resilience',
            'one real display and no virtual one: switching that monitor off leaves this machine with no picture')
    }

    $ghosts = @(Get-VigilMonitor | Where-Object { -not $_.Present })
    if ($ghosts.Count -gt 0) {
        $report.Add($script:VigilOk, 'remembered monitors',
            ("{0} not currently attached - normal, and ignored: {1}" -f $ghosts.Count,
             (($ghosts | Select-Object -First 4 | ForEach-Object { $_.Name }) -join ', ')))
    }

    if ($state.ForeignVirtual.Count -gt 0) {
        $report.Add($script:VigilOk, 'other virtual displays',
            ("left alone: {0}" -f (($state.ForeignVirtual | ForEach-Object { "$($_.Adapter) [$($_.Owner)]" }) -join ', ')))
    }

    # -- configuration -------------------------------------------------------
    if ($Config.exclude.Count -eq 0) {
        $report.Add($script:VigilOk, 'exclusions', 'none - every display stays in the topology')
    } else {
        # An exclusion that matches nothing is the classic silent misconfiguration:
        # the laptop panel stays lit and nobody can see why.
        $all = @(Get-VigilTarget)
        $dead = @()
        foreach ($pattern in $Config.exclude) {
            $hit = $all | Where-Object { "$($_.DevicePath) | $($_.FriendlyName)" -like "*$pattern*" }
            if (-not $hit) { $dead += $pattern }
        }
        if ($dead.Count -gt 0) {
            $report.Add($script:VigilWarn, 'exclusions',
                ("these match no display on this machine and do nothing: {0}" -f ($dead -join ', ')))
        } else {
            $report.Add($script:VigilOk, 'exclusions', ($Config.exclude -join ', '))
        }
    }

    # -- tasks ---------------------------------------------------------------
    $tasks = @(Get-VigilTaskState)
    $missing = @($tasks | Where-Object { -not $_.Installed })
    if ($missing.Count -eq $tasks.Count) {
        $report.Add($script:VigilWarn, 'scheduled tasks', 'none installed - run: vigil install')
    } elseif ($missing.Count -gt 0 -and $Config.watchdog.enabled) {
        $report.Add($script:VigilWarn, 'scheduled tasks',
            ("missing: {0}" -f (($missing | ForEach-Object { $_.Name }) -join ', ')))
    } else {
        # Task Scheduler reports informational codes in the same field as
        # failures. 267011 means "has not run yet", which is the normal state
        # of a freshly installed watchdog and must not read as a fault.
        $benign = @(0, 267009, 267010, 267011, 267014)   # running / queued / never ran / terminated
        $failed = @($tasks | Where-Object { $_.Installed -and $null -ne $_.LastResult -and $benign -notcontains $_.LastResult })
        if ($failed.Count -gt 0) {
            $report.Add($script:VigilWarn, 'scheduled tasks',
                ("last run failed: {0}" -f (($failed | ForEach-Object { "$($_.Name) -> $($_.LastResult)" }) -join ', ')))
        } else {
            $report.Add($script:VigilOk, 'scheduled tasks',
                ("{0} installed and healthy" -f @($tasks | Where-Object { $_.Installed }).Count))
        }
    }

    # The tasks run through a WScript launcher so they never flash a console
    # window over a fullscreen application. If policy has switched Windows
    # Script Host off since install, every trigger now fires into nothing while
    # the tasks still read as installed and healthy above.
    if (@($tasks | Where-Object { $_.Installed }).Count -gt 0 -and -not (Test-VigilScriptHost)) {
        $report.Add($script:VigilWarn, 'script host',
            'Windows Script Host is disabled by policy, so the windowless launcher cannot run.' +
            "`n        run: vigil install   (it will register plain PowerShell tasks instead)")
    }

    $report
}

function Format-VigilDoctor {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Report)

    $marks = @{ ok = '[ ok ]'; warn = '[warn]'; fail = '[FAIL]' }
    $lines = @('Vigil doctor', ('=' * 62))
    foreach ($check in $Report.Checks) {
        $lines += ("{0} {1}" -f $marks[$check.Status], $check.Name)
        if ($check.Detail) { $lines += ("        " + $check.Detail) }
    }
    $lines += ('=' * 62)
    switch ($Report.Worst) {
        'ok'   { $lines += 'All checks passed.' }
        'warn' { $lines += 'Working, with things worth knowing about above.' }
        'fail' { $lines += 'Something is broken - details above.' }
    }
    if ($Report.Worst -ne 'ok') {
        $lines += 'Troubleshooting: docs/TROUBLESHOOTING.md   Issues: https://github.com/Vovka666/vigil/issues'
    }
    $lines -join "`n"
}
