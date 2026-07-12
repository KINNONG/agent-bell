Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-AgentBellProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Get-AgentBellDefaultConfig {
    return [pscustomobject][ordered]@{
        schema_version = 1
        enabled = $true
        mode = "smart"
        duration_threshold_seconds = 60
        idle_threshold_seconds = 45
        stop_debounce_seconds = 15
        max_title_characters = 60
        templates = [pscustomobject][ordered]@{
            complete = "主人，{title} 任务已完成，请回来查看了。"
            permission = "主人，{title} 正在等待您的确认，请回来处理。"
            failure = "主人，{title} 执行遇到问题，请回来查看。"
        }
        voice = [pscustomobject][ordered]@{
            provider = "sapi"
            fallback_provider = "sapi"
            sapi_voice = "Microsoft Huihui Desktop"
            rate = 0
            volume = 100
            http = [pscustomobject][ordered]@{
                endpoint = "http://127.0.0.1:17863/synthesize"
                timeout_seconds = 60
                voice_id = "default"
            }
        }
        notifications = [pscustomobject][ordered]@{
            short_active_turn = "toast"
        }
        limits = [pscustomobject][ordered]@{
            state_entries = 500
            log_bytes = 1048576
            queue_entries = 500
            queue_ttl_hours = 168
            failed_entries = 100
            max_wav_bytes = 26214400
        }
    }
}

function Merge-AgentBellObject {
    param(
        [Parameter(Mandatory = $true)][object]$Base,
        [object]$Override
    )

    $result = [ordered]@{}
    foreach ($property in $Base.PSObject.Properties) {
        $overrideProperty = if ($null -ne $Override) {
            $Override.PSObject.Properties[$property.Name]
        }
        else {
            $null
        }

        if ($null -eq $overrideProperty -or $null -eq $overrideProperty.Value) {
            $result[$property.Name] = $property.Value
            continue
        }

        $baseValue = $property.Value
        $overrideValue = $overrideProperty.Value
        if ($baseValue -is [pscustomobject] -and $overrideValue -is [pscustomobject]) {
            $result[$property.Name] = Merge-AgentBellObject -Base $baseValue -Override $overrideValue
        }
        else {
            $result[$property.Name] = $overrideValue
        }
    }

    return [pscustomobject]$result
}

function Get-AgentBellConfig {
    param([string]$Path)

    $defaults = Get-AgentBellDefaultConfig
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $defaults
    }

    try {
        $override = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom) | ConvertFrom-Json
        $config = Merge-AgentBellObject -Base $defaults -Override $override
    }
    catch {
        throw "Agent Bell config is invalid: $($_.Exception.Message)"
    }

    if ([int]$config.schema_version -ne 1) {
        throw "Agent Bell config schema_version must be 1."
    }
    if ([string]$config.mode -notin @("smart", "always", "threshold")) {
        throw "Agent Bell mode must be smart, always, or threshold."
    }
    if ([int]$config.duration_threshold_seconds -lt 0 -or [int]$config.duration_threshold_seconds -gt 86400 -or
        [int]$config.idle_threshold_seconds -lt 0 -or [int]$config.idle_threshold_seconds -gt 86400) {
        throw "Agent Bell duration and idle thresholds must be between 0 and 86400 seconds."
    }
    if ([int]$config.stop_debounce_seconds -lt 0 -or [int]$config.stop_debounce_seconds -gt 120) {
        throw "Agent Bell stop_debounce_seconds must be between 0 and 120."
    }
    if ([int]$config.max_title_characters -lt 8 -or [int]$config.max_title_characters -gt 120) {
        throw "Agent Bell max_title_characters must be between 8 and 120."
    }
    if ([string]$config.voice.provider -notin @("sapi", "http") -or
        [string]$config.voice.fallback_provider -notin @("sapi", "none")) {
        throw "Agent Bell voice providers are invalid."
    }
    if ([int]$config.voice.rate -lt -10 -or [int]$config.voice.rate -gt 10 -or
        [int]$config.voice.volume -lt 0 -or [int]$config.voice.volume -gt 100) {
        throw "Agent Bell SAPI rate or volume is outside the supported range."
    }
    if ([int]$config.voice.http.timeout_seconds -lt 1 -or [int]$config.voice.http.timeout_seconds -gt 300) {
        throw "Agent Bell HTTP timeout_seconds must be between 1 and 300."
    }
    if ([string]$config.voice.http.voice_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Agent Bell HTTP voice_id is invalid."
    }
    if ([string]$config.notifications.short_active_turn -notin @("toast", "none")) {
        throw "Agent Bell short_active_turn must be toast or none."
    }
    if ([int]$config.limits.state_entries -lt 1 -or [int]$config.limits.state_entries -gt 10000 -or
        [int]$config.limits.queue_entries -lt 1 -or [int]$config.limits.queue_entries -gt 10000 -or
        [int]$config.limits.failed_entries -lt 1 -or [int]$config.limits.failed_entries -gt 10000) {
        throw "Agent Bell state and queue entry limits must be between 1 and 10000."
    }
    if ([int]$config.limits.queue_ttl_hours -lt 1 -or [int]$config.limits.queue_ttl_hours -gt 8760) {
        throw "Agent Bell queue_ttl_hours must be between 1 and 8760."
    }
    if ([int64]$config.limits.log_bytes -lt 4096 -or [int64]$config.limits.log_bytes -gt 104857600 -or
        [int64]$config.limits.max_wav_bytes -lt 44 -or [int64]$config.limits.max_wav_bytes -gt 104857600) {
        throw "Agent Bell byte limits are outside the supported range."
    }

    return $config
}

