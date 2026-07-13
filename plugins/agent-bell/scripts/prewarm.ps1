[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PluginRoot,
    [Parameter(Mandatory = $true)][string]$DataDir,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Alias("DelaySeconds")][ValidateRange(0, 120)][int]$TitleRetryDelaySeconds = 10,
    [object]$ResourceSnapshot = $null,
    [ValidateRange(0, 120)][int[]]$ResourceRetryDelaysSeconds = @(15, 30, 30)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Enter-AgentBellPrewarmSlot {
    param([Parameter(Mandatory = $true)][string[]]$SlotNames)

    foreach ($slotName in $SlotNames) {
        $candidate = $null
        $owned = $false
        try {
            $candidate = New-Object System.Threading.Mutex($false, $slotName)
            try {
                $owned = $candidate.WaitOne(0)
            }
            catch [System.Threading.AbandonedMutexException] {
                # An abandoned mutex is acquired by the waiting thread.
                $owned = $true
            }
            if ($owned) {
                return $candidate
            }
        }
        catch {
            # A slot that cannot be opened is unavailable.
        }
        finally {
            if ($null -ne $candidate -and -not $owned) {
                $candidate.Dispose()
            }
        }
    }
    return $null
}

function Close-AgentBellPrewarmSlot {
    param([object]$Slot)

    if ($null -eq $Slot) {
        return
    }
    try {
        $Slot.ReleaseMutex()
    }
    catch {
        # Slot cleanup is best-effort during helper shutdown.
    }
    $Slot.Dispose()
}

