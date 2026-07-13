$ErrorActionPreference = 'Stop'

$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\plugins\agent-bell')).Path
$enqueuePath = Join-Path $pluginRoot 'hooks\enqueue.ps1'
$workerPath = Join-Path $pluginRoot 'scripts\worker.ps1'
$prewarmPath = Join-Path $pluginRoot 'scripts\prewarm.ps1'
$modulePath = Join-Path $pluginRoot 'scripts\AgentBell.Core.psm1'
Import-Module $modulePath -Force -DisableNameChecking

function Invoke-AgentBellHookProcess {
    param(
        [string]$Payload,
        [string]$DataDir,
        [switch]$NoWorker
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PluginRoot "{1}" -DataDir "{2}"' -f $enqueuePath, $pluginRoot, $DataDir)
    if ($NoWorker.IsPresent) {
        $startInfo.Arguments += ' -NoWorker'
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $payloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Payload)
    $process.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
    $process.StandardInput.BaseStream.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $stopwatch.Stop()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        Milliseconds = $stopwatch.Elapsed.TotalMilliseconds
    }
}

function Get-AgentBellTestPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function New-AgentBellAllowedResourceSnapshot {
    return [pscustomobject]@{
        available_memory_bytes  = 1536MB
        cpu_percent             = 75
        free_gpu_memory_mib     = 1536
        gpu_utilization_percent = 70
    }
}