function Write-AgentBellJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [int]$Depth = 8
    )

    $directory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
    }
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null

    $temporaryPath = Join-Path $directory ("." + [System.IO.Path]::GetFileName($Path) + "." + [Guid]::NewGuid().ToString("N") + ".tmp")
    try {
        $json = $Value | ConvertTo-Json -Depth $Depth
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $script:Utf8NoBom)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AgentBellHash {
    param([string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertTo-AgentBellSafeLogData {
    param([hashtable]$Data = @{})

    $allowed = @(
        "event", "status", "action", "kind", "decision", "provider", "reason", "duration_seconds",
        "idle_seconds", "queue_size", "error_type", "attempt", "count"
    )
    $safe = [ordered]@{}
    foreach ($key in $allowed) {
        if ($Data.ContainsKey($key)) {
            $safe[$key] = $Data[$key]
        }
    }
    return [pscustomobject]$safe
}

function Write-AgentBellLog {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message,
        [hashtable]$Data = @{},
        [int]$MaxBytes = 1048576
    )

    try {
        $directory = Split-Path -Parent $Path
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null

        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge $MaxBytes) {
            $rotatedPath = "$Path.1"
            Remove-Item -LiteralPath $rotatedPath -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $Path -Destination $rotatedPath -Force
        }

        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString("o")
            level = $Level
            message = $Message
            data = ConvertTo-AgentBellSafeLogData -Data $Data
        }
        $line = $entry | ConvertTo-Json -Compress -Depth 5
        [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, $script:Utf8NoBom)
    }
    catch {
        # Logging must never affect Codex or speech behavior.
    }
}

function Normalize-AgentBellTitle {
    param(
        [string]$Title,
        [int]$MaxCharacters = 60
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $null
    }

    $normalized = $Title -replace '[\x00-\x1F\x7F]', ' '
    $normalized = $normalized -replace '\s+', ' '
    $normalized = $normalized.Trim()
    if ($normalized.Length -gt $MaxCharacters) {
        $normalized = $normalized.Substring(0, $MaxCharacters - 3).TrimEnd() + "..."
    }
    return $normalized
}

function ConvertTo-AgentBellTitle {
    param(
        [string]$Title,
        [int]$MaxLength = 60,
        [string]$FallbackTitle = "当前 Codex 会话"
    )

    $normalized = Normalize-AgentBellTitle -Title $Title -MaxCharacters $MaxLength
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return Normalize-AgentBellTitle -Title $FallbackTitle -MaxCharacters $MaxLength
    }
    return $normalized
}

