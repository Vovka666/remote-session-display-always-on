<#
    The virtual display backend.

    Vigil ships no driver binary. The Amyuni usbmmidd_v2 package is fetched
    from the vendor's own URL and its signature checked, so what lands on the
    machine is the genuine signed driver rather than a copy of unknown age
    sitting in a GitHub repository. A local copy can be supplied instead when
    the machine has no internet access.

    Amyuni's driver is used under its own licence (see docs/CREDITS.md).
    Vigil is not affiliated with Amyuni Technologies.

    The backend is deliberately a seam: everything above it speaks in terms of
    "add a virtual display" and "remove one", so Parsec VDD or IddSampleDriver
    can be added later without touching the rest.
#>

$script:AmyuniUrl = 'https://www.amyuni.com/downloads/usbmmidd_v2.zip'
$script:AmyuniAdapterName = 'USB Mobile Monitor Virtual Display'

function Get-VigilDriverPath {
    <#
    .SYNOPSIS
        Folder holding the backend's tools, from config or the default.
    #>
    [CmdletBinding()]
    param([hashtable] $Config)

    $root = if ($Config -and $Config.driverPath) { $Config.driverPath }
            else { Join-Path (Get-VigilRoot) 'driver' }
    $root
}

function Get-VigilDeviceInstaller {
    [CmdletBinding()]
    param([hashtable] $Config)

    $folder = Get-VigilDriverPath -Config $Config
    $exe = Join-Path $folder 'deviceinstaller64.exe'
    if (-not (Test-Path $exe)) {
        # 32-bit Windows still exists in the wild, mostly on old thin clients.
        $exe32 = Join-Path $folder 'deviceinstaller.exe'
        if (Test-Path $exe32) { return $exe32 }
        return $null
    }
    $exe
}

function Test-VigilDriverInstalled {
    <#
    .SYNOPSIS
        Is the backend's display adapter present in the device tree?
    #>
    [CmdletBinding()]
    param()

    [bool](Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
           Where-Object { $_.FriendlyName -like "*$script:AmyuniAdapterName*" })
}

function Get-VigilDriverSignature {
    <#
    .SYNOPSIS
        Authenticode status of the driver catalogue.
    .DESCRIPTION
        The catalogue is the file Windows checks when loading a driver, and the
        genuine package is signed by "Microsoft Windows Hardware Compatibility
        Publisher" - it passed WHQL, which is why it loads with Secure Boot on.
        The bundled deviceinstaller64.exe is an ordinary unsigned tool; judging
        the package by that file would report every healthy install as suspect.
    #>
    [CmdletBinding()]
    param([hashtable] $Config)

    $catalogue = Join-Path (Get-VigilDriverPath -Config $Config) 'usbmmidd.cat'
    if (-not (Test-Path $catalogue)) {
        return [pscustomobject]@{ Status = 'missing'; Signer = '-'; Path = $catalogue }
    }
    $signature = Get-AuthenticodeSignature $catalogue
    [pscustomobject]@{
        Status = [string]$signature.Status
        Signer = $(if ($signature.SignerCertificate) { ($signature.SignerCertificate.Subject -split ',')[0] } else { 'unsigned' })
        Path   = $catalogue
    }
}

function Install-VigilDriverFiles {
    <#
    .SYNOPSIS
        Put the driver package in place, from the vendor or from a local zip.
    .PARAMETER FromZip
        Use an already downloaded usbmmidd_v2.zip instead of fetching it.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Config,
        [string]    $FromZip
    )

    $folder = Get-VigilDriverPath -Config $Config
    if (Get-VigilDeviceInstaller -Config $Config) {
        Write-VigilLog "driver files already present in $folder"
        return $folder
    }

    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $zip = Join-Path $env:TEMP 'vigil-usbmmidd_v2.zip'

    if ($FromZip) {
        if (-not (Test-Path $FromZip)) { throw "zip not found: $FromZip" }
        Copy-Item $FromZip $zip -Force
        Write-VigilLog "using local package $FromZip"
    } else {
        Write-VigilLog "downloading $script:AmyuniUrl"
        try {
            # TLS 1.2 is not the default in Windows PowerShell 5.1 and the
            # vendor's site refuses anything older.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $script:AmyuniUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
        } catch {
            throw ("could not download the driver: " + $_.Exception.Message +
                   " - download $script:AmyuniUrl by hand and pass it with -FromZip")
        }
    }

    $staging = Join-Path $env:TEMP 'vigil-usbmmidd-extract'
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $staging -Force

    # The archive has a top-level folder; take whichever level holds the exe.
    $installer = Get-ChildItem $staging -Recurse -Filter 'deviceinstaller64.exe' | Select-Object -First 1
    if (-not $installer) { throw 'the package does not contain deviceinstaller64.exe' }
    Copy-Item (Join-Path $installer.DirectoryName '*') $folder -Recurse -Force

    # Check the driver catalogue, not the helper executable. Windows validates
    # the .cat when installing a driver; deviceinstaller64.exe is an unsigned
    # command line tool, and reporting that as "unsigned package" would alarm
    # everyone for no reason.
    $signature = Get-VigilDriverSignature -Config $Config
    Write-VigilLog ("driver catalogue signature: " + $signature.Status + " / " + $signature.Signer)
    if ($signature.Status -ne 'Valid') {
        Write-VigilLog 'WARNING: the driver catalogue is not validly signed - do not install it'
    }

    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    $folder
}

