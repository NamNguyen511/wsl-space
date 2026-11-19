<#PSScriptInfo
.VERSION 1.0.0
.GUID 76a27784-18ba-4193-a728-be9a6ee8c0d1
.AUTHOR Nam Nguyen
.COPYRIGHT (c) 2026 Nam Nguyen. MIT License.
.LICENSEURI https://github.com/NamNguyen511/wsl-space/blob/main/LICENSE
.PROJECTURI https://github.com/NamNguyen511/wsl-space
.TAGS WSL WSL2 disk-space vhdx compact Docker Windows
.RELEASENOTES
1.0.0: report (per distro and Docker Desktop data disk), big folders, trim, compact, move to another
drive, daily low-space warning, window with light/dark theme.
#>

<#
.SYNOPSIS
  wsl-space: see, find and reclaim the disk space WSL uses on C:.
.DESCRIPTION
  Shows how much of C: each WSL distribution's virtual disk really uses, finds big folders, gives
  space back to C: (trim, compact, move to another drive) and warns before C: runs low.
  Never deletes files. No switch opens the window. See README.md.
#>
[CmdletBinding()]
param(
    [switch]$Report,
    [switch]$BigFolders,
    [switch]$Trim,
    [string]$Compact,
    [string]$Move,
    [string]$To,
    [switch]$Check,
    [switch]$SelfTest,
    [string]$Distro,
    [string]$Path = '~',
    [int]$Depth = 3,
    [int]$Top = 25,
    [double]$ThresholdGB = 0,
    # Internal: set when the confirmation was already given (GUI or elevated relaunch).
    [switch]$Confirmed,
    # Internal: transcript file for the elevated compaction.
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $OutputEncoding } catch { }

$script:ScriptFile = $PSCommandPath
$script:DefaultThresholdGB = 15.0
$script:TaskName = 'wsl-space-check'
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
# Docker Desktop's data disk is not a registered distro. Distro names cannot contain spaces, so this cannot clash.
$script:DockerDiskName = 'Docker Desktop data'
# Non-ASCII symbols built from code points: PowerShell 5.1 reads a BOM-less script as ANSI.
$script:SymCheck = [string][char]0x2713   # check mark
$script:SymCross = [string][char]0x2717   # ballot x
$script:SymPlay = [string][char]0x25B6    # section marker
$script:SymBlock = [string][char]0x2588   # full block (size bars)
$script:Ell = [string][char]0x2026        # ellipsis

# ---------------------------------------------------------------- pure helpers

function Format-SizeGB([long]$Bytes) {
    ($Bytes / 1GB).ToString('0.0', $script:Inv) + ' GB'
}

function Get-ReclaimableBytes([long]$VhdxBytes, [long]$UsedBytes) {
    [Math]::Max([long]0, $VhdxBytes - $UsedBytes)
}

# Accepts `df -B1 --output=used /` (header "Used" + number) and plain `df -B1 /`
# (BusyBox / POSIX table, where the Used column is picked by the header).
function Parse-DfOutput([string]$Output) {
    $lines = @($Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $hi = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '(^|\s)Used(\s|$)') { $hi = $i; break } }
    if ($hi -lt 0) { throw "Unexpected df output: $Output" }
    $cols = $lines[$hi] -split '\s+'
    $data = (($lines | Select-Object -Skip ($hi + 1)) -join ' ') -split '\s+' | Where-Object { $_ }
    $value = @($data)[[Array]::IndexOf($cols, 'Used')]
    if ($value -notmatch '^\d+$') { throw "Unexpected df output: $Output" }
    [long]$value
}

# Parses `du -k` lines ("<KB><TAB><path>"), largest first. Paths may contain spaces.
function Parse-DuOutput([string]$Output) {
    $Output -split "`r?`n" | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+(.+?)\s*$') {
            $kb = [long]$Matches[1]
            [pscustomobject]@{ SizeKB = $kb; SizeBytes = $kb * 1024; Size = Format-SizeGB ($kb * 1024); Path = $Matches[2] }
        }
    } | Sort-Object SizeKB -Descending
}

function New-DiskpartScriptContent([string]$VhdxPath) {
    "select vdisk file=`"$VhdxPath`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit`r`n"
}

function New-DiskpartDetachScriptContent([string]$VhdxPath) {
    "select vdisk file=`"$VhdxPath`"`r`ndetach vdisk`r`nexit`r`n"
}

function Get-SettingsDir { Join-Path $env:LOCALAPPDATA 'wsl-space' }

$script:WindowKeys = 'WindowWidth', 'WindowHeight', 'WindowX', 'WindowY', 'SplitterDistance', 'LastTab'

function Get-Settings([string]$SettingsDir = (Get-SettingsDir)) {
    $file = Join-Path $SettingsDir 'settings.json'
    $s = [pscustomobject]@{
        ThresholdGB = $script:DefaultThresholdGB
        WindowWidth = 980; WindowHeight = 700; WindowX = $null; WindowY = $null; SplitterDistance = 0; LastTab = 0
    }
    if (Test-Path -LiteralPath $file) {
        $j = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        if ($j.ThresholdGB -gt 0) { $s.ThresholdGB = [double]$j.ThresholdGB }
        foreach ($k in $script:WindowKeys) { if ($null -ne $j.$k) { $s.$k = [int]$j.$k } }
    }
    $s
}

# Merges into the existing file: a threshold <= 0 keeps the stored one; $WindowState keys are $script:WindowKeys.
function Save-Settings([double]$ThresholdGB, [string]$SettingsDir = (Get-SettingsDir), [hashtable]$WindowState) {
    New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
    $s = Get-Settings $SettingsDir
    if ($ThresholdGB -gt 0) { $s.ThresholdGB = $ThresholdGB }
    if ($WindowState) { foreach ($k in $WindowState.Keys) { $s.$k = $WindowState[$k] } }
    $s | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $SettingsDir 'settings.json') -Encoding UTF8
}

function Test-LowDiskSpace([long]$FreeBytes, [double]$ThresholdGB) {
    ($FreeBytes / 1GB) -lt $ThresholdGB
}

function Get-DiskHealth([long]$FreeBytes, [double]$ThresholdGB) {
    if (($FreeBytes / 1GB) -lt 5) { $st = 'Critical'; $t = "$script:SymCross Critical (below 5 GB)" }
    elseif (Test-LowDiskSpace $FreeBytes $ThresholdGB) { $st = 'Low'; $t = "! Low (below $($ThresholdGB.ToString('0.#', $script:Inv)) GB)" }
    else { $st = 'Healthy'; $t = "$script:SymCheck Healthy" }
    [pscustomobject]@{ Status = $st; ChipText = $t }
}

function Get-ThemePalette([bool]$Dark) {
    if ($Dark) {
        @{ IsDark = $true; Background = '#0F172A'; Surface = '#1B2336'; Border = '#475569'; Text = '#F8FAFC'; MutedText = '#94A3B8'
            Accent = '#22C55E'; AccentText = '#0F172A'; Success = '#4ADE80'; Warning = '#FBBF24'; Error = '#F87171' }
    } else {
        @{ IsDark = $false; Background = '#F8FAFC'; Surface = '#FFFFFF'; Border = '#CBD5E1'; Text = '#0F172A'; MutedText = '#475569'
            Accent = '#15803D'; AccentText = '#FFFFFF'; Success = '#15803D'; Warning = '#B45309'; Error = '#B91C1C' }
    }
}

# AppsUseLightTheme = 0 means dark; missing means light.
function Test-WindowsDarkTheme {
    (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0
}

# Classifies a job/log line: '=== x ===' section, '> x' command, 'ERROR: x' error,
# 'WARNING: x' warning, two-space indent output, anything else output.
function ConvertTo-LogEntry([string]$Line) {
    if ($Line -match '^===\s*(.+?)\s*===$') { $k = 'section'; $t = $Matches[1] }
    elseif ($Line -match '^>\s?(.*)$') { $k = 'command'; $t = $Matches[1] }
    elseif ($Line -match '^ERROR:\s*(.*)$') { $k = 'error'; $t = $Matches[1] }
    elseif ($Line -match '^WARNING:\s*(.*)$') { $k = 'warning'; $t = $Matches[1] }
    elseif ($Line -match '^  (.*)$') { $k = 'output'; $t = $Matches[1] }
    else { $k = 'output'; $t = $Line }
    [pscustomobject]@{ Kind = $k; Text = $t }
}

function Select-LogEntries($Entries, [string]$Filter) {
    $kinds = switch ($Filter) { 'Commands & output' { 'command', 'output' } 'Errors only' { 'error' } default { $null } }
    @($Entries | Where-Object { $_ -and (-not $kinds -or $_.Kind -in $kinds) })
}

function Format-LogEntry($Entry, [datetime]$Time = (Get-Date)) {
    $sym = switch ($Entry.Kind) {
        'section' { $script:SymPlay } 'command' { '>' } 'success' { $script:SymCheck }
        'warning' { '!' } 'error' { $script:SymCross } default { ' ' }
    }
    $text = if ($Entry.Kind -eq 'output') { '  ' + $Entry.Text } else { $Entry.Text }
    "$($Time.ToString('HH:mm:ss', $script:Inv))  $sym  $text"
}

function ConvertTo-WslExplorerPath([string]$DistroName, [string]$LinuxPath) {
    "\\wsl.localhost\$DistroName" + ($LinuxPath -replace '/', '\')
}

# Single-quotes a string for sh.
function ConvertTo-ShQuoted([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }

# '~' and '~/x' become "$HOME"/'x'; everything else is quoted literally.
function ConvertTo-ShPath([string]$p) {
    if ($p -eq '~') { return '"$HOME"' }
    if ($p.StartsWith('~/')) { return '"$HOME"/' + (ConvertTo-ShQuoted $p.Substring(2)) }
    ConvertTo-ShQuoted $p
}

# ---------------------------------------------------------------- system helpers

# Runs a native command, logs the command line and its output.
function Invoke-Logged([string]$Exe, [string[]]$Arguments, [string]$StdIn) {
    Write-Host ("> $Exe " + ($Arguments -join ' ') + $(if ($StdIn) { "   <<< $StdIn" } else { '' }))
    $ErrorActionPreference = 'Continue'
    if ($StdIn) { $out = $StdIn | & $Exe @Arguments 2>&1 } else { $out = & $Exe @Arguments 2>&1 }
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { ("$_" -replace "`0", '').TrimEnd() } | Where-Object { $_ })
    $lines | ForEach-Object { Write-Host "  $_" }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines; Text = ($lines -join "`n") }
}

# Runs a one-line sh script inside a distro, fed on stdin (avoids Windows argument quoting).
# The trailing '#' swallows the CR that PowerShell appends to stdin.
function Invoke-WslSh([string]$DistroName, [string]$Script) {
    Invoke-Logged 'wsl.exe' @('-d', $DistroName, '--', 'sh', '-s') "$Script #"
}

function Get-CDriveFreeBytes { [long](Get-PSDrive -Name C).Free }

function Get-AllocatedBytes([string]$File) {
    if (-not ('WslSpace.Native' -as [type])) {
        Add-Type -Namespace WslSpace -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
'@
    }
    $high = [uint32]0
    $low = [WslSpace.Native]::GetCompressedFileSizeW($File, [ref]$high)
    if ($low -eq [uint32]::MaxValue -and [Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) {
        return [long](Get-Item -LiteralPath $File -Force).Length
    }
    ([long]$high -shl 32) + [long]$low
}

function Get-WslDistros {
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $root)) { return @() }
    $default = (Get-ItemProperty $root -ErrorAction SilentlyContinue).DefaultDistribution
    $list = foreach ($k in Get-ChildItem $root) {
        $p = Get-ItemProperty $k.PSPath
        if (-not $p.DistributionName -or -not $p.BasePath) { continue }
        $base = $p.BasePath -replace '^\\\\\?\\', ''
        [pscustomobject]@{
            Name      = $p.DistributionName
            IsDefault = ($k.PSChildName -eq $default)
            VhdxPath  = Join-Path $base 'ext4.vhdx'
            IsDocker  = $false
        }
    }
    # Docker Desktop 4.30+ keeps images, containers and volumes in this disk (older versions used a
    # registered docker-desktop-data distro, which the loop above already covers).
    $dockerVhdx = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
    if (Test-Path -LiteralPath $dockerVhdx) {
        $list = @($list) + [pscustomobject]@{ Name = $script:DockerDiskName; IsDefault = $false; VhdxPath = $dockerVhdx; IsDocker = $true }
    }
    # Biggest disk first: that is the distro worth inspecting when no -Distro is given.
    $size = { $f = Get-Item -LiteralPath $_.VhdxPath -Force -ErrorAction SilentlyContinue; if ($f) { $f.Length } else { 0 } }
    @($list | Sort-Object @{ e = $size; Descending = $true }, Name)
}

function Resolve-DistroName([string]$Name) {
    $all = Get-WslDistros
    if (-not $all) { throw 'No WSL distributions found.' }
    if (-not $Name) {
        $distros = @($all | Where-Object { -not $_.IsDocker })
        if (-not $distros) { throw 'No WSL distributions found.' }
        return $distros[0].Name
    }
    $d = $all | Where-Object { $_.Name -eq $Name }
    if (-not $d) { throw "Unknown distribution '$Name'. Known: $(($all.Name) -join ', ')" }
    $d.Name
}