function Get-AgentBellSqliteTitle {
    param(
        [string]$CodexHome,
        [string]$SessionId,
        [int]$MaxCharacters = 60
    )

    if ($SessionId -notmatch '^[0-9a-fA-F-]{36}$') {
        return $null
    }
    $sqlite = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($null -eq $sqlite) {
        return $null
    }
    $database = Get-ChildItem -LiteralPath $CodexHome -Filter "state_*.sqlite" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $database) {
        return $null
    }

    try {
        $query = "SELECT title FROM threads WHERE id = '$SessionId' LIMIT 1;"
        $lines = & $sqlite.Source -json $database.FullName $query 2>$null
        if ($LASTEXITCODE -ne 0 -or $null -eq $lines) {
            return $null
        }
        $row = (@($lines) -join [Environment]::NewLine) | ConvertFrom-Json | Select-Object -First 1
        return Normalize-AgentBellTitle -Title ([string](Get-AgentBellProperty -Object $row -Name "title")) -MaxCharacters $MaxCharacters
    }
    catch {
        return $null
    }
}

function Get-AgentBellConversationTitle {
    param(
        [string]$CodexHome,
        [string]$SessionId,
        [string]$Cwd,
        [string]$SessionIndexPath,
        [Alias("MaxLength")][int]$MaxCharacters = 60,
        [string]$FallbackTitle = "当前 Codex 会话"
    )

    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $CodexHome = if (-not [string]::IsNullOrWhiteSpace($SessionIndexPath)) {
            Split-Path -Parent $SessionIndexPath
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $env:CODEX_HOME
        }
        else {
            Join-Path $HOME ".codex"
        }
    }
    $indexPath = if (-not [string]::IsNullOrWhiteSpace($SessionIndexPath)) { $SessionIndexPath } else { Join-Path $CodexHome "session_index.jsonl" }
    if (Test-Path -LiteralPath $indexPath) {
        try {
            $latest = $null
            foreach ($line in [System.IO.File]::ReadAllLines($indexPath, $script:Utf8NoBom)) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }
                try {
                    $row = $line | ConvertFrom-Json
                    if ([string](Get-AgentBellProperty -Object $row -Name "id") -eq $SessionId) {
                        $latest = [string](Get-AgentBellProperty -Object $row -Name "thread_name")
                    }
                }
                catch {
                    # A concurrently written final line is safe to ignore.
                }
            }
            $title = Normalize-AgentBellTitle -Title $latest -MaxCharacters $MaxCharacters
            if (-not [string]::IsNullOrWhiteSpace($title)) {
                return $title
            }
        }
        catch {
            # Continue to stable fallbacks.
        }
    }

    $sqliteTitle = Get-AgentBellSqliteTitle -CodexHome $CodexHome -SessionId $SessionId -MaxCharacters $MaxCharacters
    if (-not [string]::IsNullOrWhiteSpace($sqliteTitle)) {
        return $sqliteTitle
    }

    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        try {
            $cwdTitle = Normalize-AgentBellTitle -Title ([System.IO.DirectoryInfo]$Cwd).Name -MaxCharacters $MaxCharacters
            if (-not [string]::IsNullOrWhiteSpace($cwdTitle)) {
                return $cwdTitle
            }
        }
        catch {
            # Use the generic title below.
        }
    }

    return ConvertTo-AgentBellTitle -Title $null -MaxLength $MaxCharacters -FallbackTitle $FallbackTitle
}

