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
        mode = "always"
        duration_threshold_seconds = 60
        idle_threshold_seconds = 45
        stop_debounce_seconds = 5
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
                timeout_seconds = 30
                voice_id = "default"
            }
        }
        notifications = [pscustomobject][ordered]@{
            short_active_turn = "toast"
            automation_runs = "none"
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
    if ([string]$config.notifications.automation_runs -notin @("none", "normal")) {
        throw "Agent Bell automation_runs must be none or normal."
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

function ConvertTo-AgentBellResourceMetric {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    try {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            return $null
        }
        return $number
    }
    catch {
        return $null
    }
}

function Get-AgentBellPrewarmSlotNames {
    param([Parameter(Mandatory = $true)][string]$DataDir)

    $normalizedPath = [System.IO.Path]::GetFullPath($DataDir).TrimEnd('\', '/').ToLowerInvariant()
    $dataDirectoryHash = Get-AgentBellHash -Value $normalizedPath
    return @(
        "Local\AgentBellPrewarm-$dataDirectoryHash-0",
        "Local\AgentBellPrewarm-$dataDirectoryHash-1"
    )
}

function Invoke-AgentBellNvidiaSmiResourceQuery {
    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction Stop | Select-Object -First 1
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $nvidiaSmi.Source
    $startInfo.Arguments = '--id=0 --query-gpu=memory.free,utilization.gpu --format=csv,noheader,nounits'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) {
            return $null
        }
        if (-not $process.WaitForExit(2000)) {
            try {
                $process.Kill()
                $process.WaitForExit(500) | Out-Null
            }
            catch {
                # The query is best-effort and never changes the fail-closed policy.
            }
            return $null
        }

        $standardOutput = $process.StandardOutput.ReadToEnd()
        $process.StandardError.ReadToEnd() | Out-Null
        if ($process.ExitCode -ne 0) {
            return $null
        }
        return $standardOutput
    }
    finally {
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit(500) | Out-Null
                }
            }
            catch {
                # Process cleanup is best-effort after a bounded query.
            }
        }
        $process.Dispose()
    }
}

function Get-AgentBellPrewarmResourceDecision {
    param([object]$Snapshot)

    $unavailable = [pscustomobject][ordered]@{
        allowed = $false
        reason = "metrics_unavailable"
    }
    if ($null -eq $Snapshot) {
        return $unavailable
    }

    $metricNames = @(
        "available_memory_bytes",
        "cpu_percent",
        "free_gpu_memory_mib",
        "gpu_utilization_percent"
    )
    $metrics = @{}
    foreach ($name in $metricNames) {
        $property = $Snapshot.PSObject.Properties[$name]
        if ($null -eq $property) {
            return $unavailable
        }
        $number = ConvertTo-AgentBellResourceMetric -Value $property.Value
        if ($null -eq $number) {
            return $unavailable
        }
        $metrics[$name] = $number
    }

    if ($metrics.available_memory_bytes -lt 0 -or
        $metrics.cpu_percent -lt 0 -or $metrics.cpu_percent -gt 100 -or
        $metrics.free_gpu_memory_mib -lt 0 -or
        $metrics.gpu_utilization_percent -lt 0 -or $metrics.gpu_utilization_percent -gt 100) {
        return $unavailable
    }
    if ($metrics.available_memory_bytes -lt 2GB) {
        return [pscustomobject][ordered]@{ allowed = $false; reason = "memory_low" }
    }
    if ($metrics.cpu_percent -gt 75) {
        return [pscustomobject][ordered]@{ allowed = $false; reason = "cpu_busy" }
    }
    if ($metrics.free_gpu_memory_mib -lt 1536) {
        return [pscustomobject][ordered]@{ allowed = $false; reason = "gpu_memory_low" }
    }
    if ($metrics.gpu_utilization_percent -gt 70) {
        return [pscustomobject][ordered]@{ allowed = $false; reason = "gpu_busy" }
    }

    return [pscustomobject][ordered]@{ allowed = $true; reason = "ready" }
}