function Get-VhdxSparseStatus([string]$VhdxPath) {
    $r = Invoke-Logged 'fsutil.exe' @('sparse', 'queryflag', $VhdxPath)
    if ($r.Text -match 'NOT set as sparse') { return $false }
    if ($r.Text -match 'set as sparse') { return $true }
    $null
}

function Assert-NotDockerDisk([string]$DistroName, [string]$What) {
    if ($DistroName -eq $script:DockerDiskName) {
        throw "$What does not apply to the Docker Desktop data disk. See Docker's usage with 'docker system df'; free space with 'docker system prune' (you choose what goes), then Compact."
    }
}

# Docker Desktop restarts WSL on its own, so it must be closed while its disk is compacted.
function Assert-DockerDesktopStopped([string]$DistroName) {
    if ($DistroName -eq $script:DockerDiskName -and (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        throw 'Quit Docker Desktop first (tray icon > Quit Docker Desktop); it restarts WSL while running. Nothing was changed.'
    }
}

function Get-WslUsedBytes([string]$DistroName) {
    # GNU df first; BusyBox (e.g. docker-desktop) lacks --output.
    $r = Invoke-WslSh $DistroName 'df -B1 --output=used / 2>/dev/null || df -B1 /'
    if ($r.ExitCode -ne 0) { throw "df failed in $DistroName (exit $($r.ExitCode))" }
    Parse-DfOutput $r.Text
}

# ---------------------------------------------------------------- operations

function Get-SpaceReportData {
    $rows = foreach ($d in Get-WslDistros) {
        $row = [pscustomobject]@{
            Name = $d.Name; IsDefault = $d.IsDefault; VhdxPath = $d.VhdxPath; IsDocker = $d.IsDocker
            Drive = ([System.IO.Path]::GetPathRoot($d.VhdxPath)).TrimEnd('\')
            VhdxBytes = $null; UsedBytes = $null; ReclaimableBytes = $null; Sparse = $null; Note = ''
        }
        if (Test-Path -LiteralPath $d.VhdxPath) {
            $row.VhdxBytes = Get-AllocatedBytes $d.VhdxPath
            $row.Sparse = Get-VhdxSparseStatus $d.VhdxPath
            # ponytail: Docker disk usage not measured (needs Docker Desktop running); add via its data mount if wanted.
            if ($d.IsDocker) { $row.Note = "Docker images/volumes; start Docker Desktop, then: docker system df"; $row; continue }
            try {
                $row.UsedBytes = Get-WslUsedBytes $d.Name
                $row.ReclaimableBytes = Get-ReclaimableBytes $row.VhdxBytes $row.UsedBytes
            } catch { $row.Note = "$_" }
        } else { $row.Note = 'no ext4.vhdx at BasePath' }
        $row
    }
    [pscustomobject]@{ Distros = @($rows); CFreeBytes = (Get-CDriveFreeBytes) }
}

function Format-Report($data) {
    $fmt = { param($b) if ($null -eq $b) { '?' } else { Format-SizeGB $b } }
    $table = $data.Distros | ForEach-Object {
        [pscustomobject]@{
            Distro      = $_.Name + $(if ($_.IsDefault) { ' (default)' } else { '' })
            Drive          = $_.Drive
            'VHDX on disk' = & $fmt $_.VhdxBytes
            'Linux used'   = & $fmt $_.UsedBytes
            Reclaimable    = & $fmt $_.ReclaimableBytes
            Sparse         = $(if ($null -eq $_.Sparse) { '?' } elseif ($_.Sparse) { 'yes' } else { 'no' })
            Note           = $_.Note
        }
    } | Format-Table -AutoSize | Out-String
    $table.TrimEnd() + "`n`nC: free: $(Format-SizeGB $data.CFreeBytes)`n" + (Get-TrimHint)
}

function Get-TrimHint { 'Tip: weekly automatic trim inside WSL: sudo systemctl enable --now fstrim.timer' }

function Get-BigFoldersData([string]$DistroName, [string]$LinuxPath = '~', [int]$Depth = 3, [int]$Top = 25) {
    Assert-NotDockerDisk $DistroName 'Big folders'
    $sh = "du -xk --max-depth=$([int]$Depth) -- $(ConvertTo-ShPath $LinuxPath) 2>/dev/null | sort -n | tail -n $([int]$Top)"
    $r = Invoke-WslSh $DistroName $sh
    @(Parse-DuOutput $r.Text)
}

function Invoke-Trim([string]$DistroName) {
    Assert-NotDockerDisk $DistroName 'Trim'
    $before = Get-CDriveFreeBytes
    Write-Host "C: free before: $(Format-SizeGB $before)"
    $r = Invoke-Logged 'wsl.exe' @('-d', $DistroName, '-u', 'root', '--', 'fstrim', '-v', '/')
    $after = Get-CDriveFreeBytes
    Write-Host "C: free after:  $(Format-SizeGB $after)  (change: $(Format-SizeGB ($after - $before)))"
    Write-Host (Get-TrimHint)
    if ($r.ExitCode -ne 0) { throw "fstrim failed (exit $($r.ExitCode))" }
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Copies the script to %LOCALAPPDATA%\wsl-space so it does not depend on \\wsl.localhost.
function Install-LocalCopy {
    $dir = Get-SettingsDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir 'wsl-space.ps1'
    if ($script:ScriptFile -ne $dest) { Copy-Item -LiteralPath $script:ScriptFile -Destination $dest -Force }
    $dest
}

# Non-elevated entry: relaunches itself elevated and shows the elevated run's transcript.
function Start-ElevatedCompact([string]$DistroName) {
    Assert-DockerDesktopStopped $DistroName
    $exe = Install-LocalCopy
    $log = Join-Path (Get-SettingsDir) ("compact-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$exe`" -Compact `"$DistroName`" -Confirmed -LogFile `"$log`""
    Write-Host "> Start-Process powershell.exe -Verb RunAs -ArgumentList '$argList'"
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host "  $_" } }
    if ($p.ExitCode -ne 0) { throw "Elevated compaction failed (exit $($p.ExitCode)). Log: $log" }
}

function Invoke-Compact([string]$DistroName) {
    $d = Get-WslDistros | Where-Object { $_.Name -eq $DistroName }
    if (-not $d) { throw "Unknown distribution '$DistroName'." }
    Assert-DockerDesktopStopped $DistroName
    $vhdx = $d.VhdxPath
    if (-not (Test-Path -LiteralPath $vhdx)) { throw "VHDX not found: $vhdx" }
    $sizeBefore = Get-AllocatedBytes $vhdx
    $freeBefore = Get-CDriveFreeBytes
    Write-Host "Compacting $DistroName : $vhdx"
    Write-Host "Before: VHDX $(Format-SizeGB $sizeBefore), C: free $(Format-SizeGB $freeBefore)"

    $r = Invoke-Logged 'wsl.exe' @('--shutdown')
    if ($r.ExitCode -ne 0) { throw "wsl --shutdown failed (exit $($r.ExitCode)). Nothing was changed." }

    $wasSparse = Get-VhdxSparseStatus $vhdx
    if ($wasSparse -ne $false) {
        # wsl --manage only knows registered distros; the Docker disk gets the NTFS flag cleared directly.
        $r = if ($d.IsDocker) { Invoke-Logged 'fsutil.exe' @('sparse', 'setflag', $vhdx, '0') }
             else { Invoke-Logged 'wsl.exe' @('--manage', $DistroName, '--set-sparse', 'false') }
        if ($r.ExitCode -ne 0) { throw "Could not turn sparse off (exit $($r.ExitCode)); diskpart refuses sparse files. Nothing else was changed." }
    }

    $tag = [guid]::NewGuid().ToString('N')
    $dpScript = Join-Path $env:TEMP "wsl-space-diskpart-$tag.txt"
    $dpDetach = Join-Path $env:TEMP "wsl-space-diskpart-detach-$tag.txt"
    Set-Content -LiteralPath $dpScript -Value (New-DiskpartScriptContent $vhdx) -Encoding ASCII
    Set-Content -LiteralPath $dpDetach -Value (New-DiskpartDetachScriptContent $vhdx) -Encoding ASCII
    Write-Host "diskpart script ($dpScript):"
    Get-Content -LiteralPath $dpScript | ForEach-Object { Write-Host "  $_" }
    $failed = $null
    try {
        $r = Invoke-Logged 'diskpart.exe' @('/s', $dpScript)
        if ($r.ExitCode -ne 0) { $failed = "diskpart compact failed (exit $($r.ExitCode))." }
    } finally {
        # Never leave the disk attached. Errors here just mean it was already detached.
        Invoke-Logged 'diskpart.exe' @('/s', $dpDetach) | Out-Null
    }
    if ($wasSparse -ne $false) {
        # Not turned back on: WSL now gates sparse VHDs behind --allow-unsafe (possible data corruption).
        Write-Host "Note: sparse was turned off for compaction and left off (WSL marks sparse VHDs as unsafe)."
    }
    $sizeAfter = Get-AllocatedBytes $vhdx
    $freeAfter = Get-CDriveFreeBytes
    Write-Host "After:  VHDX $(Format-SizeGB $sizeAfter), C: free $(Format-SizeGB $freeAfter)"
    Write-Host (Format-CompactResult $sizeBefore $sizeAfter $freeBefore $freeAfter)
    if ($failed) { throw $failed }
}

# Moves a distro's disk to another folder (usually another drive) with WSL's own wsl --manage --move.
# All checks run before anything is stopped or changed.
function Invoke-Move([string]$DistroName, [string]$Target) {
    if ($DistroName -eq $script:DockerDiskName) {
        throw 'Move the Docker disk in Docker Desktop: Settings > Resources > Advanced > Disk image location.'
    }
    $d = Get-WslDistros | Where-Object { $_.Name -eq $DistroName }
    if (-not $d) { throw "Unknown distribution '$DistroName'." }
    if (-not $Target) { throw 'No target folder given.' }
    $Target = [System.IO.Path]::GetFullPath($Target)
    $from = Split-Path -Parent $d.VhdxPath
    if ($Target.TrimEnd('\') -eq $from.TrimEnd('\')) { throw "'$DistroName' is already in $Target." }
    $root = [System.IO.Path]::GetPathRoot($Target)
    if ($root -eq [System.IO.Path]::GetPathRoot($from)) {
        throw "$Target is on $root, the drive '$DistroName' is on now: moving within one drive frees nothing there. Pick a folder on another drive."
    }
    if ($Target.TrimEnd('\') -eq $root.TrimEnd('\')) {
        throw "Pick a folder, not the drive root $root (for example $(Join-Path $root "WSL\$DistroName"))."
    }
    if (Test-Path -LiteralPath (Join-Path $Target 'ext4.vhdx')) { throw "$Target already holds an ext4.vhdx. Pick an empty folder." }
    $need = Get-AllocatedBytes $d.VhdxPath
    $drive = [System.IO.DriveInfo]::new($root)
    if (-not $drive.IsReady) { throw "Drive $($drive.Name) is not available." }
    if ($drive.AvailableFreeSpace -lt $need + 1GB) {
        throw "Not enough space on $($drive.Name): need $(Format-SizeGB ($need + 1GB)), free $(Format-SizeGB $drive.AvailableFreeSpace)."
    }

    $freeBefore = Get-CDriveFreeBytes
    Write-Host "Moving $DistroName ($(Format-SizeGB $need)) from $from to $Target"
    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target | Out-Null }
    # wsl --terminate is not enough: WSL keeps the disk open (ERROR_SHARING_VIOLATION) until a full shutdown.
    $r = Invoke-Logged 'wsl.exe' @('--shutdown')
    if ($r.ExitCode -ne 0) { throw "wsl --shutdown failed (exit $($r.ExitCode)). Nothing was moved." }
    $r = Invoke-Logged 'wsl.exe' @('--manage', $DistroName, '--move', $Target)
    if ($r.ExitCode -ne 0) { throw "wsl --manage --move failed (exit $($r.ExitCode)). WSL keeps the distro where it was." }
    $freeAfter = Get-CDriveFreeBytes
    Write-Host "Moved. C: free $(Format-SizeGB $freeBefore) -> $(Format-SizeGB $freeAfter)"
}

# The disk file's own change is the compaction result. C: free also moves for other reasons
# (wsl --shutdown deletes WSL's swap file), so it is never reported as the gain.
function Format-CompactResult([long]$SizeBefore, [long]$SizeAfter, [long]$FreeBefore, [long]$FreeAfter) {
    $shrank = $SizeBefore - $SizeAfter
    $other = "C: free changed by $(Format-SizeGB ($FreeAfter - $FreeBefore)) in total (WSL's swap file is also removed on shutdown)."
    if ($shrank -ge 100MB) { return "Disk shrank by $(Format-SizeGB $shrank). $other" }
    "The disk did not shrink: Linux had no trimmed free space to give back. Free space inside Linux (or prune Docker), trim, then compact again. $other"
}

function Show-LowSpaceNotification([long]$FreeBytes, [double]$ThresholdGB) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $n = New-Object System.Windows.Forms.NotifyIcon
    $n.Icon = [System.Drawing.SystemIcons]::Warning
    $n.Visible = $true
    $n.BalloonTipIcon = 'Warning'
    $n.BalloonTipTitle = 'C: is running low on space'
    $n.BalloonTipText = "C: has $(Format-SizeGB $FreeBytes) free (warning below $ThresholdGB GB). Open wsl-space to reclaim WSL disk space."
    $script = $script:ScriptFile
    $n.add_BalloonTipClicked({ Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" }.GetNewClosure())
    $n.ShowBalloonTip(10000)
    $end = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
    $n.Dispose()
}

function Invoke-Check([double]$ThresholdGB) {
    if ($ThresholdGB -le 0) { $ThresholdGB = (Get-Settings).ThresholdGB }
    $free = Get-CDriveFreeBytes
    Write-Host "C: free $(Format-SizeGB $free), threshold $ThresholdGB GB"
    if (Test-LowDiskSpace $free $ThresholdGB) { Show-LowSpaceNotification $free $ThresholdGB }
}

function Enable-DailyCheck([double]$ThresholdGB) {
    Save-Settings $ThresholdGB
    $exe = Install-LocalCopy
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$exe`" -Check"
    Write-Host "> Register-ScheduledTask $script:TaskName (daily 09:00 + at logon): powershell.exe $arg"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $triggers = @((New-ScheduledTaskTrigger -Daily -At '09:00'), (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"))
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) `
        -Description 'wsl-space: warn when C: is low on free space' -Force | Out-Null
    Write-Host "Daily check enabled (threshold $ThresholdGB GB)."
}

function Disable-DailyCheck {
    Write-Host "> Unregister-ScheduledTask $script:TaskName"
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        Write-Host 'Daily check disabled.'
    } else { Write-Host 'Daily check was not enabled.' }
}

function Test-DailyCheckEnabled { [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------- self-test

function Invoke-SelfTest {
    $script:fails = 0
    function Assert($cond, [string]$name) {
        if ($cond) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name"; $script:fails++ }
    }
    function AssertThrows([scriptblock]$sb, [string]$name) {
        $threw = $false; try { & $sb | Out-Null } catch { $threw = $true }
        Assert $threw $name
    }

    # Size formatting
    Assert ((Format-SizeGB 0) -eq '0.0 GB') 'format 0 bytes'
    Assert ((Format-SizeGB 1GB) -eq '1.0 GB') 'format 1 GB'
    Assert ((Format-SizeGB 1610612736) -eq '1.5 GB') 'format 1.5 GB'
    Assert ((Format-SizeGB 69793218560) -eq '65.0 GB') 'format 65 GB'
    Assert ((Format-SizeGB 103079215104) -eq '96.0 GB') 'format 96 GB'
    Assert ((Format-SizeGB 1100000000) -eq '1.0 GB') 'format rounds to one decimal'

    # Reclaimable
    Assert ((Get-ReclaimableBytes 96GB 65GB) -eq 31GB) 'reclaimable 96-65'
    Assert ((Get-ReclaimableBytes 10GB 10GB) -eq 0) 'reclaimable equal'
    Assert ((Get-ReclaimableBytes 5GB 6GB) -eq 0) 'reclaimable clamped at 0'

    # df parsing
    Assert ((Parse-DfOutput "     Used`n68671483904`n") -eq 68671483904) 'df --output=used'
    Assert ((Parse-DfOutput "Used`r`n 123`r`n") -eq 123) 'df --output=used CRLF'
    $bb = "Filesystem           1B-blocks      Used Available Use% Mounted on`n/dev/sdd             1081101176832 5368709120 1020000000000   1% /"
    Assert ((Parse-DfOutput $bb) -eq 5368709120) 'df table (BusyBox)'
    $wrapped = "Filesystem 1B-blocks Used Available Use% Mounted on`n/dev/very/long/device/name`n 1000 400 600 40% /"
    Assert ((Parse-DfOutput $wrapped) -eq 400) 'df table with wrapped line'
    AssertThrows { Parse-DfOutput 'garbage' } 'df garbage throws'

    # du parsing (path with spaces)
    $du = "12`t/home/u/small`n9437184`t/home/u/My Project Data/raw captures`n52428800`t/home/u/project/data`n104857600`t/home/u`n"
    $p = @(Parse-DuOutput $du)
    Assert ($p.Count -eq 4) 'du 4 entries'
    Assert ($p[0].Path -eq '/home/u' -and $p[0].SizeBytes -eq 104857600L * 1024) 'du largest first'
    Assert ($p[2].Path -eq '/home/u/My Project Data/raw captures') 'du path with spaces'
    Assert ($p[2].Size -eq '9.0 GB') 'du size formatted'
    Assert (@(Parse-DuOutput '').Count -eq 0) 'du empty output'

    # diskpart script with spaces
    $v = 'C:\Users\someone\My VHDX Folder\ext4.vhdx'
    $dp = (New-DiskpartScriptContent $v) -split "`r`n"
    Assert ($dp[0] -eq 'select vdisk file="C:\Users\someone\My VHDX Folder\ext4.vhdx"') 'diskpart quoted path'
    Assert ($dp[1] -eq 'attach vdisk readonly' -and $dp[2] -eq 'compact vdisk' -and $dp[3] -eq 'detach vdisk') 'diskpart steps in order'
    $dd = (New-DiskpartDetachScriptContent $v) -split "`r`n"
    Assert ($dd[0] -eq $dp[0] -and $dd[1] -eq 'detach vdisk') 'diskpart detach script'

    # Settings round trip (temp folder; left in place, the tool never deletes files)
    $tmp = Join-Path $env:TEMP ('wsl-space-test-' + [guid]::NewGuid().ToString('N'))
    Assert ((Get-Settings $tmp).ThresholdGB -eq 15) 'settings default 15 when missing'
    Save-Settings 42.5 $tmp
    Assert ((Get-Settings $tmp).ThresholdGB -eq 42.5) 'settings round trip'
    Save-Settings 7 $tmp
    Assert ((Get-Settings $tmp).ThresholdGB -eq 7) 'settings overwrite'
    Save-Settings 0 $tmp @{ WindowWidth = 1200; WindowHeight = 800; WindowX = 10; WindowY = 20; SplitterDistance = 333; LastTab = 1 }
    $st = Get-Settings $tmp
    Assert ($st.ThresholdGB -eq 7 -and $st.WindowWidth -eq 1200 -and $st.WindowY -eq 20 -and $st.SplitterDistance -eq 333 -and $st.LastTab -eq 1) 'settings window state keeps threshold'

    # Docker Desktop data disk: found via LOCALAPPDATA, never the default, Trim/Big folders refuse it.
    $realLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = Join-Path $env:TEMP ('wsl-space-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk') | Out-Null
        Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx') -Value 'x'
        $dk = @(Get-WslDistros | Where-Object { $_.IsDocker })
        Assert ($dk.Count -eq 1 -and $dk[0].Name -eq $script:DockerDiskName) 'docker data disk listed'
        $hasDistro = @(Get-WslDistros | Where-Object { -not $_.IsDocker }).Count -gt 0
        if ($hasDistro) { Assert ((Resolve-DistroName '') -ne $script:DockerDiskName) 'docker disk never the default' }
        else { AssertThrows { Resolve-DistroName '' } 'docker disk alone is not a default' }
        Assert ((Resolve-DistroName $script:DockerDiskName) -eq $script:DockerDiskName) 'docker disk resolvable by name'
        AssertThrows { Invoke-Trim $script:DockerDiskName } 'trim refuses docker disk'
        AssertThrows { Get-BigFoldersData $script:DockerDiskName } 'big folders refuses docker disk'
        AssertThrows { Invoke-Move $script:DockerDiskName 'D:\x' } 'move refuses docker disk'
    } finally { $env:LOCALAPPDATA = $realLocal }

    # Compact result wording: the disk's own change, never the C: change, is the gain.
    $cr = Format-CompactResult 20GB 12GB 10GB 25GB
    Assert ($cr -like 'Disk shrank by 8.0 GB.*' -and $cr -like '*changed by 15.0 GB*') 'compact result: shrank'
    $cr = Format-CompactResult 17GB 17GB 31GB 38GB
    Assert ($cr -like 'The disk did not shrink*' -and $cr -notlike '*shrank by*') 'compact result: no shrink despite C: gain'

    # Move refuses before stopping anything.
    AssertThrows { Invoke-Move 'wsl-space-no-such-distro' $env:TEMP } 'move refuses unknown distro'
    $mv = @(Get-WslDistros | Where-Object { -not $_.IsDocker })
    if ($mv) {
        $d0 = $mv[0]
        AssertThrows { Invoke-Move $d0.Name (Split-Path -Parent $d0.VhdxPath) } 'move refuses current folder'
        AssertThrows { Invoke-Move $d0.Name '' } 'move refuses empty target'
        $r0 = [System.IO.Path]::GetPathRoot($d0.VhdxPath)
        AssertThrows { Invoke-Move $d0.Name $r0 } 'move refuses drive root'
        AssertThrows { Invoke-Move $d0.Name (Join-Path $r0 'wsl-space-test-same-drive') } 'move refuses same drive'
        Assert (-not (Test-Path -LiteralPath (Join-Path $r0 'wsl-space-test-same-drive'))) 'refused move creates no folder'
        $busy = Join-Path $env:TEMP ('wsl-space-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $busy | Out-Null
        Set-Content -LiteralPath (Join-Path $busy 'ext4.vhdx') -Value 'x'
        AssertThrows { Invoke-Move $d0.Name $busy } 'move refuses folder that has ext4.vhdx'
    }
    Save-Settings 9 $tmp
    $st = Get-Settings $tmp
    Assert ($st.ThresholdGB -eq 9 -and $st.WindowWidth -eq 1200 -and $st.LastTab -eq 1) 'settings threshold keeps window state'
    Assert ($null -eq (Get-Settings (Join-Path $tmp 'none')).WindowX) 'settings window position unset by default'

    # Threshold check
    Assert (Test-LowDiskSpace 10GB 15) 'below threshold warns'
    Assert (-not (Test-LowDiskSpace 20GB 15)) 'above threshold quiet'
    Assert (-not (Test-LowDiskSpace 15GB 15)) 'exactly at threshold quiet'

    # Path helpers
    Assert ((ConvertTo-WslExplorerPath 'Ubuntu-24.04' '/home/u/My Data') -eq '\\wsl.localhost\Ubuntu-24.04\home\u\My Data') 'explorer path'
    Assert ((ConvertTo-ShPath '~') -eq '"$HOME"') 'sh path ~'
    Assert ((ConvertTo-ShPath "~/it's here") -eq ('"$HOME"/' + "'it'\''s here'")) 'sh path ~/ with quote'

    # Theme palette
    $tokens = 'Background', 'Surface', 'Border', 'Text', 'MutedText', 'Accent', 'AccentText', 'Success', 'Warning', 'Error'
    $pd = Get-ThemePalette $true; $pl = Get-ThemePalette $false
    Assert ($pd.IsDark -and -not $pl.IsDark) 'palette IsDark flag'
    Assert (@($tokens | Where-Object { $pd[$_] -notmatch '^#[0-9A-F]{6}$' -or $pl[$_] -notmatch '^#[0-9A-F]{6}$' }).Count -eq 0) 'palette has every token'
    Assert ($pd.Background -eq '#0F172A' -and $pd.Surface -eq '#1B2336' -and $pd.Accent -eq '#22C55E' -and $pd.Error -eq '#F87171') 'palette dark values'
    Assert ($pl.Background -eq '#F8FAFC' -and $pl.Text -eq '#0F172A' -and $pl.Accent -eq '#15803D' -and $pl.Warning -eq '#B45309') 'palette light values'
    Assert ((Test-WindowsDarkTheme) -is [bool]) 'windows theme detection returns bool'

    # Disk health chip
    $h = Get-DiskHealth 40GB 15
    Assert ($h.Status -eq 'Healthy' -and $h.ChipText -eq "$script:SymCheck Healthy") 'health healthy'
    $h = Get-DiskHealth 10GB 15
    Assert ($h.Status -eq 'Low' -and $h.ChipText -eq '! Low (below 15 GB)') 'health low'
    Assert ((Get-DiskHealth 10GB 15.5).ChipText -eq '! Low (below 15.5 GB)') 'health low decimal threshold'
    $h = Get-DiskHealth 3GB 15
    Assert ($h.Status -eq 'Critical' -and $h.ChipText -eq "$script:SymCross Critical (below 5 GB)") 'health critical'
    Assert ((Get-DiskHealth 15GB 15).Status -eq 'Healthy') 'health exactly at threshold'

    # Log entries
    $le = ConvertTo-LogEntry '=== Refresh ==='
    Assert ($le.Kind -eq 'section' -and $le.Text -eq 'Refresh') 'log section'
    $le = ConvertTo-LogEntry '> wsl.exe --status'
    Assert ($le.Kind -eq 'command' -and $le.Text -eq 'wsl.exe --status') 'log command'
    $le = ConvertTo-LogEntry '  output text'
    Assert ($le.Kind -eq 'output' -and $le.Text -eq 'output text') 'log indented output'
    $le = ConvertTo-LogEntry 'ERROR: disk full'
    Assert ($le.Kind -eq 'error' -and $le.Text -eq 'disk full') 'log error'
    $le = ConvertTo-LogEntry 'WARNING: could not turn sparse back on'
    Assert ($le.Kind -eq 'warning' -and $le.Text -eq 'could not turn sparse back on') 'log warning'
    $le = ConvertTo-LogEntry 'C: free before: 1.0 GB'
    Assert ($le.Kind -eq 'output' -and $le.Text -eq 'C: free before: 1.0 GB') 'log plain line is output'

    $ents = @('section', 'command', 'output', 'success', 'warning', 'error') | ForEach-Object { [pscustomobject]@{ Kind = $_; Text = "t-$_" } }
    Assert (@(Select-LogEntries $ents 'All').Count -eq 6) 'log filter all'
    $sel = @(Select-LogEntries $ents 'Commands & output')
    Assert ($sel.Count -eq 2 -and $sel[0].Kind -eq 'command' -and $sel[1].Kind -eq 'output') 'log filter commands & output'
    $sel = @(Select-LogEntries $ents 'Errors only')
    Assert ($sel.Count -eq 1 -and $sel[0].Kind -eq 'error') 'log filter errors only'
    Assert (@(Select-LogEntries @() 'All').Count -eq 0) 'log filter empty'

    $tm = [datetime]::new(2026, 1, 2, 3, 4, 5)
    $fmt = @{}; foreach ($e in $ents) { $fmt[$e.Kind] = Format-LogEntry $e $tm }
    Assert ($fmt.section -eq "03:04:05  $script:SymPlay  t-section") 'log format section'
    Assert ($fmt.command -eq '03:04:05  >  t-command') 'log format command'
    Assert ($fmt.output -eq '03:04:05       t-output') 'log format output indented'
    Assert ($fmt.success -eq "03:04:05  $script:SymCheck  t-success") 'log format success'
    Assert ($fmt.warning -eq '03:04:05  !  t-warning') 'log format warning'
    Assert ($fmt.error -eq "03:04:05  $script:SymCross  t-error") 'log format error'

    # Window build: each palette, never shown, no jobs, no dialogs.
    $names = 'FreeSpaceLabel', 'UsageBar', 'HealthChip', 'MainSplit', 'MainTabs', 'DistrosTab', 'BigFoldersTab',
        'DistrosGrid', 'GridStateLabel', 'TrimHintBox', 'BigDistroCombo', 'BigPathBox', 'BigDepthNum', 'BigTopNum', 'BtnScanBig',
        'BigFoldersGrid', 'BtnOpenExplorer', 'BtnCopyPath', 'BtnRefresh', 'BtnTrim', 'BtnCompact', 'BtnMove', 'ChkDailyWarn', 'ThresholdNum',
        'ActivityLog', 'LogFilterCombo', 'BtnCopyLog', 'BtnSaveLog', 'BtnClearLog',
        'StatusBar', 'StatusLabel', 'StatusProgress', 'ElapsedLabel', 'BtnCancel'
    foreach ($dark in $true, $false) {
        $tn = if ($dark) { 'dark' } else { 'light' }
        $f = $null
        try {
            $f = New-MainWindow -Palette (Get-ThemePalette $dark) -SettingsDir $tmp
            Assert ($f -is [System.Windows.Forms.Form]) "window builds ($tn)"
            Assert (-not $f.Visible) "window not shown ($tn)"
            Assert ($f.MinimumSize.Width -eq 900 -and $f.MinimumSize.Height -eq 600) "window minimum size 900x600 ($tn)"
            $find = { param($n) @($f.Controls.Find($n, $true))[0] }
            $missing = @($names | Where-Object { $c = & $find $_; -not $c -or -not $c.AccessibleName })
            Assert ($missing.Count -eq 0) "window named controls with AccessibleName ($tn)$(if ($missing) { ': ' + ($missing -join ', ') })"
            Assert ((& $find 'MainTabs').TabPages.Count -eq 2 -and (& $find 'MainTabs').SelectedIndex -eq 1) "window tabs, last tab restored ($tn)"
            Assert (@((& $find 'LogFilterCombo').Items) -join '|' -eq 'All|Commands & output|Errors only') "window log filter items ($tn)"
            Assert ((& $find 'ActivityLog') -is [System.Windows.Forms.RichTextBox] -and (& $find 'ActivityLog').ReadOnly) "window log read-only rich text ($tn)"
            Assert (-not (& $find 'BtnCancel').Enabled -and -not (& $find 'BtnTrim').Enabled) "window idle and empty: cancel and trim disabled ($tn)"
            Assert ((& $find 'BtnRefresh').BackColor -eq [System.Drawing.ColorTranslator]::FromHtml((Get-ThemePalette $dark).Accent)) "window primary button uses accent ($tn)"
            Assert ((& $find 'BtnCompact').ForeColor -eq [System.Drawing.ColorTranslator]::FromHtml((Get-ThemePalette $dark).Error)) "window compact button danger style ($tn)"
            Assert ((& $find 'ThresholdNum').Value -eq 9) "window threshold from settings ($tn)"
            # Dark-theme fixes: native controls that ignore BackColor are replaced by palette-painted subclasses.
            $types = [ordered]@{ MainTabs = 'ThemedTabControl'; BigDistroCombo = 'ThemedComboBox'; LogFilterCombo = 'ThemedComboBox'
                BigDepthNum = 'ThemedNumericUpDown'; BigTopNum = 'ThemedNumericUpDown'; ThresholdNum = 'ThemedNumericUpDown'
                BtnRefresh = 'ThemedButton'; BtnTrim = 'ThemedButton'; BtnCompact = 'ThemedButton'; BtnMove = 'ThemedButton'; BtnCancel = 'ThemedButton'
                ChkDailyWarn = 'ThemedCheckBox'; StatusProgress = 'ThemedProgressBar' }
            $wrong = @($types.Keys | Where-Object { $c = & $find $_; -not ($c -is [type]"WslSpace.$($types[$_])") -or $null -eq $c.Theme -or $c.Theme.Dark -ne $dark })
            Assert ($wrong.Count -eq 0) "window themed controls ($tn)$(if ($wrong) { ': ' + ($wrong -join ', ') })"
            $grids = @('DistrosGrid', 'BigFoldersGrid' | ForEach-Object { & $find $_ })
            Assert (@($grids | Where-Object { $_.ColumnHeadersBorderStyle -ne 'None' -or $_.EnableHeadersVisualStyles }).Count -eq 0) "window grids flat headers ($tn)"
            Assert ((& $find 'DistrosGrid').DefaultCellStyle.SelectionBackColor -ne [System.Drawing.ColorTranslator]::FromHtml((Get-ThemePalette $dark).Accent)) "window grid selection is not full accent ($tn)"
            Assert ((& $find 'HealthChip').BorderStyle -eq 'None' -and (& $find 'BigPathBox').BorderStyle -eq 'FixedSingle') "window chip and path box borders ($tn)"
        } catch { Assert $false "window build ($tn): $_" } finally { if ($f -is [System.Windows.Forms.Form]) { $f.Dispose() } }
    }

    if ($script:fails) { Write-Host "$($script:fails) self-test(s) FAILED"; return $false }
    Write-Host 'All self-tests passed.'
    $true
}

# ---------------------------------------------------------------- GUI

function Initialize-WinForms {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    # With visual styles on, several native controls ignore BackColor (white tab strip, combo face,
    # spinners, 3D borders, progress trough, scrollbars). These subclasses paint themselves from a
    # shared Theme so both palettes look right; each still derives from its WinForms class.
    if (-not ('WslSpace.Ui' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace WslSpace {
public class Theme {
    public bool Dark;
    public Color Background, Surface, Border, Text, Muted, Accent, AccentText, Select, DisabledBg, DisabledBorder;
}

public static class Ui {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, ref POINT lParam);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    // Dark scrollbars on the control and its children (DataGridView scrollbars are child controls).
    public static void ApplyDarkTheme(Control c, bool dark) {
        if (!dark) return;
        EventHandler h = delegate { try { SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { } };
        c.HandleCreated += h;
        if (c.IsHandleCreated) h(c, EventArgs.Empty);
        foreach (Control ch in c.Controls) ApplyDarkTheme(ch, dark);
    }

    // A 1 px line along the top or bottom edge of a panel.
    public static void AddEdgeLine(Control c, Theme t, bool top) {
        c.Paint += delegate(object s, PaintEventArgs e) {
            using (Pen p = new Pen(t.Border)) { int y = top ? 0 : c.Height - 1; e.Graphics.DrawLine(p, 0, y, c.Width, y); }
        };
        c.Resize += delegate { c.Invalidate(); };
    }

    // A 1 px outline in the control's ForeColor (FixedSingle is always black).
    public static void AddOutline(Control c) {
        c.Paint += delegate(object s, PaintEventArgs e) {
            using (Pen p = new Pen(c.ForeColor)) e.Graphics.DrawRectangle(p, 0, 0, c.Width - 1, c.Height - 1);
        };
    }

    // Repaints the non-client FixedSingle border of a TextBox / NumericUpDown in the palette.
    public static BorderPainter AttachBorder(Control c, Theme t) { return new BorderPainter(c, t); }

    public static void ThemeSplitter(SplitContainer sc, Theme t) {
        sc.Paint += delegate(object s, PaintEventArgs e) {
            Rectangle r = sc.SplitterRectangle;
            int y = r.Y + r.Height / 2, cx = r.X + r.Width / 2;
            using (Pen p = new Pen(t.Border)) e.Graphics.DrawLine(p, r.X, y, r.Right, y);
            using (Pen p = new Pen(t.Muted, 2)) e.Graphics.DrawLine(p, cx - 16, y, cx + 16, y);
        };
    }

    public static TextFormatFlags AlignFlags(DataGridViewContentAlignment a) {
        string n = a.ToString();
        if (n.EndsWith("Right")) return TextFormatFlags.Right;
        if (n.EndsWith("Center")) return TextFormatFlags.HorizontalCenter;
        return TextFormatFlags.Left;
    }

    // Flat headers (no white 3D lines), an accent bar on the selected row, proportional size bars
    // (cell Tag = ratio 0..1 in a column named SizeBar) and a 1 px frame.
    public static void ThemeGrid(DataGridView g, Theme t) {
        g.CellPainting += delegate(object s, DataGridViewCellPaintingEventArgs e) {
            if (e.ColumnIndex < 0) return;
            Rectangle b = e.CellBounds;
            if (e.RowIndex < 0) {
                using (SolidBrush br = new SolidBrush(t.Background)) e.Graphics.FillRectangle(br, b);
                using (Pen p = new Pen(t.Border)) e.Graphics.DrawLine(p, b.Left, b.Bottom - 1, b.Right, b.Bottom - 1);
                TextRenderer.DrawText(e.Graphics, Convert.ToString(e.Value), e.CellStyle.Font ?? g.Font,
                    new Rectangle(b.X + 8, b.Y, Math.Max(0, b.Width - 16), b.Height - 1), t.Muted,
                    AlignFlags(e.CellStyle.Alignment) | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                e.Handled = true;
                return;
            }
            bool sel = (e.State & DataGridViewElementStates.Selected) != 0;
            if (g.Columns[e.ColumnIndex].Name == "SizeBar") {
                e.Paint(b, DataGridViewPaintParts.Background | DataGridViewPaintParts.Border | DataGridViewPaintParts.SelectionBackground);
                object tag = g.Rows[e.RowIndex].Cells[e.ColumnIndex].Tag;
                double ratio = tag == null ? 0 : Math.Max(0, Math.Min(1, Convert.ToDouble(tag)));
                Rectangle tr = new Rectangle(b.X + 8, b.Y + (b.Height - 10) / 2, Math.Max(0, b.Width - 16), 10);
                using (SolidBrush br = new SolidBrush(t.Background)) e.Graphics.FillRectangle(br, tr);
                using (SolidBrush br = new SolidBrush(t.Accent)) e.Graphics.FillRectangle(br, tr.X, tr.Y, Math.Max(2, (int)(tr.Width * ratio)), tr.Height);
            } else e.Paint(b, DataGridViewPaintParts.All & ~DataGridViewPaintParts.Focus);
            if (sel && e.ColumnIndex == 0)
                using (SolidBrush br = new SolidBrush(t.Accent)) e.Graphics.FillRectangle(br, b.X, b.Y, 3, b.Height - 1);
            e.Handled = true;
        };
        g.Paint += delegate(object s, PaintEventArgs e) {
            using (Pen p = new Pen(t.Border)) e.Graphics.DrawRectangle(p, 0, 0, g.Width - 1, g.Height - 1);
        };
    }
}

public class BorderPainter : NativeWindow {
    readonly Control c; readonly Theme t;
    public BorderPainter(Control ctl, Theme theme) {
        c = ctl; t = theme;
        if (c.IsHandleCreated) AssignHandle(c.Handle);
        c.HandleCreated += delegate { AssignHandle(c.Handle); };
        c.HandleDestroyed += delegate { ReleaseHandle(); };
        c.Enter += delegate { Draw(); };
        c.Leave += delegate { Draw(); };
    }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg == 0x0085) Draw();  // WM_NCPAINT
    }
    void Draw() {
        if (Handle == IntPtr.Zero) return;
        IntPtr dc = Ui.GetWindowDC(Handle);
        if (dc == IntPtr.Zero) return;
        try {
            using (Graphics g = Graphics.FromHdc(dc))
            using (Pen p = new Pen(c.ContainsFocus ? t.Accent : t.Border)) g.DrawRectangle(p, 0, 0, c.Width - 1, c.Height - 1);
        } finally { Ui.ReleaseDC(Handle, dc); }
    }
}

// Underline-style tabs: flat strip, bold selected caption with an accent bar, no native 3D frame.
public class ThemedTabControl : TabControl {
    public Theme Theme;
    public ThemedTabControl() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SizeMode = TabSizeMode.Fixed;
        ItemSize = new Size(130, 32);
    }
    int StripHeight { get { return ItemSize.Height + 3; } }
    public override Rectangle DisplayRectangle {
        get { return new Rectangle(0, StripHeight + 1, Math.Max(0, Width), Math.Max(0, Height - StripHeight - 1)); }
    }
    protected override void OnSelectedIndexChanged(EventArgs e) { base.OnSelectedIndexChanged(e); Invalidate(); }
    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
        if (Theme == null) { base.OnPaint(e); return; }
        Graphics g = e.Graphics;
        g.Clear(Theme.Background);
        using (Pen p = new Pen(Theme.Border)) g.DrawLine(p, 0, StripHeight, Width, StripHeight);
        using (Font bold = new Font(Font, FontStyle.Bold)) {
            for (int i = 0; i < TabCount; i++) {
                Rectangle r = GetTabRect(i);
                r = new Rectangle(r.X, 0, r.Width, StripHeight);
                bool sel = i == SelectedIndex;
                TextFormatFlags f = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;
                if (!ShowKeyboardCues) f |= TextFormatFlags.HidePrefix;
                TextRenderer.DrawText(g, TabPages[i].Text, sel ? bold : Font, r, sel ? Theme.Text : Theme.Muted, f);
                if (sel) {
                    using (SolidBrush br = new SolidBrush(Theme.Accent)) g.FillRectangle(br, r.X + 8, StripHeight - 2, r.Width - 16, 3);
                    if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(r, -6, -6), Theme.Text, Theme.Background);
                }
            }
        }
    }
}

public class ThemedComboBox : ComboBox {
    public Theme Theme;
    public ThemedComboBox() {
        DrawMode = DrawMode.OwnerDrawFixed;
        DropDownStyle = ComboBoxStyle.DropDownList;
        FlatStyle = FlatStyle.Flat;
        ItemHeight = 20;
    }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (Theme == null) return;
        if (m.Msg == 0x000F) using (Graphics g = Graphics.FromHwnd(Handle)) PaintFace(g);  // WM_PAINT: overpaint the native face
        else if ((m.Msg == 0x0317 || m.Msg == 0x0318) && m.WParam != IntPtr.Zero)        // WM_PRINT / WM_PRINTCLIENT
            using (Graphics g = Graphics.FromHdc(m.WParam)) PaintFace(g);
    }
    void PaintFace(Graphics g) {
        {
            Rectangle r = ClientRectangle;
            Color fg = Enabled ? Theme.Text : Theme.Muted;
            using (SolidBrush b = new SolidBrush(Enabled ? Theme.Surface : Theme.DisabledBg)) g.FillRectangle(b, r);
            using (Pen p = new Pen(Focused || DroppedDown ? Theme.Accent : Theme.Border)) g.DrawRectangle(p, 0, 0, r.Width - 1, r.Height - 1);
            TextRenderer.DrawText(g, Text, Font, new Rectangle(6, 0, Math.Max(0, r.Width - 30), r.Height), fg,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            int cx = r.Width - 13, cy = r.Height / 2;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen p = new Pen(fg, 1.6f)) g.DrawLines(p, new Point[] { new Point(cx - 4, cy - 2), new Point(cx, cy + 2), new Point(cx + 4, cy - 2) });
        }
    }
    protected override void OnDrawItem(DrawItemEventArgs e) {
        if (e.Index < 0 || Theme == null) { base.OnDrawItem(e); return; }
        bool sel = (e.State & DrawItemState.ComboBoxEdit) == 0 && (e.State & DrawItemState.Selected) != 0;
        using (SolidBrush b = new SolidBrush(sel ? Theme.Select : Theme.Surface)) e.Graphics.FillRectangle(b, e.Bounds);
        TextRenderer.DrawText(e.Graphics, GetItemText(Items[e.Index]), Font, new Rectangle(e.Bounds.X + 4, e.Bounds.Y, e.Bounds.Width - 4, e.Bounds.Height),
            Theme.Text, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
    protected override void OnSelectedIndexChanged(EventArgs e) { base.OnSelectedIndexChanged(e); Invalidate(); }
    protected override void OnDropDownClosed(EventArgs e) { base.OnDropDownClosed(e); Invalidate(); }
}

// Flat spinner buttons; pair with Ui.AttachBorder for the outer border.
public class ThemedNumericUpDown : NumericUpDown {
    public Theme Theme;
    public ThemedNumericUpDown() {
        BorderStyle = BorderStyle.FixedSingle;
        foreach (Control c in Controls) if (!(c is TextBox)) c.Paint += PaintButtons;
    }
    void PaintButtons(object sender, PaintEventArgs e) {
        if (Theme == null) return;
        Control b = (Control)sender;
        Graphics g = e.Graphics;
        int w = b.ClientSize.Width, h = b.ClientSize.Height, cx = w / 2, q = h / 4;
        using (SolidBrush br = new SolidBrush(BackColor)) g.FillRectangle(br, 0, 0, w, h);
        using (Pen p = new Pen(Theme.Border)) g.DrawLine(p, 0, 0, 0, h);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (SolidBrush br = new SolidBrush(Enabled ? Theme.Text : Theme.Muted)) {
            g.FillPolygon(br, new Point[] { new Point(cx - 4, q + 2), new Point(cx + 4, q + 2), new Point(cx, q - 2) });
            g.FillPolygon(br, new Point[] { new Point(cx - 4, 3 * q - 2), new Point(cx + 4, 3 * q - 2), new Point(cx, 3 * q + 2) });
        }
    }
}

// Flat button whose disabled state stays legible (no embossed Win32 text).
public class ThemedButton : Button {
    public Theme Theme;
    protected override void OnPaint(PaintEventArgs e) {
        if (Enabled || Theme == null) { base.OnPaint(e); return; }
        Graphics g = e.Graphics;
        using (SolidBrush b = new SolidBrush(Theme.DisabledBg)) g.FillRectangle(b, ClientRectangle);
        using (Pen p = new Pen(Theme.DisabledBorder)) g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, Theme.Muted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.HidePrefix);
    }
}

public class ThemedCheckBox : CheckBox {
    public Theme Theme;
    const int Box = 16, Gap = 6;
    public ThemedCheckBox() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
    public override Size GetPreferredSize(Size proposed) {
        Size s = TextRenderer.MeasureText(Text, Font);
        return new Size(Box + Gap + s.Width + 2, Math.Max(Box + 4, s.Height + 4));
    }
    protected override void OnPaint(PaintEventArgs e) {
        if (Theme == null) { base.OnPaint(e); return; }
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        int y = (Height - Box) / 2;
        Rectangle box = new Rectangle(0, y, Box - 1, Box - 1);
        if (Checked) {
            using (SolidBrush b = new SolidBrush(Enabled ? Theme.Accent : Theme.Border)) g.FillRectangle(b, box);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen p = new Pen(Theme.AccentText, 2f))
                g.DrawLines(p, new Point[] { new Point(3, y + 8), new Point(6, y + 11), new Point(12, y + 4) });
            g.SmoothingMode = SmoothingMode.Default;
        } else {
            using (SolidBrush b = new SolidBrush(Enabled ? Theme.Surface : Theme.DisabledBg)) g.FillRectangle(b, box);
            using (Pen p = new Pen(Focused ? Theme.Accent : Theme.Border)) g.DrawRectangle(p, box);
        }
        TextFormatFlags f = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;
        if (!ShowKeyboardCues) f |= TextFormatFlags.HidePrefix;
        Rectangle tr = new Rectangle(Box + Gap, 0, Math.Max(0, Width - Box - Gap), Height);
        TextRenderer.DrawText(g, Text, Font, tr, Enabled ? Theme.Text : Theme.Muted, f);
        if (Focused && ShowFocusCues) {
            Size ts = TextRenderer.MeasureText(Text, Font);
            ControlPaint.DrawFocusRectangle(g, new Rectangle(Box + Gap - 2, (Height - ts.Height) / 2, Math.Min(ts.Width + 2, tr.Width + 2), ts.Height), Theme.Text, BackColor);
        }
    }
}

// Marquee bar painted from the palette (the native one is a white Aero trough in dark mode).
public class ThemedProgressBar : ProgressBar {
    public Theme Theme;
    int offset;
    readonly System.Windows.Forms.Timer anim = new System.Windows.Forms.Timer();
    public ThemedProgressBar() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        anim.Interval = 30;
        anim.Tick += delegate { offset = (offset + 4) % (Width + Width * 35 / 100 + 1); Invalidate(); };
    }
    protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); offset = 0; anim.Enabled = Visible; }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        Color track = Theme == null ? SystemColors.Control : Theme.Background;
        Color fill = Theme == null ? SystemColors.Highlight : Theme.Accent;
        Color border = Theme == null ? SystemColors.ControlDark : Theme.Border;
        g.Clear(track);
        int w = Width * 35 / 100;
        using (SolidBrush b = new SolidBrush(fill)) g.FillRectangle(b, offset - w, 1, w, Height - 2);
        using (Pen p = new Pen(border)) g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
    }
    protected override void Dispose(bool disposing) { if (disposing) anim.Dispose(); base.Dispose(disposing); }
}
}
'@
    }
}

