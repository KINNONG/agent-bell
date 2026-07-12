[CmdletBinding()]
param(
    [string]$PluginRoot,
    [string]$DataDir,
    [string]$TestJson,
    [switch]$NoWorker,
    [switch]$RunWorkerSynchronously,
    [switch]$WorkerDryRun,
    [switch]$NoExit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$eventName = $null
$rawPayload = $null
$writeStopOutput = $false

try {
    if ([string]::IsNullOrWhiteSpace($PluginRoot)) {
        $PluginRoot = if (-not [string]::IsNullOrWhiteSpace($env:PLUGIN_ROOT)) {
            $env:PLUGIN_ROOT
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:AGENT_BELL_PLUGIN_ROOT)) {
            $env:AGENT_BELL_PLUGIN_ROOT
        }
        else {
            Split-Path -Parent $PSScriptRoot
        }
    }
    if ([string]::IsNullOrWhiteSpace($DataDir)) {
        $DataDir = if (-not [string]::IsNullOrWhiteSpace($env:AGENT_BELL_DATA)) {
            $env:AGENT_BELL_DATA
        }
        else {
            Join-Path $env:LOCALAPPDATA "AgentBell"
        }
    }

    $rawPayload = if (-not [string]::IsNullOrWhiteSpace($TestJson)) {
        $TestJson
    }
    else {
        [Console]::In.ReadToEnd()
    }
    if ([string]::IsNullOrWhiteSpace($rawPayload)) {
        throw "Agent Bell did not receive a Codex hook payload."
    }

    $writeStopOutput = $rawPayload -match '"hook_event_name"\s*:\s*"Stop"'
    $payload = $rawPayload | ConvertFrom-Json
    $eventName = [string]$payload.hook_event_name
    $writeStopOutput = $eventName -eq "Stop"

    $modulePath = Join-Path $PluginRoot "scripts\AgentBell.Core.psm1"
    Import-Module $modulePath -Force -DisableNameChecking
    $event = ConvertTo-AgentBellEvent -Payload $payload

    $pendingDirectory = Join-Path $DataDir "queue\pending"
    [System.IO.Directory]::CreateDirectory($pendingDirectory) | Out-Null
    $fileName = ([DateTime]::UtcNow.ToString("yyyyMMddHHmmssfffffff") + "-" + [Guid]::NewGuid().ToString("N") + ".json")
    $eventPath = Join-Path $pendingDirectory $fileName
    Write-AgentBellJsonAtomic -Path $eventPath -Value $event

    if (-not $NoWorker.IsPresent) {
        $workerPath = Join-Path $PluginRoot "scripts\worker.ps1"
        $workerArguments = @(
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", ('"' + $workerPath + '"'),
            "-DataDir", ('"' + $DataDir + '"'),
            "-PluginRoot", ('"' + $PluginRoot + '"')
        )
        if ($WorkerDryRun.IsPresent) {
            $workerArguments += "-DryRun"
        }

        if ($RunWorkerSynchronously.IsPresent) {
            & powershell.exe @workerArguments | Out-Null
        }
        else {
            Start-Process -FilePath "powershell.exe" -ArgumentList ($workerArguments -join " ") -WindowStyle Hidden | Out-Null
        }
    }
}
catch {
    try {
        $fallbackDataDir = if (-not [string]::IsNullOrWhiteSpace($DataDir)) { $DataDir } else { Join-Path $env:LOCALAPPDATA "AgentBell" }
        $errorDirectory = Join-Path $fallbackDataDir "logs"
        [System.IO.Directory]::CreateDirectory($errorDirectory) | Out-Null
        $errorLine = ([DateTimeOffset]::UtcNow.ToString("o") + " enqueue_error " + $_.Exception.GetType().Name + [Environment]::NewLine)
        [System.IO.File]::AppendAllText((Join-Path $errorDirectory "hook-errors.log"), $errorLine)
    }
    catch {
        # Hook errors must never block Codex.
    }
}
finally {
    if ($writeStopOutput) {
        [Console]::Out.Write('{"continue":true}')
    }
}

if (-not $NoExit.IsPresent) {
    exit 0
}
