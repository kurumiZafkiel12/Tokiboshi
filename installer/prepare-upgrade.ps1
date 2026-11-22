[CmdletBinding()]
param(
    [ValidateSet('Prepare','Cleanup')][string]$Mode = 'Prepare',
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [Parameter(Mandatory=$true)][string]$DataDir,
    [Parameter(Mandatory=$true)][string]$Snapshot,
    [Parameter(Mandatory=$true)][string]$LegacyManifest,
    [string]$OriginalSidFile,
    [string]$RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$data = [IO.Path]::GetFullPath($DataDir).TrimEnd('\')
function Manifest([string]$Path) {
    $entries = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($entry in $entries) {
        if ($entry -isnot [string] -or [IO.Path]::IsPathRooted($entry) -or $entry -match '(^|[\\/])\.\.([\\/]|$)' -or $entry.Contains(':')) { throw 'Unsafe installed-file manifest' }
        $full = [IO.Path]::GetFullPath((Join-Path $root $entry))
        if (-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest escapes installation directory' }
    }
    return $entries
}
function PathEquals([string]$A,[string]$B) { return [string]::Equals($A,$B,[StringComparison]::OrdinalIgnoreCase) }
if ($Mode -eq 'Prepare') {
    if ($OriginalSidFile) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (Test-Path -LiteralPath $OriginalSidFile) {
            $sid = (Get-Content -LiteralPath $OriginalSidFile -Raw).Trim()
            if ($sid -notmatch '^S-1-5-21-(?:[0-9]+-){3}[0-9]+$') { throw 'Invalid upgrade profile SID' }
        } else {
            Set-Content -LiteralPath $OriginalSidFile -Value $sid -Encoding ASCII
        }
        if (-not $PSBoundParameters.ContainsKey('RegistryPath')) {
            $RegistryPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        }
    }
    $manifest = Join-Path $root 'installer-files.json'
    $owned = if (Test-Path -LiteralPath $manifest) { @(Manifest $manifest) } else { @(Manifest $LegacyManifest) }
    ConvertTo-Json -InputObject $owned | Set-Content -LiteralPath $Snapshot -Encoding UTF8
    # Match executable paths, not global process names. A second client using
    # another sing-box.exe is never selected.
    $all = @(Get-CimInstance Win32_Process -Filter "Name='tokiboshi.exe' OR Name='sing-box.exe'")
    $gui = @($all | Where-Object { PathEquals $_.ExecutablePath (Join-Path $root 'tokiboshi.exe') })
    $guiIds = @($gui | ForEach-Object { $_.ProcessId })
    $cores = @($all | Where-Object { $_.Name -eq 'sing-box.exe' -and (
        (PathEquals $_.ExecutablePath (Join-Path $root 'sing-box.exe')) -or
        (PathEquals $_.ExecutablePath (Join-Path $data 'core\sing-box.exe')) -or
        ($guiIds -contains $_.ParentProcessId)) })
    $coreIds = @($cores | ForEach-Object { $_.ProcessId })
    $port = 0; $ownedProxy = $false
    try {
        $saved = Get-Content -LiteralPath (Join-Path $data 'data.json') -Raw | ConvertFrom-Json
        $port = [int]$saved.mixedPort
        if ($port -gt 0 -and $port -le 65535) {
            $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
            $ownedProxy = @($listeners | Where-Object { $coreIds -contains $_.OwningProcess }).Count -gt 0
        }
    } catch { $ownedProxy = $false }
    foreach ($item in $gui) {
        $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if ($process) { $null = $process.CloseMainWindow() }
    }
    if ($gui.Count -gt 0) { Start-Sleep -Milliseconds 1200 }
    foreach ($item in @($gui)+@($cores)) {
        $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.ProcessId)" -ErrorAction SilentlyContinue
        # Recheck identity immediately before killing; do not terminate a reused PID.
        if ($live -and $live.CreationDate -eq $item.CreationDate -and (PathEquals $live.ExecutablePath $item.ExecutablePath)) {
            Stop-Process -Id $item.ProcessId -Force -ErrorAction Stop
            Wait-Process -Id $item.ProcessId -Timeout 8 -ErrorAction SilentlyContinue
        }
    }
    $remaining = @(Get-CimInstance Win32_Process -Filter "Name='tokiboshi.exe' OR Name='sing-box.exe'" | Where-Object {
        (PathEquals $_.ExecutablePath (Join-Path $root 'tokiboshi.exe')) -or
        (PathEquals $_.ExecutablePath (Join-Path $root 'sing-box.exe')) -or
        (PathEquals $_.ExecutablePath (Join-Path $data 'core\sing-box.exe')) })
    if ($remaining.Count) { throw 'The previous installation is still running' }
    # A standard-user query may omit the paths of elevated processes.
    # Detect locked installation binaries before replacement begins.
    $blocked = foreach ($name in 'tokiboshi.exe', 'sing-box.exe', 'flutter_windows.dll', 'rust_lib_tokiboshi.dll') {
        $path = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $file = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
            $file.Dispose()
        } catch [IO.IOException] { $name } catch [UnauthorizedAccessException] { $name }
    }
    if ($blocked) { throw "Installation binaries still in use: $($blocked -join ', ')" }
    # Forced shutdown must not strand the proxy at our stopped core. Change only
    # a loopback setting whose listener was proved to belong to that core.
    $proxyCleared = $false
    if ($ownedProxy) {
        $setting = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
        $stillListening = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).Count -gt 0
        if (-not $stillListening -and $setting.ProxyEnable -eq 1 -and @("127.0.0.1:$port","localhost:$port") -contains ([string]$setting.ProxyServer).Trim().ToLowerInvariant()) {
            Set-ItemProperty -LiteralPath $RegistryPath -Name ProxyEnable -Value 0
            $proxyCleared = $true
            if ($OriginalSidFile -or (PathEquals $RegistryPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings')) {
                Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class TokiboshiProxyRefresh { [DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int size); }'
                $null = [TokiboshiProxyRefresh]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)
                $null = [TokiboshiProxyRefresh]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)
            }
        }
    }
    @{ mode='Prepare'; stoppedGui=$gui.Count; stoppedCore=$cores.Count; proxyCleared=$proxyCleared } | ConvertTo-Json -Compress
} else {
    $before = @(Manifest $Snapshot)
    $after = @(Manifest (Join-Path $root 'installer-files.json'))
    $removed = 0
    foreach ($relative in $before) {
        if ($after -contains $relative) { continue }
        $file = Join-Path $root $relative
        # Do not traverse junctions or symbolic links, even if a manifest was
        # tampered with. Only previously installed files may be removed.
        $cursor = $file
        $linked = $false
        while (-not (PathEquals $cursor $root)) {
            $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if ($entry -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $linked=$true; break }
            $cursor = Split-Path $cursor -Parent
            if (-not $cursor) { throw 'Invalid manifest path' }
        }
        if ($linked) { throw 'Refusing cleanup through a reparse point' }
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force
            $removed++
            $parent = Split-Path $file -Parent
            while (-not (PathEquals $parent $root)) {
                if (@(Get-ChildItem -LiteralPath $parent -Force).Count) { break }
                Remove-Item -LiteralPath $parent
                $parent = Split-Path $parent -Parent
            }
        }
    }
    @{ mode='Cleanup'; removedObsoleteFiles=$removed } | ConvertTo-Json -Compress
}
