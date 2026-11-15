param([string]$OutputDir)
$ErrorActionPreference='Stop'
$base=Join-Path $env:RUNNER_TEMP ('tokiboshi-upgrade-'+[Guid]::NewGuid().ToString('N'))
$install=Join-Path $base 'app';$data=Join-Path $base 'profile';$other=Join-Path $base 'other-client'
New-Item $install,$data,$other -ItemType Directory -Force | Out-Null
$code=@'
using System; using System.Net; using System.Net.Sockets; using System.Threading;
class UpgradeFixture { static void Main(string[] args) { if(args.Length>0){ var s=new TcpListener(IPAddress.Loopback,Int32.Parse(args[0])); s.Start(); } Thread.Sleep(600000); } }
'@
$exe=Join-Path $base 'fixture.exe'
Add-Type -TypeDefinition $code -OutputAssembly $exe -OutputType ConsoleApplication
Copy-Item $exe "$install/tokiboshi.exe";Copy-Item $exe "$install/sing-box.exe";Copy-Item $exe "$other/sing-box.exe"
$socket=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$socket.Start();$port=$socket.LocalEndpoint.Port;$socket.Stop()
$dataJson='{"mixedPort":'+$port+',"nodes":[],"fixture":"must-survive"}'
Set-Content "$data/data.json" $dataJson;Set-Content "$data/data.json.tmp" 'synthetic recovery candidate';Set-Content "$data/data.json.bak" 'synthetic backup'
$before=@{};Get-ChildItem $data -File | ForEach-Object {$before[$_.Name]=(Get-FileHash $_.FullName).Hash}
@('obsolete.dll','data/old.asset','same.dll','tokiboshi.exe','sing-box.exe') | ConvertTo-Json | Set-Content "$install/installer-files.json"
Set-Content "$install/obsolete.dll" 'old';New-Item "$install/data" -ItemType Directory | Out-Null;Set-Content "$install/data/old.asset" 'old';Set-Content "$install/same.dll" 'new';Set-Content "$install/user-notes.txt" 'preserve'
$key='HKCU:\Software\TokiboshiInstallerAudit\'+[Guid]::NewGuid().ToString('N')
New-Item $key -Force | Out-Null;New-ItemProperty $key -Name ProxyEnable -Value 1 -PropertyType DWord | Out-Null;New-ItemProperty $key -Name ProxyServer -Value "127.0.0.1:$port" | Out-Null
$processes=@();$result=@{}
try {
 $gui=Start-Process "$install/tokiboshi.exe" -PassThru;$core=Start-Process "$install/sing-box.exe" -ArgumentList "$port" -PassThru;$outsider=Start-Process "$other/sing-box.exe" -PassThru;$processes=@($gui,$core,$outsider)
 for($i=0;$i -lt 50;$i++){if(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue){break};Start-Sleep -Milliseconds 100}
 $helper=Join-Path $PSScriptRoot '../prepare-upgrade.ps1';$legacy=Join-Path $PSScriptRoot '../legacy-v005-files.json';$snapshot=Join-Path $base 'snapshot.json'
 & $helper -Mode Prepare -InstallDir $install -DataDir $data -Snapshot $snapshot -LegacyManifest $legacy -RegistryPath $key
 $gui.Refresh();$core.Refresh();$outsider.Refresh()
 $result.closedOwnedProcesses=$gui.HasExited -and $core.HasExited
 $result.otherClientSurvives=-not $outsider.HasExited
 $result.ownedProxyDisabled=(Get-ItemProperty $key).ProxyEnable -eq 0
 @('same.dll','tokiboshi.exe','sing-box.exe','installer-files.json') | ConvertTo-Json | Set-Content "$install/installer-files.json"
 & $helper -Mode Cleanup -InstallDir $install -DataDir $data -Snapshot $snapshot -LegacyManifest $legacy -RegistryPath $key
 $result.retiredFilesRemoved=(-not(Test-Path "$install/obsolete.dll")) -and (-not(Test-Path "$install/data/old.asset"))
 $result.currentAndUnknownFilesPreserved=(Test-Path "$install/same.dll") -and (Test-Path "$install/user-notes.txt")
 $result.userDataAndRecoveryFilesPreserved=$true
 foreach($name in $before.Keys){if((Get-FileHash (Join-Path $data $name)).Hash -ne $before[$name]){$result.userDataAndRecoveryFilesPreserved=$false}}
 # Repeat with a proxy belonging to another tool; it must remain enabled.
 Set-ItemProperty $key ProxyEnable 1;Set-ItemProperty $key ProxyServer '127.0.0.1:65530'
 & $helper -Mode Prepare -InstallDir $install -DataDir $data -Snapshot $snapshot -LegacyManifest $legacy -RegistryPath $key
 $result.otherProxyUntouched=(Get-ItemProperty $key).ProxyEnable -eq 1
 $result.allPassed=-not($result.Values -contains $false)
 New-Item $OutputDir -ItemType Directory -Force | Out-Null
 $result | ConvertTo-Json | Set-Content (Join-Path $OutputDir 'installer-helper.json') -Encoding UTF8
 $result | ConvertTo-Json
 if(-not $result.allPassed){throw 'Upgrade helper assertion failed'}
} finally {
 foreach($p in $processes){if(-not $p.HasExited){Stop-Process $p.Id -Force -ErrorAction SilentlyContinue}}
 Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue
}
