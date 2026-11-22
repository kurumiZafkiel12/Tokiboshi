param([Parameter(Mandatory)][string]$Payload)
$ErrorActionPreference = 'Stop'
$Payload = (Resolve-Path $Payload).Path
$fixture = Join-Path $env:RUNNER_TEMP ('tokiboshi-standby-' + [Guid]::NewGuid())
$dataDir = Join-Path $fixture 'Tokiboshi'
New-Item $dataDir -ItemType Directory -Force | Out-Null
@{
    systemProxy = $true
    enableTun = $true
    desktop = @{ startCoreOnOpen = $true; autoCheckUpdates = $false }
} | ConvertTo-Json | Set-Content (Join-Path $dataDir 'data.json')
$network = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
function ProxySnapshot {
    Get-ItemProperty $network | Select-Object ProxyEnable,ProxyServer,ProxyOverride | ConvertTo-Json -Compress
}

$before = ProxySnapshot
$originalAppData = $env:APPDATA
$app = $null
try {
    $env:APPDATA = $fixture
    $app = Start-Process (Join-Path $Payload 'tokiboshi.exe') -WorkingDirectory $Payload -PassThru
    $ready = $false
    $configPath = Join-Path $dataDir 'config.json'
    for ($i = 0; $i -lt 90; $i++) {
        if ($app.HasExited) { throw "Tokiboshi exited with code $($app.ExitCode)" }
        if (Test-Path $configPath) {
            try {
                $config = Get-Content $configPath -Raw | ConvertFrom-Json
                $api = $config.experimental.clash_api
                $response = Invoke-RestMethod "http://$($api.external_controller)/version" -Headers @{Authorization = "Bearer $($api.secret)"} -TimeoutSec 2
                if ($response.version) { $ready = $true; break }
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'The bundled core did not bring up its controller' }
    if ($config.inbounds.Count -ne 1 -or $config.inbounds[0].listen -ne '127.0.0.1' -or $config.inbounds[0].type -ne 'mixed') {
        throw 'The first launch has an unexpected inbound or enables TUN'
    }
    if ((ProxySnapshot) -ne $before) { throw 'The first launch changed Windows system proxy settings' }
    Write-Output 'Elevated Windows runner started the core on first launch, with TUN and system proxy inactive.'
} finally {
    $env:APPDATA = $originalAppData
    if ($app) {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($app.Id) AND Name='sing-box.exe'" |
            Where-Object { $_.ExecutablePath -eq (Join-Path $Payload 'sing-box.exe') })
        if (-not $app.HasExited) {
            Stop-Process -Id $app.Id -Force
            Wait-Process -Id $app.Id -Timeout 6 -ErrorAction SilentlyContinue
        }
        foreach ($child in $children) { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
