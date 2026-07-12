[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'AgentBell\voice-pack'),
    [string]$Model,
    [switch]$Hidden,
    [ValidateRange(5, 300)][int]$ReadyTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fullInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $fullInstallRoot '.agent-bell-qwen-voice-pack'
$pythonPath = Join-Path $fullInstallRoot '.venv\Scripts\python.exe'
$serverPath = Join-Path $fullInstallRoot 'app\server.py'

if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "InstallRoot is not an Agent Bell Voice Pack installation: $fullInstallRoot"
}
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "The isolated Voice Pack Python environment is missing: $pythonPath"
}
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    throw "The Voice Pack server is missing: $serverPath"
}

try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:17863/health' -Method Get -TimeoutSec 2
    if ([string]$health.service -eq 'agent-bell-qwen-voice-pack' -and [string]$health.status -eq 'ready') {
        Write-Output ([pscustomobject][ordered]@{
            Started = $false
            AlreadyRunning = $true
            Ready = $true
            Endpoint = 'http://127.0.0.1:17863'
        })
        exit 0
    }
}
catch {
    # No ready Voice Pack is listening yet; continue with startup.
}

$serverArguments = @($serverPath, '--install-root', $fullInstallRoot)
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $serverArguments += @('--model', $Model.Trim())
}

if ($Hidden.IsPresent) {
    $processArguments = @("`"$serverPath`"", '--install-root', "`"$fullInstallRoot`"")
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $processArguments += @('--model', "`"$($Model.Trim())`"")
    }
    $process = Start-Process -FilePath $pythonPath `
        -ArgumentList $processArguments `
        -WorkingDirectory $fullInstallRoot `
        -WindowStyle Hidden `
        -PassThru
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $ready = $false
    do {
        try {
            $health = Invoke-RestMethod -Uri 'http://127.0.0.1:17863/health' -Method Get -TimeoutSec 2
            if ([string]$health.service -eq 'agent-bell-qwen-voice-pack' -and [string]$health.status -eq 'ready') {
                $ready = $true
                break
            }
        }
        catch {
            # Model loading keeps the loopback port reserved before health is ready.
        }
        $process.Refresh()
        if ($process.HasExited) {
            throw "The Voice Pack process exited before becoming ready (exit code $($process.ExitCode))."
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    if (-not $ready) {
        throw "The Voice Pack did not become ready within $ReadyTimeoutSeconds seconds."
    }
    Write-Output ([pscustomobject][ordered]@{
        Started = $true
        Hidden = $true
        Ready = $true
        ProcessId = $process.Id
        Endpoint = 'http://127.0.0.1:17863'
    })
    exit 0
}

& $pythonPath @serverArguments
exit $LASTEXITCODE
