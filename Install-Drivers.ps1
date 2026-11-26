#Requires -Version 5.1
<#
.SYNOPSIS
    Installs every driver for a laptop from ONE folder (or ONE .zip / .cab) silently,
    asking for administrator rights only once - right at the start.

.DESCRIPTION
    Put all of the laptop's driver downloads into one folder first (see README.md).
    Then this script:
      1. Asks for administrator rights ONCE (a single UAC prompt), then runs on its own.
      2. Downloads anything listed in an optional downloads.txt.
      3. Unpacks .zip and .cab files.
      4. Works out the silent-install switches for each installer
         (Dell, HP, NVIDIA, Intel, Realtek, Inno Setup, NSIS, InstallShield, WiX,
         Advanced Installer, .msi, .msu and raw .inf drivers).
      5. Installs in a sensible order - chipset first, BIOS/firmware last - and holds
         restarts back until everything is done.
      6. Logs everything, remembers what finished (a re-run carries on where it stopped),
         and offers a single restart at the end.

.PARAMETER DriverPath
    The folder, .zip or .cab that holds ALL the drivers for this laptop.
    Default: a "Drivers" folder (or Drivers.zip / Drivers.cab) next to this script.
    If none exists you are asked to pick the folder.

.PARAMETER WorkFolder
    Where logs, unpacked files and downloads go. Default: C:\DriverInstall

.PARAMETER TimeoutMinutes
    Longest any single installer may run before it is stopped. Default: 20.

.PARAMETER IncludeFirmware
    Also run BIOS / firmware updates (skipped by default). Needs the charger plugged in.
    BitLocker is paused for one restart so you are not asked for the recovery key.

.PARAMETER AllowUnsigned
    Also run installers that are not validly digitally signed (skipped by default).

.PARAMETER OrderByName
    Install in plain alphabetical order instead of by category. Name files 01_..., 02_...
    to control the order. BIOS/firmware still goes last.

.PARAMETER Force
    Re-install items that already finished in an earlier run.

.PARAMETER DryRun
    Only show what would be installed and how. Installs nothing; no admin prompt.

.PARAMETER AutoReboot
    Restart automatically 30 seconds after finishing, instead of asking.

.PARAMETER NoPause
    Don't wait for a key press at the end (for unattended use).

.EXAMPLE
    .\Install-Drivers.ps1
    Uses the "Drivers" folder next to this script.

.EXAMPLE
    .\Install-Drivers.ps1 -DriverPath 'E:\Latitude 5420 Drivers' -DryRun
    Shows what would be installed, and with which switches, without installing anything.

.EXAMPLE
    .\Install-Drivers.ps1 -DriverPath 'E:\ThinkPad-T14.zip' -AutoReboot
#>
[CmdletBinding()]
param(
    [string]$DriverPath,
    [string]$WorkFolder = "$env:SystemDrive\DriverInstall",
    [ValidateRange(1, 240)]
    [int]$TimeoutMinutes = 20,
    [switch]$IncludeFirmware,
    [switch]$AllowUnsigned,
    [switch]$OrderByName,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$AutoReboot,
    [switch]$NoPause
)

# ============================================================================
#  Settings you can tweak
# ============================================================================

# File types that are installed directly, and file types that are unpacked first.
$InstallerExtensions = @('.exe', '.msi', '.msu')
$ArchiveExtensions   = @('.zip', '.cab')

# Inside a sub-folder, one of these PLUS the files that came with it = one unpacked
# installer, so only this file is run (not every .exe sitting next to it).
$MainInstallerNames = @('setup.exe', 'install.exe', 'installer.exe', 'setup.msi', 'install.msi')
$SupportExtensions  = @('.dll', '.cab', '.inf', '.ini', '.xml', '.dat', '.sys', '.cat', '.msi', '.mst',
                        '.bin', '.json', '.iss', '.manifest', '.config')

# BIOS / firmware updates (matched against file name, folder name and file description).
$FirmwarePattern = 'BIOS|UEFI|firmware|embedded ?controller'

# Install order. Anything that matches nothing is group 6; BIOS/firmware is always last (9).
# Names are matched with "_", "-" and "." turned into spaces.
$CategoryRules = @(
    @{ Order = 1; Name = 'Chipset & platform';  Pattern = 'chipset|serial ?io|management ?engine|\bME\b|\bMEI\b|\bGNA\b|\bDPTF\b|dynamic ?tuning|innovation ?platform|\bIPF\b|\bGPIO\b|\bI2C\b' }
    @{ Order = 2; Name = 'Storage';             Pattern = 'storage|\bRST\b|\bVMD\b|NVMe|\bSATA\b|\bAHCI\b|optane' }
    @{ Order = 3; Name = 'Graphics';            Pattern = 'graphic|video|display|\bVGA\b|nvidia|geforce|quadro|radeon|\bGFX\b|\bArc\b|\bUHD\b|\bIris\b' }
    @{ Order = 4; Name = 'Audio';               Pattern = 'audio|sound|conexant|waves|dolby|cirrus|\bSST\b' }
    @{ Order = 5; Name = 'Network & Bluetooth'; Pattern = 'network|ethernet|\bLAN\b|WLAN|wi ?fi|wireless|bluetooth|killer|\bWWAN\b|\bNIC\b' }
)

# Child processes with these names mean "still installing" after the main installer exits.
$InstallerProcessPattern = 'setup|install|msiexec|\.tmp$|dpinst|drvinst|pnputil|wusa|unpack|extract'