function Get-AgentBellResourceSnapshot {
    $snapshot = [ordered]@{
        available_memory_bytes  = $null
        cpu_percent             = $null
        free_gpu_memory_mib     = $null
        gpu_utilization_percent = $null
    }

    try {
        $operatingSystem = Get-CimInstance `
            -ClassName Win32_OperatingSystem `
            -OperationTimeoutSec 2 `
            -ErrorAction Stop
        $availableMemory = ConvertTo-AgentBellResourceMetric -Value $operatingSystem.FreePhysicalMemory
        if ($null -ne $availableMemory -and $availableMemory -ge 0) {
            $snapshot.available_memory_bytes = [int64]($availableMemory * 1KB)
        }
    }
    catch {
        # The policy fails closed when a metric cannot be collected.
    }

    try {
        $processor = Get-CimInstance `
            -ClassName Win32_PerfFormattedData_PerfOS_Processor `
            -Filter "Name='_Total'" `
            -OperationTimeoutSec 2 `
            -ErrorAction Stop |
            Select-Object -First 1
        $cpuPercent = ConvertTo-AgentBellResourceMetric -Value $processor.PercentProcessorTime
        if ($null -ne $cpuPercent -and $cpuPercent -ge 0 -and $cpuPercent -le 100) {
            $snapshot.cpu_percent = $cpuPercent
        }
    }
    catch {
        # The policy fails closed when a metric cannot be collected.
    }

    try {
        $queryOutput = Invoke-AgentBellNvidiaSmiResourceQuery
        $lines = @([string]$queryOutput -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -gt 0) {
            $fields = @($lines[0] -split ',')
            if ($fields.Count -eq 2) {
                $freeGpuMemory = 0.0
                $gpuUtilization = 0.0
                $style = [System.Globalization.NumberStyles]::Float
                $culture = [System.Globalization.CultureInfo]::InvariantCulture
                $freeValid = [double]::TryParse($fields[0].Trim(), $style, $culture, [ref]$freeGpuMemory)
                $utilizationValid = [double]::TryParse($fields[1].Trim(), $style, $culture, [ref]$gpuUtilization)
                if ($freeValid -and $freeGpuMemory -ge 0) {
                    $snapshot.free_gpu_memory_mib = $freeGpuMemory
                }
                if ($utilizationValid -and $gpuUtilization -ge 0 -and $gpuUtilization -le 100) {
                    $snapshot.gpu_utilization_percent = $gpuUtilization
                }
            }
        }
    }
    catch {
        # The policy fails closed when a metric cannot be collected.
    }

    return [pscustomobject]$snapshot
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

function ConvertTo-AgentBellComparablePath {
    param([string]$Path)

    $pathValue = $Path
    if ($pathValue.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $pathValue = '\\' + $pathValue.Substring(8)
    }
    elseif ($pathValue.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $pathValue = $pathValue.Substring(4)
    }
    return [System.IO.Path]::GetFullPath($pathValue)
}

function Read-AgentBellFirstUtf8Line {
    param(
        [string]$Path,
        [int]$MaxBytes = 1048576
    )

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $memory = New-Object System.IO.MemoryStream
    try {
        $buffer = New-Object byte[] 8192
        $lineComplete = $false
        while ($memory.Length -le $MaxBytes) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }
            $writeCount = $read
            for ($index = 0; $index -lt $read; $index++) {
                if ($buffer[$index] -eq 10) {
                    $writeCount = $index
                    $lineComplete = $true
                    break
                }
            }
            if ($writeCount -gt 0) {
                $memory.Write($buffer, 0, $writeCount)
            }
            if ($memory.Length -gt $MaxBytes) {
                return $null
            }
            if ($lineComplete) {
                break
            }
        }
        if ($memory.Length -le 0 -or ($memory.Length -ge $MaxBytes -and -not $lineComplete)) {
            return $null
        }
        $line = [System.Text.Encoding]::UTF8.GetString($memory.ToArray()).TrimEnd("`r")
        if ($line.Length -gt 0 -and $line[0] -eq [char]0xFEFF) {
            $line = $line.Substring(1)
        }
        return $line
    }
    finally {
        $memory.Dispose()
        $stream.Dispose()
    }
}