# Builds the main window and returns it WITHOUT showing it (the self-test builds it this way).
# Show-MainWindow dot-sources this function so the event handlers, which run during ShowDialog,
# still see its local variables (PowerShell resolves them through the caller's scope).
function New-MainWindow([hashtable]$Palette, [string]$SettingsDir = (Get-SettingsDir), [switch]$AutoStart) {
    Initialize-WinForms
    if (-not $Palette) { $Palette = Get-ThemePalette (Test-WindowsDarkTheme) }
    $Col = @{}
    foreach ($k in @($Palette.Keys)) { if ($Palette[$k] -is [string]) { $Col[$k] = [System.Drawing.ColorTranslator]::FromHtml($Palette[$k]) } }
    # Interaction shades derived from the palette (row tints, hover/press, disabled).
    $derived = if ($Palette.IsDark) {
        @{ RowAlt = '#161E30'; RowSelect = '#24344D'; HoverSurface = '#26314A'; PressSurface = '#2E3B57'; HoverAccent = '#16A34A'; HoverDanger = '#2D1B24'; DisabledBg = '#151D2E'; DisabledBorder = '#334155' }
    } else {
        @{ RowAlt = '#F8FAFC'; RowSelect = '#DCFCE7'; HoverSurface = '#F1F5F9'; PressSurface = '#E2E8F0'; HoverAccent = '#166534'; HoverDanger = '#FEF2F2'; DisabledBg = '#F1F5F9'; DisabledBorder = '#E2E8F0' }
    }
    foreach ($k in $derived.Keys) { $Col[$k] = [System.Drawing.ColorTranslator]::FromHtml($derived[$k]) }
    $theme = New-Object WslSpace.Theme
    $theme.Dark = [bool]$Palette.IsDark; $theme.Background = $Col.Background; $theme.Surface = $Col.Surface; $theme.Border = $Col.Border
    $theme.Text = $Col.Text; $theme.Muted = $Col.MutedText; $theme.Accent = $Col.Accent; $theme.AccentText = $Col.AccentText
    $theme.Select = $Col.RowSelect; $theme.DisabledBg = $Col.DisabledBg; $theme.DisabledBorder = $Col.DisabledBorder
    $settings = Get-Settings $SettingsDir
    $Ell = $script:Ell
    $uiFont = New-Object System.Drawing.Font('Segoe UI', 10)
    $boldFont = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $mono = New-Object System.Drawing.Font('Cascadia Mono', 10)
    if ($mono.Name -ne 'Cascadia Mono') { $mono = New-Object System.Drawing.Font('Consolas', 10) }
    $monoBold = New-Object System.Drawing.Font($mono, [System.Drawing.FontStyle]::Bold)
    $tip = New-Object System.Windows.Forms.ToolTip

    $themed = 'TabControl', 'ComboBox', 'NumericUpDown', 'Button', 'CheckBox', 'ProgressBar'
    function New-Ctl([string]$Type, [string]$Name, [string]$Access) {
        $ctl = if ($Type -in $themed) { New-Object "WslSpace.Themed$Type"; } else { New-Object "System.Windows.Forms.$Type" }
        if ($Type -in $themed) { $ctl.Theme = $theme }
        $ctl.Name = $Name; $ctl.AccessibleName = $Access
        $ctl
    }
    function New-Btn([string]$Name, [string]$Text, [string]$Access, [string]$Kind, [string]$TipText) {
        $b = New-Ctl 'Button' $Name $Access
        $b.Text = $Text; $b.AutoSize = $true; $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false
        $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0); $b.Margin = New-Object System.Windows.Forms.Padding(3, 3, 5, 3)
        $b.FlatAppearance.BorderSize = 1
        $fa = $b.FlatAppearance
        switch ($Kind) {
            'primary' { $b.BackColor = $Col.Accent; $b.ForeColor = $Col.AccentText; $fa.BorderColor = $Col.Accent; $fa.MouseOverBackColor = $Col.HoverAccent; $fa.MouseDownBackColor = $Col.HoverAccent }
            'danger' { $b.BackColor = $Col.Surface; $b.ForeColor = $Col.Error; $fa.BorderColor = $Col.Error; $fa.MouseOverBackColor = $Col.HoverDanger; $fa.MouseDownBackColor = $Col.HoverDanger }
            default { $b.BackColor = $Col.Surface; $b.ForeColor = $Col.Text; $fa.BorderColor = $Col.Border; $fa.MouseOverBackColor = $Col.HoverSurface; $fa.MouseDownBackColor = $Col.PressSurface }
        }
        if ($TipText) { $tip.SetToolTip($b, $TipText) }
        $b
    }
    function New-Lbl([string]$Name, [string]$Text) {
        $l = New-Ctl 'Label' $Name $Text
        $l.Text = $Text; $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(8, 8, 3, 0)
        $l
    }
    function New-Flow([string]$Name, [string]$Access, [string]$Dock) {
        $fl = New-Ctl 'FlowLayoutPanel' $Name $Access
        $fl.AutoSize = $true; $fl.AutoSizeMode = 'GrowAndShrink'; $fl.Dock = $Dock
        $fl.Padding = New-Object System.Windows.Forms.Padding(4)
        $fl
    }
    function Set-InputStyle($ctl) {
        $ctl.BackColor = $Col.Surface; $ctl.ForeColor = $Col.Text; $ctl.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 0)
        if ($ctl -is [System.Windows.Forms.TextBox] -or $ctl -is [System.Windows.Forms.NumericUpDown]) {
            $ctl.BorderStyle = 'FixedSingle'; [void][WslSpace.Ui]::AttachBorder($ctl, $theme)
        }
    }
    function Set-GridStyle($g) {
        $g.Dock = 'Fill'; $g.ReadOnly = $true; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false
        $g.AllowUserToResizeRows = $false; $g.SelectionMode = 'FullRowSelect'; $g.MultiSelect = $false
        $g.RowHeadersVisible = $false; $g.AutoSizeColumnsMode = 'Fill'; $g.BorderStyle = 'None'
        $g.EnableHeadersVisualStyles = $false; $g.BackgroundColor = $Col.Surface; $g.GridColor = $Col.Border
        $g.CellBorderStyle = 'SingleHorizontal'; $g.ColumnHeadersBorderStyle = 'None'
        $g.ColumnHeadersHeightSizeMode = 'DisableResizing'; $g.ColumnHeadersHeight = 34; $g.RowTemplate.Height = 30
        $pad = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
        $hs = $g.ColumnHeadersDefaultCellStyle
        $hs.BackColor = $Col.Background; $hs.ForeColor = $Col.MutedText; $hs.SelectionBackColor = $Col.Background; $hs.SelectionForeColor = $Col.MutedText; $hs.Font = $boldFont; $hs.Padding = $pad
        $cs = $g.DefaultCellStyle
        $cs.BackColor = $Col.Surface; $cs.ForeColor = $Col.Text; $cs.SelectionBackColor = $Col.RowSelect; $cs.SelectionForeColor = $Col.Text; $cs.Padding = $pad
        $g.AlternatingRowsDefaultCellStyle.BackColor = $Col.RowAlt
        [WslSpace.Ui]::ThemeGrid($g, $theme)
        [WslSpace.Ui]::ApplyDarkTheme($g, $theme.Dark)
    }
    function Add-GridColumn($g, [string]$Name, [string]$Header, [int]$Weight, [string]$Align = 'MiddleLeft') {
        $col = $g.Columns[$g.Columns.Add($Name, $Header)]
        $col.FillWeight = $Weight; $col.SortMode = 'NotSortable'
        $col.DefaultCellStyle.Alignment = $Align; $col.HeaderCell.Style.Alignment = $Align
    }

    # ---- form + root layout
    $form = New-Ctl 'Form' 'MainWindow' 'wsl-space'
    $form.Text = 'wsl-space'; $form.Font = $uiFont; $form.KeyPreview = $true
    $form.BackColor = $Col.Background; $form.ForeColor = $Col.Text
    $form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $form.Size = New-Object System.Drawing.Size([Math]::Max(900, $settings.WindowWidth), [Math]::Max(600, $settings.WindowHeight))
    $form.StartPosition = 'CenterScreen'
    if ($null -ne $settings.WindowX -and $null -ne $settings.WindowY) {
        $rect = New-Object System.Drawing.Rectangle($settings.WindowX, $settings.WindowY, $form.Width, $form.Height)
        if (@([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($rect) }).Count) {
            $form.StartPosition = 'Manual'; $form.Location = $rect.Location
        }
    }

    $root = New-Ctl 'TableLayoutPanel' 'RootLayout' 'Main layout'
    $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 3
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    foreach ($rs in @(@('AutoSize', 0), @('Percent', 100), @('AutoSize', 0))) {
        [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($rs[0], $rs[1])))
    }
    $form.Controls.Add($root)

    # ---- 1. header: free space, usage bar, health chip
    $header = New-Flow 'HeaderPanel' 'C: drive summary' 'Fill'
    $header.WrapContents = $false; $header.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 8)
    [WslSpace.Ui]::AddEdgeLine($header, $theme, $false)
    $freeLbl = New-Ctl 'Label' 'FreeSpaceLabel' 'C: drive free space'
    $freeLbl.AutoSize = $true; $freeLbl.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 22); $freeLbl.Text = "C: $Ell free"
    $usage = New-Ctl 'Panel' 'UsageBar' 'C: drive usage bar'
    $usage.Size = New-Object System.Drawing.Size(220, 16); $usage.Margin = New-Object System.Windows.Forms.Padding(16, 18, 16, 0)
    $usage.Tag = @{ Ratio = 0.0; Color = $Col.Accent }
    $usage.add_Paint({
        param($s, $e)
        $w = $s.ClientSize.Width; $hh = $s.ClientSize.Height
        $br = New-Object System.Drawing.SolidBrush($Col.Surface); $e.Graphics.FillRectangle($br, 0, 0, $w, $hh); $br.Dispose()
        $br = New-Object System.Drawing.SolidBrush($s.Tag.Color); $e.Graphics.FillRectangle($br, 0, 0, [int]($w * $s.Tag.Ratio), $hh); $br.Dispose()
        $pen = New-Object System.Drawing.Pen($Col.Border); $e.Graphics.DrawRectangle($pen, 0, 0, $w - 1, $hh - 1); $pen.Dispose()
    })
    $chip = New-Ctl 'Label' 'HealthChip' 'C: drive health status'
    $chip.AutoSize = $true; $chip.Font = $boldFont; $chip.BackColor = $Col.Surface; $chip.BorderStyle = 'None'
    $chip.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4); $chip.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
    [WslSpace.Ui]::AddOutline($chip)
    $header.Controls.AddRange([System.Windows.Forms.Control[]]@($freeLbl, $usage, $chip))
    $root.Controls.Add($header)

    # ---- split: content (tabs + action bar) above, activity log below
    $split = New-Ctl 'SplitContainer' 'MainSplit' 'Content and activity log'
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.BackColor = $Col.Background; $split.SplitterWidth = 6
    $split.Panel1.BackColor = $Col.Background; $split.Panel2.BackColor = $Col.Background
    $split.Panel1.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 0)
    $split.Panel2.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 6)
    [WslSpace.Ui]::ThemeSplitter($split, $theme)
    $root.Controls.Add($split)

    # ---- 2. tabs (WslSpace.ThemedTabControl paints the whole strip from the palette)
    $tabs = New-Ctl 'TabControl' 'MainTabs' 'Views'
    $tabs.Dock = 'Fill'

    # Distros tab
    $distTab = New-Ctl 'TabPage' 'DistrosTab' 'Distros tab'
    $distTab.Text = 'Distros'; $distTab.BackColor = $Col.Background; $distTab.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $grid = New-Ctl 'DataGridView' 'DistrosGrid' 'WSL distributions'
    Set-GridStyle $grid
    Add-GridColumn $grid 'Distribution' 'Distribution' 140
    Add-GridColumn $grid 'Drive' 'Drive' 50 'MiddleCenter'
    Add-GridColumn $grid 'DiskOnC' 'Disk size' 85 'MiddleRight'
    Add-GridColumn $grid 'LinuxUsed' 'Linux used' 85 'MiddleRight'
    Add-GridColumn $grid 'Reclaimable' 'Reclaimable' 85 'MiddleRight'
    Add-GridColumn $grid 'Sparse' 'Sparse' 60 'MiddleCenter'
    Add-GridColumn $grid 'Note' 'Note' 160
    $state = New-Ctl 'Label' 'GridStateLabel' 'Distributions status message'
    $state.Dock = 'Top'; $state.Height = 32; $state.TextAlign = 'MiddleLeft'; $state.ForeColor = $Col.MutedText
    $state.BackColor = $Col.Surface; $state.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $state.Text = "Press Refresh (F5) to check the distributions."
    $hint = New-Ctl 'TextBox' 'TrimHintBox' 'Automatic trim hint'
    $hint.ReadOnly = $true; $hint.BorderStyle = 'None'; $hint.Dock = 'Bottom'; $hint.Text = Get-TrimHint
    $hint.BackColor = $Col.Background; $hint.ForeColor = $Col.MutedText
    $hintPad = New-Ctl 'Panel' 'TrimHintPanel' 'Automatic trim hint area'
    $hintPad.Dock = 'Bottom'; $hintPad.Height = $hint.PreferredHeight + 14; $hintPad.Padding = New-Object System.Windows.Forms.Padding(2, 8, 2, 0)
    $hintPad.Controls.Add($hint); $hint.Dock = 'Fill'
    $distTab.Controls.AddRange([System.Windows.Forms.Control[]]@($grid, $state, $hintPad))

    # Big folders tab
    $bigTab = New-Ctl 'TabPage' 'BigFoldersTab' 'Big folders tab'
    $bigTab.Text = 'Big folders'; $bigTab.BackColor = $Col.Background; $bigTab.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
    $bigBar = New-Flow 'BigFoldersBar' 'Big folders scan options' 'Top'
    $bigBar.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
    $bigDistro = New-Ctl 'ComboBox' 'BigDistroCombo' 'Distribution to scan'
    $bigDistro.Width = 180; Set-InputStyle $bigDistro
    $bigPath = New-Ctl 'TextBox' 'BigPathBox' 'Linux path to scan'
    $bigPath.Text = '~'; $bigPath.Width = 240; Set-InputStyle $bigPath
    $bigDepth = New-Ctl 'NumericUpDown' 'BigDepthNum' 'Scan depth'
    $bigDepth.Minimum = 1; $bigDepth.Maximum = 20; $bigDepth.Value = 3; $bigDepth.Width = 55; Set-InputStyle $bigDepth
    $bigTop = New-Ctl 'NumericUpDown' 'BigTopNum' 'Number of folders to show'
    $bigTop.Minimum = 1; $bigTop.Maximum = 200; $bigTop.Value = 25; $bigTop.Width = 65; Set-InputStyle $bigTop
    $btnScan = New-Btn 'BtnScanBig' '&Scan' 'Scan big folders' 'primary' 'Run du inside the distribution to list its biggest folders. Read-only; WSL keeps running.'
    $bigBar.Controls.AddRange([System.Windows.Forms.Control[]]@(
            (New-Lbl 'BigDistroLabel' 'Distribution'), $bigDistro, (New-Lbl 'BigPathLabel' 'Path'), $bigPath,
            (New-Lbl 'BigDepthLabel' 'Depth'), $bigDepth, (New-Lbl 'BigTopLabel' 'Top'), $bigTop, $btnScan))
    $bigGrid = New-Ctl 'DataGridView' 'BigFoldersGrid' 'Big folders results'
    Set-GridStyle $bigGrid
    Add-GridColumn $bigGrid 'Size' 'Size' 14 'MiddleRight'
    Add-GridColumn $bigGrid 'SizeBar' 'Relative size' 22
    Add-GridColumn $bigGrid 'Path' 'Path' 64
    $bigActions = New-Flow 'BigFoldersActions' 'Big folders actions' 'Bottom'
    $bigActions.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $btnOpen = New-Btn 'BtnOpenExplorer' '&Open in Explorer' 'Open selected folder in Explorer' '' 'Open the selected folder in Windows Explorer (also: double-click a row).'
    $btnCopyPath = New-Btn 'BtnCopyPath' 'Copy &path' 'Copy selected folder path' '' 'Copy the selected Linux path to the clipboard.'
    $bigActions.Controls.AddRange([System.Windows.Forms.Control[]]@($btnOpen, $btnCopyPath))
    $bigTab.Controls.AddRange([System.Windows.Forms.Control[]]@($bigGrid, $bigBar, $bigActions))
    $bigBar.TabIndex = 0; $bigGrid.TabIndex = 1; $bigActions.TabIndex = 2

    $tabs.TabPages.AddRange([System.Windows.Forms.TabPage[]]@($distTab, $bigTab))
    if ($settings.LastTab -ge 0 -and $settings.LastTab -lt $tabs.TabCount) { $tabs.SelectedIndex = $settings.LastTab }

    # ---- 3. action bar
    $actions = New-Flow 'ActionBar' 'Actions' 'Bottom'
    $actions.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 6)
    [WslSpace.Ui]::AddEdgeLine($actions, $theme, $true)
    $btnRefresh = New-Btn 'BtnRefresh' '&Refresh' 'Refresh' 'primary' 'Refresh C: free space and the distributions (F5). Read-only; WSL keeps running.'
    $btnTrim = New-Btn 'BtnTrim' "&Trim$Ell" 'Trim selected distribution' '' 'Run fstrim -v / as root inside the selected distribution so freed blocks go back to C:. WSL keeps running.'
    $btnCompact = New-Btn 'BtnCompact' "Co&mpact$Ell" 'Compact selected distribution disk' 'danger' 'Shrink the selected disk with diskpart (needs admin). STOPS ALL WSL SESSIONS (wsl --shutdown).'
    $btnMove = New-Btn 'BtnMove' "Move to &drive$Ell" 'Move selected distribution to another folder' '' 'Move the selected disk to another folder or drive with wsl --manage --move. STOPS ALL WSL SESSIONS (wsl --shutdown).'
    $chk = New-Ctl 'CheckBox' 'ChkDailyWarn' 'Warn me daily when C: is below the threshold'
    $chk.Text = '&Warn me daily when C: is below'; $chk.AutoSize = $true; $chk.Margin = New-Object System.Windows.Forms.Padding(24, 7, 0, 0)
    $tip.SetToolTip($chk, 'Checked: a daily task (09:00 and at logon) shows a notification when C: is low. Unchecked: the task is removed.')
    $num = New-Ctl 'NumericUpDown' 'ThresholdNum' 'Low space threshold in GB'
    $num.Minimum = 1; $num.Maximum = 10000; $num.Width = 70; Set-InputStyle $num
    $num.Value = [decimal][Math]::Min(10000, [Math]::Max(1, $settings.ThresholdGB))
    $actions.Controls.AddRange([System.Windows.Forms.Control[]]@($btnRefresh, $btnTrim, $btnCompact, $btnMove, $chk, $num, (New-Lbl 'ThresholdUnitLabel' 'GB')))
    $split.Panel1.Controls.AddRange([System.Windows.Forms.Control[]]@($tabs, $actions))

    # ---- 4. activity log
    $logBar = New-Flow 'LogToolbar' 'Activity log toolbar' 'Top'
    $logTitle = New-Lbl 'LogTitleLabel' 'Activity log'
    $logTitle.Font = $boldFont; $logTitle.Margin = New-Object System.Windows.Forms.Padding(4, 8, 12, 0)
    $filter = New-Ctl 'ComboBox' 'LogFilterCombo' 'Filter activity log'
    $filter.Width = 170; Set-InputStyle $filter
    $filter.Items.AddRange([object[]]@('All', 'Commands & output', 'Errors only')); $filter.SelectedIndex = 0
    $btnCopyLog = New-Btn 'BtnCopyLog' '&Copy' 'Copy activity log' '' 'Copy the selected log text, or all of it.'
    $btnSaveLog = New-Btn 'BtnSaveLog' "Sa&ve$Ell" 'Save activity log to a file' '' 'Save the shown log to a text file.'
    $btnClearLog = New-Btn 'BtnClearLog' 'C&lear view' 'Clear activity log view' '' 'Clear the log display. Nothing else is cleared or deleted.'
    $logBar.Controls.AddRange([System.Windows.Forms.Control[]]@($logTitle, $filter, $btnCopyLog, $btnSaveLog, $btnClearLog))
    $log = New-Ctl 'RichTextBox' 'ActivityLog' 'Activity log'
    $log.Dock = 'Fill'; $log.ReadOnly = $true; $log.WordWrap = $false; $log.ScrollBars = 'Both'; $log.DetectUrls = $false
    $log.BorderStyle = 'None'; $log.BackColor = $Col.Surface; $log.ForeColor = $Col.Text; $log.Font = $mono
    [WslSpace.Ui]::ApplyDarkTheme($log, $theme.Dark)
    # 1 px border (outer panel) and inner padding (inner panel) around the log.
    $logFrame = New-Ctl 'Panel' 'LogFrame' 'Activity log frame'
    $logFrame.Dock = 'Fill'; $logFrame.BackColor = $Col.Border; $logFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $logInner = New-Ctl 'Panel' 'LogInner' 'Activity log area'
    $logInner.Dock = 'Fill'; $logInner.BackColor = $Col.Surface; $logInner.Padding = New-Object System.Windows.Forms.Padding(8, 6, 2, 2)
    $logInner.Controls.Add($log); $logFrame.Controls.Add($logInner)
    $split.Panel2.Controls.AddRange([System.Windows.Forms.Control[]]@($logFrame, $logBar))
    $logBar.TabIndex = 0; $logFrame.TabIndex = 1

    # ---- 5. status bar
    $statusBar = New-Ctl 'TableLayoutPanel' 'StatusBar' 'Status bar'
    $statusBar.Dock = 'Fill'; $statusBar.AutoSize = $true; $statusBar.ColumnCount = 4; $statusBar.RowCount = 1
    $statusBar.BackColor = $Col.Surface; $statusBar.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
    [WslSpace.Ui]::AddEdgeLine($statusBar, $theme, $true)
    [void]$statusBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    1..3 | ForEach-Object { [void]$statusBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize'))) }
    $status = New-Ctl 'Label' 'StatusLabel' 'Status message'
    $status.Text = 'Ready'; $status.AutoSize = $true; $status.Anchor = 'Left'; $status.UseMnemonic = $false
    $progress = New-Ctl 'ProgressBar' 'StatusProgress' 'Operation progress'
    $progress.Style = 'Marquee'; $progress.Size = New-Object System.Drawing.Size(140, 12)
    $progress.Anchor = 'Right'; $progress.Visible = $false
    $elapsed = New-Ctl 'Label' 'ElapsedLabel' 'Elapsed time'
    $elapsed.Text = '0 s'; $elapsed.AutoSize = $true; $elapsed.Anchor = 'Right'; $elapsed.Visible = $false
    $btnCancel = New-Btn 'BtnCancel' 'Cancel' 'Cancel running operation' '' 'Stop the running Refresh, Big folders, Trim or daily-check job. Compact cannot be cancelled.'
    $statusBar.Controls.AddRange([System.Windows.Forms.Control[]]@($status, $progress, $elapsed, $btnCancel))
    $root.Controls.Add($statusBar)

    # ---- state and behaviour
    $ui = @{
        Job = $null; InfoSeen = 0; OnDone = $null; Title = ''; Started = $null; Cancellable = $true; Cancelled = $false
        Entries = New-Object System.Collections.ArrayList; ClearedAt = 0; Carry = $null; Syncing = $false
        Prev = $null; BigDistro = $null; FreeBefore = 0
    }
    $scriptFile = $script:ScriptFile
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250

    $setStatus = { param([string]$Text, $Color) $status.Text = $Text; $status.ForeColor = $(if ($Color) { $Color } else { $Col.Text }) }

    $appendEntry = {
        param($entry)
        $n = $log.TextLength
        $atEnd = ($n -eq 0) -or ($log.GetPositionFromCharIndex($n - 1).Y -lt $log.ClientSize.Height)
        $pos = New-Object WslSpace.Ui+POINT
        if (-not $atEnd) { [void][WslSpace.Ui]::SendMessage($log.Handle, 0x4DD, [IntPtr]::Zero, [ref]$pos) }  # EM_GETSCROLLPOS
        $selStart = $log.SelectionStart; $selLen = $log.SelectionLength
        $log.Select($n, 0)
        $log.SelectionColor = switch ($entry.Kind) {
            'command' { $Col.MutedText } 'success' { $Col.Success } 'warning' { $Col.Warning } 'error' { $Col.Error } default { $Col.Text }
        }
        $log.SelectionFont = $(if ($entry.Kind -eq 'section') { $monoBold } else { $mono })
        $log.AppendText((Format-LogEntry $entry $entry.Time) + "`n")
        if ($atEnd) { $log.Select($log.TextLength, 0); $log.ScrollToCaret() }
        else {
            # The user scrolled up: keep their selection and scroll position.
            $log.Select($selStart, $selLen)
            [void][WslSpace.Ui]::SendMessage($log.Handle, 0x4DE, [IntPtr]::Zero, [ref]$pos)      # EM_SETSCROLLPOS
        }
    }
    $renderLog = {
        $log.Clear()
        $rest = @($ui.Entries | Select-Object -Skip $ui.ClearedAt)
        foreach ($en in (Select-LogEntries $rest ([string]$filter.SelectedItem))) { & $appendEntry $en }
    }
    $addLog = {
        param([string]$Kind, [string]$Text)
        $en = [pscustomobject]@{ Kind = $Kind; Text = $Text; Time = Get-Date }
        [void]$ui.Entries.Add($en)
        if (@(Select-LogEntries @($en) ([string]$filter.SelectedItem)).Count) { & $appendEntry $en }
    }
    $addLine = { param([string]$Line) $en = ConvertTo-LogEntry $Line; & $addLog $en.Kind $en.Text }

    $selected = {
        if ($grid.SelectedRows.Count) { return [string]$grid.SelectedRows[0].Tag }
        if ($grid.Rows.Count) { return [string]$grid.Rows[0].Tag }
        $null
    }

    $updateHeader = {
        $drv = Get-PSDrive -Name C
        $free = [long]$drv.Free; $total = [long]$drv.Free + [long]$drv.Used
        $health = Get-DiskHealth $free ([double]$num.Value)
        $hc = switch ($health.Status) { 'Critical' { $Col.Error } 'Low' { $Col.Warning } default { $Col.Success } }
        $freeLbl.Text = "C: $(Format-SizeGB $free) free"
        $chip.Text = $health.ChipText; $chip.ForeColor = $hc
        $usage.Tag = @{ Ratio = $(if ($total -gt 0) { ($total - $free) / $total } else { 0.0 }); Color = $(if ($health.Status -eq 'Healthy') { $Col.Accent } else { $hc }) }
        $usage.AccessibleDescription = "C: $(Format-SizeGB ($total - $free)) used of $(Format-SizeGB $total)"
        $tip.SetToolTip($usage, $usage.AccessibleDescription)
        $usage.Invalidate()
    }

    # Loading / empty / busy: everything but Cancel is disabled while a job runs.
    $updateEnabled = {
        $idle = -not $ui.Job
        $has = $grid.Rows.Count -gt 0
        $btnRefresh.Enabled = $idle
        $btnTrim.Enabled = $idle -and $has -and (& $selected) -ne $script:DockerDiskName
        $btnCompact.Enabled = $idle -and $has
        $btnMove.Enabled = $idle -and $has -and (& $selected) -ne $script:DockerDiskName
        $btnScan.Enabled = $idle -and $bigDistro.Items.Count -gt 0
        $btnOpen.Enabled = $idle -and $bigGrid.Rows.Count -gt 0
        $btnCopyPath.Enabled = $idle -and $bigGrid.Rows.Count -gt 0
        $chk.Enabled = $idle
        $num.Enabled = $idle
        $btnCancel.Enabled = (-not $idle) -and $ui.Cancellable
    }

    # Runs a function of this script in a background job (dot-sources the script there).
    $runJob = {
        param([string]$Title, [string]$Fn, [object[]]$FnArgs, [scriptblock]$OnDone, [bool]$Cancellable = $true)
        & $addLog 'section' $Title
        $ui.Title = $Title; $ui.Cancellable = $Cancellable; $ui.Cancelled = $false
        $ui.Started = Get-Date; $ui.InfoSeen = 0; $ui.OnDone = $OnDone
        $ui.Job = Start-Job -ArgumentList $scriptFile, $Fn, $FnArgs -ScriptBlock {
            param($file, $fn, $a)
            Set-Location $env:SystemRoot
            . $file
            & $fn @a
        }
        & $setStatus "$Title$Ell"
        $elapsed.Text = '0 s'; $elapsed.Visible = $true; $progress.Visible = $true
        & $updateEnabled
        $timer.Start()
    }

    $timer.add_Tick({
        $job = $ui.Job
        if (-not $job) { $timer.Stop(); return }
        $secs = [int]((Get-Date) - $ui.Started).TotalSeconds
        $elapsed.Text = "$secs s"
        $info = $job.ChildJobs[0].Information
        while ($ui.InfoSeen -lt $info.Count) { & $addLine ("" + $info[$ui.InfoSeen].MessageData); $ui.InfoSeen++ }
        if ($job.State -notin 'Completed', 'Failed', 'Stopped') { return }
        $timer.Stop()
        $out = @($job.ChildJobs[0].Output)
        $err = $null
        foreach ($er in $job.ChildJobs[0].Error) { $err = "$er"; & $addLog 'error' $err }
        if ($job.State -eq 'Failed' -and -not $ui.Cancelled) { $err = $job.ChildJobs[0].JobStateInfo.Reason.Message; & $addLog 'error' $err }
        Remove-Job $job -Force
        $ui.Job = $null
        $progress.Visible = $false; $elapsed.Visible = $false
        if ($ui.Cancelled) { & $addLog 'warning' "$($ui.Title) cancelled ($secs s)"; & $setStatus "$($ui.Title) cancelled" $Col.Warning }
        elseif ($err) { & $addLog 'error' "$($ui.Title) failed ($secs s)"; & $setStatus "$($ui.Title) failed: $err" $Col.Error }
        else { & $addLog 'success' "$($ui.Title) done ($secs s)"; & $setStatus "$($ui.Title) done ($secs s)" }
        & $updateEnabled
        if ($ui.OnDone -and -not $ui.Cancelled) { & $ui.OnDone $out (-not $err) }
    })

    $showReport = {
        param($out)
        $data = $out | Where-Object { $_.PSObject.Properties['Distros'] } | Select-Object -Last 1
        try { & $updateHeader } catch { & $addLog 'error' "C: drive: $_" }
        $grid.Rows.Clear(); $bigDistro.Items.Clear()
        $fmt = { param($b) if ($null -eq $b) { '?' } else { Format-SizeGB $b } }
        foreach ($d in @($data.Distros)) {
            if (-not $d) { continue }
            $note = if ($d.IsDocker) { $d.Note } elseif ($d.Note) { "$script:SymCross $($d.Note)" } else { '' }
            $i = $grid.Rows.Add(($d.Name + $(if ($d.IsDefault) { ' (default)' } else { '' })), $d.Drive, (& $fmt $d.VhdxBytes),
                (& $fmt $d.UsedBytes), (& $fmt $d.ReclaimableBytes),
                $(if ($null -eq $d.Sparse) { '?' } elseif ($d.Sparse) { 'yes' } else { 'no' }), $note)
            $row = $grid.Rows[$i]; $row.Tag = $d.Name
            # Per-cell colors keep their color on the selected row too.
            if ($d.ReclaimableBytes -ge 5GB) { $cs = $row.Cells['Reclaimable'].Style; $cs.Font = $boldFont; $cs.ForeColor = $Col.Warning; $cs.SelectionForeColor = $Col.Warning }
            if ($d.Note -and -not $d.IsDocker) { $cs = $row.Cells['Note'].Style; $cs.ForeColor = $Col.Error; $cs.SelectionForeColor = $Col.Error }
            if (-not $d.IsDocker) { [void]$bigDistro.Items.Add($d.Name) }
        }
        foreach ($row in $grid.Rows) { if ($row.Tag -eq $ui.Prev) { $grid.CurrentCell = $row.Cells[0] } }
        $state.Text = if ($data) { 'WSL has no distributions.' } else { 'Could not read the distributions. See the activity log.' }
        $state.Visible = $grid.Rows.Count -eq 0
        if ($bigDistro.Items.Count) { $bigDistro.SelectedItem = & $selected }
        if ($ui.Carry) { & $setStatus $ui.Carry[0] $ui.Carry[1]; $ui.Carry = $null }
        & $updateEnabled
    }
    $refresh = {
        $ui.Prev = & $selected
        $grid.Rows.Clear()
        $state.Text = "Checking distributions$Ell"; $state.Visible = $true
        & $runJob 'Refresh' 'Get-SpaceReportData' @() $showReport
    }

    # After Trim/Compact: show what C: gained (or keep the error), then refresh.
    $afterReclaim = {
        param([string]$What, [bool]$Ok)
        if ($Ok) {
            $gain = (Get-CDriveFreeBytes) - $ui.FreeBefore
            # After Compact/Move the C: change also includes WSL's swap file; the log has the disk's own change.
            $ui.Carry = @("$What finished: C: free $(if ($gain -ge 0) { '+' })$(Format-SizeGB $gain)$(if ($What -ne 'Trim') { ' (details in the log)' })", $Col.Success)
        } else { $ui.Carry = @($status.Text, $status.ForeColor) }
        & $refresh
    }

    $syncDaily = {
        $ui.Syncing = $true
        try { $chk.Checked = Test-DailyCheckEnabled } catch { } finally { $ui.Syncing = $false }
    }

    $scan = {
        $name = [string]$bigDistro.SelectedItem
        if (-not $name) { return }
        $lp = $bigPath.Text.Trim(); if (-not $lp) { $lp = '~' }
        $dp = [int]$bigDepth.Value; $tp = [int]$bigTop.Value
        $ui.BigDistro = $name
        & $runJob "Big folders in $name ($lp, depth $dp, top $tp)" 'Get-BigFoldersData' @($name, $lp, $dp, $tp) {
            param($out)
            $rows = @($out | Where-Object { $_.PSObject.Properties['SizeKB'] })
            $bigGrid.Rows.Clear()
            $max = ($rows | Measure-Object SizeKB -Maximum).Maximum
            foreach ($r in $rows) {
                $bars = if ($max -gt 0) { [Math]::Max(1, [int][Math]::Round(20 * $r.SizeKB / $max)) } else { 1 }
                # The block text stays for copy/screen readers; the cell paints a bar from the ratio in Tag.
                $i = $bigGrid.Rows.Add($r.Size, ($script:SymBlock * $bars), $r.Path)
                $bigGrid.Rows[$i].Tag = $r.Path
                $bigGrid.Rows[$i].Cells['SizeBar'].Tag = $(if ($max -gt 0) { [double]$r.SizeKB / $max } else { 0.0 })
            }
            & $updateEnabled
        }
    }
    $bigPathSel = { if ($bigGrid.SelectedRows.Count) { [string]$bigGrid.SelectedRows[0].Tag } }
    $openSel = {
        $lp = & $bigPathSel
        if (-not $lp -or -not $ui.BigDistro) { return }
        $win = ConvertTo-WslExplorerPath $ui.BigDistro $lp
        & $addLog 'command' "explorer.exe `"$win`""
        Start-Process explorer.exe -ArgumentList "`"$win`""
        & $setStatus "Opened $win"
    }

    # ---- events
    $btnRefresh.add_Click({ & $refresh })
    $btnScan.add_Click({ & $scan })
    $btnOpen.add_Click({ & $openSel })
    $bigGrid.add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { & $openSel } })
    $btnCopyPath.add_Click({
        $lp = & $bigPathSel
        if (-not $lp) { return }
        [System.Windows.Forms.Clipboard]::SetText($lp)
        & $addLog 'success' "Copied path: $lp"
        & $setStatus "Copied $lp"
    })
    $grid.add_SelectionChanged({
        $name = & $selected
        if ($name -and $bigDistro.Items.Contains($name)) { $bigDistro.SelectedItem = $name }
        & $updateEnabled
    })

    $btnTrim.add_Click({
        $name = & $selected
        if (-not $name) { return }
        $ok = [System.Windows.Forms.MessageBox]::Show($form, "Run fstrim inside '$name' as root?`n`nWSL keeps running. Freed blocks go back to C: when the disk is sparse; otherwise run Compact afterwards.",
            'Trim', 'OKCancel', 'Question')
        if ($ok -ne 'OK') { return }
        $ui.FreeBefore = Get-CDriveFreeBytes
        & $runJob "Trim $name" 'Invoke-Trim' @($name) { param($out, $ok) & $afterReclaim 'Trim' $ok }
    })

    $btnCompact.add_Click({
        $name = & $selected
        if (-not $name) { return }
        $msg = $(if ($name -eq $script:DockerDiskName) { "Quit Docker Desktop first (tray icon > Quit Docker Desktop).`n`n" } else { '' }) +
            "Compact the disk of '$name'?`n`nALL WSL SESSIONS WILL STOP (wsl --shutdown), including running Claude Code sessions, editors and terminals. Save your work first.`n`nThis needs administrator rights (a UAC prompt follows) and can take several minutes."
        $ok = [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Compact - WSL will stop', 'OKCancel', 'Warning', 'Button2')
        if ($ok -ne 'OK') { return }
        $ui.FreeBefore = Get-CDriveFreeBytes
        # The elevated run cannot be stopped safely: no Cancel.
        & $runJob "Compact $name (elevated)" 'Start-ElevatedCompact' @($name) { param($out, $ok) & $afterReclaim 'Compact' $ok } $false
    })

    $btnMove.add_Click({
        $name = & $selected
        if (-not $name) { return }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Pick an empty folder for '$name', ideally on a drive other than C:."
        try { if ($dlg.ShowDialog($form) -ne 'OK') { return }; $target = $dlg.SelectedPath } finally { $dlg.Dispose() }
        $msg = "Move '$name' to`n$target ?`n`nALL WSL SESSIONS WILL STOP (wsl --shutdown), including running Claude Code sessions, editors and terminals. Save your work first.`n`nWSL moves the disk itself; if it fails, the distribution stays where it was."
        $ok = [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Move - WSL will stop', 'OKCancel', 'Warning', 'Button2')
        if ($ok -ne 'OK') { return }
        $ui.FreeBefore = Get-CDriveFreeBytes
        # Stopping a move halfway is not safe: no Cancel.
        & $runJob "Move $name to $target" 'Invoke-Move' @($name, $target) { param($out, $ok) & $afterReclaim 'Move' $ok } $false
    })

    $chk.add_CheckedChanged({
        if ($ui.Syncing) { return }
        if ($chk.Checked) { & $runJob 'Enable daily check' 'Enable-DailyCheck' @([double]$num.Value) { & $syncDaily } }
        else { & $runJob 'Disable daily check' 'Disable-DailyCheck' @() { & $syncDaily } }
    })
    $num.add_ValueChanged({
        try { Save-Settings ([double]$num.Value) $SettingsDir } catch { & $addLog 'error' "Could not save settings: $_" }
        try { & $updateHeader } catch { }
    })

    $btnCancel.add_Click({
        if (-not $ui.Job -or -not $ui.Cancellable) { return }
        $ui.Cancelled = $true
        & $addLog 'command' "Stop-Job ($($ui.Title))"
        Stop-Job $ui.Job
    })

    $filter.add_SelectedIndexChanged({ & $renderLog })
    $btnCopyLog.add_Click({
        $t = if ($log.SelectionLength) { $log.SelectedText } else { $log.Text }
        if (-not $t) { return }
        [System.Windows.Forms.Clipboard]::SetText(($t -replace "\r?\n", "`r`n"))
        & $setStatus 'Log copied to the clipboard'
    })
    $btnSaveLog.add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.FileName = 'wsl-space-log-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date)
        $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        try {
            if ($dlg.ShowDialog($form) -eq 'OK') {
                [System.IO.File]::WriteAllText($dlg.FileName, ($log.Text -replace "\r?\n", "`r`n"), (New-Object System.Text.UTF8Encoding $true))
                & $setStatus "Log saved to $($dlg.FileName)"
            }
        } catch { & $addLog 'error' "Could not save the log: $_"; & $setStatus "Could not save the log: $_" $Col.Error }
        finally { $dlg.Dispose() }
    })
    $btnClearLog.add_Click({ $ui.ClearedAt = $ui.Entries.Count; $log.Clear(); & $setStatus 'Log view cleared' })

    $form.add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F5') { if (-not $ui.Job) { & $refresh }; $e.Handled = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'F') {
            $tabs.SelectedTab = $bigTab; [void]$bigPath.Focus(); $bigPath.SelectAll()
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })
    $form.add_HandleCreated({
        if (-not $Palette.IsDark) { return }
        try {
            $v = 1  # DWMWA_USE_IMMERSIVE_DARK_MODE: 20, older Windows 10 builds use 19.
            if ([WslSpace.Ui]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) -ne 0) { [void][WslSpace.Ui]::DwmSetWindowAttribute($form.Handle, 19, [ref]$v, 4) }
        } catch { }
    })
    $form.add_Load({
        try {
            # Log panel min 220 px (toolbar + ~10 lines), so a saved or dragged position cannot squash it to a few lines.
            $split.Panel1MinSize = 200; $split.Panel2MinSize = 220
            $sd = if ($settings.SplitterDistance -gt 0) { $settings.SplitterDistance } else { [int]($split.Height * 0.5) }
            $split.SplitterDistance = [Math]::Max(200, [Math]::Min($sd, $split.Height - $split.Panel2MinSize - $split.SplitterWidth))
        } catch { }
    })
    if ($AutoStart) { $form.add_Shown({ & $syncDaily; & $refresh }) }
    $form.add_FormClosing({
        $timer.Stop()
        if ($ui.Job) { Stop-Job $ui.Job; Remove-Job $ui.Job -Force }
        $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
        try {
            Save-Settings 0 $SettingsDir @{ WindowWidth = $b.Width; WindowHeight = $b.Height; WindowX = $b.X; WindowY = $b.Y
                SplitterDistance = $split.SplitterDistance; LastTab = $tabs.SelectedIndex }
        } catch { }
    })

    & $updateHeader
    & $updateEnabled
    $form
}

