[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DataDir,
    [Parameter(Mandatory = $true)][string]$PluginRoot,
    [string]$CodexHome,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PluginRoot "scripts\AgentBell.Core.psm1"
Import-Module $modulePath -Force -DisableNameChecking

$pendingDirectory = Join-Path $DataDir "queue\pending"
$processingDirectory = Join-Path $DataDir "queue\processing"
$failedDirectory = Join-Path $DataDir "queue\failed"
$prewarmDirectory = Join-Path $DataDir "queue\prewarm"
$statePath = Join-Path $DataDir "state\state.json"
$configPath = Join-Path $DataDir "config.json"
$logPath = Join-Path $DataDir "logs\agent-bell.jsonl"
$cacheDirectory = Join-Path $DataDir "cache"
$prewarmCandidates = @()
$prewarmLaunchLimit = 2
$config = $null
$state = $null

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
}

function Remove-AgentBellStaleQueueFiles {
    param(
        [string]$Directory,
        [int]$MaxEntries,
        [DateTime]$Cutoff
    )

    $files = @(Get-ChildItem -LiteralPath $Directory -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    for ($index = 0; $index -lt $files.Count; $index++) {
        if ($index -ge $MaxEntries -or $files[$index].LastWriteTimeUtc -lt $Cutoff) {
            Remove-Item -LiteralPath $files[$index].FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AgentBellLaterSessionActivity {
    param(
        [string]$PendingDirectory,
        [string]$SessionId,
        [DateTimeOffset]$CapturedAt,
        [string]$TurnId,
        [switch]$SameTurnOnly
    )

    $earliestAt = $null
    $activity = $null
    foreach ($file in @(Get-ChildItem -LiteralPath $PendingDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $candidate = [System.IO.File]::ReadAllText($file.FullName, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
            $candidateAt = [DateTimeOffset]::Parse([string]$candidate.captured_at)
            $sameTurn = [string]$candidate.turn_id -eq $TurnId
            if ([string]$candidate.session_id -eq $SessionId -and
                (-not $SameTurnOnly.IsPresent -or $sameTurn) -and
                $candidateAt -gt $CapturedAt -and
                ($null -eq $earliestAt -or $candidateAt -lt $earliestAt)) {
                $earliestAt = $candidateAt
                $activity = if ($sameTurn) { "same-turn" } else { "different-turn" }
            }
        }
        catch {
            # The normal queue pass will quarantine malformed events.
        }
    }
    return $activity
}

foreach ($directory in @($pendingDirectory, $processingDirectory, $failedDirectory, $prewarmDirectory, (Split-Path -Parent $statePath), (Split-Path -Parent $logPath), $cacheDirectory)) {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
}

$mutexName = "Local\AgentBellVoiceWorker-" + (Get-AgentBellHash -Value ([System.IO.Path]::GetFullPath($DataDir))).Substring(0, 16)
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$lockTaken = $false

try {
    try {
        $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(3))
    }
    catch [System.Threading.AbandonedMutexException] {
        $lockTaken = $true
    }
    if (-not $lockTaken) {
        exit 0
    }

    $config = Get-AgentBellConfig -Path $configPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-AgentBellJsonAtomic -Path $configPath -Value $config
    }
    $state = Get-AgentBellState -Path $statePath

    # Once this worker owns the mutex, any file left in processing is orphaned
    # from a crashed or interrupted earlier worker and is safe to retry.
    foreach ($orphan in @(Get-ChildItem -LiteralPath $processingDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $recoveryName = "recovered-" + [Guid]::NewGuid().ToString("N") + ".json"
        Move-Item -LiteralPath $orphan.FullName -Destination (Join-Path $pendingDirectory $recoveryName) -Force -ErrorAction SilentlyContinue
    }
    $queueCutoff = [DateTime]::UtcNow.AddHours(-1 * [int]$config.limits.queue_ttl_hours)
    Remove-AgentBellStaleQueueFiles -Directory $pendingDirectory -MaxEntries ([int]$config.limits.queue_entries) -Cutoff $queueCutoff
    Remove-AgentBellStaleQueueFiles -Directory $failedDirectory -MaxEntries ([int]$config.limits.failed_entries) -Cutoff $queueCutoff
    Remove-AgentBellStaleQueueFiles -Directory $prewarmDirectory -MaxEntries ([int]$config.limits.queue_entries) -Cutoff $queueCutoff

    $emptyChecks = 0

    while ($emptyChecks -lt 2) {
        $pendingFiles = @(Get-ChildItem -LiteralPath $pendingDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($pendingFiles.Count -eq 0) {
            $emptyChecks++
            Start-Sleep -Milliseconds 300
            continue
        }
        $emptyChecks = 0

        foreach ($pendingFile in $pendingFiles) {
            $processingPath = Join-Path $processingDirectory $pendingFile.Name
            $event = $null
            try {
                Move-Item -LiteralPath $pendingFile.FullName -Destination $processingPath -Force
                $event = [System.IO.File]::ReadAllText($processingPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json

                $turnKey = ([string]$event.session_id + "|" + [string]$event.turn_id)
                if ([string]$event.kind -eq "start") {
                    $state = Set-AgentBellTurnStart -State $state -Key $turnKey -CapturedAt ([string]$event.captured_at) -MaxEntries ([int]$config.limits.state_entries)
                    Write-AgentBellJsonAtomic -Path $statePath -Value $state
                    if (Test-AgentBellShouldPrewarm -Event $event -Config $config -DryRun $DryRun.IsPresent) {
                        $prewarmCandidates += [pscustomobject]@{
                            key = $turnKey
                            session_id = [string]$event.session_id
                            turn_id = [string]$event.turn_id
                            thread_source = if ($null -ne $event.PSObject.Properties['thread_source']) { [string]$event.thread_source } else { 'unknown' }
                        }
                    }
                    Remove-Item -LiteralPath $processingPath -Force
                    continue
                }

                if ([string]$event.event -eq "Stop") {
                    $duration = Get-AgentBellEventDurationSeconds -Event $event -State $state -Key $turnKey -StoppedAt ([string]$event.captured_at)
                    Write-AgentBellJsonAtomic -Path $processingPath -Value $event
                }
                else {
                    $duration = Get-AgentBellTurnDurationSeconds -State $state -Key $turnKey -StoppedAt ([string]$event.captured_at)
                }

                if (Test-AgentBellHandled -State $state -Key ([string]$event.dedupe_key)) {
                    Write-AgentBellLog -Path $logPath -Level "info" -Message "Skipped duplicate event." -Data @{ event = [string]$event.kind } -MaxBytes ([int]$config.limits.log_bytes)
                    Remove-Item -LiteralPath $processingPath -Force
                    continue
                }

                $threadSourceProperty = $event.PSObject.Properties["thread_source"]
                $threadSource = if ($null -ne $threadSourceProperty) { [string]$threadSourceProperty.Value } else { "unknown" }
                if ([string]$config.notifications.automation_runs -eq "none" -and $threadSource -eq "automation") {
                    if ([string]$event.event -eq "Stop") {
                        $state = Remove-AgentBellTurnStart -State $state -Key $turnKey
                    }
                    $state = Add-AgentBellHandled -State $state -Key ([string]$event.dedupe_key) -MaxEntries ([int]$config.limits.state_entries)
                    Write-AgentBellJsonAtomic -Path $statePath -Value $state
                    Write-AgentBellLog -Path $logPath -Level "info" -Message "Suppressed an automation event." -Data @{
                        event = [string]$event.kind
                        decision = "suppressed"
                        reason = "automation"
                    } -MaxBytes ([int]$config.limits.log_bytes)
                    Remove-Item -LiteralPath $processingPath -Force
                    continue
                }

                if ([string]$event.kind -in @("complete", "failure")) {
                    $debounceSeconds = [int]$config.stop_debounce_seconds
                    if ($debounceSeconds -gt 0) {
                        $waitMilliseconds = Get-AgentBellDebounceWaitMilliseconds `
                            -CapturedAt ([string]$event.captured_at) `
                            -DebounceSeconds $debounceSeconds
                        if ($waitMilliseconds -gt 0) {
                            Start-Sleep -Milliseconds $waitMilliseconds
                        }
                    }
                    $capturedAt = [DateTimeOffset]::Parse([string]$event.captured_at)
                    $laterActivity = Get-AgentBellLaterSessionActivity `
                        -PendingDirectory $pendingDirectory `
                        -SessionId ([string]$event.session_id) `
                        -CapturedAt $capturedAt `
                        -TurnId ([string]$event.turn_id) `
                        -SameTurnOnly:($debounceSeconds -le 0)
                    if ($null -ne $laterActivity) {
                        if ($laterActivity -eq "different-turn") {
                            $state = Remove-AgentBellTurnStart -State $state -Key $turnKey
                            $state = Add-AgentBellHandled -State $state -Key ([string]$event.dedupe_key) -MaxEntries ([int]$config.limits.state_entries)
                            Write-AgentBellJsonAtomic -Path $statePath -Value $state
                        }
                        Write-AgentBellLog -Path $logPath -Level "info" -Message "Suppressed a Stop candidate after later session activity." -Data @{ event = [string]$event.kind; decision = "suppressed" } -MaxBytes ([int]$config.limits.log_bytes)
                        Remove-Item -LiteralPath $processingPath -Force
                        continue
                    }
                }

                if ([string]$event.event -eq "Stop") {
                    $state = Remove-AgentBellTurnStart -State $state -Key $turnKey
                    Write-AgentBellJsonAtomic -Path $statePath -Value $state
                }

                $title = Get-AgentBellConversationTitle -CodexHome $CodexHome -SessionId ([string]$event.session_id) -Cwd ([string]$event.cwd) -MaxCharacters ([int]$config.max_title_characters)
                $idleSeconds = try { Get-AgentBellIdleSeconds } catch { 0 }
                $decision = Get-AgentBellDecision -Kind ([string]$event.kind) -DurationSeconds $duration -IdleSeconds $idleSeconds -Config $config
                $announcement = Get-AgentBellAnnouncement -Kind ([string]$event.kind) -Title $title -Config $config

                $provider = "none"
                if (-not $DryRun.IsPresent) {
                    if ($decision -eq "speak") {
                        if ([string]$event.kind -eq "complete" -and [string]$config.voice.provider -eq "http") {
                            $provider = Invoke-AgentBellHttpCompletion -Message $announcement -Config $config -CacheDirectory $cacheDirectory
                        }
                        else {
                            $provider = Invoke-AgentBellSpeech -Message $announcement -Config $config -CacheDirectory $cacheDirectory
                        }
                    }
                    elseif ($decision -eq "notify" -and [string]$config.notifications.short_active_turn -eq "toast") {
                        Show-AgentBellNotification -Title "Agent Bell" -Message $announcement
                        $provider = "toast"
                    }
                }
                else {
                    $provider = "dry-run"
                }

                $state = Add-AgentBellHandled -State $state -Key ([string]$event.dedupe_key) -MaxEntries ([int]$config.limits.state_entries)
                Write-AgentBellJsonAtomic -Path $statePath -Value $state
                Write-AgentBellLog -Path $logPath -Level "info" -Message "Processed attention event." -Data @{
                    event = [string]$event.kind
                    decision = $decision
                    provider = $provider
                    duration_seconds = $duration
                    idle_seconds = [Math]::Round($idleSeconds, 1)
                } -MaxBytes ([int]$config.limits.log_bytes)
                Remove-Item -LiteralPath $processingPath -Force
            }
            catch {
                Write-AgentBellLog -Path $logPath -Level "error" -Message "Worker event failed." -Data @{
                    error_type = $_.Exception.GetType().Name
                } -MaxBytes ([int]$config.limits.log_bytes)
                if (Test-Path -LiteralPath $processingPath) {
                    if ($null -ne $event) {
                        $attemptProperty = $event.PSObject.Properties["attempt"]
                        $attempt = if ($null -ne $attemptProperty) { [int]$attemptProperty.Value + 1 } else { 1 }
                        if ($null -eq $attemptProperty) {
                            $event | Add-Member -MemberType NoteProperty -Name "attempt" -Value $attempt
                        }
                        else {
                            $event.attempt = $attempt
                        }
                        if ($attempt -le 2) {
                            $retryPath = Join-Path $pendingDirectory ("retry-$attempt-" + [Guid]::NewGuid().ToString("N") + ".json")
                            Write-AgentBellJsonAtomic -Path $retryPath -Value $event
                            Remove-Item -LiteralPath $processingPath -Force -ErrorAction SilentlyContinue
                            continue
                        }
                    }
                    $failedPath = Join-Path $failedDirectory ((Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmssfff") + "-" + [Guid]::NewGuid().ToString("N") + ".json")
                    Move-Item -LiteralPath $processingPath -Destination $failedPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
catch {
    Write-AgentBellLog -Path $logPath -Level "error" -Message "Worker failed." -Data @{
        error_type = $_.Exception.GetType().Name
    }
}
finally {
    if ($lockTaken) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}

if ($null -ne $config -and $null -ne $state -and $prewarmCandidates.Count -gt 0) {
    $prewarmScript = Join-Path $PluginRoot "scripts\prewarm.ps1"
    $launched = @{}
    foreach ($candidate in $prewarmCandidates) {
        if ($launched.Count -ge $prewarmLaunchLimit) {
            break
        }
        if ($launched.ContainsKey([string]$candidate.key) -or -not (Test-AgentBellTurnActive -State $state -Key ([string]$candidate.key))) {
            continue
        }
        $launched[[string]$candidate.key] = $true
        [System.IO.Directory]::CreateDirectory($prewarmDirectory) | Out-Null
        $requestPath = Join-Path $prewarmDirectory ("prewarm-" + [Guid]::NewGuid().ToString("N") + ".json")
        $request = [pscustomobject][ordered]@{
            schema_version = 1
            session_id = [string]$candidate.session_id
            turn_id = [string]$candidate.turn_id
            thread_source = [string]$candidate.thread_source
        }
        try {
            Write-AgentBellJsonAtomic -Path $requestPath -Value $request
            $arguments = @(
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy", "Bypass",
                "-File", ('"' + $prewarmScript + '"'),
                "-PluginRoot", ('"' + $PluginRoot + '"'),
                "-DataDir", ('"' + $DataDir + '"'),
                "-CodexHome", ('"' + $CodexHome + '"'),
                "-RequestPath", ('"' + $requestPath + '"')
            )
            Start-Process -FilePath "powershell.exe" -ArgumentList ($arguments -join " ") -WindowStyle Hidden | Out-Null
        }
        catch {
            Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
            Write-AgentBellLog -Path $logPath -Level "error" -Message "Prewarm process failed to launch." -Data @{
                error_type = $_.Exception.GetType().Name
            } -MaxBytes ([int]$config.limits.log_bytes)
        }
    }
}

exit 0
