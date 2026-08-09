<#
    Configuration and logging.

    Every machine's display setup is its own mess, so nothing here is guessed
    at run time: what to keep, what to drop and when to intervene are written
    down in one file that a person can read and edit.

    Lives in ProgramData rather than a user profile because the watchdog runs
    from Task Scheduler and has to find the same answers whoever is logged in.
#>

$script:VigilRoot = Join-Path $env:ProgramData 'Vigil'

function Get-VigilRoot { $script:VigilRoot }
function Get-VigilConfigPath { Join-Path $script:VigilRoot 'config.json' }
function Get-VigilLogPath { Join-Path $script:VigilRoot 'vigil.log' }

function Get-VigilDefaultConfig {
    @{
        # Which backend provides the virtual display.
        backend      = 'amyuni'
        driverPath   = Join-Path $script:VigilRoot 'driver'

        # preserve - keep the arrangement Windows already has, minus the
        #            displays named in exclude. Works on every machine.
        # clone    - additionally give every kept display one shared source, so
        #            they show the same desktop. Only possible while they are
        #            all on one graphics adapter; Vigil falls back to preserve
        #            and logs why when they are not.
        topology     = 'preserve'

        # Substrings matched against a target's device path and EDID name.
        # Anything matching is left out of the topology. The usual entry is a
        # laptop's built-in panel, which you do not want lit at home.
        exclude      = @()

        watchdog = @{
            enabled          = $true
            onLogon          = $true
            logonDelaySeconds = 40      # let the GPU driver settle first
            onResume         = $true    # waking from sleep drops displays
            everyMinutes     = 5        # the honest catch-all
        }

        safety = @{
            # Refuse to remove the virtual display while it is the only picture.
            # Without this, one click blinds a remote session with no way back.
            refuseIfOnlyDisplay = $true
        }

        logRetentionDays = 30
    }
}

function Read-VigilConfig {
    <#
    .SYNOPSIS
        Configuration from disk, merged over the defaults.
    #>
    [CmdletBinding()]
    param()

    $config = Get-VigilDefaultConfig
    $path = Get-VigilConfigPath
    if (-not (Test-Path $path)) { return $config }

    try {
        $saved = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-VigilLog "config.json is unreadable, using defaults: $($_.Exception.Message)"
        return $config
    }

    foreach ($property in $saved.PSObject.Properties) {
        $name = $property.Name
        $value = $property.Value
        if ($name -in @('watchdog', 'safety') -and $value) {
            # Merge one level down so a partial section keeps the other defaults.
            $section = $config[$name]
            foreach ($sub in $value.PSObject.Properties) { $section[$sub.Name] = $sub.Value }
            $config[$name] = $section
        } elseif ($name -eq 'exclude') {
            $config[$name] = @($value)
        } else {
            $config[$name] = $value
        }
    }
    $config
}

function Write-VigilConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    New-Item -ItemType Directory -Force -Path $script:VigilRoot | Out-Null
    $json = $Config | ConvertTo-Json -Depth 6
    Set-Content -Path (Get-VigilConfigPath) -Value $json -Encoding UTF8
    Get-VigilConfigPath
}

function Write-VigilLog {
    <#
    .SYNOPSIS
        Append a line to the log, and echo it when running interactively.
    .DESCRIPTION
        The watchdog runs unattended, so the log is the only account of what
        happened at 3am when the machine came back from sleep.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [string] $Message,
        [string] $Tag = ''
    )
    process {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = if ($Tag) { "$stamp  $($Tag.PadRight(6)) $Message" } else { "$stamp  $Message" }
        try {
            New-Item -ItemType Directory -Force -Path $script:VigilRoot | Out-Null
            Add-Content -Path (Get-VigilLogPath) -Value $line -Encoding UTF8
        } catch {
            # A tool that fails because it cannot write its own log is worse
            # than one that quietly carries on.
        }
        Write-Verbose $line
    }
}

function Clear-VigilOldLog {
    <#
    .SYNOPSIS
        Trim the log once it outgrows the retention window.
    #>
    [CmdletBinding()]
    param([int] $Days = 30)

    $path = Get-VigilLogPath
    if (-not (Test-Path $path)) { return }
    if ((Get-Item $path).Length -lt 512KB) { return }

    $cutoff = (Get-Date).AddDays(-$Days)
    $kept = Get-Content $path | Where-Object {
        $stamp = $null
        if ($_.Length -ge 19 -and [datetime]::TryParse($_.Substring(0, 19), [ref]$stamp)) {
            $stamp -ge $cutoff
        } else { $true }
    }
    Set-Content -Path $path -Value $kept -Encoding UTF8
}

function Test-VigilElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