# Folders built for a different processor type are skipped.
$OsArch = $env:PROCESSOR_ARCHITEW6432
if (-not $OsArch) { $OsArch = $env:PROCESSOR_ARCHITECTURE }
switch -Regex ($OsArch) {
    'ARM64' { $WrongArchPattern = '^(x86|win32|i386|32 ?bit|w32|x64|amd64|win64|w64)$' }
    '^x86$' { $WrongArchPattern = '^(x64|amd64|win64|64 ?bit|w64|arm|arm64|aarch64)$' }
    default { $WrongArchPattern = '^(x86|win32|i386|32 ?bit|w32|arm|arm64|aarch64)$' }
}

# ============================================================================
#  Small helpers
# ============================================================================

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Info([string]$Text, [string]$Color = 'Gray') {
    Write-Host "    $Text" -ForegroundColor $Color
}

function Wait-ForEnter {
    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
}

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SystemTool([string]$Name) {
    # 32-bit PowerShell on 64-bit Windows has to go through Sysnative to reach the real tools.
    $folder = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $folder = 'Sysnative' }
    return (Join-Path $env:WINDIR "$folder\$Name")
}

function Get-PowerShellExe {
    $exe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $PSHOME 'pwsh.exe' }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $native = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $native) { $exe = $native }
    }
    return $exe
}

