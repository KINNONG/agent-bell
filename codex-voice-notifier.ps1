[CmdletBinding()]
param(
    [string]$TestSessionId,
    [string]$TestTurnId,
    [ValidateSet("UserPromptSubmit", "PermissionRequest", "Stop")][string]$TestEvent = "Stop",
    [string]$TestLastAssistantMessage,
    [switch]$DryRun
)

# Compatibility entry point for the already trusted local hook definition.
$pluginRoot = Join-Path $PSScriptRoot "plugins\agent-bell"
$dataDir = if (-not [string]::IsNullOrWhiteSpace($env:AGENT_BELL_DATA)) {
    $env:AGENT_BELL_DATA
}
else {
    Join-Path $env:LOCALAPPDATA "AgentBell"
}
$enqueuePath = Join-Path $pluginRoot "hooks\enqueue.ps1"

$arguments = @{
    PluginRoot = $pluginRoot
    DataDir = $dataDir
    NoExit = $true
}

if (-not [string]::IsNullOrWhiteSpace($TestSessionId)) {
    $turnId = if ([string]::IsNullOrWhiteSpace($TestTurnId)) { "manual-" + [Guid]::NewGuid().ToString("N") } else { $TestTurnId }
    $payload = [ordered]@{
        hook_event_name = $TestEvent
        session_id = $TestSessionId
        turn_id = $turnId
        cwd = $PSScriptRoot
        last_assistant_message = $TestLastAssistantMessage
    }
    $arguments.TestJson = $payload | ConvertTo-Json -Compress
    $arguments.RunWorkerSynchronously = $true
    if ($DryRun.IsPresent) {
        $dataDir = Join-Path $env:TEMP ("agent-bell-dry-run-" + [Guid]::NewGuid().ToString("N"))
        $arguments.DataDir = $dataDir
        $arguments.WorkerDryRun = $true
    }
}

try {
    & $enqueuePath @arguments
}
finally {
    if ($DryRun.IsPresent -and -not [string]::IsNullOrWhiteSpace($TestSessionId)) {
        Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit 0