function Install-VigilDriver {
    <#
    .SYNOPSIS
        Register the virtual display driver with Windows. Needs elevation.
    #>
    [CmdletBinding()]
    param([hashtable] $Config)

    if (Test-VigilDriverInstalled) {
        Write-VigilLog 'driver already registered'
        return $true
    }

    $exe = Get-VigilDeviceInstaller -Config $Config
    if (-not $exe) { throw 'driver files are missing - run: vigil install' }

    Write-VigilLog 'registering the driver (install usbmmidd.inf usbmmidd)'
    $proc = Start-Process -FilePath $exe -ArgumentList 'install', 'usbmmidd.inf', 'usbmmidd' `
                          -WorkingDirectory (Split-Path $exe) -Wait -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3

    if (-not (Test-VigilDriverInstalled)) {
        throw "driver registration failed (exit $($proc.ExitCode)). Elevation is required, and Windows may have blocked the driver."
    }
    Write-VigilLog 'driver registered'
    $true
}

function Add-VigilVirtualDisplay {
    <#
    .SYNOPSIS
        Attach one virtual monitor. The backend supports up to four.
    #>
    [CmdletBinding()]
    param([hashtable] $Config)

    $exe = Get-VigilDeviceInstaller -Config $Config
    if (-not $exe) { throw 'driver files are missing - run: vigil install' }

    Start-Process -FilePath $exe -ArgumentList 'enableidd', '1' `
                  -WorkingDirectory (Split-Path $exe) -Wait -WindowStyle Hidden

    # Windows needs a moment to enumerate the new monitor; the topology call
    # that follows would otherwise not see it.
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 500
        if (@(Get-VigilOwnMonitor).Count -gt 0) { return $true }
    }
    $false
}

function Remove-VigilVirtualDisplay {
    <#
    .SYNOPSIS
        Detach virtual monitors created by this backend, one call each.
    #>
    [CmdletBinding()]
    param([hashtable] $Config, [int] $Max = 4)

    $exe = Get-VigilDeviceInstaller -Config $Config
    if (-not $exe) { throw 'driver files are missing - run: vigil install' }

    for ($i = 0; $i -lt $Max; $i++) {
        if (@(Get-VigilOwnMonitor).Count -eq 0) { break }
        Start-Process -FilePath $exe -ArgumentList 'enableidd', '0' `
                      -WorkingDirectory (Split-Path $exe) -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }
    (@(Get-VigilOwnMonitor).Count -eq 0)
}

function Get-VigilDriverResolutions {
    <#
    .SYNOPSIS
        Resolutions the virtual monitor offers, and which one it defaults to.
    .DESCRIPTION
        The backend keeps its mode list in the registry, up to ten entries. This
        is the knob to reach for when a remote client wants a size the default
        list does not contain - see docs/TROUBLESHOOTING.md.
    #>
    [CmdletBinding()]
    param()

    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\usbmmIdd\Parameters\Monitors'
    if (-not (Test-Path $key)) { return $null }

    $values = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    $list = @()
    foreach ($i in 0..9) {
        $name = "$i"
        if ($values.PSObject.Properties.Name -contains $name) { $list += $values.$name }
    }
    [pscustomobject]@{
        Default     = $values.'(default)'
        Resolutions = $list
        RegistryKey = $key
    }
}