function Get-AgentBellRolloutThreadSource {
    param(
        [string]$CodexHome,
        [string]$SessionId,
        [string]$TranscriptPath
    )

    if ($SessionId -notmatch '^[0-9a-fA-F-]{36}$' -or
        [string]::IsNullOrWhiteSpace($CodexHome) -or
        [string]::IsNullOrWhiteSpace($TranscriptPath)) {
        return "unknown"
    }

    try {
        $openPath = [System.IO.Path]::GetFullPath($TranscriptPath)
        $fullPath = ConvertTo-AgentBellComparablePath -Path $TranscriptPath
        $allowedRoots = @(
            (Join-Path $CodexHome "sessions"),
            (Join-Path $CodexHome "archived_sessions")
        )
        $insideCodexHistory = $false
        foreach ($root in $allowedRoots) {
            $fullRoot = (ConvertTo-AgentBellComparablePath -Path $root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            if ($fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $insideCodexHistory = $true
                break
            }
        }
        if (-not $insideCodexHistory -or
            -not [System.IO.Path]::GetFileName($fullPath).EndsWith("-$SessionId.jsonl", [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $openPath -PathType Leaf)) {
            return "unknown"
        }

        $line = Read-AgentBellFirstUtf8Line -Path $openPath
        if ([string]::IsNullOrWhiteSpace($line)) {
            return "unknown"
        }

        $metadata = $line | ConvertFrom-Json
        if ([string](Get-AgentBellProperty -Object $metadata -Name "type") -ne "session_meta") {
            return "unknown"
        }
        $payload = Get-AgentBellProperty -Object $metadata -Name "payload"
        $metadataSessionId = [string](Get-AgentBellProperty -Object $payload -Name "id")
        if ([string]::IsNullOrWhiteSpace($metadataSessionId)) {
            $metadataSessionId = [string](Get-AgentBellProperty -Object $payload -Name "session_id")
        }
        if ($metadataSessionId -ne $SessionId) {
            return "unknown"
        }

        $threadSource = [string](Get-AgentBellProperty -Object $payload -Name "thread_source")
        if ($threadSource -in @("user", "automation", "subagent")) {
            return $threadSource
        }
    }
    catch {
        # Missing, concurrently moved, or legacy rollout metadata fails open.
    }
    return "unknown"
}

function Get-AgentBellRealConversationTitle {
    param(
        [string]$CodexHome,
        [string]$SessionId,
        [string]$SessionIndexPath,
        [Alias("MaxLength")][int]$MaxCharacters = 60
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
            # Continue to the local Codex database.
        }
    }

    $sqliteTitle = Get-AgentBellSqliteTitle -CodexHome $CodexHome -SessionId $SessionId -MaxCharacters $MaxCharacters
    if (-not [string]::IsNullOrWhiteSpace($sqliteTitle)) {
        return $sqliteTitle
    }

    return $null
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

    $title = Get-AgentBellRealConversationTitle `
        -CodexHome $CodexHome `
        -SessionId $SessionId `
        -SessionIndexPath $SessionIndexPath `
        -MaxCharacters $MaxCharacters
    if (-not [string]::IsNullOrWhiteSpace($title)) {
        return $title
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
        [ValidateSet("user", "automation", "subagent", "unknown")][string]$ThreadSource = "unknown",
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

    $dedupeKey = if ($eventName -eq "Stop") {
        "$sessionId|$turnId|Stop"
    }
    else {
        "$sessionId|$turnId|$kind|$toolName|$fingerprint"
    }
    return [pscustomobject][ordered]@{
        schema_version = 1
        event = $eventName
        kind = $kind
        session_id = $sessionId
        turn_id = $turnId
        cwd = [string](Get-AgentBellProperty -Object $Payload -Name "cwd")
        thread_source = $ThreadSource
        tool_name = $toolName
        stop_hook_active = $stopHookActive
        attempt = 0
        captured_at = $CapturedAt.ToString("o")
        dedupe_key = $dedupeKey
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

function Test-AgentBellTurnActive {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Key
    )

    return $null -ne ($State.turns | Where-Object { [string]$_.key -eq $Key } | Select-Object -First 1)
}

function Remove-AgentBellTurnStart {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Key
    )

    $State.turns = @($State.turns | Where-Object { [string]$_.key -ne $Key })
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

function Get-AgentBellEventDurationSeconds {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][object]$State,
        [string]$Key,
        [string]$StoppedAt
    )

    $durationProperty = $Event.PSObject.Properties["duration_seconds"]
    if ($null -ne $durationProperty) {
        if ($null -eq $durationProperty.Value) {
            return $null
        }
        return [double]$durationProperty.Value
    }

    $duration = Get-AgentBellTurnDurationSeconds -State $State -Key $Key -StoppedAt $StoppedAt
    $Event | Add-Member -MemberType NoteProperty -Name "duration_seconds" -Value $duration
    return $duration
}

function Get-AgentBellDebounceWaitMilliseconds {
    param(
        [string]$CapturedAt,
        [int]$DebounceSeconds,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    if ($DebounceSeconds -le 0) {
        return 0
    }
    try {
        $captured = [DateTimeOffset]::Parse($CapturedAt)
        $elapsedMilliseconds = [Math]::Max(0, ($Now - $captured).TotalMilliseconds)
        $maximumMilliseconds = [double]$DebounceSeconds * 1000
        return [int][Math]::Ceiling([Math]::Max(0, $maximumMilliseconds - [Math]::Min($elapsedMilliseconds, $maximumMilliseconds)))
    }
    catch {
        return $DebounceSeconds * 1000
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

function Test-AgentBellShouldPrewarm {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][object]$Config,
        [bool]$DryRun = $false
    )

    if ($DryRun -or -not [bool]$Config.enabled -or [string]$Config.voice.provider -ne "http") {
        return $false
    }
    if ([string](Get-AgentBellProperty -Object $Event -Name "kind") -ne "start") {
        return $false
    }
    $threadSource = [string](Get-AgentBellProperty -Object $Event -Name "thread_source" -Default "unknown")
    return $threadSource -ne "automation" -or [string]$Config.notifications.automation_runs -eq "normal"
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

function Resolve-AgentBellLoopbackUri {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [string]$Path
    )

    try {
        $uri = [Uri]$Endpoint
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
    if (-not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw "The local voice endpoint cannot include a query or fragment."
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

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (-not $Path.StartsWith('/') -or $Path.Contains('?') -or $Path.Contains('#') -or $Path.Contains('\')) {
            throw "The local voice endpoint path is invalid."
        }
        $builder = New-Object System.UriBuilder($uri)
        $builder.Path = $Path
        $builder.Query = ""
        $builder.Fragment = ""
        $uri = $builder.Uri
    }
    return $uri
}

function New-AgentBellVoiceHttpRequest {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter(Mandatory = $true)][string]$Accept
    )

    $payload = [ordered]@{
        text = $Message
        voice_id = [string]$Config.voice.http.voice_id
    } | ConvertTo-Json -Compress
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = "POST"
    $request.ContentType = "application/json; charset=utf-8"
    $request.Accept = $Accept
    $request.Timeout = $TimeoutMs
    $request.ReadWriteTimeout = $TimeoutMs
    $request.ContentLength = $payloadBytes.Length
    $request.AllowAutoRedirect = $false

    return [pscustomobject]@{
        request = $request
        payload_bytes = $payloadBytes
        deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    }
}

function Get-AgentBellVoiceHttpResponse {
    param([Parameter(Mandatory = $true)][object]$Context)

    $requestStream = $Context.request.GetRequestStream()
    try {
        $requestStream.Write($Context.payload_bytes, 0, $Context.payload_bytes.Length)
    }
    finally {
        $requestStream.Dispose()
    }
    return $Context.request.GetResponse()
}

function Save-AgentBellVoiceWavResponse {
    param(
        [Parameter(Mandatory = $true)][object]$Response,
        [Parameter(Mandatory = $true)][DateTime]$Deadline,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int64]$MaxWavBytes
    )

    $contentType = ([string]$Response.ContentType).Split(';')[0].Trim().ToLowerInvariant()
    if ($contentType -notin @("audio/wav", "audio/x-wav", "audio/wave")) {
        throw "The local voice provider returned an unexpected content type."
    }
    if ($Response.ContentLength -gt $MaxWavBytes) {
        throw "The local voice provider returned a WAV larger than the configured limit."
    }

    $responseStream = $Response.GetResponseStream()
    try {
        $fileStream = [System.IO.File]::Create($OutputPath)
        try {
            $buffer = New-Object byte[] 65536
            [int64]$totalBytes = 0
            while ($true) {
                $remainingMs = [int][Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
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
                if ($totalBytes -gt $MaxWavBytes) {
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
    if (-not (Test-Path -LiteralPath $OutputPath) -or (Get-Item -LiteralPath $OutputPath).Length -lt 44) {
        throw "The local voice provider did not return a valid WAV payload."
    }
}

function Invoke-AgentBellWavPlayback {
    param([Parameter(Mandatory = $true)][string]$Path)

    $player = New-Object System.Media.SoundPlayer $Path
    try {
        $player.PlaySync()
    }
    finally {
        $player.Dispose()
    }
}

function Invoke-AgentBellHttpVoice {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $uri = Resolve-AgentBellLoopbackUri -Endpoint ([string]$Config.voice.http.endpoint)
    $timeoutMs = [Math]::Max(1000, [int]$Config.voice.http.timeout_seconds * 1000)
    $maxWavBytes = [Math]::Max(44, [int64]$Config.limits.max_wav_bytes)
    $context = New-AgentBellVoiceHttpRequest -Uri $uri -Message $Message -Config $Config -TimeoutMs $timeoutMs -Accept "audio/wav"
    $response = Get-AgentBellVoiceHttpResponse -Context $context
    try {
        Save-AgentBellVoiceWavResponse -Response $response -Deadline $context.deadline -OutputPath $OutputPath -MaxWavBytes $maxWavBytes
    }
    finally {
        $response.Dispose()
    }
    Invoke-AgentBellWavPlayback -Path $OutputPath
}

function Invoke-AgentBellHttpPrewarm {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config
    )

    try {
        $uri = Resolve-AgentBellLoopbackUri -Endpoint ([string]$Config.voice.http.endpoint) -Path "/prewarm"
        $timeoutMs = [Math]::Min(2000, [Math]::Max(1000, [int]$Config.voice.http.timeout_seconds * 1000))
        $context = New-AgentBellVoiceHttpRequest -Uri $uri -Message $Message -Config $Config -TimeoutMs $timeoutMs -Accept "application/json"
        $response = Get-AgentBellVoiceHttpResponse -Context $context
        try {
            $statusCode = [int]$response.StatusCode
            return $statusCode -ge 200 -and $statusCode -lt 300
        }
        finally {
            $response.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Request-AgentBellCachedVoice {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    try {
        $uri = Resolve-AgentBellLoopbackUri -Endpoint ([string]$Config.voice.http.endpoint) -Path "/cached"
        $timeoutMs = [Math]::Min(2000, [Math]::Max(1000, [int]$Config.voice.http.timeout_seconds * 1000))
        $maxWavBytes = [Math]::Max(44, [int64]$Config.limits.max_wav_bytes)
        $context = New-AgentBellVoiceHttpRequest -Uri $uri -Message $Message -Config $Config -TimeoutMs $timeoutMs -Accept "audio/wav"
        $response = Get-AgentBellVoiceHttpResponse -Context $context
        try {
            if ([int]$response.StatusCode -ne 200) {
                return $false
            }
            Save-AgentBellVoiceWavResponse -Response $response -Deadline $context.deadline -OutputPath $OutputPath -MaxWavBytes $maxWavBytes
        }
        finally {
            $response.Dispose()
        }
        return $true
    }
    catch {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-AgentBellHttpCompletion {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$CacheDirectory
    )

    [System.IO.Directory]::CreateDirectory($CacheDirectory) | Out-Null
    $wavPath = Join-Path $CacheDirectory ("cached-" + [Guid]::NewGuid().ToString("N") + ".wav")
    try {
        if (Request-AgentBellCachedVoice -Message $Message -Config $Config -OutputPath $wavPath) {
            Invoke-AgentBellWavPlayback -Path $wavPath
            return "http-cache"
        }
    }
    catch {
        # Completion playback stays cache-only and never delays Codex with live synthesis.
    }
    finally {
        Remove-Item -LiteralPath $wavPath -Force -ErrorAction SilentlyContinue
    }

    return "http-cache-miss"
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
    "Get-AgentBellPrewarmSlotNames",
    "Get-AgentBellPrewarmResourceDecision",
    "Get-AgentBellResourceSnapshot",
    "Normalize-AgentBellTitle",
    "ConvertTo-AgentBellTitle",
    "Get-AgentBellRolloutThreadSource",
    "Get-AgentBellRealConversationTitle",
    "Get-AgentBellConversationTitle",
    "Test-AgentBellFailureMessage",
    "Test-AgentBellExplicitFailure",
    "ConvertTo-AgentBellEvent",
    "Get-AgentBellState",
    "Set-AgentBellTurnStart",
    "Test-AgentBellTurnActive",
    "Remove-AgentBellTurnStart",
    "Get-AgentBellTurnDurationSeconds",
    "Get-AgentBellEventDurationSeconds",
    "Get-AgentBellDebounceWaitMilliseconds",
    "Test-AgentBellHandled",
    "Add-AgentBellHandled",
    "Get-AgentBellDecision",
    "Test-AgentBellShouldPrewarm",
    "Get-AgentBellCompletionAction",
    "Get-AgentBellAnnouncement",
    "New-AgentBellLogRecord",
    "Limit-AgentBellDedupeEntries",
    "Get-AgentBellIdleSeconds",
    "Invoke-AgentBellSapi",
    "Resolve-AgentBellLoopbackUri",
    "Invoke-AgentBellHttpVoice",
    "Invoke-AgentBellHttpPrewarm",
    "Request-AgentBellCachedVoice",
    "Invoke-AgentBellWavPlayback",
    "Invoke-AgentBellHttpCompletion",
    "Invoke-AgentBellSpeech",
    "Show-AgentBellNotification"
)