function Test-AgentBellFailureMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    $trimmed = $Message.Trim()
    $patterns = @(
        '^(API Error|Fatal Error|Fatal:|Execution failed|Task failed)\b',
        '^(任务失败|任务执行失败|执行失败|操作失败|无法完成|未能完成)',
        '^(抱歉[，,]\s*)?(任务|执行|操作).*(失败|无法完成|未能完成)',
        '\b(I could not|I couldn''t|I was unable to) complete\b'
    )
    foreach ($pattern in $patterns) {
        if ($trimmed -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-AgentBellExplicitFailure {
    param([string]$Message)
    return Test-AgentBellFailureMessage -Message $Message
}

function ConvertTo-AgentBellEvent {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [DateTimeOffset]$CapturedAt = [DateTimeOffset]::UtcNow
    )

    $eventName = [string](Get-AgentBellProperty -Object $Payload -Name "hook_event_name")
    if ($eventName -notin @("UserPromptSubmit", "PermissionRequest", "Stop")) {
        throw "Unsupported Codex hook event: $eventName"
    }

    $sessionId = [string](Get-AgentBellProperty -Object $Payload -Name "session_id")
    $turnId = [string](Get-AgentBellProperty -Object $Payload -Name "turn_id" -Default "unknown-turn")
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw "The hook payload did not include session_id."
    }
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        $turnId = "unknown-turn"
    }

    $kind = switch ($eventName) {
        "UserPromptSubmit" { "start" }
        "PermissionRequest" { "permission" }
        "Stop" {
            $lastMessage = [string](Get-AgentBellProperty -Object $Payload -Name "last_assistant_message")
            if (Test-AgentBellFailureMessage -Message $lastMessage) { "failure" } else { "complete" }
        }
    }

    $toolName = [string](Get-AgentBellProperty -Object $Payload -Name "tool_name")
    $stopHookActive = (Get-AgentBellProperty -Object $Payload -Name "stop_hook_active" -Default $false) -eq $true
    $fingerprintInput = ""
    if ($eventName -eq "PermissionRequest") {
        $toolInput = Get-AgentBellProperty -Object $Payload -Name "tool_input"
        if ($null -ne $toolInput) {
            $fingerprintInput = $toolInput | ConvertTo-Json -Compress -Depth 5
        }
    }
    $fingerprint = (Get-AgentBellHash -Value $fingerprintInput).Substring(0, 12)

    $dedupeSuffix = if ($eventName -eq "Stop") { [string]$stopHookActive } else { $fingerprint }
    return [pscustomobject][ordered]@{
        schema_version = 1
        event = $eventName
        kind = $kind
        session_id = $sessionId
        turn_id = $turnId
        cwd = [string](Get-AgentBellProperty -Object $Payload -Name "cwd")
        tool_name = $toolName
        stop_hook_active = $stopHookActive
        attempt = 0
        captured_at = $CapturedAt.ToString("o")
        dedupe_key = "$sessionId|$turnId|$kind|$toolName|$dedupeSuffix"
    }
}

function Get-AgentBellState {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        try {
            $state = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom) | ConvertFrom-Json
            if ($null -ne $state.PSObject.Properties["turns"] -and $null -ne $state.PSObject.Properties["handled"]) {
                return $state
            }
        }
        catch {
            # Return a clean state after corruption.
        }
    }

    return [pscustomobject][ordered]@{
        schema_version = 1
        turns = @()
        handled = @()
    }
}

function Set-AgentBellTurnStart {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Key,
        [string]$CapturedAt,
        [int]$MaxEntries = 500
    )

    $remaining = @($State.turns | Where-Object { [string]$_.key -ne $Key })
    $State.turns = @([pscustomobject]@{ key = $Key; started_at = $CapturedAt }) + $remaining
    if ($State.turns.Count -gt $MaxEntries) {
        $State.turns = @($State.turns | Select-Object -First $MaxEntries)
    }
    return $State
}

function Get-AgentBellTurnDurationSeconds {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Key,
        [string]$StoppedAt
    )

    $record = $State.turns | Where-Object { [string]$_.key -eq $Key } | Select-Object -First 1
    if ($null -eq $record) {
        return $null
    }
    try {
        $start = [DateTimeOffset]::Parse([string]$record.started_at)
        $stop = [DateTimeOffset]::Parse($StoppedAt)
        return [Math]::Max(0, [Math]::Round(($stop - $start).TotalSeconds, 3))
    }
    catch {
        return $null
    }
}

