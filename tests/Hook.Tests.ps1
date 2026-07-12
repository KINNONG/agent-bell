$ErrorActionPreference = 'Stop'

$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\plugins\agent-bell')).Path
$enqueuePath = Join-Path $pluginRoot 'hooks\enqueue.ps1'
$workerPath = Join-Path $pluginRoot 'scripts\worker.ps1'
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

Describe 'Agent Bell hook queue' {
    BeforeEach {
        $script:dataDir = Join-Path $env:TEMP ('agent-bell-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:dataDir | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
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
        @($lines | Where-Object { $_ -match 'Processed attention event' }).Count | Should Be 1
        @($lines | Where-Object { $_ -match 'Skipped duplicate event' }).Count | Should Be 1
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