function Show-MainWindow {
    $form = . New-MainWindow -AutoStart
    try { [void]$form.ShowDialog() } finally { $form.Dispose() }
}

# ---------------------------------------------------------------- main

function Invoke-Main {
    # wsl.exe cannot translate a \\wsl.localhost\ working directory for another distro.
    Set-Location $env:SystemRoot
    if ($SelfTest) { if (Invoke-SelfTest) { exit 0 } else { exit 1 } }
    if ($Report) { Write-Host (Format-Report (Get-SpaceReportData)); return }
    if ($BigFolders) {
        $name = Resolve-DistroName $Distro
        $rows = Get-BigFoldersData $name $Path $Depth $Top
        Write-Host "Big folders in $name ($Path, depth $Depth, top $Top):"
        Write-Host ($rows | Format-Table Size, Path -AutoSize | Out-String)
        return
    }
    if ($Trim) { Invoke-Trim (Resolve-DistroName $Distro); return }
    if ($Compact) {
        $name = Resolve-DistroName $Compact
        if (Test-IsAdmin) {
            if ($LogFile) { Start-Transcript -LiteralPath $LogFile | Out-Null }
            try {
                if (-not $Confirmed) {
                    $a = Read-Host "ALL WSL sessions will stop. Type '$name' to compact its disk"
                    if ($a -ne $name) { throw 'Cancelled.' }
                }
                Invoke-Compact $name
            } catch { Write-Host "ERROR: $_"; exit 1 } finally { if ($LogFile) { Stop-Transcript | Out-Null } }
        } else {
            if (-not $Confirmed) {
                $a = Read-Host "ALL WSL sessions will stop and admin rights are needed. Type '$name' to compact its disk"
                if ($a -ne $name) { Write-Host 'Cancelled.'; exit 1 }
            }
            Start-ElevatedCompact $name
        }
        return
    }
    if ($Move) {
        $name = Resolve-DistroName $Move
        if (-not $Confirmed) {
            $a = Read-Host "ALL WSL sessions will stop while '$name' moves to $To. Type '$name' to continue"
            if ($a -ne $name) { Write-Host 'Cancelled.'; exit 1 }
        }
        try { Invoke-Move $name $To } catch { Write-Host "ERROR: $_"; exit 1 }
        return
    }
    if ($Check) { Invoke-Check $ThresholdGB; return }
    Show-MainWindow
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Main } catch { Write-Host "ERROR: $_"; exit 1 }
}