function Test-AgentBellHandled {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Key
    )
    return $null -ne ($State.handled | Where-Object { [string]$_.key -eq $Key } | Select-Object -First 1)
}

function Add-AgentBellHandled {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Key,
        [string]$HandledAt = [DateTimeOffset]::UtcNow.ToString("o"),
        [int]$MaxEntries = 500
    )

    $remaining = @($State.handled | Where-Object { [string]$_.key -ne $Key })
    $State.handled = @([pscustomobject]@{ key = $Key; handled_at = $HandledAt }) + $remaining
    if ($State.handled.Count -gt $MaxEntries) {
        $State.handled = @($State.handled | Select-Object -First $MaxEntries)
    }
    return $State
}

function Get-AgentBellDecision {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Nullable[double]]$DurationSeconds,
        [double]$IdleSeconds,
        [Parameter(Mandatory = $true)][object]$Config
    )

    if (-not [bool]$Config.enabled) {
        return "none"
    }
    if ($Kind -in @("permission", "failure")) {
        return "speak"
    }
    if ($Kind -ne "complete") {
        return "none"
    }

    switch ([string]$Config.mode) {
        "always" { return "speak" }
        "threshold" {
            if ($null -ne $DurationSeconds -and [double]$DurationSeconds -ge [double]$Config.duration_threshold_seconds) {
                return "speak"
            }
            return "notify"
        }
        default {
            $longTurn = $null -ne $DurationSeconds -and [double]$DurationSeconds -ge [double]$Config.duration_threshold_seconds
            $userAway = $IdleSeconds -ge [double]$Config.idle_threshold_seconds
            if ($longTurn -or $userAway) { return "speak" }
            return "notify"
        }
    }
}

function Get-AgentBellCompletionAction {
    param(
        [Nullable[double]]$DurationSeconds,
        [double]$IdleSeconds,
        [double]$DurationThresholdSeconds = 60,
        [double]$IdleThresholdSeconds = 45
    )

    if (($null -ne $DurationSeconds -and [double]$DurationSeconds -ge $DurationThresholdSeconds) -or $IdleSeconds -ge $IdleThresholdSeconds) {
        return "speak"
    }
    return "notify"
}

function Get-AgentBellAnnouncement {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Title,
        [object]$Config = (Get-AgentBellDefaultConfig)
    )

    $template = switch ($Kind) {
        "permission" { [string]$Config.templates.permission }
        "failure" { [string]$Config.templates.failure }
        default { [string]$Config.templates.complete }
    }
    return $template.Replace("{title}", $Title)
}

function New-AgentBellLogRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Data = @{}
    )

    return [pscustomobject][ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString("o")
        level = $Level
        event = $Event
        data = ConvertTo-AgentBellSafeLogData -Data $Data
    }
}

function Limit-AgentBellDedupeEntries {
    param(
        [object[]]$Entries = @(),
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [int]$MaxAgeSeconds = 604800,
        [int]$MaxEntries = 500
    )

    $cutoff = $Now.AddSeconds(-1 * $MaxAgeSeconds)
    $byKey = @{}
    foreach ($entry in @($Entries)) {
        try {
            $timestamp = [DateTimeOffset]::Parse([string]$entry.timestamp)
            if ($timestamp -lt $cutoff) {
                continue
            }
            $key = [string]$entry.key
            if ([string]::IsNullOrWhiteSpace($key)) {
                continue
            }
            if (-not $byKey.ContainsKey($key) -or $timestamp -gt $byKey[$key].parsed_timestamp) {
                $byKey[$key] = [pscustomobject]@{
                    key = $key
                    timestamp = [string]$entry.timestamp
                    parsed_timestamp = $timestamp
                }
            }
        }
        catch {
            # Ignore malformed historical entries.
        }
    }

    $ordered = @($byKey.Values | Sort-Object parsed_timestamp)
    if ($ordered.Count -gt $MaxEntries) {
        $ordered = @($ordered | Select-Object -Last $MaxEntries)
    }
    return @($ordered | ForEach-Object { [pscustomobject]@{ key = $_.key; timestamp = $_.timestamp } })
}

