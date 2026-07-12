$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\plugins\agent-bell\scripts\AgentBell.Core.psm1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\session_index.jsonl'

$moduleImportError = $null
if (Test-Path -LiteralPath $modulePath) {
    try {
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    }
    catch {
        $moduleImportError = $_
    }
}

Describe 'Agent Bell core module contract' {
    It 'has a loadable core module' {
        (Test-Path -LiteralPath $modulePath -PathType Leaf) | Should Be $true
        ($null -eq $moduleImportError) | Should Be $true
    }
}

Describe 'Agent Bell configuration validation' {
    It 'rejects queue limits that would discard every event' {
        $config = Get-AgentBellDefaultConfig
        $config.limits.queue_entries = -1
        $path = Join-Path $TestDrive 'invalid-queue.json'
        Write-AgentBellJsonAtomic -Path $path -Value $config

        { Get-AgentBellConfig -Path $path } | Should Throw
    }

    It 'rejects a debounce that can hold the worker indefinitely' {
        $config = Get-AgentBellDefaultConfig
        $config.stop_debounce_seconds = 121
        $path = Join-Path $TestDrive 'invalid-debounce.json'
        Write-AgentBellJsonAtomic -Path $path -Value $config

        { Get-AgentBellConfig -Path $path } | Should Throw
    }

    It 'rejects an excessive local voice timeout' {
        $config = Get-AgentBellDefaultConfig
        $config.voice.http.timeout_seconds = 301
        $path = Join-Path $TestDrive 'invalid-timeout.json'
        Write-AgentBellJsonAtomic -Path $path -Value $config

        { Get-AgentBellConfig -Path $path } | Should Throw
    }
}

Describe 'Agent Bell title handling' {
    It 'removes control characters, collapses whitespace, and trims the title' {
        $title = "`t  Agent`r`n  Bell`a   开源版  "

        ConvertTo-AgentBellTitle -Title $title -MaxLength 48 -FallbackTitle 'Codex' |
            Should Be 'Agent Bell 开源版'
    }

    It 'uses the privacy-safe fallback for an empty title' {
        ConvertTo-AgentBellTitle -Title "`r`n`t" -MaxLength 48 -FallbackTitle 'Codex' |
            Should Be 'Codex'
    }

    It 'bounds long titles and marks truncation with three dots' {
        $title = '这是一个非常非常长的会话标题用于测试截断'
        $expected = $title.Substring(0, 9) + '...'

        $actual = ConvertTo-AgentBellTitle -Title $title -MaxLength 12 -FallbackTitle 'Codex'

        $actual | Should Be $expected
        $actual.Length | Should Be 12
    }

    It 'resolves the latest matching title from the JSONL fixture' {
        $actual = Get-AgentBellConversationTitle `
            -SessionId '11111111-1111-1111-1111-111111111111' `
            -SessionIndexPath $fixturePath `
            -MaxLength 48 `
            -FallbackTitle 'Codex'

        $actual | Should Be 'Agent Bell 开源版'
    }
}

Describe 'Agent Bell announcement wording' {
    It 'formats the completion announcement' {
        Get-AgentBellAnnouncement -Kind 'complete' -Title 'Agent Bell' |
            Should Be '主人，Agent Bell 任务已完成，请回来查看了。'
    }

    It 'formats the permission announcement' {
        Get-AgentBellAnnouncement -Kind 'permission' -Title 'Agent Bell' |
            Should Be '主人，Agent Bell 正在等待您的确认，请回来处理。'
    }

    It 'formats the conservative failure announcement' {
        Get-AgentBellAnnouncement -Kind 'failure' -Title 'Agent Bell' |
            Should Be '主人，Agent Bell 执行遇到问题，请回来查看。'
    }
}

Describe 'Agent Bell smart completion policy' {
    It 'uses a Windows notification below both thresholds' {
        Get-AgentBellCompletionAction -DurationSeconds 59.999 -IdleSeconds 44.999 |
            Should Be 'notify'
    }

    It 'speaks at the exact 60-second duration boundary' {
        Get-AgentBellCompletionAction -DurationSeconds 60 -IdleSeconds 0 |
            Should Be 'speak'
    }

    It 'speaks at the exact 45-second idle boundary' {
        Get-AgentBellCompletionAction -DurationSeconds 0 -IdleSeconds 45 |
            Should Be 'speak'
    }

    It 'speaks when either threshold is exceeded' {
        Get-AgentBellCompletionAction -DurationSeconds 61 -IdleSeconds 1 |
            Should Be 'speak'
        Get-AgentBellCompletionAction -DurationSeconds 1 -IdleSeconds 46 |
            Should Be 'speak'
    }
}

Describe 'Agent Bell conservative failure classification' {
    $explicitFailures = @(
        '任务执行失败，原因是构建命令返回了非零退出码。',
        '无法完成该任务：缺少必须的本地依赖。',
        'Task failed: the build exited with code 1.',
        'I could not complete the task because the required file is missing.'
    )

    foreach ($message in $explicitFailures) {
        It "classifies an explicit final failure: $message" {
            Test-AgentBellExplicitFailure -Message $message | Should Be $true
        }
    }

    $nonFailures = @(
        '测试一开始失败，但修复后已经全部通过。',
        '我没有发现失败或错误。',
        '任务已经完成，所有验证均通过。',
        '有一个可能的问题，建议稍后检查。',
        'The earlier build failed, but the final run passed.'
    )

    foreach ($message in $nonFailures) {
        It "does not infer failure from ambiguous or resolved wording: $message" {
            Test-AgentBellExplicitFailure -Message $message | Should Be $false
        }
    }
}