$requestFile = $null
$prewarmSlot = $null
$waiterSlot = $null
try {
    $modulePath = Join-Path $PluginRoot "scripts\AgentBell.Core.psm1"
    Import-Module $modulePath -Force -DisableNameChecking

    $requestRoot = [System.IO.Path]::GetFullPath((Join-Path $DataDir "queue\prewarm")).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $requestFullPath = [System.IO.Path]::GetFullPath($RequestPath)
    $requestName = [System.IO.Path]::GetFileName($requestFullPath)
    if (-not $requestFullPath.StartsWith($requestRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $requestName -notmatch '^prewarm-[0-9a-f]{32}\.json$' -or
        -not (Test-Path -LiteralPath $requestFullPath -PathType Leaf)) {
        return
    }
    $requestFile = $requestFullPath

    $requestItem = Get-Item -LiteralPath $requestFullPath
    if ($requestItem.Length -le 0 -or $requestItem.Length -gt 8192) {
        return
    }
    $request = [System.IO.File]::ReadAllText($requestFullPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
    Remove-Item -LiteralPath $requestFullPath -Force -ErrorAction SilentlyContinue
    $requestFile = $null

    $sessionId = [string]$request.session_id
    $turnId = [string]$request.turn_id
    $threadSource = if ($null -ne $request.PSObject.Properties['thread_source']) { [string]$request.thread_source } else { 'unknown' }
    if ([int]$request.schema_version -ne 1 -or
        $sessionId -notmatch '^[0-9a-fA-F-]{36}$' -or
        [string]::IsNullOrWhiteSpace($turnId) -or
        $turnId.Length -gt 256 -or
        $threadSource -notin @('user', 'automation', 'subagent', 'unknown')) {
        return
    }
    foreach ($character in $turnId.ToCharArray()) {
        if ([char]::IsControl($character)) {
            return
        }
    }

    $waiterSlot = Enter-AgentBellPrewarmSlot -SlotNames @(Get-AgentBellPrewarmWaiterSlotNames -DataDir $DataDir)
    if ($null -eq $waiterSlot) {
        return
    }

    $statePath = Join-Path $DataDir "state\state.json"
    $turnKey = "$sessionId|$turnId"
    $configPath = Join-Path $DataDir "config.json"
    $title = $null
    $titleLookupDelays = @([int]0)
    if ($TitleRetryDelaySeconds -gt 0) {
        $titleLookupDelays += $TitleRetryDelaySeconds
    }
    foreach ($titleLookupDelay in $titleLookupDelays) {
        if ($titleLookupDelay -gt 0) {
            Start-Sleep -Seconds $titleLookupDelay
        }

        $config = Get-AgentBellConfig -Path $configPath
        if (-not [bool]$config.enabled -or [string]$config.voice.provider -ne 'http') {
            return
        }
        if ($threadSource -eq 'automation' -and [string]$config.notifications.automation_runs -eq 'none') {
            return
        }

        $state = Get-AgentBellState -Path $statePath
        if (-not (Test-AgentBellTurnActive -State $state -Key $turnKey)) {
            return
        }

        $title = Get-AgentBellRealConversationTitle `
            -CodexHome $CodexHome `
            -SessionId $sessionId `
            -MaxCharacters ([int]$config.max_title_characters)
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        return
    }

    $state = Get-AgentBellState -Path $statePath
    if (-not (Test-AgentBellTurnActive -State $state -Key $turnKey)) {
        return
    }

    $injectedSnapshots = @()
    if ($null -ne $ResourceSnapshot) {
        $injectedSnapshots = @($ResourceSnapshot)
    }
    $resourceRetrySchedule = @([int]0) + @($ResourceRetryDelaysSeconds)
    $resourceDecision = $null
    $lastResourceAttempt = 0
    for ($resourceIndex = 0; $resourceIndex -lt $resourceRetrySchedule.Count; $resourceIndex++) {
        $resourceDelay = [int]$resourceRetrySchedule[$resourceIndex]
        if ($resourceDelay -gt 0) {
            Start-Sleep -Seconds $resourceDelay
        }

        $config = Get-AgentBellConfig -Path $configPath
        if (-not [bool]$config.enabled -or [string]$config.voice.provider -ne 'http') {
            return
        }
        if ($threadSource -eq 'automation' -and [string]$config.notifications.automation_runs -eq 'none') {
            return
        }
        $state = Get-AgentBellState -Path $statePath
        if (-not (Test-AgentBellTurnActive -State $state -Key $turnKey)) {
            return
        }

        $slotDeadline = [DateTimeOffset]::UtcNow.AddSeconds(3)
        do {
            $prewarmSlot = Enter-AgentBellPrewarmSlot -SlotNames @(Get-AgentBellPrewarmSlotNames -DataDir $DataDir)
            if ($null -eq $prewarmSlot -and [DateTimeOffset]::UtcNow -lt $slotDeadline) {
                Start-Sleep -Milliseconds 250
            }
        } while ($null -eq $prewarmSlot -and [DateTimeOffset]::UtcNow -lt $slotDeadline)

        if ($null -eq $prewarmSlot) {
            $resourceDecision = [pscustomobject][ordered]@{ allowed = $false; reason = "helper_busy" }
            $lastResourceAttempt = $resourceIndex + 1
            continue
        }

        $snapshot = if ($injectedSnapshots.Count -gt 0) {
            $injectedSnapshots[[Math]::Min($resourceIndex, $injectedSnapshots.Count - 1)]
        }
        else {
            Get-AgentBellResourceSnapshot
        }
        $resourceDecision = Get-AgentBellPrewarmResourceDecision -Snapshot $snapshot
        $lastResourceAttempt = $resourceIndex + 1
        if ([bool]$resourceDecision.allowed) {
            break
        }
        Close-AgentBellPrewarmSlot -Slot $prewarmSlot
        $prewarmSlot = $null
    }
    if (-not [bool]$resourceDecision.allowed) {
        Write-AgentBellLog `
            -Path (Join-Path $DataDir "logs\agent-bell.jsonl") `
            -Level "info" `
            -Message "Skipped custom voice prewarm" `
            -Data @{ reason = [string]$resourceDecision.reason; attempt = $lastResourceAttempt } `
            -MaxBytes ([int64]$config.limits.log_bytes)
        return
    }

    $config = Get-AgentBellConfig -Path $configPath
    if (-not [bool]$config.enabled -or [string]$config.voice.provider -ne 'http') {
        return
    }
    if ($threadSource -eq 'automation' -and [string]$config.notifications.automation_runs -eq 'none') {
        return
    }
    $state = Get-AgentBellState -Path $statePath
    if (-not (Test-AgentBellTurnActive -State $state -Key $turnKey)) {
        return
    }

    $title = Get-AgentBellRealConversationTitle `
        -CodexHome $CodexHome `
        -SessionId $sessionId `
        -MaxCharacters ([int]$config.max_title_characters)
    if ([string]::IsNullOrWhiteSpace($title)) {
        return
    }
    $state = Get-AgentBellState -Path $statePath
    if (-not (Test-AgentBellTurnActive -State $state -Key $turnKey)) {
        return
    }

    $announcement = Get-AgentBellAnnouncement -Kind 'complete' -Title $title -Config $config
    $accepted = Invoke-AgentBellHttpPrewarm -Message $announcement -Config $config
    Write-AgentBellLog `
        -Path (Join-Path $DataDir "logs\agent-bell.jsonl") `
        -Level "info" `
        -Message "Requested custom voice prewarm" `
        -Data @{ status = $(if ($accepted) { "accepted" } else { "rejected" }); attempt = $lastResourceAttempt } `
        -MaxBytes ([int64]$config.limits.log_bytes)
}
catch {
    # Prewarming is best-effort and must never affect Codex or the main worker.
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($requestFile)) {
        Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $prewarmSlot) {
        Close-AgentBellPrewarmSlot -Slot $prewarmSlot
    }
    if ($null -ne $waiterSlot) {
        Close-AgentBellPrewarmSlot -Slot $waiterSlot
    }
}

exit 0