function Get-AgentBellIdleSeconds {
    if ($null -eq ("AgentBell.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace AgentBell {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [DllImport("kernel32.dll")]
        private static extern uint GetTickCount();

        public static double GetIdleSeconds() {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(info);
            if (!GetLastInputInfo(ref info)) return 0;
            return (GetTickCount() - info.dwTime) / 1000.0;
        }
    }
}
"@
    }
    return [AgentBell.NativeMethods]::GetIdleSeconds()
}

function Invoke-AgentBellSapi {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config
    )

    Add-Type -AssemblyName System.Speech
    $synthesizer = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $preferredName = [string]$Config.voice.sapi_voice
        $voices = $synthesizer.GetInstalledVoices()
        $preferred = $voices | Where-Object { $_.Enabled -and $_.VoiceInfo.Name -eq $preferredName } | Select-Object -First 1
        if ($null -eq $preferred) {
            $preferred = $voices | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -eq "zh-CN" } | Select-Object -First 1
        }
        if ($null -ne $preferred) {
            $synthesizer.SelectVoice($preferred.VoiceInfo.Name)
        }
        $synthesizer.Rate = [Math]::Max(-10, [Math]::Min(10, [int]$Config.voice.rate))
        $synthesizer.Volume = [Math]::Max(0, [Math]::Min(100, [int]$Config.voice.volume))
        $synthesizer.SetOutputToDefaultAudioDevice()
        $synthesizer.Speak($Message)
    }
    finally {
        $synthesizer.Dispose()
    }
}

function Invoke-AgentBellHttpVoice {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $endpoint = [string]$Config.voice.http.endpoint
    try {
        $uri = [Uri]$endpoint
    }
    catch {
        throw "The local voice endpoint is not a valid URI."
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "http") {
        throw "The local voice endpoint must use loopback HTTP."
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        throw "The local voice endpoint cannot include credentials."
    }
    $literalAddress = $null
    if ([System.Net.IPAddress]::TryParse($uri.DnsSafeHost, [ref]$literalAddress)) {
        if (-not [System.Net.IPAddress]::IsLoopback($literalAddress)) {
            throw "The local voice endpoint must use a loopback address."
        }
    }
    else {
        if (-not $uri.DnsSafeHost.Equals("localhost", [StringComparison]::OrdinalIgnoreCase)) {
            throw "The local voice endpoint host must be localhost or a literal loopback address."
        }
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($uri.DnsSafeHost))
        }
        catch {
            throw "The local voice endpoint host could not be resolved."
        }
        if ($addresses.Count -eq 0 -or @($addresses | Where-Object { -not [System.Net.IPAddress]::IsLoopback($_) }).Count -gt 0) {
            throw "The local voice endpoint must resolve only to loopback addresses."
        }
    }

    $timeoutMs = [Math]::Max(1000, [int]$Config.voice.http.timeout_seconds * 1000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    $maxWavBytes = [Math]::Max(44, [int64]$Config.limits.max_wav_bytes)
    $payload = [ordered]@{
        text = $Message
        voice_id = [string]$Config.voice.http.voice_id
    } | ConvertTo-Json -Compress
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = "POST"
    $request.ContentType = "application/json; charset=utf-8"
    $request.Accept = "audio/wav"
    $request.Timeout = $timeoutMs
    $request.ReadWriteTimeout = $timeoutMs
    $request.ContentLength = $payloadBytes.Length
    $request.AllowAutoRedirect = $false

    $requestStream = $request.GetRequestStream()
    try {
        $requestStream.Write($payloadBytes, 0, $payloadBytes.Length)
    }
    finally {
        $requestStream.Dispose()
    }

    $response = $request.GetResponse()
    try {
        $contentType = ([string]$response.ContentType).Split(';')[0].Trim().ToLowerInvariant()
        if ($contentType -notin @("audio/wav", "audio/x-wav", "audio/wave")) {
            throw "The local voice provider returned an unexpected content type."
        }
        if ($response.ContentLength -gt $maxWavBytes) {
            throw "The local voice provider returned a WAV larger than the configured limit."
        }
        $responseStream = $response.GetResponseStream()
        try {
            $fileStream = [System.IO.File]::Create($OutputPath)
            try {
                $buffer = New-Object byte[] 65536
                [int64]$totalBytes = 0
                while ($true) {
                    $remainingMs = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                    if ($remainingMs -le 0) {
                        throw "The local voice provider exceeded the configured total timeout."
                    }
                    if ($responseStream.CanTimeout) {
                        $responseStream.ReadTimeout = $remainingMs
                    }
                    $read = $responseStream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) {
                        break
                    }
                    $totalBytes += $read
                    if ($totalBytes -gt $maxWavBytes) {
                        throw "The local voice provider exceeded the configured WAV size limit."
                    }
                    $fileStream.Write($buffer, 0, $read)
                }
            }
            finally {
                $fileStream.Dispose()
            }
        }
        finally {
            $responseStream.Dispose()
        }
    }
    finally {
        $response.Dispose()
    }

    if (-not (Test-Path -LiteralPath $OutputPath) -or (Get-Item -LiteralPath $OutputPath).Length -lt 44) {
        throw "The local voice provider did not return a valid WAV payload."
    }

    $player = New-Object System.Media.SoundPlayer $OutputPath
    try {
        $player.PlaySync()
    }
    finally {
        $player.Dispose()
    }
}