Describe 'Agent Bell Stop continuation handling' {
    It 'keeps initial and continued Stop candidates in separate dedupe slots' {
        $base = [ordered]@{
            hook_event_name = 'Stop'
            session_id = '77777777-7777-7777-7777-777777777777'
            turn_id = 'turn-stop-active'
            cwd = 'C:\work\project'
            last_assistant_message = 'Done.'
        }
        $base.stop_hook_active = $false
        $initial = ConvertTo-AgentBellEvent -Payload ([pscustomobject]$base)
        $base.stop_hook_active = $true
        $continued = ConvertTo-AgentBellEvent -Payload ([pscustomobject]$base)

        $initial.stop_hook_active | Should Be $false
        $continued.stop_hook_active | Should Be $true
        $initial.dedupe_key | Should Not Be $continued.dedupe_key
    }
}

Describe 'Agent Bell privacy-safe logging' {
    It 'keeps operational metadata but removes private hook data by default' {
        $record = New-AgentBellLogRecord -Level 'info' -Event 'announcement' -Data @{
            action                 = 'speak'
            kind                   = 'complete'
            duration_seconds       = 75
            title                  = '绝密客户项目'
            session_id             = '11111111-1111-1111-1111-111111111111'
            prompt                 = '不要记录这条用户提示'
            transcript_path        = 'C:\private\transcript.jsonl'
            tool_command           = 'Remove-Item C:\private\secret.txt'
            last_assistant_message = '完整助手回复也不应进入日志'
        }
        $json = $record | ConvertTo-Json -Compress -Depth 6

        $json | Should Match '"action":"speak"'
        $json | Should Match '"kind":"complete"'
        $json | Should Match '"duration_seconds":75'
        $json | Should Not Match ([regex]::Escape('绝密客户项目'))
        $json | Should Not Match ([regex]::Escape('11111111-1111-1111-1111-111111111111'))
        $json | Should Not Match ([regex]::Escape('不要记录这条用户提示'))
        $json | Should Not Match ([regex]::Escape('C:\private\transcript.jsonl'))
        $json | Should Not Match ([regex]::Escape('Remove-Item C:\private\secret.txt'))
        $json | Should Not Match ([regex]::Escape('完整助手回复也不应进入日志'))
    }
}

Describe 'Agent Bell local voice boundary' {
    It 'rejects a non-loopback voice endpoint before sending announcement text' {
        $config = Get-AgentBellDefaultConfig
        $config.voice.http.endpoint = 'https://example.com/synthesize'
        $outputPath = Join-Path $env:TEMP ('agent-bell-http-' + [guid]::NewGuid().ToString('N') + '.wav')

        { Invoke-AgentBellHttpVoice -Message 'private conversation title' -Config $config -OutputPath $outputPath } |
            Should Throw

        (Test-Path -LiteralPath $outputPath) | Should Be $false
    }
}

Describe 'Agent Bell dedupe pruning' {
    It 'drops expired entries, keeps only the newest duplicate, and caps state size' {
        $now = [DateTimeOffset]::Parse('2026-07-12T10:00:00Z')
        $entries = @(
            [pscustomobject]@{ key = 'expired'; timestamp = '2026-07-12T09:57:59Z' },
            [pscustomobject]@{ key = 'oldest-recent'; timestamp = '2026-07-12T09:58:30Z' },
            [pscustomobject]@{ key = 'duplicate'; timestamp = '2026-07-12T09:59:00Z' },
            [pscustomobject]@{ key = 'middle'; timestamp = '2026-07-12T09:59:30Z' },
            [pscustomobject]@{ key = 'duplicate'; timestamp = '2026-07-12T09:59:40Z' },
            [pscustomobject]@{ key = 'newest'; timestamp = '2026-07-12T09:59:50Z' }
        )

        $actual = @(Limit-AgentBellDedupeEntries `
            -Entries $entries `
            -Now $now `
            -MaxAgeSeconds 120 `
            -MaxEntries 3)

        $actual.Count | Should Be 3
        (($actual | ForEach-Object { $_.key }) -join ',') |
            Should Be 'middle,duplicate,newest'
        @($actual | Where-Object { $_.key -eq 'duplicate' }).Count | Should Be 1
        ($actual | Where-Object { $_.key -eq 'duplicate' }).timestamp |
            Should Be '2026-07-12T09:59:40Z'
    }

    It 'retains an entry exactly on the maximum-age boundary' {
        $now = [DateTimeOffset]::Parse('2026-07-12T10:00:00Z')
        $entries = @(
            [pscustomobject]@{ key = 'boundary'; timestamp = '2026-07-12T09:58:00Z' }
        )

        $actual = @(Limit-AgentBellDedupeEntries `
            -Entries $entries `
            -Now $now `
            -MaxAgeSeconds 120 `
            -MaxEntries 3)

        $actual.Count | Should Be 1
        $actual[0].key | Should Be 'boundary'
    }
}
