[CmdletBinding()]
param(
    [string]$PluginRoot,
    [string]$DataDir,
    [string]$CodexHome,
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
$stage = "initialize"

try {
    $stage = "resolve_paths"
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
    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $env:CODEX_HOME
        }
        else {
            Join-Path $HOME ".codex"
        }
    }

    $stage = "read_payload"
    $rawPayload = if (-not [string]::IsNullOrWhiteSpace($TestJson)) {
        $TestJson
    }
    else {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8, $true)
        try {
            $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    if ([string]::IsNullOrWhiteSpace($rawPayload)) {
        throw "Agent Bell did not receive a Codex hook payload."
    }

    $stage = "parse_payload"
    $writeStopOutput = $rawPayload -match '"hook_event_name"\s*:\s*"Stop"'
    $payload = $rawPayload | ConvertFrom-Json
    $eventName = [string]$payload.hook_event_name
    $writeStopOutput = $eventName -eq "Stop"

    $stage = "import_module"
    $modulePath = Join-Path $PluginRoot "scripts\AgentBell.Core.psm1"
    Import-Module $modulePath -Force -DisableNameChecking

    $stage = "normalize_event"
    $transcriptProperty = $payload.PSObject.Properties["transcript_path"]
    $transcriptPath = if ($null -ne $transcriptProperty) { [string]$transcriptProperty.Value } else { $null }
    $threadSource = Get-AgentBellRolloutThreadSource `
        -CodexHome $CodexHome `
        -SessionId ([string]$payload.session_id) `
        -TranscriptPath $transcriptPath
    $event = ConvertTo-AgentBellEvent -Payload $payload -ThreadSource $threadSource

    $stage = "enqueue_event"
    $pendingDirectory = Join-Path $DataDir "queue\pending"
    [System.IO.Directory]::CreateDirectory($pendingDirectory) | Out-Null
    $fileName = ([DateTime]::UtcNow.ToString("yyyyMMddHHmmssfffffff") + "-" + [Guid]::NewGuid().ToString("N") + ".json")
    $eventPath = Join-Path $pendingDirectory $fileName
    Write-AgentBellJsonAtomic -Path $eventPath -Value $event

    if (-not $NoWorker.IsPresent) {
        $stage = "launch_worker"
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
        $exception = $_.Exception
        $safeEventName = if ($eventName -in @("UserPromptSubmit", "PermissionRequest", "Stop")) { $eventName } else { "unknown" }
        $parameterName = if ($exception -is [System.ArgumentException] -and
            -not [string]::IsNullOrWhiteSpace($exception.ParamName) -and
            $exception.ParamName -match '^[A-Za-z0-9_.-]{1,64}$') { $exception.ParamName } else { "none" }
        $errorLine = ([DateTimeOffset]::UtcNow.ToString("o") +
            " enqueue_error stage=" + $stage +
            " event=" + $safeEventName +
            " type=" + $exception.GetType().Name +
            " hresult=0x" + $exception.HResult.ToString("X8") +
            " param=" + $parameterName +
            [Environment]::NewLine)
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