function Invoke-AgentBellSpeech {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$CacheDirectory
    )

    if ([string]$Config.voice.provider -eq "http") {
        [System.IO.Directory]::CreateDirectory($CacheDirectory) | Out-Null
        $wavPath = Join-Path $CacheDirectory ("speech-" + [Guid]::NewGuid().ToString("N") + ".wav")
        try {
            Invoke-AgentBellHttpVoice -Message $Message -Config $Config -OutputPath $wavPath
            return "http"
        }
        catch {
            if ([string]$Config.voice.fallback_provider -ne "sapi") {
                throw
            }
        }
        finally {
            Remove-Item -LiteralPath $wavPath -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-AgentBellSapi -Message $Message -Config $Config
    return "sapi"
}

function Show-AgentBellNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $notification = New-Object System.Windows.Forms.NotifyIcon
    try {
        $notification.Icon = [System.Drawing.SystemIcons]::Information
        $notification.Visible = $true
        $notification.BalloonTipTitle = $Title
        $notification.BalloonTipText = $Message
        $notification.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notification.ShowBalloonTip(5000)
        Start-Sleep -Milliseconds 1500
    }
    finally {
        $notification.Visible = $false
        $notification.Dispose()
    }
}

Export-ModuleMember -Function @(
    "Get-AgentBellDefaultConfig",
    "Get-AgentBellConfig",
    "Write-AgentBellJsonAtomic",
    "Get-AgentBellHash",
    "ConvertTo-AgentBellSafeLogData",
    "Write-AgentBellLog",
    "Normalize-AgentBellTitle",
    "ConvertTo-AgentBellTitle",
    "Get-AgentBellConversationTitle",
    "Test-AgentBellFailureMessage",
    "Test-AgentBellExplicitFailure",
    "ConvertTo-AgentBellEvent",
    "Get-AgentBellState",
    "Set-AgentBellTurnStart",
    "Get-AgentBellTurnDurationSeconds",
    "Test-AgentBellHandled",
    "Add-AgentBellHandled",
    "Get-AgentBellDecision",
    "Get-AgentBellCompletionAction",
    "Get-AgentBellAnnouncement",
    "New-AgentBellLogRecord",
    "Limit-AgentBellDedupeEntries",
    "Get-AgentBellIdleSeconds",
    "Invoke-AgentBellSapi",
    "Invoke-AgentBellHttpVoice",
    "Invoke-AgentBellSpeech",
    "Show-AgentBellNotification"
)