function Get-ShortHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return (-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function Join-Label([string]$Parent, [string]$Child) {
    if ($Parent) { return "$Parent\$Child" }
    return $Child
}

function ConvertTo-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-UncPath([string]$Path) {
    # Drive letters mapped to network shares are invisible to the elevated (admin) session,
    # so swap them for the \\server\share form before elevating.
    if ($Path -match '^([A-Za-z]):\\') {
        $drive = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($drive -and $drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\')) {
            return ($drive.DisplayRoot.TrimEnd('\') + $Path.Substring(2))
        }
    }
    return $Path
}

function ConvertTo-CommandLineArg([string]$Value) {
    # Quote for the command line; double any trailing backslashes so they can't escape the quote.
    return '"' + ($Value -replace '(\\+)$', '$1$1') + '"'
}

function Set-KeepAwake([bool]$On) {
    # Stops the PC going to sleep half-way through. Changes no power settings.
    try {
        if (-not ('DriverInstall.Power' -as [type])) {
            Add-Type -Namespace DriverInstall -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int esFlags);'
        }
        $flags = 0x80000000                       # ES_CONTINUOUS
        if ($On) { $flags = 0x80000001 }          # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        [void][DriverInstall.Power]::SetThreadExecutionState($flags)
    } catch { }
}

function Test-OnACPower {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        return ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Offline')
    } catch { return $true }
}

function Suspend-BitLockerOnce {
    try {
        $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($volume.ProtectionStatus -eq 'On') {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null
            Write-Info 'BitLocker paused for one restart, so the BIOS update will not ask for the recovery key.' 'Yellow'
        }
    } catch {
        Write-Info "Could not check or pause BitLocker ($($_.Exception.Message)). Have your recovery key handy." 'Yellow'
    }
}

# ============================================================================
#  Finding the driver folder
# ============================================================================

function Resolve-DriverSource([string]$Path) {
    if ($Path) {
        $full = ConvertTo-FullPath ($Path.Trim().Trim('"'))
        if (-not (Test-Path -LiteralPath $full)) { throw "Can't find the driver folder or file: $full" }
        return $full
    }
    if ($PSScriptRoot) {
        foreach ($name in @('Drivers', 'Drivers.zip', 'Drivers.cab')) {
            $candidate = Join-Path $PSScriptRoot $name
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    Write-Host 'Pick the folder that holds ALL the drivers for this laptop...' -ForegroundColor Yellow
    $picked = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Pick the folder that holds ALL the drivers for this laptop'
        $dialog.ShowNewFolderButton = $false
        if ($PSScriptRoot) { $dialog.SelectedPath = $PSScriptRoot }
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { $picked = $dialog.SelectedPath }
        $owner.Dispose()
    } catch {
        $typed = Read-Host 'Type the full path of the driver folder (or .zip)'
        if ($typed) { $picked = $typed.Trim().Trim('"') }
    }
    if ($picked -and (Test-Path -LiteralPath $picked)) { return (ConvertTo-FullPath $picked) }
    return $null
}

function Find-ControlFile([string]$Name) {
    # switches.txt / downloads.txt can sit in the driver folder, its only sub-folder,
    # next to the .zip, or next to this script.
    $places = @($script:Root)
    $subDirs = @(Get-ChildItem -LiteralPath $script:Root -Directory -ErrorAction SilentlyContinue)
    $loose   = @(Get-ChildItem -LiteralPath $script:Root -File -ErrorAction SilentlyContinue)
    if ($subDirs.Count -eq 1 -and $loose.Count -eq 0) { $places += $subDirs[0].FullName }
    if (Test-Path -LiteralPath $script:Source -PathType Leaf) { $places += (Split-Path -Parent $script:Source) }
    if ($PSScriptRoot) { $places += $PSScriptRoot }
    foreach ($place in $places) {
        if (-not $place) { continue }
        $candidate = Join-Path $place $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Read-SwitchOverrides([string]$Path) {
    $rules = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $parts = $text -split '=', 2
        if ($parts.Count -lt 2 -or -not $parts[0].Trim()) {
            Write-Info "switches.txt: ignoring a line with no '=': $text" 'Yellow'
            continue
        }
        $rules += [pscustomobject]@{ Pattern = $parts[0].Trim(); Arguments = $parts[1].Trim() }
    }
    return $rules
}

function Invoke-DownloadList([string]$ListPath) {
    New-Item -ItemType Directory -Force -Path $DownloadFolder | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads far slower
    foreach ($line in Get-Content -LiteralPath $ListPath) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $parts = $text -split '\|', 2
        $url = $parts[0].Trim()
        $name = ''
        if ($parts.Count -gt 1) { $name = $parts[1].Trim() }
        if (-not $name) { try { $name = [IO.Path]::GetFileName(([Uri]$url).LocalPath) } catch { } }
        if (-not $name) {
            Write-Info "Can't tell the file name for $url - add ' | name.exe' after the link." 'Yellow'
            $script:DownloadFailures += $url
            continue
        }
        $name = $name -replace '[\\/:*?"<>|]', '_'
        $target = Join-Path $DownloadFolder $name
        if (Test-Path -LiteralPath $target) { Write-Info "Already downloaded: $name"; continue }
        Write-Info "Downloading $name ..."
        try {
            Invoke-WebRequest -Uri $url -OutFile "$target.partial" -UseBasicParsing -ErrorAction Stop `
                -UserAgent ([Microsoft.PowerShell.Commands.PSUserAgent]::Chrome)
            Move-Item -LiteralPath "$target.partial" -Destination $target -Force
        } catch {
            Remove-Item -LiteralPath "$target.partial" -Force -ErrorAction SilentlyContinue
            Write-Info "Download failed: $name - $($_.Exception.Message)" 'Red'
            $script:DownloadFailures += $name
        }
    }
}

# ============================================================================
#  Working out what to install, and how
# ============================================================================

function Expand-DriverArchive([IO.FileInfo]$Archive) {
    # Short, fixed folder names keep paths under Windows' 260-character limit and let a
    # re-run reuse what was already unpacked.
    $id = Get-ShortHash ('{0}|{1}|{2}' -f $Archive.FullName, $Archive.Length, $Archive.LastWriteTimeUtc.Ticks)
    $destination = Join-Path $UnpackFolder $id
    $marker = "$destination.ok"
    if ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $destination)) { return $destination }
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Write-Info "Unpacking $($Archive.Name) ..."
    switch ($Archive.Extension.ToLower()) {
        '.zip' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($Archive.FullName, $destination)
        }
        '.cab' {
            $output = & (Get-SystemTool 'expand.exe') $Archive.FullName '-F:*' $destination 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "expand.exe failed (exit code $LASTEXITCODE): $($output.Trim())" }
        }
    }
    New-Item -ItemType File -Force -Path $marker | Out-Null
    return $destination
}

function Get-FileFingerprint([IO.FileInfo]$File) {
    $company = ''; $description = ''; $versionText = ''; $head = ''
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($File.FullName)
        $company     = [string]$vi.CompanyName
        $description = (@($vi.FileDescription, $vi.ProductName) | Where-Object { $_ }) -join ' / '
        $versionText = (@($vi.CompanyName, $vi.ProductName, $vi.FileDescription, $vi.Comments,
                          $vi.LegalCopyright, $vi.InternalName, $vi.OriginalFilename) | Where-Object { $_ }) -join ' | '
    } catch { }
    if ($File.Extension -ieq '.exe') {
        # The first few MB of an installer tell us which tool built it.
        try {
            $stream = [IO.File]::OpenRead($File.FullName)
            try {
                $length = [int][Math]::Min($stream.Length, 3MB)
                $buffer = New-Object byte[] $length
                $read = 0
                while ($read -lt $length) {
                    $n = $stream.Read($buffer, $read, $length - $read)
                    if ($n -le 0) { break }
                    $read += $n
                }
            } finally { $stream.Dispose() }
            $head = [Text.Encoding]::ASCII.GetString($buffer, 0, $read) + [Text.Encoding]::Unicode.GetString($buffer, 0, $read)
        } catch { }
    }
    return [pscustomobject]@{ Company = $company; Description = $description; VersionText = $versionText; Head = $head }
}

function Get-SilentSwitches([IO.FileInfo]$File, $Fingerprint) {
    $company = $Fingerprint.Company
    $info    = $Fingerprint.VersionText
    $head    = $Fingerprint.Head
    $name    = $File.Name

    if ($company -match 'Dell') {
        return @{ Arguments = '/s'; Method = 'Dell Update Package' }
    }
    if ($company -match '^\s*(HP|Hewlett)' -or $name -match '^sp\d+\.exe$') {
        return @{ Arguments = '/s'; Method = 'HP SoftPaq' }
    }
    if ($company -match 'NVIDIA') {
        return @{ Arguments = '-s -noreboot -noeula'; Method = 'NVIDIA installer' }
    }
    if ($head -cmatch '\.wixburn') {
        return @{ Arguments = '/quiet /norestart'; Method = 'WiX bundle' }
    }
    if ($info -match 'Inno Setup' -or $head -cmatch 'Inno Setup|InnoSetupLdr') {
        return @{ Arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'; Method = 'Inno Setup' }
    }
    if ($head -cmatch 'Nullsoft') {
        return @{ Arguments = '/S'; Method = 'NSIS installer' }
    }
    if ($info -match 'Advanced Installer' -or $head -cmatch 'Advanced Installer') {
        return @{ Arguments = '/exenoui /qn /norestart'; Method = 'Advanced Installer' }
    }
    if ($info -match 'InstallShield' -or $head -cmatch 'InstallShield') {
        return @{ Arguments = '/s /v"/qn REBOOT=ReallySuppress"'; Method = 'InstallShield' }
    }
    if ($company -match 'Intel|Realtek|Synaptics|ELAN|Conexant|Qualcomm|MediaTek|Broadcom|AMD|Advanced Micro') {
        return @{ Arguments = '-s'; Method = "$($company.Trim()) installer" }
    }
    return @{ Arguments = '/s'; Method = 'Unknown installer type - guessing /s' }
}

function Add-PlanItem {
    param(
        [string]$Display, [string]$Kind, [string]$Path, [string]$Arguments = '', [string]$Method = '',
        [string]$Key = '', [string]$MatchText = '', [string]$Vendor = '', [string[]]$InfFiles = @(),
        [bool]$Firmware = $false, [string]$SkipReason = ''
    )
    $order = 6
    $category = 'Other drivers & apps'
    if ($Firmware) {
        $order = 9
        $category = 'BIOS & firmware'
    } else {
        $normalized = "$Display $MatchText" -replace '[_\-\.]', ' '
        foreach ($rule in $CategoryRules) {
            if ($normalized -match $rule.Pattern) { $order = $rule.Order; $category = $rule.Name; break }
        }
    }
    $script:Plan.Add([pscustomobject]@{
        Order = $order; Category = $category; Display = $Display; Kind = $Kind; Path = $Path
        Arguments = $Arguments; Method = $Method; Key = $Key; Vendor = $Vendor; InfFiles = $InfFiles
        Firmware = $Firmware; SkipReason = $SkipReason
        Status = ''; ExitCode = $null; Ok = $false; Reboot = $false
    })
}

function Get-InfFiles([string]$Folder) {
    Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.inf' -and -not $_.Name.StartsWith('_') }
    Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $WrongArchPattern -and -not $_.Name.StartsWith('_') -and -not $_.Name.StartsWith('.') } |
        ForEach-Object { Get-InfFiles $_.FullName }
}

function Test-FirmwareInf([string]$Path) {
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $false }
    return (($text -match '(?im)^\s*Class\s*=\s*"?Firmware\b') -or ($text -match 'f2e7dd72-6468-4e36-b6f1-6488f42c1b52'))
}

function Add-InfPackage {
    param([string]$Folder, [string]$Label, [switch]$TopLevelOnly)
    if ($TopLevelOnly) {
        $infs = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.inf' })
    } else {
        $infs = @(Get-InfFiles $Folder)
    }
    if ($infs.Count -eq 0) { return }

    # Firmware delivered as .inf (UEFI capsules) is split out so it can be skipped safely.
    $normal = @(); $firmware = @()
    foreach ($inf in $infs) {
        if (Test-FirmwareInf $inf.FullName) { $firmware += $inf } else { $normal += $inf }
    }
    $display = $Label
    if (-not $display) { $display = '(loose .inf files)' }
    foreach ($group in @(@{ Files = $normal; Firmware = $false }, @{ Files = $firmware; Firmware = $true })) {
        $files = @($group.Files)
        if ($files.Count -eq 0) { continue }
        $key = Get-ShortHash ('INF|' + (($files | ForEach-Object { '{0}:{1}' -f $_.Name, $_.Length }) -join '|'))
        $plural = ''
        if ($files.Count -ne 1) { $plural = 's' }
        $itemDisplay = $display
        if ($group.Firmware) { $itemDisplay = "$display (firmware .inf)" }
        Add-PlanItem -Display $itemDisplay -Kind 'INF' -Path $Folder -Key $key -Firmware $group.Firmware `
            -Method ("pnputil, {0} .inf file{1}" -f $files.Count, $plural) -InfFiles @($files | ForEach-Object { $_.FullName })
    }
}

function Add-FilePackage {
    param([IO.FileInfo]$File, [int]$Depth, [string]$Label)
    $ext = $File.Extension.ToLower()
    $display = Join-Label $Label $File.Name
    $kind = $ext.TrimStart('.').ToUpper()

    if ($ArchiveExtensions -contains $ext) {
        try {
            $destination = Expand-DriverArchive $File
        } catch {
            Add-PlanItem -Display $display -Kind $kind -Path $File.FullName -SkipReason "Could not unpack: $($_.Exception.Message)"
            return
        }
        Add-FolderToPlan -Folder $destination -Depth ($Depth + 1) -Label $display
        return
    }

    $key = Get-ShortHash ('{0}|{1}|{2}' -f $File.Name, $File.Length, $File.LastWriteTimeUtc.Ticks)
    $fingerprint = Get-FileFingerprint $File
    $vendor = ''
    if ($fingerprint.Company -match 'Dell') { $vendor = 'Dell' }
    $isFirmware = (("$display $($fingerprint.Description)" -replace '[_\-\.]', ' ') -match $FirmwarePattern)

    $override = $null
    foreach ($rule in $script:Overrides) {
        if ($File.Name -like $rule.Pattern) { $override = $rule; break }
    }
    if ($override -and $override.Arguments -ieq 'SKIP') {
        Add-PlanItem -Display $display -Kind $kind -Path $File.FullName -MatchText $fingerprint.Description `
            -Firmware $isFirmware -SkipReason "Skipped by switches.txt ($($override.Pattern))"
        return
    }

    switch ($kind) {
        'MSI'   { $arguments = '/qn /norestart REBOOT=ReallySuppress'; $method = 'Windows Installer (.msi)' }
        'MSU'   { $arguments = '/quiet /norestart'; $method = 'Windows update package (.msu)' }
        default {
            $detected = Get-SilentSwitches $File $fingerprint
            $arguments = $detected.Arguments
            $method = $detected.Method
        }
    }
    if ($override) {
        $arguments = $override.Arguments
        if ($arguments -ieq 'NONE') { $arguments = '' }
        $method = "switches.txt ($($override.Pattern))"
    }

    $skip = ''
    if (-not $AllowUnsigned) {
        $signature = $null
        try { $signature = Get-AuthenticodeSignature -LiteralPath $File.FullName -ErrorAction Stop } catch { }
        if (-not $signature -or $signature.Status -ne 'Valid') {
            $status = 'unknown'
            if ($signature) { $status = [string]$signature.Status }
            $skip = "Not validly signed ($status) - use -AllowUnsigned if you trust it"
        }
    }

    Add-PlanItem -Display $display -Kind $kind -Path $File.FullName -Arguments $arguments -Method $method `
        -Key $key -MatchText $fingerprint.Description -Vendor $vendor -Firmware $isFirmware -SkipReason $skip
}

function Add-FolderToPlan {
    param([string]$Folder, [int]$Depth, [string]$Label)
    if ($Depth -gt 12) { return }
    # Names starting with "_" or "." are ignored - handy for parking files you don't want installed.
    $children = @(Get-ChildItem -LiteralPath $Folder -ErrorAction SilentlyContinue | Where-Object {
        -not $_.Name.StartsWith('_') -and -not $_.Name.StartsWith('.') -and $_.FullName -ne $WorkFolder })
    $files = @($children | Where-Object { -not $_.PSIsContainer })
    $dirs  = @($children | Where-Object { $_.PSIsContainer -and $_.Name -notmatch $WrongArchPattern })

    if ($Depth -gt 0) {
        # Rule 1: an unpacked installer (setup.exe plus its own files) - run only its setup program.
        $main = $files | Where-Object { $MainInstallerNames -contains $_.Name.ToLower() } | Select-Object -First 1
        if ($main) {
            $hasOwnFiles = ($dirs.Count -gt 0) -or [bool]($files | Where-Object {
                $_.Name -ne $main.Name -and $SupportExtensions -contains $_.Extension.ToLower() })
            if ($hasOwnFiles) { Add-FilePackage -File $main -Depth $Depth -Label $Label; return }
        }
        # Rule 2: a folder of raw drivers (.inf files) - add them all with pnputil.
        if ($files | Where-Object { $_.Extension -ieq '.inf' }) { Add-InfPackage -Folder $Folder -Label $Label; return }
    }

    # Rule 3: every installer or archive in this folder is its own item.
    foreach ($file in $files) {
        $ext = $file.Extension.ToLower()
        if ($InstallerExtensions -contains $ext -or $ArchiveExtensions -contains $ext) {
            Add-FilePackage -File $file -Depth $Depth -Label $Label
        }
    }
    # Loose .inf files dropped straight into the main folder.
    if ($Depth -eq 0 -and ($files | Where-Object { $_.Extension -ieq '.inf' })) {
        Add-InfPackage -Folder $Folder -Label $Label -TopLevelOnly
    }

    # Rule 4: look inside the sub-folders.
    foreach ($dir in $dirs) {
        Add-FolderToPlan -Folder $dir.FullName -Depth ($Depth + 1) -Label (Join-Label $Label $dir.Name)
    }
}

# ============================================================================
#  Running installers
# ============================================================================

function Wait-MsiIdle([int]$MaxMinutes = 10) {
    # Only one Windows Installer job can run at a time; wait for any other to finish.
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    while ((Get-Date) -lt $deadline) {
        $mutex = $null
        $busy = $false
        try { $busy = [Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mutex) } catch { }
        if ($mutex) { $mutex.Dispose() }
        if (-not $busy) { return }
        Start-Sleep -Seconds 3
    }
}

function Get-DescendantProcesses {
    param([int]$RootId, [datetime]$Since, [System.Collections.Generic.HashSet[int]]$Seen)
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($process in $all) {
            $id = [int]$process.ProcessId
            if ($Seen.Contains($id) -or $process.CreationDate -lt $Since) { continue }
            $parent = [int]$process.ParentProcessId
            if ($parent -eq $RootId -or $Seen.Contains($parent)) { [void]$Seen.Add($id); $grew = $true }
        }
    }
    return @($all | Where-Object { $Seen.Contains([int]$_.ProcessId) -and $_.CreationDate -ge $Since })
}

function Start-Installer {
    param([string]$FilePath, [string]$Arguments, [int]$Minutes)
    Wait-MsiIdle
    $start = Get-Date
    $deadline = $start.AddMinutes($Minutes)
    # Windows stay visible on purpose: if an installer ignores the silent switch and shows a
    # window, you can still click through it.
    $startArgs = @{ FilePath = $FilePath; PassThru = $true; ErrorAction = 'Stop'; WorkingDirectory = (Split-Path -Parent $FilePath) }
    if ($Arguments) { $startArgs['ArgumentList'] = $Arguments }
    $process = Start-Process @startArgs
    $null = $process.Handle   # without this, ExitCode can come back empty

    while (-not $process.WaitForExit(1000)) {
        if ((Get-Date) -gt $deadline) {
            & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            return [pscustomobject]@{ TimedOut = $true; ExitCode = $null }
        }
    }
    $exitCode = $process.ExitCode

    # Some installers hand over to a second process and quit at once - wait for those too.
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $pending = @()
    while ($true) {
        $pending = @(Get-DescendantProcesses -RootId $process.Id -Since $start -Seen $seen |
            Where-Object { $_.Name -match $InstallerProcessPattern })
        if ($pending.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 3
    }
    if ($pending.Count -gt 0) {
        foreach ($child in $pending) { & taskkill.exe /PID $child.ProcessId /T /F 2>&1 | Out-Null }
        return [pscustomobject]@{ TimedOut = $true; ExitCode = $exitCode }
    }
    return [pscustomobject]@{ TimedOut = $false; ExitCode = $exitCode }
}

function Resolve-ExitCode($Code, [string]$Vendor) {
    $result = [pscustomobject]@{ Status = "Failed (exit code $Code)"; Ok = $false; Reboot = $false }
    if ($null -eq $Code) {
        $result.Status = 'Finished (no exit code reported)'
        $result.Ok = $true
        return $result
    }
    $code = [int]$Code
    if ($Vendor -eq 'Dell') {
        # Dell Update Packages use their own codes.
        switch ($code) {
            0 { $result.Status = 'Installed'; $result.Ok = $true }
            2 { $result.Status = 'Installed - restart needed'; $result.Ok = $true; $result.Reboot = $true }
            3 { $result.Status = 'Already up to date'; $result.Ok = $true }
            4 { $result.Status = 'Needs another update first - run the script again after restarting' }
            5 { $result.Status = 'Not needed on this PC'; $result.Ok = $true }
            6 { $result.Status = 'Installed - restart needed'; $result.Ok = $true; $result.Reboot = $true }
        }
        return $result
    }
    switch ($code) {
        0           { $result.Status = 'Installed'; $result.Ok = $true }
        3010        { $result.Status = 'Installed - restart needed'; $result.Ok = $true; $result.Reboot = $true }
        1641        { $result.Status = 'Installed - restart needed'; $result.Ok = $true; $result.Reboot = $true }
        1638        { $result.Status = 'Already installed (same or newer version)'; $result.Ok = $true }
        1602        { $result.Status = 'Cancelled' }
        1618        { $result.Status = 'Another installation was running - run the script again' }
        2359302     { $result.Status = 'Already installed'; $result.Ok = $true }      # wusa 0x240006
        -2145124329 { $result.Status = 'Not needed on this PC'; $result.Ok = $true }  # wusa 0x80240017
    }
    return $result
}

function Install-InfPackage($Item) {
    $pnputil = Get-SystemTool 'pnputil.exe'
    $added = 0; $failed = 0; $reboot = $false; $index = 0
    $total = @($Item.InfFiles).Count
    foreach ($inf in $Item.InfFiles) {
        $index++
        Write-Progress -Id 2 -ParentId 1 -Activity 'Adding .inf drivers' -Status (Split-Path -Leaf $inf) -PercentComplete ([int](100 * $index / $total))
        $output = & $pnputil /add-driver $inf /install 2>&1 | Out-String
        $code = $LASTEXITCODE
        Add-Content -LiteralPath $PnpLog -Value ('[{0}] exit {1}  {2}{3}{4}' -f (Get-Date -Format 'HH:mm:ss'), $code, $inf, [Environment]::NewLine, $output.Trim())
        switch ($code) {
            0       { $added++ }
            259     { $added++ }                    # added to Windows' driver store, no device needed it right now
            3010    { $added++; $reboot = $true }
            1641    { $added++; $reboot = $true }
            default { $failed++ }
        }
    }
    Write-Progress -Id 2 -Activity 'Adding .inf drivers' -Completed
    if ($added -eq 0) {
        return [pscustomobject]@{ Status = 'Failed - no .inf could be added (see the pnputil log)'; Ok = $false; Reboot = $false; ExitCode = $null }
    }
    $status = "Installed ($added .inf added)"
    if ($failed -gt 0) { $status = "Installed ($added of $total .inf added; $failed did not apply to this PC)" }
    if ($reboot) { $status += ' - restart needed' }
    return [pscustomobject]@{ Status = $status; Ok = $true; Reboot = $reboot; ExitCode = $null }
}

function Invoke-PlanItem($Item, [int]$Number) {
    switch ($Item.Kind) {
        'INF' { return (Install-InfPackage $Item) }
        'MSI' {
            $safeName = ($Item.Display -replace '[^\w\.-]', '_')
            if ($safeName.Length -gt 80) { $safeName = $safeName.Substring($safeName.Length - 80) }
            $msiLog = Join-Path $LogFolder ('msi_{0:D3}_{1}.log' -f $Number, $safeName)
            $file = Get-SystemTool 'msiexec.exe'
            $arguments = '/i "{0}" {1} /l*v "{2}"' -f $Item.Path, $Item.Arguments, $msiLog
        }
        'MSU' {
            $file = Get-SystemTool 'wusa.exe'
            $arguments = '"{0}" {1}' -f $Item.Path, $Item.Arguments
        }
        default {
            $file = $Item.Path
            $arguments = $Item.Arguments
        }
    }
    $run = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $run = Start-Installer -FilePath $file -Arguments $arguments -Minutes $TimeoutMinutes
        if ($run.TimedOut -or $run.ExitCode -ne 1618) { break }
        Write-Info 'Another installation is running - waiting, then trying again...' 'Yellow'
        Start-Sleep -Seconds 30
    }
    if ($run.TimedOut) {
        return [pscustomobject]@{
            Status = "Timed out after $TimeoutMinutes min (probably waiting for a click - see switches.txt in the README)"
            Ok = $false; Reboot = $false; ExitCode = $run.ExitCode
        }
    }
    $result = Resolve-ExitCode $run.ExitCode $Item.Vendor
    $result | Add-Member -NotePropertyName ExitCode -NotePropertyValue $run.ExitCode
    return $result
}

# ============================================================================
#  1. Find the drivers (done before elevating so mapped network drives still work)
# ============================================================================

try { $Host.UI.RawUI.WindowTitle = 'Driver installer' } catch { }

try {
    $Source = Resolve-DriverSource $DriverPath
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Wait-ForEnter
    exit 1
}
if (-not $Source) {
    Write-Host 'No driver folder was chosen, so there is nothing to do.' -ForegroundColor Red
    Wait-ForEnter
    exit 1
}

# ============================================================================
#  2. Ask for administrator rights ONCE, by restarting this script elevated
# ============================================================================

if (-not $DryRun -and -not (Test-IsAdmin)) {
    if (-not $PSCommandPath) {
        Write-Host 'Save this as a .ps1 file and run that file - it needs to restart itself as administrator.' -ForegroundColor Red
        exit 1
    }
    Write-Host 'Administrator rights are needed. Windows will ask ONCE now - after that everything runs on its own.' -ForegroundColor Yellow
    $relaunch = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-CommandLineArg (ConvertTo-UncPath $PSCommandPath)),
        '-DriverPath', (ConvertTo-CommandLineArg (ConvertTo-UncPath $Source)),
        '-WorkFolder', (ConvertTo-CommandLineArg $WorkFolder),
        '-TimeoutMinutes', $TimeoutMinutes
    )
    foreach ($switchName in @('IncludeFirmware', 'AllowUnsigned', 'OrderByName', 'Force', 'AutoReboot', 'NoPause')) {
        if ((Get-Variable -Name $switchName -ValueOnly).IsPresent) { $relaunch += "-$switchName" }
    }
    try {
        Start-Process -FilePath (Get-PowerShellExe) -ArgumentList ($relaunch -join ' ') -Verb RunAs -ErrorAction Stop | Out-Null
    } catch {
        Write-Host 'Administrator rights were not given, so nothing was installed.' -ForegroundColor Red
        Wait-ForEnter
        exit 1
    }
    exit 0
}

# ============================================================================
#  3. From here on we are administrator - no more prompts
# ============================================================================

$LogFolder      = Join-Path $WorkFolder 'Logs'
$UnpackFolder   = Join-Path $WorkFolder 'Unpacked'
$DownloadFolder = Join-Path $WorkFolder 'Downloads'
$StateFile      = Join-Path $WorkFolder 'completed.txt'
$Stamp          = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$PnpLog         = Join-Path $LogFolder "pnputil_$Stamp.log"
$ResultsCsv     = Join-Path $LogFolder "results_$Stamp.csv"

$script:Plan = New-Object System.Collections.Generic.List[object]
$script:Overrides = @()
$script:DownloadFailures = @()
$RestartNow = $false
$ScriptExitCode = 0

New-Item -ItemType Directory -Force -Path $LogFolder, $UnpackFolder | Out-Null
$TranscriptOn = $false
try { Start-Transcript -Path (Join-Path $LogFolder "DriverInstall_$Stamp.log") -Force | Out-Null; $TranscriptOn = $true } catch { }

try {
    Set-KeepAwake $true
    Write-Host ''
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host '  Driver installer' -ForegroundColor Cyan
    Write-Host "  Drivers from : $Source"
    Write-Host "  Logs         : $LogFolder"
    if ($DryRun) { Write-Host '  DRY RUN - nothing will be installed' -ForegroundColor Yellow }
    Write-Host '=================================================================' -ForegroundColor Cyan

    # Files downloaded from the internet carry a "blocked" flag that can pop up a security
    # warning for every installer. Clear it once here instead.
    Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { ($InstallerExtensions + $ArchiveExtensions) -contains $_.Extension.ToLower() } |
        Unblock-File -ErrorAction SilentlyContinue

    $script:Root = $Source
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        $sourceFile = Get-Item -LiteralPath $Source
        if ($ArchiveExtensions -notcontains $sourceFile.Extension.ToLower()) {
            throw "$Source is not a folder, .zip or .cab file."
        }
        Write-Step "Unpacking $($sourceFile.Name)"
        $script:Root = Expand-DriverArchive $sourceFile
    }

    $switchesFile = Find-ControlFile 'switches.txt'
    if ($switchesFile) {
        $script:Overrides = @(Read-SwitchOverrides $switchesFile)
        Write-Step "Using $($script:Overrides.Count) custom rule(s) from $switchesFile"
    }

    $downloadsFile = Find-ControlFile 'downloads.txt'
    if ($downloadsFile) {
        Write-Step "Downloading files listed in $downloadsFile"
        Invoke-DownloadList $downloadsFile
    }

    Write-Step 'Looking through the driver folder'
    Add-FolderToPlan -Folder $script:Root -Depth 0 -Label ''
    if ($downloadsFile -and (Test-Path -LiteralPath $DownloadFolder)) {
        Add-FolderToPlan -Folder $DownloadFolder -Depth 0 -Label 'downloads'
    }

    # Skip what already finished, duplicates, and (unless asked) BIOS/firmware.
    $completed = New-Object 'System.Collections.Generic.HashSet[string]'
    if (-not $Force -and (Test-Path -LiteralPath $StateFile)) {
        foreach ($line in Get-Content -LiteralPath $StateFile) { if ($line) { [void]$completed.Add($line.Trim()) } }
    }
    $keysInPlan = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $script:Plan) {
        if ($item.SkipReason) { continue }
        if ($item.Key -and -not $keysInPlan.Add($item.Key)) {
            $item.SkipReason = 'Same file as another item in the list'
        } elseif ($item.Key -and $completed.Contains($item.Key)) {
            $item.SkipReason = 'Already done in an earlier run (use -Force to redo)'
        } elseif ($item.Firmware -and -not $IncludeFirmware) {
            $item.SkipReason = 'BIOS/firmware update - skipped for safety (use -IncludeFirmware)'
        }
    }

    if ($OrderByName) {
        $sorted = @($script:Plan | Sort-Object @{ Expression = { [int]$_.Firmware } }, Display)
    } else {
        $sorted = @($script:Plan | Sort-Object Order, Display)
    }
    $todo    = @($sorted | Where-Object { -not $_.SkipReason })
    $skipped = @($sorted | Where-Object { $_.SkipReason })

    Write-Step ("Plan: {0} to install, {1} skipped" -f $todo.Count, $skipped.Count)
    $number = 0
    foreach ($item in $todo) {
        $number++
        Write-Host ('  {0,3}. {1,-21} {2}' -f $number, $item.Category, $item.Display)
        Write-Host ('       {0}   {1}' -f $item.Method, $item.Arguments) -ForegroundColor DarkGray
    }
    foreach ($item in $skipped) {
        Write-Host ('   --  {0}' -f $item.Display) -ForegroundColor DarkYellow
        Write-Host ('       {0}' -f $item.SkipReason) -ForegroundColor DarkGray
    }

    if ($todo.Count -eq 0) {
        Write-Step 'Nothing to install.'
        if ($script:Plan.Count -eq 0) {
            Write-Info 'No .exe, .msi, .msu, .zip, .cab or .inf files were found. See README.md for what to put in the folder.' 'Yellow'
        }
    } elseif ($DryRun) {
        Write-Step 'Dry run finished - nothing was installed. Run again without -DryRun to install.'
    } else {
        # ---------------- Install ----------------
        $bitLockerHandled = $false
        $number = 0
        foreach ($item in $todo) {
            $number++
            Write-Progress -Id 1 -Activity 'Installing drivers' -Status ("{0} of {1}: {2}" -f $number, $todo.Count, $item.Display) `
                -PercentComplete ([int](100 * ($number - 1) / $todo.Count))
            Write-Step ('[{0}/{1}] {2}' -f $number, $todo.Count, $item.Display)
            Write-Info ('{0}   {1}' -f $item.Method, $item.Arguments) 'DarkGray'

            if ($item.Firmware) {
                if (-not (Test-OnACPower)) {
                    $item.Status = 'Skipped - plug in the charger for BIOS/firmware updates'
                    Write-Info $item.Status 'Yellow'
                    continue
                }
                if (-not $bitLockerHandled) { Suspend-BitLockerOnce; $bitLockerHandled = $true }
            }

            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                $result = Invoke-PlanItem $item $number
            } catch {
                $result = [pscustomobject]@{ Status = "Could not start: $($_.Exception.Message)"; Ok = $false; Reboot = $false; ExitCode = $null }
            }
            $item.Status = $result.Status
            $item.Ok = [bool]$result.Ok
            $item.Reboot = [bool]$result.Reboot
            $item.ExitCode = $result.ExitCode
            $color = 'Red'
            if ($item.Ok) { $color = 'Green' }
            Write-Info ('{0}  ({1:mm\:ss})' -f $item.Status, $timer.Elapsed) $color
            if ($item.Ok -and $item.Key) { Add-Content -LiteralPath $StateFile -Value $item.Key }
        }
        Write-Progress -Id 1 -Activity 'Installing drivers' -Completed

        # ---------------- Summary ----------------
        $good = @($todo | Where-Object { $_.Ok })
        $bad  = @($todo | Where-Object { -not $_.Ok })
        Write-Step 'Summary'
        Write-Info ('Done (installed / up to date) : {0}' -f $good.Count) 'Green'
        $badColor = 'Gray'
        if ($bad.Count -gt 0) { $badColor = 'Red'; $ScriptExitCode = 1 }
        Write-Info ('Not done                      : {0}' -f $bad.Count) $badColor
        Write-Info ('Skipped                       : {0}' -f $skipped.Count)
        foreach ($item in $bad) { Write-Info ('  x {0}: {1}' -f $item.Display, $item.Status) 'Red' }
        foreach ($name in $script:DownloadFailures) { Write-Info "  x download failed: $name" 'Red' }
        if ($bad.Count -gt 0) {
            Write-Info 'Fix or remove those, then run the script again - finished items are skipped automatically.' 'Yellow'
        }

        foreach ($item in $skipped) { $item.Status = 'Skipped' }
        $sorted | Select-Object Category, Display, Kind, Method, Arguments, Status, ExitCode, SkipReason, Path |
            Export-Csv -LiteralPath $ResultsCsv -NoTypeInformation
        Write-Info "Logs and results: $LogFolder"

        if ($bad.Count -eq 0) {
            Remove-Item -LiteralPath $UnpackFolder -Recurse -Force -ErrorAction SilentlyContinue
        }

        # ---------------- One restart at the end ----------------
        $needsRestart = @($todo | Where-Object { $_.Reboot }).Count -gt 0
        $installedAny = @($todo | Where-Object { $_.Ok -and $_.Status -like 'Installed*' }).Count -gt 0
        if ($needsRestart -or $installedAny) {
            if ($needsRestart) {
                Write-Step 'A restart is needed to finish installing.'
            } else {
                Write-Step 'A restart is recommended so the new drivers load.'
            }
            if ($AutoReboot) {
                $RestartNow = $true
            } elseif (-not $NoPause) {
                $answer = Read-Host 'Restart now? (Y/N)'
                $RestartNow = ($answer -match '^\s*y')
            }
        }
    }
} catch {
    Write-Host ''
    Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Details are in the log folder.' -ForegroundColor Red
    $ScriptExitCode = 1
} finally {
    Set-KeepAwake $false
    if ($TranscriptOn) { try { Stop-Transcript | Out-Null } catch { } }
}

if ($RestartNow) {
    if ($AutoReboot) {
        Write-Host 'Restarting in 30 seconds - press Ctrl+C to cancel.' -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
    Restart-Computer -Force
} else {
    Wait-ForEnter
}
exit $ScriptExitCode
