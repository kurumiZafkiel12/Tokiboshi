param([string]$Installer,[string]$OldInstaller,[string]$Payload,[string]$OutputDir)
$ErrorActionPreference='Stop'
$root=Join-Path $env:RUNNER_TEMP ('tokiboshi-install-'+[Guid]::NewGuid().ToString('N'))
$app=Join-Path $root 'installed';New-Item $app,$OutputDir -ItemType Directory -Force | Out-Null
function Install([string]$Exe,[string]$Log) {
 $p=Start-Process $Exe -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/TASKS=',('/DIR="'+$app+'"'),('/LOG="'+$Log+'"')) -PassThru -Wait
 if($p.ExitCode -ne 0){throw "Installer failed ($($p.ExitCode)); see $Log"}
}
# Install the real old release first; this exercises its registration and log.
Install $OldInstaller (Join-Path $OutputDir 'old-install.log')
# A synthetic GUI process at the actual old install path keeps the executable
# occupied without launching Flutter or modifying the runner's network settings.
$code='using System.Threading; class OldGui { static void Main(){Thread.Sleep(600000);} }'
$stub=Join-Path $root 'stub.exe';Add-Type -TypeDefinition $code -OutputAssembly $stub -OutputType ConsoleApplication
Copy-Item $stub "$app/tokiboshi.exe" -Force
$gui=Start-Process "$app/tokiboshi.exe" -PassThru
Copy-Item $stub "$app/sing-box.exe" -Force
$core=Start-Process "$app/sing-box.exe" -PassThru
$otherDir=Join-Path $root 'other-client';New-Item $otherDir -ItemType Directory | Out-Null
Copy-Item $stub "$otherDir/sing-box.exe"
$unrelated=Start-Process "$otherDir/sing-box.exe" -PassThru
$oldFiles=Get-Content (Join-Path $PSScriptRoot '../legacy-v005-files.json') -Raw | ConvertFrom-Json
$oldFiles+=@('retired-plugin.dll','data/retired.asset')
ConvertTo-Json -InputObject $oldFiles | Set-Content "$app/installer-files.json"
Set-Content "$app/retired-plugin.dll" 'synthetic retired plugin';Set-Content "$app/data/retired.asset" 'synthetic retired asset';Set-Content "$app/user-notes.txt" 'user file remains'
# Only synthetic APPDATA, in the ephemeral Windows runner. The installer must
# preserve it. Do not change ProxyEnable, ProxyServer, DNS, or TUN.
$data=Join-Path $env:APPDATA 'Tokiboshi'
if(Test-Path $data){throw 'Expected a fresh runner profile; refusing to overwrite existing data'}
New-Item $data -ItemType Directory | Out-Null
Set-Content "$data/data.json" '{"nodes":[],"mixedPort":18991,"fixture":"keep"}'
Set-Content "$data/data.json.tmp" 'recovery fixture';Set-Content "$data/data.json.bak" 'backup fixture'
$hashes=@{};Get-ChildItem $data -File | ForEach-Object {$hashes[$_.Name]=(Get-FileHash $_.FullName).Hash}
$result=@{}
try {
 Install $Installer (Join-Path $OutputDir 'chinese-upgrade.log')
 $gui.Refresh();$result.oldProcessClosed=$gui.HasExited
 $core.Refresh();$result.oldCoreClosed=$core.HasExited
 $unrelated.Refresh();$result.unrelatedCorePreserved=-not $unrelated.HasExited
 $result.retiredFilesRemoved=(-not(Test-Path "$app/retired-plugin.dll")) -and (-not(Test-Path "$app/data/retired.asset"))
 $result.unknownUserFilePreserved=Test-Path "$app/user-notes.txt"
 $result.dataAndRecoveryFilesPreserved=$true
 foreach($name in $hashes.Keys){if((Get-FileHash (Join-Path $data $name)).Hash -ne $hashes[$name]){$result.dataAndRecoveryFilesPreserved=$false}}
 $result.payloadHashesMatch=$true
 foreach($file in Get-ChildItem $Payload -File -Recurse){$relative=$file.FullName.Substring($Payload.Length+1);$dest=Join-Path $app $relative;if(-not(Test-Path $dest) -or (Get-FileHash $dest).Hash -ne (Get-FileHash $file.FullName).Hash){$result.payloadHashesMatch=$false}}
 $log=Get-Content (Join-Path $OutputDir 'chinese-upgrade.log') -Raw
 $result.chineseLanguageSelected=$log -match 'chinesesimp'
 # A second unattended run must also succeed without deleting personal files.
 Install $Installer (Join-Path $OutputDir 'chinese-repeat.log')
 $result.repeatInstallPassed=$true
 $result.allPassed=-not($result.Values -contains $false)
 $result | ConvertTo-Json | Set-Content (Join-Path $OutputDir 'installer-upgrade.json') -Encoding UTF8
 $result | ConvertTo-Json
 if(-not $result.allPassed){throw 'Installer upgrade assertion failed'}
} finally {
 foreach($process in $gui,$core,$unrelated) {
  if(-not $process.HasExited){Stop-Process $process.Id -Force -ErrorAction SilentlyContinue}
 }
 $uninstall=Join-Path $app 'unins000.exe'
 if(Test-Path $uninstall){Start-Process $uninstall -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait | Out-Null}
 Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
}