function Start-AgentBellTestServer {
    param(
        [int]$Port,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$ResponseBody,
        [int]$DelayMilliseconds = 0,
        [int]$WaitTimeoutMilliseconds = 0
    )

    $job = Start-Job -ArgumentList $Port, $StatusCode, $ContentType, $ResponseBody, $DelayMilliseconds, $WaitTimeoutMilliseconds -ScriptBlock {
        param($Port, $StatusCode, $ContentType, [byte[]]$ResponseBody, $DelayMilliseconds, $WaitTimeoutMilliseconds)
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()
        try {
            if ($WaitTimeoutMilliseconds -gt 0) {
                $pendingContext = $listener.BeginGetContext($null, $null)
                if (-not $pendingContext.AsyncWaitHandle.WaitOne($WaitTimeoutMilliseconds)) {
                    return [pscustomobject]@{ received = $false }
                }
                $context = $listener.EndGetContext($pendingContext)
            }
            else {
                $context = $listener.GetContext()
            }
            $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
            try {
                $body = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
            if ($DelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
            try {
                $context.Response.StatusCode = $StatusCode
                $context.Response.ContentType = $ContentType
                $context.Response.ContentLength64 = $ResponseBody.Length
                $context.Response.OutputStream.Write($ResponseBody, 0, $ResponseBody.Length)
                $context.Response.Close()
            }
            catch {
                # Timeout tests may close the client before the response is written.
            }
            [pscustomobject]@{
                received = $true
                path = $context.Request.Url.AbsolutePath
                body = $body
            }
        }
        finally {
            $listener.Stop()
            $listener.Close()
        }
    }
    Start-Sleep -Milliseconds 400
    return $job
}

Describe 'Agent Bell hook queue' {
    BeforeEach {
        $script:dataDir = Join-Path $env:TEMP ('agent-bell-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:dataDir | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ships the detached prewarm entry point' {
        Test-Path -LiteralPath $prewarmPath -PathType Leaf | Should Be $true
    }

    It 'propagates the resolved Codex home to the background worker' {
        $enqueueSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $enqueuePath
        $enqueueSource | Should Match '"-CodexHome"\s*,\s*\(''"''\s*\+\s*\$CodexHome'
    }

    It 'never deletes a prewarm request outside its private ticket directory' {
        $outsidePath = Join-Path $script:dataDir 'outside-prewarm.json'
        [System.IO.File]::WriteAllText($outsidePath, '{"private":"keep"}', (New-Object System.Text.UTF8Encoding($false)))

        & $prewarmPath `
            -PluginRoot $pluginRoot `
            -DataDir $script:dataDir `
            -CodexHome (Join-Path $script:dataDir 'codex-home') `
            -RequestPath $outsidePath `
            -TitleRetryDelaySeconds 0

        Test-Path -LiteralPath $outsidePath -PathType Leaf | Should Be $true
        Get-Content -Raw -Encoding UTF8 -LiteralPath $outsidePath | Should Be '{"private":"keep"}'
    }

    It 'releases a denied helper slot before waiting for the next resource attempt' {
        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $prewarmPath

        $source | Should Match 'if \(\[bool\]\$resourceDecision\.allowed\)\s*\{\s*break\s*\}\s*Close-AgentBellPrewarmSlot -Slot \$prewarmSlot\s*\$prewarmSlot = \$null'
    }

    It 'caps deferred prewarm helpers independently from active resource slots' {
        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $prewarmPath

        $source | Should Match '\$ResourceRetryDelaysSeconds\s*=\s*@\(15,\s*30,\s*30\)'
        $source | Should Match 'Get-AgentBellPrewarmWaiterSlotNames'
        $source | Should Match 'if \(\$null -eq \$waiterSlot\)\s*\{\s*return\s*\}'
        $source | Should Match 'Close-AgentBellPrewarmSlot -Slot \$waiterSlot'
    }

    It 'rechecks config and active state after collection before sending HTTP' {
        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $prewarmPath
        $pattern = '\$resourceDecision\s*=.*?[\s\S]+?Get-AgentBellConfig[\s\S]+?Get-AgentBellState[\s\S]+?Get-AgentBellRealConversationTitle[\s\S]+?Get-AgentBellState[\s\S]+?Invoke-AgentBellHttpPrewarm'

        $source | Should Match $pattern
    }

    It 'caps each worker pass at two detached prewarm launches' {
        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $workerPath

        $source | Should Match '\$prewarmLaunchLimit\s*=\s*2'
        $source | Should Match 'foreach\s*\(\$candidate\s+in\s+\$prewarmCandidates\)[\s\S]+?\$launched\.Count\s+-ge\s+\$prewarmLaunchLimit[\s\S]+?break'
    }

    It 'prewarms the exact completion announcement only for an active turn with a real Codex title' {
        $port = Get-AgentBellTestPort
        $responseBody = [System.Text.Encoding]::UTF8.GetBytes('{"status":"queued"}')
        $server = Start-AgentBellTestServer -Port $port -StatusCode 202 -ContentType 'application/json' -ResponseBody $responseBody
        try {
            $config = Get-AgentBellDefaultConfig
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

            $sessionId = '56565656-5656-5656-5656-565656565656'
            $turnId = 'turn-prewarm-exact-title'
            $codexHome = Join-Path $script:dataDir 'codex-home'
            New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
            $titleRow = [ordered]@{
                id = $sessionId
                thread_name = '真实 Codex 会话名'
                updated_at = '2026-07-13T00:00:00Z'
            } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'), $titleRow + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

            $state = Get-AgentBellState
            $state = Set-AgentBellTurnStart -State $state -Key "$sessionId|$turnId" -CapturedAt '2026-07-13T00:00:00Z'
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'state\state.json') -Value $state

            $requestDirectory = Join-Path $script:dataDir 'queue\prewarm'
            New-Item -ItemType Directory -Force -Path $requestDirectory | Out-Null
            $requestPath = Join-Path $requestDirectory ('prewarm-' + [guid]::NewGuid().ToString('N') + '.json')
            Write-AgentBellJsonAtomic -Path $requestPath -Value ([ordered]@{
                schema_version = 1
                session_id = $sessionId
                turn_id = $turnId
                thread_source = 'user'
            })

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            & $prewarmPath `
                -PluginRoot $pluginRoot `
                -DataDir $script:dataDir `
                -CodexHome $codexHome `
                -RequestPath $requestPath `
                -ResourceSnapshot (New-AgentBellAllowedResourceSnapshot)
            $stopwatch.Stop()

            $result = Receive-Job -Job (Wait-Job -Job $server -Timeout 5)
            $payload = $result.body | ConvertFrom-Json
            $result.path | Should Be '/prewarm'
            $payload.text | Should Be '主人，真实 Codex 会话名 任务已完成，请回来查看了。'
            $payload.voice_id | Should Be 'default'
            ($stopwatch.ElapsedMilliseconds -lt 3000) | Should Be $true
            Test-Path -LiteralPath $requestPath | Should Be $false
        }
        finally {
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'retries once when a new Codex title appears during the grace period' {
        $port = Get-AgentBellTestPort
        $responseBody = [System.Text.Encoding]::UTF8.GetBytes('{"status":"queued"}')
        $server = Start-AgentBellTestServer -Port $port -StatusCode 202 -ContentType 'application/json' -ResponseBody $responseBody
        $titleWriter = $null
        try {
            $config = Get-AgentBellDefaultConfig
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

            $sessionId = '58585858-5858-5858-5858-585858585858'
            $turnId = 'turn-title-retry'
            $codexHome = Join-Path $script:dataDir 'codex-home'
            New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
            $indexPath = Join-Path $codexHome 'session_index.jsonl'
            $writerReadyPath = Join-Path $script:dataDir 'title-writer-ready'
            $titleRow = [ordered]@{ id = $sessionId; thread_name = '稍后出现的标题' } | ConvertTo-Json -Compress
            $titleWriter = Start-Job -ArgumentList $indexPath, $titleRow, $writerReadyPath -ScriptBlock {
                param($Path, $Row, $ReadyPath)
                [System.IO.File]::WriteAllText($ReadyPath, 'ready', (New-Object System.Text.UTF8Encoding($false)))
                Start-Sleep -Seconds 2
                [System.IO.File]::WriteAllText($Path, $Row + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            }
            $writerDeadline = (Get-Date).AddSeconds(5)
            while (-not (Test-Path -LiteralPath $writerReadyPath) -and (Get-Date) -lt $writerDeadline) {
                Start-Sleep -Milliseconds 50
            }
            Test-Path -LiteralPath $writerReadyPath | Should Be $true
            $state = Set-AgentBellTurnStart -State (Get-AgentBellState) -Key "$sessionId|$turnId" -CapturedAt '2026-07-13T00:00:00Z'
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'state\state.json') -Value $state
            $requestDirectory = Join-Path $script:dataDir 'queue\prewarm'
            New-Item -ItemType Directory -Force -Path $requestDirectory | Out-Null
            $requestPath = Join-Path $requestDirectory ('prewarm-' + [guid]::NewGuid().ToString('N') + '.json')
            Write-AgentBellJsonAtomic -Path $requestPath -Value ([ordered]@{
                schema_version = 1
                session_id = $sessionId
                turn_id = $turnId
                thread_source = 'user'
            })

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            & $prewarmPath `
                -PluginRoot $pluginRoot `
                -DataDir $script:dataDir `
                -CodexHome $codexHome `
                -RequestPath $requestPath `
                -TitleRetryDelaySeconds 3 `
                -ResourceSnapshot (New-AgentBellAllowedResourceSnapshot)
            $stopwatch.Stop()

            $result = Receive-Job -Job (Wait-Job -Job $server -Timeout 5)
            $payload = $result.body | ConvertFrom-Json
            $result.path | Should Be '/prewarm'
            $payload.text | Should Be '主人，稍后出现的标题 任务已完成，请回来查看了。'
            ($stopwatch.ElapsedMilliseconds -ge 2800) | Should Be $true
            ($stopwatch.ElapsedMilliseconds -lt 5000) | Should Be $true
            Test-Path -LiteralPath $requestPath | Should Be $false
        }
        finally {
            if ($null -ne $titleWriter) {
                Stop-Job -Job $titleWriter -ErrorAction SilentlyContinue
                Remove-Job -Job $titleWriter -Force -ErrorAction SilentlyContinue
            }
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips denied resource snapshots without HTTP or private log data' {
        $port = Get-AgentBellTestPort
        $responseBody = [System.Text.Encoding]::UTF8.GetBytes('{"status":"queued"}')
        $server = Start-AgentBellTestServer -Port $port -StatusCode 202 -ContentType 'application/json' -ResponseBody $responseBody -WaitTimeoutMilliseconds 2000
        try {
            $config = Get-AgentBellDefaultConfig
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

            $sessionId = '59595959-5959-5959-5959-595959595959'
            $turnId = 'private-turn-resource-denied'
            $privateTitle = '绝密资源检测会话'
            $codexHome = Join-Path $script:dataDir 'codex-home'
            New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
            $titleRow = [ordered]@{ id = $sessionId; thread_name = $privateTitle } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'), $titleRow + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            $state = Set-AgentBellTurnStart -State (Get-AgentBellState) -Key "$sessionId|$turnId" -CapturedAt '2026-07-13T00:00:00Z'
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'state\state.json') -Value $state
            $requestDirectory = Join-Path $script:dataDir 'queue\prewarm'
            New-Item -ItemType Directory -Force -Path $requestDirectory | Out-Null
            $requestPath = Join-Path $requestDirectory ('prewarm-' + [guid]::NewGuid().ToString('N') + '.json')
            Write-AgentBellJsonAtomic -Path $requestPath -Value ([ordered]@{
                schema_version = 1
                session_id = $sessionId
                turn_id = $turnId
                thread_source = 'user'
            })
            $deniedSnapshot = New-AgentBellAllowedResourceSnapshot
            $deniedSnapshot.available_memory_bytes = 1536MB - 1

            & $prewarmPath `
                -PluginRoot $pluginRoot `
                -DataDir $script:dataDir `
                -CodexHome $codexHome `
                -RequestPath $requestPath `
                -ResourceSnapshot $deniedSnapshot `
                -ResourceRetryDelaysSeconds 0

            $result = Receive-Job -Job (Wait-Job -Job $server -Timeout 5)
            $result.received | Should Be $false
            $entry = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl') | ConvertFrom-Json
            (($entry.data.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') | Should Be 'reason,attempt'
            $entry.data.reason | Should Be 'memory_low'
            $entry.data.attempt | Should Be 2
            ($entry | ConvertTo-Json -Compress -Depth 5) | Should Not Match ([regex]::Escape($privateTitle))
            ($entry | ConvertTo-Json -Compress -Depth 5) | Should Not Match ([regex]::Escape($sessionId))
            ($entry | ConvertTo-Json -Compress -Depth 5) | Should Not Match ([regex]::Escape($turnId))
        }
        finally {
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'retries a denied resource snapshot and prewarms after headroom recovers' {
        $port = Get-AgentBellTestPort
        $responseBody = [System.Text.Encoding]::UTF8.GetBytes('{"status":"queued"}')
        $server = Start-AgentBellTestServer -Port $port -StatusCode 202 -ContentType 'application/json' -ResponseBody $responseBody
        try {
            $config = Get-AgentBellDefaultConfig
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

            $sessionId = '62626262-6262-6262-6262-626262626262'
            $turnId = 'turn-resource-recovery'
            $privateTitle = '资源恢复测试会话'
            $codexHome = Join-Path $script:dataDir 'codex-home'
            New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
            $titleRow = [ordered]@{ id = $sessionId; thread_name = $privateTitle } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'), $titleRow + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            $state = Set-AgentBellTurnStart -State (Get-AgentBellState) -Key "$sessionId|$turnId" -CapturedAt '2026-07-13T00:00:00Z'
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'state\state.json') -Value $state
            $requestDirectory = Join-Path $script:dataDir 'queue\prewarm'
            New-Item -ItemType Directory -Force -Path $requestDirectory | Out-Null
            $requestPath = Join-Path $requestDirectory ('prewarm-' + [guid]::NewGuid().ToString('N') + '.json')
            Write-AgentBellJsonAtomic -Path $requestPath -Value ([ordered]@{
                schema_version = 1
                session_id = $sessionId
                turn_id = $turnId
                thread_source = 'user'
            })
            $deniedSnapshot = New-AgentBellAllowedResourceSnapshot
            $deniedSnapshot.cpu_percent = 76
            $recoveredSnapshot = New-AgentBellAllowedResourceSnapshot

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            & $prewarmPath `
                -PluginRoot $pluginRoot `
                -DataDir $script:dataDir `
                -CodexHome $codexHome `
                -RequestPath $requestPath `
                -ResourceSnapshot @($deniedSnapshot, $recoveredSnapshot) `
                -ResourceRetryDelaysSeconds 1
            $stopwatch.Stop()

            $result = Receive-Job -Job (Wait-Job -Job $server -Timeout 5)
            $payload = $result.body | ConvertFrom-Json
            $entry = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl') | ConvertFrom-Json
            $result.path | Should Be '/prewarm'
            $payload.text | Should Be '主人，资源恢复测试会话 任务已完成，请回来查看了。'
            ($stopwatch.ElapsedMilliseconds -ge 800) | Should Be $true
            ($stopwatch.ElapsedMilliseconds -lt 4000) | Should Be $true
            $entry.message | Should Be 'Requested custom voice prewarm'
            $entry.data.status | Should Be 'accepted'
            $entry.data.attempt | Should Be 2
            ($entry | ConvertTo-Json -Compress -Depth 5) | Should Not Match ([regex]::Escape($privateTitle))
            ($entry | ConvertTo-Json -Compress -Depth 5) | Should Not Match ([regex]::Escape($sessionId))
            ($entry | ConvertTo-Json -Compress -Depth 5) | Should Not Match ([regex]::Escape($turnId))
        }
        finally {
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not prewarm an automation ticket even when its turn and title exist' {
        $config = Get-AgentBellDefaultConfig
        $config.voice.provider = 'http'
        $config.voice.http.endpoint = 'http://127.0.0.1:9/synthesize'
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $sessionId = '67676767-6767-6767-6767-676767676767'
        $turnId = 'turn-automation-prewarm'
        $codexHome = Join-Path $script:dataDir 'codex-home'
        New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
        $titleRow = [ordered]@{ id = $sessionId; thread_name = '自动化会话' } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'), $titleRow + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        $state = Get-AgentBellState
        $state = Set-AgentBellTurnStart -State $state -Key "$sessionId|$turnId" -CapturedAt '2026-07-13T00:00:00Z'
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'state\state.json') -Value $state
        $requestDirectory = Join-Path $script:dataDir 'queue\prewarm'
        New-Item -ItemType Directory -Force -Path $requestDirectory | Out-Null
        $requestPath = Join-Path $requestDirectory ('prewarm-' + [guid]::NewGuid().ToString('N') + '.json')
        Write-AgentBellJsonAtomic -Path $requestPath -Value ([ordered]@{
            schema_version = 1
            session_id = $sessionId
            turn_id = $turnId
            thread_source = 'automation'
        })

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        & $prewarmPath -PluginRoot $pluginRoot -DataDir $script:dataDir -CodexHome $codexHome -RequestPath $requestPath
        $stopwatch.Stop()

        ($stopwatch.ElapsedMilliseconds -lt 1000) | Should Be $true
        Test-Path -LiteralPath $requestPath | Should Be $false
    }

    It 'downloads a cached custom WAV without calling synthesis' {
        $port = Get-AgentBellTestPort
        $wav = New-Object byte[] 44
        [System.Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($wav, 0)
        [System.Text.Encoding]::ASCII.GetBytes('WAVE').CopyTo($wav, 8)
        [System.Text.Encoding]::ASCII.GetBytes('fmt ').CopyTo($wav, 12)
        [System.Text.Encoding]::ASCII.GetBytes('data').CopyTo($wav, 36)
        $server = Start-AgentBellTestServer -Port $port -StatusCode 200 -ContentType 'audio/wav' -ResponseBody $wav
        $outputPath = Join-Path $script:dataDir 'cached.wav'
        try {
            $config = Get-AgentBellDefaultConfig
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"

            $hit = Request-AgentBellCachedVoice -Message '主人，缓存测试 任务已完成，请回来查看了。' -Config $config -OutputPath $outputPath
            $result = Receive-Job -Job (Wait-Job -Job $server -Timeout 5)
            $payload = $result.body | ConvertFrom-Json

            $hit | Should Be $true
            $result.path | Should Be '/cached'
            $payload.text | Should Be '主人，缓存测试 任务已完成，请回来查看了。'
            $payload.voice_id | Should Be 'default'
            (Get-Item -LiteralPath $outputPath).Length | Should Be 44
        }
        finally {
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'caps a cached lookup at two seconds and leaves no partial WAV' {
        $port = Get-AgentBellTestPort
        $responseBody = [System.Text.Encoding]::UTF8.GetBytes('{"error":"cache_miss"}')
        $server = Start-AgentBellTestServer `
            -Port $port `
            -StatusCode 404 `
            -ContentType 'application/json' `
            -ResponseBody $responseBody `
            -DelayMilliseconds 5000
        $outputPath = Join-Path $script:dataDir 'slow-cache.wav'
        try {
            $config = Get-AgentBellDefaultConfig
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"
            $config.voice.http.timeout_seconds = 300

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $hit = Request-AgentBellCachedVoice -Message 'private title' -Config $config -OutputPath $outputPath
            $stopwatch.Stop()

            $hit | Should Be $false
            ($stopwatch.ElapsedMilliseconds -lt 3000) | Should Be $true
            Test-Path -LiteralPath $outputPath | Should Be $false
        }
        finally {
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps an HTTP completion cache miss silent without a Windows system sound' {
        $port = Get-AgentBellTestPort
        $responseBody = [System.Text.Encoding]::UTF8.GetBytes('{"error":"cache_miss"}')
        $server = Start-AgentBellTestServer -Port $port -StatusCode 404 -ContentType 'application/json' -ResponseBody $responseBody
        try {
            $config = Get-AgentBellDefaultConfig
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"
            $cacheDirectory = Join-Path $script:dataDir 'cache'

            $provider = Invoke-AgentBellHttpCompletion `
                -Message '主人，静默缓存测试 任务已完成，请回来查看了。' `
                -Config $config `
                -CacheDirectory $cacheDirectory
            $result = Receive-Job -Job (Wait-Job -Job $server -Timeout 5)
            $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $modulePath

            $provider | Should Be 'http-cache-miss'
            $result.path | Should Be '/cached'
            @(Get-ChildItem -LiteralPath $cacheDirectory -Filter '*.wav' -File -ErrorAction SilentlyContinue).Count | Should Be 0
            $source | Should Not Match 'SystemSounds'
            $source | Should Not Match 'Invoke-AgentBellInformationChime'
        }
        finally {
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'logs a silent worker cache miss without private task metadata' {
        $port = Get-AgentBellTestPort
        $responseBody = [System.Text.Encoding]::UTF8.GetBytes('{"error":"cache_miss"}')
        $server = Start-AgentBellTestServer -Port $port -StatusCode 404 -ContentType 'application/json' -ResponseBody $responseBody
        try {
            $config = Get-AgentBellDefaultConfig
            $config.stop_debounce_seconds = 0
            $config.voice.provider = 'http'
            $config.voice.http.endpoint = "http://127.0.0.1:$port/synthesize"
            Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

            $sessionId = '61616161-6161-6161-6161-616161616161'
            $turnId = 'private-silent-cache-turn'
            $privateTitle = '静默缓存隐私会话'
            $codexHome = Join-Path $script:dataDir 'codex-home'
            New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
            $titleRow = [ordered]@{ id = $sessionId; thread_name = $privateTitle } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'), $titleRow + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            $payload = [ordered]@{
                hook_event_name = 'Stop'
                session_id = $sessionId
                turn_id = $turnId
                cwd = 'C:\work\private-silent-cache'
                stop_hook_active = $false
                last_assistant_message = 'Done.'
            } | ConvertTo-Json -Compress

            & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -CodexHome $codexHome -TestJson $payload -NoWorker
            & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -CodexHome $codexHome

            $result = Receive-Job -Job (Wait-Job -Job $server -Timeout 5)
            $log = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl')
            $result.path | Should Be '/cached'
            $log | Should Match '"provider":"http-cache-miss"'
            $log | Should Not Match ([regex]::Escape($privateTitle))
            $log | Should Not Match ([regex]::Escape($sessionId))
            $log | Should Not Match ([regex]::Escape($turnId))
        }
        finally {
            Stop-Job -Job $server -ErrorAction SilentlyContinue
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    It 'queues only sanitized prompt-start metadata' {
        $payload = [ordered]@{
            hook_event_name = 'UserPromptSubmit'
            session_id = '11111111-1111-1111-1111-111111111111'
            turn_id = 'turn-1'
            cwd = 'C:\work\secret-project'
            prompt = 'do not persist this private prompt'
            transcript_path = 'C:\private\transcript.jsonl'
        } | ConvertTo-Json -Compress

        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker

        $queueFile = Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\pending') -Filter '*.json' | Select-Object -First 1
        $queuedJson = Get-Content -Raw -Encoding UTF8 -LiteralPath $queueFile.FullName
        $queuedJson | Should Match '"kind"\s*:\s*"start"'
        $queuedJson | Should Not Match 'do not persist'
        $queuedJson | Should Not Match 'transcript.jsonl'
    }

    It 'returns exact event-specific stdout while launching the real background worker path' {
        $config = Get-AgentBellDefaultConfig
        $config.enabled = $false
        $config.stop_debounce_seconds = 0
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $stopPayload = [ordered]@{
            hook_event_name = 'Stop'
            session_id = '55555555-5555-5555-5555-555555555555'
            turn_id = 'turn-stdout'
            cwd = 'C:\work\project'
            stop_hook_active = $false
            last_assistant_message = 'Done.'
        } | ConvertTo-Json -Compress
        $stopResult = Invoke-AgentBellHookProcess -Payload $stopPayload -DataDir $script:dataDir

        $stopResult.ExitCode | Should Be 0
        $stopResult.Stdout | Should Be '{"continue":true}'
        $stopResult.Stderr | Should Be ''
        ($stopResult.Milliseconds -lt 2000) | Should Be $true

        $startPayload = [ordered]@{
            hook_event_name = 'UserPromptSubmit'
            session_id = '55555555-5555-5555-5555-555555555555'
            turn_id = 'turn-start-stdout'
            cwd = 'C:\work\project'
            prompt = 'private'
        } | ConvertTo-Json -Compress
        $startResult = Invoke-AgentBellHookProcess -Payload $startPayload -DataDir $script:dataDir

        $startResult.ExitCode | Should Be 0
        $startResult.Stdout | Should Be ''
        $startResult.Stderr | Should Be ''
        ($startResult.Milliseconds -lt 2000) | Should Be $true
    }

    It 'accepts UTF-8 Codex stdin payloads without persisting their private text' {
        $payloads = @(
            ([ordered]@{
                hook_event_name = 'UserPromptSubmit'
                session_id = '77777777-7777-7777-7777-777777777777'
                turn_id = 'turn-utf8-start'
                cwd = 'C:\work\project'
                prompt = '请检查中文和 emoji 😀'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                hook_event_name = 'PermissionRequest'
                session_id = '77777777-7777-7777-7777-777777777777'
                turn_id = 'turn-utf8-permission'
                cwd = 'C:\work\project'
                tool_name = 'Bash'
                tool_input = @{ description = '请确认中文和 emoji 😀' }
            } | ConvertTo-Json -Compress -Depth 5),
            ([ordered]@{
                hook_event_name = 'Stop'
                session_id = '77777777-7777-7777-7777-777777777777'
                turn_id = 'turn-utf8-stop'
                cwd = 'C:\work\project'
                stop_hook_active = $false
                last_assistant_message = '任务已完成 😀'
            } | ConvertTo-Json -Compress)
        )

        foreach ($payload in $payloads) {
            $result = Invoke-AgentBellHookProcess -Payload $payload -DataDir $script:dataDir -NoWorker
            $result.ExitCode | Should Be 0
            $result.Stderr | Should Be ''
        }

        @(Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\pending') -Filter '*.json').Count | Should Be 3
        Test-Path -LiteralPath (Join-Path $script:dataDir 'logs\hook-errors.log') | Should Be $false
        $queuedJson = @(Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\pending') -Filter '*.json' | ForEach-Object {
            Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName
        }) -join [Environment]::NewLine
        $queuedJson | Should Not Match '请检查|请确认|任务已完成|😀'
    }

    It 'suppresses automation events while preserving normal user events' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 0
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $codexHome = Join-Path $script:dataDir 'codex-home'
        $sessionDirectory = Join-Path $codexHome 'sessions\2026\07\12'
        New-Item -ItemType Directory -Force -Path $sessionDirectory | Out-Null
        $cases = @(
            [ordered]@{
                id = '12121212-1212-1212-1212-121212121212'
                source = 'automation'
            },
            [ordered]@{
                id = '34343434-3434-3434-3434-343434343434'
                source = 'user'
            }
        )
        foreach ($case in $cases) {
            $transcriptPath = Join-Path $sessionDirectory ("rollout-test-" + $case.id + ".jsonl")
            $metadata = [ordered]@{
                type = 'session_meta'
                payload = [ordered]@{
                    id = $case.id
                    source = 'vscode'
                    thread_source = $case.source
                    private = 'do not persist this transcript metadata'
                }
            } | ConvertTo-Json -Compress -Depth 5
            [System.IO.File]::WriteAllText($transcriptPath, $metadata + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            $payload = [ordered]@{
                hook_event_name = 'Stop'
                session_id = $case.id
                turn_id = ('turn-' + $case.source)
                transcript_path = $transcriptPath
                cwd = 'C:\work\project'
                stop_hook_active = $false
                last_assistant_message = 'Done.'
            } | ConvertTo-Json -Compress
            & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -CodexHome $codexHome -TestJson $payload -NoWorker
        }

        $queuedJson = @(Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\pending') -Filter '*.json' | ForEach-Object {
            Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName
        }) -join [Environment]::NewLine
        $queuedJson | Should Match '"thread_source"\s*:\s*"automation"'
        $queuedJson | Should Match '"thread_source"\s*:\s*"user"'
        $queuedJson | Should Not Match 'transcript_path|do not persist|codex-home'

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $log = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl')
        $log | Should Match 'Suppressed an automation event'
        $log | Should Match '"reason":"automation"'
        @($log -split [Environment]::NewLine | Where-Object { $_ -match 'Processed attention event' }).Count | Should Be 1
        $log | Should Not Match 'do not persist|codex-home|12121212|34343434'
    }

    It 'reduces a final response to a conservative status' {
        $payload = [ordered]@{
            hook_event_name = 'Stop'
            session_id = '22222222-2222-2222-2222-222222222222'
            turn_id = 'turn-2'
            cwd = 'C:\work\project'
            last_assistant_message = '任务执行失败，缺少依赖。这里还有不应保存的完整说明。'
        } | ConvertTo-Json -Compress

        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker

        $queueFile = Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\pending') -Filter '*.json' | Select-Object -First 1
        $queuedJson = Get-Content -Raw -Encoding UTF8 -LiteralPath $queueFile.FullName
        $queuedJson | Should Match '"kind"\s*:\s*"failure"'
        $queuedJson | Should Not Match '缺少依赖'
        $queuedJson | Should Not Match '完整说明'
    }

    It 'drains a dry-run event and writes privacy-safe state and logs' {
        $payload = [ordered]@{
            hook_event_name = 'PermissionRequest'
            session_id = '33333333-3333-3333-3333-333333333333'
            turn_id = 'turn-3'
            cwd = 'C:\work\private-name'
            tool_name = 'Bash'
            tool_input = @{ command = 'private command'; description = 'private reason' }
        } | ConvertTo-Json -Compress -Depth 5

        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        @(Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\pending') -Filter '*.json').Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\processing') -Filter '*.json').Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\failed') -Filter '*.json').Count | Should Be 0

        $log = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl')
        $log | Should Match '"event":"permission"'
        $log | Should Match '"provider":"dry-run"'
        $log | Should Not Match 'private command'
        $log | Should Not Match 'private-name'
        $log | Should Not Match '33333333-3333-3333-3333-333333333333'
    }

    It 'removes a completed turn from active state without launching prewarm in dry-run mode' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 0
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $sessionId = '45454545-4545-4545-4545-454545454545'
        $turnId = 'turn-finished-before-prewarm'
        $startPayload = [ordered]@{
            hook_event_name = 'UserPromptSubmit'
            session_id = $sessionId
            turn_id = $turnId
            cwd = 'C:\work\private-name'
            prompt = 'private'
        } | ConvertTo-Json -Compress
        $stopPayload = [ordered]@{
            hook_event_name = 'Stop'
            session_id = $sessionId
            turn_id = $turnId
            cwd = 'C:\work\private-name'
            stop_hook_active = $false
            last_assistant_message = 'Done.'
        } | ConvertTo-Json -Compress

        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $startPayload -NoWorker
        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $stopPayload -NoWorker
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $state = Get-AgentBellState -Path (Join-Path $script:dataDir 'state\state.json')
        Test-AgentBellTurnActive -State $state -Key "$sessionId|$turnId" | Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'queue\prewarm') -Filter '*.json' -File).Count | Should Be 0
    }

    It 'prunes abandoned prewarm tickets with the normal queue retention policy' {
        $config = Get-AgentBellDefaultConfig
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config
        $prewarmDirectory = Join-Path $script:dataDir 'queue\prewarm'
        New-Item -ItemType Directory -Force -Path $prewarmDirectory | Out-Null
        $ticketPath = Join-Path $prewarmDirectory ('prewarm-' + [guid]::NewGuid().ToString('N') + '.json')
        Write-AgentBellJsonAtomic -Path $ticketPath -Value ([ordered]@{
            schema_version = 1
            session_id = '89898989-8989-8989-8989-898989898989'
            turn_id = 'abandoned'
            thread_source = 'user'
        })
        (Get-Item -LiteralPath $ticketPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        Test-Path -LiteralPath $ticketPath | Should Be $false
    }

    It 'deduplicates repeated stop events' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 0
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $payload = [ordered]@{
            hook_event_name = 'Stop'
            session_id = '44444444-4444-4444-4444-444444444444'
            turn_id = 'turn-4'
            cwd = 'C:\work\project'
            last_assistant_message = '任务已完成。'
        } | ConvertTo-Json -Compress

        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker
        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $lines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl'))
        $processed = @($lines | Where-Object { $_ -match 'Processed attention event' })
        $processed.Count | Should Be 1
        $processed[0] | Should Match '"event":"complete"'
        @($lines | Where-Object { $_ -match 'Suppressed a Stop candidate' }).Count | Should Be 1
    }

    It 'deduplicates initial and continued Stop events with zero debounce' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 0
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        foreach ($active in @($false, $true)) {
            $payload = [ordered]@{
                hook_event_name = 'Stop'
                session_id = '91919191-9191-9191-9191-919191919191'
                turn_id = 'same-zero-debounce-turn'
                cwd = 'C:\work\project'
                stop_hook_active = $active
                last_assistant_message = if ($active) { 'Task failed: final continuation failed.' } else { 'Done.' }
            } | ConvertTo-Json -Compress
            & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker
            Start-Sleep -Milliseconds 50
        }

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $lines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl'))
        $processed = @($lines | Where-Object { $_ -match 'Processed attention event' })
        $processed.Count | Should Be 1
        $processed[0] | Should Match '"event":"failure"'
        $processed[0] | Should Not Match '"event":"complete"'
        @($lines | Where-Object { $_ -match 'Suppressed a Stop candidate' }).Count | Should Be 1
    }

    It 'keeps Stop notifications for different turns independent at zero debounce' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 0
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        foreach ($turnId in @('zero-debounce-turn-a', 'zero-debounce-turn-b')) {
            $payload = [ordered]@{
                hook_event_name = 'Stop'
                session_id = '92929292-9292-9292-9292-929292929292'
                turn_id = $turnId
                cwd = 'C:\work\project'
                stop_hook_active = $false
                last_assistant_message = 'Done.'
            } | ConvertTo-Json -Compress
            & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker
            Start-Sleep -Milliseconds 50
        }

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $lines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl'))
        @($lines | Where-Object { $_ -match 'Processed attention event' }).Count | Should Be 2
        @($lines | Where-Object { $_ -match 'Skipped duplicate event' }).Count | Should Be 0
    }

    It 'suppresses an initial Stop candidate when the same session becomes active during debounce' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 1
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $stopPayload = [ordered]@{
            hook_event_name = 'Stop'
            session_id = '66666666-6666-6666-6666-666666666666'
            turn_id = 'turn-before-continuation'
            cwd = 'C:\work\project'
            stop_hook_active = $false
            last_assistant_message = 'Done.'
        } | ConvertTo-Json -Compress
        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $stopPayload -NoWorker
        Start-Sleep -Milliseconds 50
        $startPayload = [ordered]@{
            hook_event_name = 'UserPromptSubmit'
            session_id = '66666666-6666-6666-6666-666666666666'
            turn_id = 'continuation-turn'
            cwd = 'C:\work\project'
            prompt = 'continue'
        } | ConvertTo-Json -Compress
        & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $startPayload -NoWorker

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $log = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl')
        $log | Should Match 'Suppressed a Stop candidate'
        $log | Should Not Match 'Processed attention event.*complete'
    }

    It 'retires an old Stop when a later different turn becomes active' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 1
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $sessionId = '94949494-9494-9494-9494-949494949494'
        $oldTurnId = 'old-turn'
        $newTurnId = 'new-turn'
        $pendingDirectory = Join-Path $script:dataDir 'queue\pending'
        New-Item -ItemType Directory -Force -Path $pendingDirectory | Out-Null
        $oldStart = ConvertTo-AgentBellEvent -Payload ([pscustomobject][ordered]@{
            hook_event_name = 'UserPromptSubmit'
            session_id = $sessionId
            turn_id = $oldTurnId
            cwd = 'C:\work\project'
        }) -CapturedAt ([DateTimeOffset]::Parse('2026-07-13T00:00:00Z'))
        $oldStop = ConvertTo-AgentBellEvent -Payload ([pscustomobject][ordered]@{
            hook_event_name = 'Stop'
            session_id = $sessionId
            turn_id = $oldTurnId
            cwd = 'C:\work\project'
            stop_hook_active = $false
            last_assistant_message = 'Done.'
        }) -CapturedAt ([DateTimeOffset]::Parse('2026-07-13T00:00:05Z'))
        $newStart = ConvertTo-AgentBellEvent -Payload ([pscustomobject][ordered]@{
            hook_event_name = 'UserPromptSubmit'
            session_id = $sessionId
            turn_id = $newTurnId
            cwd = 'C:\work\project'
        }) -CapturedAt ([DateTimeOffset]::Parse('2026-07-13T00:00:06Z'))
        Write-AgentBellJsonAtomic -Path (Join-Path $pendingDirectory '001-old-start.json') -Value $oldStart
        Write-AgentBellJsonAtomic -Path (Join-Path $pendingDirectory '002-old-stop.json') -Value $oldStop
        Write-AgentBellJsonAtomic -Path (Join-Path $pendingDirectory '003-new-start.json') -Value $newStart

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $statePath = Join-Path $script:dataDir 'state\state.json'
        $state = Get-AgentBellState -Path $statePath
        Test-AgentBellTurnActive -State $state -Key "$sessionId|$oldTurnId" | Should Be $false
        Test-AgentBellTurnActive -State $state -Key "$sessionId|$newTurnId" | Should Be $true
        Test-AgentBellHandled -State $state -Key ([string]$oldStop.dedupe_key) | Should Be $true

        $retriedOldStop = ConvertTo-AgentBellEvent -Payload ([pscustomobject][ordered]@{
            hook_event_name = 'Stop'
            session_id = $sessionId
            turn_id = $oldTurnId
            cwd = 'C:\work\project'
            stop_hook_active = $true
            last_assistant_message = 'Done.'
        }) -CapturedAt ([DateTimeOffset]::Parse('2026-07-13T00:00:07Z'))
        Write-AgentBellJsonAtomic -Path (Join-Path $pendingDirectory '004-retried-old-stop.json') -Value $retriedOldStop
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $lines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl'))
        @($lines | Where-Object { $_ -match 'Processed attention event' -and $_ -match '"event":"complete"' }).Count | Should Be 0
        @($lines | Where-Object { $_ -match 'Skipped duplicate event' }).Count | Should Be 1
        $state = Get-AgentBellState -Path $statePath
        @($state.turns).Count | Should Be 1
        Test-AgentBellTurnActive -State $state -Key "$sessionId|$newTurnId" | Should Be $true
    }

    It 'suppresses an earlier Stop candidate when a continued Stop arrives during debounce' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 1
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        foreach ($active in @($false, $true)) {
            $payload = [ordered]@{
                hook_event_name = 'Stop'
                session_id = '99999999-9999-9999-9999-999999999999'
                turn_id = 'continued-stop-turn'
                cwd = 'C:\work\project'
                stop_hook_active = $active
                last_assistant_message = 'Done.'
            } | ConvertTo-Json -Compress
            & $enqueuePath -PluginRoot $pluginRoot -DataDir $script:dataDir -TestJson $payload -NoWorker
            Start-Sleep -Milliseconds 50
        }

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $lines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl'))
        @($lines | Where-Object { $_ -match 'Suppressed a Stop candidate' }).Count | Should Be 1
        @($lines | Where-Object { $_ -match 'Processed attention event' -and $_ -match '"event":"complete"' }).Count | Should Be 1
    }

    It 'preserves turn duration and threshold decision for the final continued Stop' {
        $config = Get-AgentBellDefaultConfig
        $config.mode = 'threshold'
        $config.duration_threshold_seconds = 10
        $config.stop_debounce_seconds = 1
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config

        $sessionId = '93939393-9393-9393-9393-939393939393'
        $turnId = 'continued-duration-turn'
        $pendingDirectory = Join-Path $script:dataDir 'queue\pending'
        New-Item -ItemType Directory -Force -Path $pendingDirectory | Out-Null
        $start = ConvertTo-AgentBellEvent -Payload ([pscustomobject][ordered]@{
            hook_event_name = 'UserPromptSubmit'
            session_id = $sessionId
            turn_id = $turnId
            cwd = 'C:\work\project'
        }) -CapturedAt ([DateTimeOffset]::Parse('2026-07-13T00:00:00Z'))
        $initial = ConvertTo-AgentBellEvent -Payload ([pscustomobject][ordered]@{
            hook_event_name = 'Stop'
            session_id = $sessionId
            turn_id = $turnId
            cwd = 'C:\work\project'
            stop_hook_active = $false
            last_assistant_message = 'Done.'
        }) -CapturedAt ([DateTimeOffset]::Parse('2026-07-13T00:00:15Z'))
        $continued = ConvertTo-AgentBellEvent -Payload ([pscustomobject][ordered]@{
            hook_event_name = 'Stop'
            session_id = $sessionId
            turn_id = $turnId
            cwd = 'C:\work\project'
            stop_hook_active = $true
            last_assistant_message = 'Done.'
        }) -CapturedAt ([DateTimeOffset]::Parse('2026-07-13T00:00:16Z'))
        Write-AgentBellJsonAtomic -Path (Join-Path $pendingDirectory '001-start.json') -Value $start
        Write-AgentBellJsonAtomic -Path (Join-Path $pendingDirectory '002-initial-stop.json') -Value $initial
        Write-AgentBellJsonAtomic -Path (Join-Path $pendingDirectory '003-continued-stop.json') -Value $continued

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        $lines = @(Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl'))
        @($lines | Where-Object { $_ -match 'Suppressed a Stop candidate' }).Count | Should Be 1
        $processed = @($lines | Where-Object { $_ -match 'Processed attention event' -and $_ -match '"event":"complete"' })
        $processed.Count | Should Be 1
        $processed[0] | Should Match '"decision":"speak"'
        $processed[0] | Should Match '"duration_seconds":16'
    }

    It 'recovers an orphaned processing event after a worker interruption' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 0
        Write-AgentBellJsonAtomic -Path (Join-Path $script:dataDir 'config.json') -Value $config
        $processingDirectory = Join-Path $script:dataDir 'queue\processing'
        New-Item -ItemType Directory -Force -Path $processingDirectory | Out-Null
        $payload = [pscustomobject][ordered]@{
            hook_event_name = 'PermissionRequest'
            session_id = '88888888-8888-8888-8888-888888888888'
            turn_id = 'turn-recover'
            cwd = 'C:\work\project'
            tool_name = 'Bash'
            tool_input = [pscustomobject]@{ description = 'test' }
        }
        $event = ConvertTo-AgentBellEvent -Payload $payload
        Write-AgentBellJsonAtomic -Path (Join-Path $processingDirectory 'orphan.json') -Value $event

        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerPath -DataDir $script:dataDir -PluginRoot $pluginRoot -DryRun

        @(Get-ChildItem -LiteralPath $processingDirectory -Filter '*.json').Count | Should Be 0
        $log = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:dataDir 'logs\agent-bell.jsonl')
        $log | Should Match 'Processed attention event'
        $log | Should Match '"event":"permission"'
    }
}
