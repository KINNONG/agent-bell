$ErrorActionPreference = 'Stop'

$setupPath = Join-Path $PSScriptRoot '..\plugins\agent-bell\scripts\setup.ps1'
$voicePackInstallPath = Join-Path $PSScriptRoot '..\plugins\agent-bell\voice-pack\install.ps1'
$voicePackUpdatePath = Join-Path $PSScriptRoot '..\plugins\agent-bell\voice-pack\update.ps1'
$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\plugins\agent-bell'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$updateTokens = $null
$updateParseErrors = $null
$updateAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $voicePackUpdatePath,
    [ref]$updateTokens,
    [ref]$updateParseErrors
)
if (@($updateParseErrors).Count -gt 0) {
    throw 'The Voice Pack updater could not be parsed for setup tests.'
}
$updateFunctionNames = @(
    'Test-ReparsePoint',
    'Assert-VoicePackRuntimeDestination',
    'Test-VoicePackTransactionCanBeRemoved',
    'Get-VoicePackRecoveryDetail',
    'Restore-VoicePackRuntime'
)
foreach ($functionName in $updateFunctionNames) {
    $functionAst = @($updateAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true))[0]
    if ($null -eq $functionAst) {
        throw "Voice Pack updater function was not found: $functionName"
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$installTokens = $null
$installParseErrors = $null
$installAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $voicePackInstallPath,
    [ref]$installTokens,
    [ref]$installParseErrors
)
if (@($installParseErrors).Count -gt 0) {
    throw 'The Voice Pack installer could not be parsed for setup tests.'
}
$installFunctionNames = @(
    'Test-CompleteVoicePackInstallation',
    'ConvertFrom-VoicePackNvidiaSmiOutput',
    'Assert-VoicePackPlatformPreflight',
    'Assert-VoicePackInstallPreflight'
)
foreach ($functionName in $installFunctionNames) {
    $functionAst = @($installAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true))[0]
    if ($null -eq $functionAst) {
        throw "Voice Pack installer function was not found: $functionName"
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Write-TestJson {
    param([string]$Path, [object]$Value)

    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function New-SetupTestEnvironment {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-bell-setup-' + [Guid]::NewGuid().ToString('N'))
    $codexHome = Join-Path $root '.codex'
    $dataDir = Join-Path $root 'agent-bell-data'
    [System.IO.Directory]::CreateDirectory($codexHome) | Out-Null

    $hooks = [pscustomobject][ordered]@{
        description = 'Keep this user hook document.'
        customMetadata = [pscustomobject][ordered]@{ owner = 'existing-user' }
        hooks = [pscustomobject][ordered]@{
            Stop = @(
                [pscustomobject][ordered]@{
                    hooks = @(
                        [pscustomobject][ordered]@{
                            type = 'command'
                            command = 'existing-stop-handler.exe'
                            commandWindows = 'existing-stop-handler.exe'
                            timeout = 11
                        }
                    )
                }
            )
            PermissionRequest = @(
                [pscustomobject][ordered]@{
                    matcher = 'Bash'
                    hooks = @(
                        [pscustomobject][ordered]@{
                            type = 'command'
                            command = 'existing-permission-handler.exe'
                            commandWindows = 'existing-permission-handler.exe'
                            timeout = 12
                        }
                    )
                }
            )
        }
    }
    Write-TestJson -Path (Join-Path $codexHome 'hooks.json') -Value $hooks

    $configToml = @'
model = "gpt-test"
notify = ["existing-notifier.exe", "turn-ended"]

[hooks.state.'keep-this-trust-record']
enabled = true
trusted_hash = "sha256:do-not-change"
'@
    [System.IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'), $configToml, $utf8NoBom)

    return [pscustomobject]@{
        Root = $root
        CodexHome = $codexHome
        DataDir = $dataDir
        HooksPath = Join-Path $codexHome 'hooks.json'
        ConfigPath = Join-Path $codexHome 'config.toml'
        OriginalConfig = $configToml
    }
}

function Invoke-SetupAction {
    param(
        [string]$Action,
        [object]$Environment,
        [switch]$DryRun,
        [switch]$PurgeData
    )

    $arguments = @{
        Action = $Action
        PluginRoot = $pluginRoot
        DataDir = $Environment.DataDir
        CodexHome = $Environment.CodexHome
        AsJson = $true
    }
    if ($DryRun.IsPresent) {
        $arguments['DryRun'] = $true
    }
    if ($PurgeData.IsPresent) {
        $arguments['PurgeData'] = $true
    }

    $output = & $setupPath @arguments
    return ((@($output) -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Get-TestHookHandlers {
    param([object]$Document)

    $handlers = @()
    foreach ($eventProperty in $Document.hooks.PSObject.Properties) {
        foreach ($group in @($eventProperty.Value)) {
            foreach ($handler in @($group.hooks)) {
                $handlers += $handler
            }
        }
    }
    return @($handlers)
}

Describe 'Agent Bell setup lifecycle' {
    BeforeEach {
        $testEnvironment = New-SetupTestEnvironment
    }

    AfterEach {
        if (Test-Path -LiteralPath $testEnvironment.Root) {
            Remove-Item -LiteralPath $testEnvironment.Root -Recurse -Force
        }
    }

    It 'initializes runtime data idempotently without changing Codex config.toml' {
        $first = Invoke-SetupAction -Action 'Initialize' -Environment $testEnvironment
        $configPath = Join-Path $testEnvironment.DataDir 'config.json'
        $firstConfig = [System.IO.File]::ReadAllText($configPath, $utf8NoBom)
        $second = Invoke-SetupAction -Action 'Initialize' -Environment $testEnvironment
        $secondConfig = [System.IO.File]::ReadAllText($configPath, $utf8NoBom)

        $first.Success | Should Be $true
        $first.ConfigCreated | Should Be $true
        $second.Success | Should Be $true
        $second.Changed | Should Be $false
        $firstConfig | Should Be $secondConfig
        (Test-Path -LiteralPath (Join-Path $testEnvironment.DataDir '.agent-bell-data')) | Should Be $true
        [System.IO.File]::ReadAllText($testEnvironment.ConfigPath, $utf8NoBom) |
            Should Be $testEnvironment.OriginalConfig
    }

    It 'initializes after the optional Voice Pack was installed first' {
        $voicePackDirectory = Join-Path $testEnvironment.DataDir 'voice-pack'
        [System.IO.Directory]::CreateDirectory($voicePackDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $voicePackDirectory 'private-voice.marker'), 'keep', $utf8NoBom)

        $result = Invoke-SetupAction -Action 'Initialize' -Environment $testEnvironment

        $result.Success | Should Be $true
        (Test-Path -LiteralPath (Join-Path $testEnvironment.DataDir '.agent-bell-data')) | Should Be $true
        [System.IO.File]::ReadAllText((Join-Path $voicePackDirectory 'private-voice.marker'), $utf8NoBom) |
            Should Be 'keep'
    }

    It 'merges local-development handlers once and preserves unrelated hooks and metadata' {
        $first = Invoke-SetupAction -Action 'EnableLocalDevelopment' -Environment $testEnvironment
        $second = Invoke-SetupAction -Action 'EnableLocalDevelopment' -Environment $testEnvironment
        $document = [System.IO.File]::ReadAllText($testEnvironment.HooksPath, $utf8NoBom) | ConvertFrom-Json
        $handlers = @(Get-TestHookHandlers -Document $document)
        $agentBellHandlers = @($handlers | Where-Object {
            $null -ne $_.PSObject.Properties['statusMessage'] -and
            ([string]$_.statusMessage).StartsWith('Agent Bell local development hook:')
        })

        $first.AddedHandlers | Should Be 3
        $second.AddedHandlers | Should Be 0
        $second.Changed | Should Be $false
        $agentBellHandlers.Count | Should Be 3
        @($handlers | Where-Object { $_.command -eq 'existing-stop-handler.exe' }).Count | Should Be 1
        @($handlers | Where-Object { $_.command -eq 'existing-permission-handler.exe' }).Count | Should Be 1
        $document.description | Should Be 'Keep this user hook document.'
        $document.customMetadata.owner | Should Be 'existing-user'
        [System.IO.File]::ReadAllText($testEnvironment.ConfigPath, $utf8NoBom) |
            Should Be $testEnvironment.OriginalConfig
    }

    It 'uninstalls only Agent Bell handlers and preserves data by default' {
        $null = Invoke-SetupAction -Action 'EnableLocalDevelopment' -Environment $testEnvironment
        $first = Invoke-SetupAction -Action 'UninstallLocalDevelopment' -Environment $testEnvironment
        $second = Invoke-SetupAction -Action 'UninstallLocalDevelopment' -Environment $testEnvironment
        $document = [System.IO.File]::ReadAllText($testEnvironment.HooksPath, $utf8NoBom) | ConvertFrom-Json
        $handlers = @(Get-TestHookHandlers -Document $document)

        $first.RemovedHandlers | Should Be 3
        $first.DataPreserved | Should Be $true
        $second.RemovedHandlers | Should Be 0
        $second.Changed | Should Be $false
        @($handlers | Where-Object { $_.command -eq 'existing-stop-handler.exe' }).Count | Should Be 1
        @($handlers | Where-Object { $_.command -eq 'existing-permission-handler.exe' }).Count | Should Be 1
        @($handlers | Where-Object {
            $null -ne $_.PSObject.Properties['statusMessage'] -and
            ([string]$_.statusMessage).StartsWith('Agent Bell local development hook:')
        }).Count | Should Be 0
        (Test-Path -LiteralPath $testEnvironment.DataDir -PathType Container) | Should Be $true
        [System.IO.File]::ReadAllText($testEnvironment.ConfigPath, $utf8NoBom) |
            Should Be $testEnvironment.OriginalConfig
    }

    It 'purges only an explicitly requested and marked Agent Bell data directory' {
        $null = Invoke-SetupAction -Action 'EnableLocalDevelopment' -Environment $testEnvironment

        $result = Invoke-SetupAction -Action 'UninstallLocalDevelopment' -Environment $testEnvironment -PurgeData

        $result.Success | Should Be $true
        $result.DataRemoved | Should Be $true
        (Test-Path -LiteralPath $testEnvironment.DataDir) | Should Be $false
        [System.IO.File]::ReadAllText($testEnvironment.ConfigPath, $utf8NoBom) |
            Should Be $testEnvironment.OriginalConfig
    }

    It 'preserves an optional Voice Pack during an explicit main-data purge' {
        $null = Invoke-SetupAction -Action 'Initialize' -Environment $testEnvironment
        $voicePackDirectory = Join-Path $testEnvironment.DataDir 'voice-pack'
        [System.IO.Directory]::CreateDirectory($voicePackDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $voicePackDirectory 'private-voice.marker'), 'keep', $utf8NoBom)

        $result = Invoke-SetupAction -Action 'UninstallLocalDevelopment' -Environment $testEnvironment -PurgeData

        $result.Success | Should Be $true
        (Test-Path -LiteralPath (Join-Path $voicePackDirectory 'private-voice.marker') -PathType Leaf) |
            Should Be $true
        (Test-Path -LiteralPath (Join-Path $testEnvironment.DataDir 'config.json')) | Should Be $false
    }

    It 'uses AGENT_BELL_DATA instead of an unrelated PLUGIN_DATA value' {
        $agentBellData = Join-Path $testEnvironment.Root 'agent-bell-env-data'
        $pluginData = Join-Path $testEnvironment.Root 'unrelated-plugin-data'
        $previousAgentBellData = $env:AGENT_BELL_DATA
        $previousPluginData = $env:PLUGIN_DATA
        try {
            $env:AGENT_BELL_DATA = $agentBellData
            $env:PLUGIN_DATA = $pluginData
            $output = & $setupPath -Action Initialize -PluginRoot $pluginRoot -CodexHome $testEnvironment.CodexHome -AsJson
            $result = ((@($output) -join [Environment]::NewLine) | ConvertFrom-Json)
        }
        finally {
            $env:AGENT_BELL_DATA = $previousAgentBellData
            $env:PLUGIN_DATA = $previousPluginData
        }

        $result.Success | Should Be $true
        [System.IO.Path]::GetFullPath([string]$result.DataDir) | Should Be ([System.IO.Path]::GetFullPath($agentBellData))
        (Test-Path -LiteralPath $pluginData) | Should Be $false
    }

    It 'refuses to initialize inside the non-empty Codex home' {
        $unsafeEnvironment = [pscustomobject]@{
            Root = $testEnvironment.Root
            CodexHome = $testEnvironment.CodexHome
            DataDir = $testEnvironment.CodexHome
            HooksPath = $testEnvironment.HooksPath
            ConfigPath = $testEnvironment.ConfigPath
            OriginalConfig = $testEnvironment.OriginalConfig
        }
        { Invoke-SetupAction -Action 'Initialize' -Environment $unsafeEnvironment } |
            Should Throw

        (Test-Path -LiteralPath $testEnvironment.CodexHome -PathType Container) | Should Be $true
        [System.IO.File]::ReadAllText($testEnvironment.ConfigPath, $utf8NoBom) |
            Should Be $testEnvironment.OriginalConfig
    }

    It 'runs a dry pipeline test and reports doctor results without changing Codex config.toml' {
        $null = Invoke-SetupAction -Action 'Initialize' -Environment $testEnvironment
        $testResult = Invoke-SetupAction -Action 'Test' -Environment $testEnvironment -DryRun
        $doctor = Invoke-SetupAction -Action 'Doctor' -Environment $testEnvironment

        $testResult.Success | Should Be $true
        $testResult.Pipeline | Should Be 'ok'
        $testResult.AudioPlayed | Should Be $false
        $doctor.Success | Should Be $true
        $doctor.NotifyOrConfigTomlModified | Should Be $false
        $doctor.TrustState | Should Be 'not modified or inferred'
        [System.IO.File]::ReadAllText($testEnvironment.ConfigPath, $utf8NoBom) |
            Should Be $testEnvironment.OriginalConfig
    }

    It 'keeps SAPI installs independent of the optional Voice Pack' {
        $null = Invoke-SetupAction -Action 'Initialize' -Environment $testEnvironment

        $doctor = Invoke-SetupAction -Action 'Doctor' -Environment $testEnvironment

        $doctor.Success | Should Be $true
        @($doctor.Checks | Where-Object { $_.Name -eq 'voice-pack-low-latency' }).Count |
            Should Be 0
    }

    It 'keeps normal agent onboarding explicitly model-free' {
        $skillSource = [System.IO.File]::ReadAllText(
            (Join-Path $pluginRoot 'skills\setup\SKILL.md'),
            $utf8NoBom
        )
        $manifest = [System.IO.File]::ReadAllText(
            (Join-Path $pluginRoot '.codex-plugin\plugin.json'),
            $utf8NoBom
        ) | ConvertFrom-Json

        $skillSource | Should Match 'Default to model-free Lite mode'
        $skillSource | Should Match ([regex]::Escape('Never run `voice-pack\install.ps1`'))
        ([string]$manifest.interface.defaultPrompt[0]) | Should Match 'model-free Lite mode'
    }

    It 'fails Doctor clearly when the configured HTTP Voice Pack is unavailable' {
        $null = Invoke-SetupAction -Action 'Initialize' -Environment $testEnvironment
        $runtimeConfigPath = Join-Path $testEnvironment.DataDir 'config.json'
        $runtimeConfig = [System.IO.File]::ReadAllText($runtimeConfigPath, $utf8NoBom) | ConvertFrom-Json
        $runtimeConfig.voice.provider = 'http'
        $runtimeConfig.voice.http.endpoint = 'http://127.0.0.1:1/synthesize'
        Write-TestJson -Path $runtimeConfigPath -Value $runtimeConfig

        $doctor = Invoke-SetupAction -Action 'Doctor' -Environment $testEnvironment
        $voicePackCheck = @($doctor.Checks | Where-Object { $_.Name -eq 'voice-pack-low-latency' })[0]

        $doctor.Success | Should Be $false
        $voicePackCheck.Passed | Should Be $false
        $voicePackCheck.Detail | Should Match 'unavailable'
    }

    It 'refuses to update an unmarked directory without changing its contents' {
        $unmarkedRoot = Join-Path $testEnvironment.Root 'unmarked-voice-pack'
        [System.IO.Directory]::CreateDirectory($unmarkedRoot) | Out-Null
        $privateSentinel = Join-Path $unmarkedRoot 'private-sentinel.txt'
        [System.IO.File]::WriteAllText($privateSentinel, 'keep', $utf8NoBom)

        { & $voicePackUpdatePath -InstallRoot $unmarkedRoot -ReadyTimeoutSeconds 30 } |
            Should Throw

        [System.IO.File]::ReadAllText($privateSentinel, $utf8NoBom) | Should Be 'keep'
        @(Get-ChildItem -LiteralPath $unmarkedRoot -Force).Count | Should Be 1
    }

    It 'rolls back only runtime files whose replacement completed' {
        $voicePackRoot = Join-Path $testEnvironment.Root 'rollback-voice-pack'
        $appDirectory = Join-Path $voicePackRoot 'app'
        $backupDirectory = Join-Path $voicePackRoot 'transaction\backup'
        foreach ($directory in @(
            $appDirectory,
            $backupDirectory,
            (Join-Path $voicePackRoot 'voices'),
            (Join-Path $voicePackRoot 'models'),
            (Join-Path $voicePackRoot '.venv')
        )) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }

        $serverPath = Join-Path $appDirectory 'server.py'
        $startPath = Join-Path $appDirectory 'start.ps1'
        [System.IO.File]::WriteAllText($serverPath, 'new server', $utf8NoBom)
        [System.IO.File]::WriteAllText($startPath, 'original start', $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $backupDirectory 'server.py'), 'old server', $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $backupDirectory 'start.ps1'), 'original start', $utf8NoBom)
        foreach ($privateDirectory in @('voices', 'models', '.venv')) {
            [System.IO.File]::WriteAllText(
                (Join-Path $voicePackRoot "$privateDirectory\private-sentinel.txt"),
                'keep',
                $utf8NoBom
            )
        }
        $records = @(
            [pscustomobject]@{ Sequence = 0; Name = 'server.py'; HadOriginal = $true; Replaced = $true },
            [pscustomobject]@{ Sequence = 1; Name = 'start.ps1'; HadOriginal = $true; Replaced = $false }
        )

        $lockedStart = [System.IO.File]::Open(
            $startPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            { Restore-VoicePackRuntime -AppDirectory $appDirectory -BackupDirectory $backupDirectory -Records $records } |
                Should Not Throw
        }
        finally {
            $lockedStart.Dispose()
        }

        [System.IO.File]::ReadAllText($serverPath, $utf8NoBom) | Should Be 'old server'
        [System.IO.File]::ReadAllText($startPath, $utf8NoBom) | Should Be 'original start'
        @(Get-ChildItem -LiteralPath $appDirectory -Filter '.agent-bell-restore-*' -Force).Count | Should Be 0
        foreach ($privateDirectory in @('voices', 'models', '.venv')) {
            [System.IO.File]::ReadAllText(
                (Join-Path $voicePackRoot "$privateDirectory\private-sentinel.txt"),
                $utf8NoBom
            ) | Should Be 'keep'
        }
    }

    It 'rejects a runtime destination that is a directory' {
        $appDirectory = Join-Path $testEnvironment.Root 'directory-runtime\app'
        $backupDirectory = Join-Path $testEnvironment.Root 'directory-runtime\backup'
        $directoryDestination = Join-Path $appDirectory 'server.py'
        [System.IO.Directory]::CreateDirectory($directoryDestination) | Out-Null
        [System.IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
        $sentinel = Join-Path $directoryDestination 'keep.txt'
        [System.IO.File]::WriteAllText($sentinel, 'keep', $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $backupDirectory 'server.py'), 'old server', $utf8NoBom)
        $records = @(
            [pscustomobject]@{ Sequence = 0; Name = 'server.py'; HadOriginal = $true; Replaced = $true }
        )

        { Restore-VoicePackRuntime -AppDirectory $appDirectory -BackupDirectory $backupDirectory -Records $records } |
            Should Throw

        (Test-Path -LiteralPath $directoryDestination -PathType Container) | Should Be $true
        [System.IO.File]::ReadAllText($sentinel, $utf8NoBom) | Should Be 'keep'
        @(Get-ChildItem -LiteralPath $directoryDestination -Force).Count | Should Be 1
        @(Get-ChildItem -LiteralPath $appDirectory -Filter '.agent-bell-restore-*' -Force).Count | Should Be 0
    }

    It 'keeps recovery files unless update or rollback completed safely' {
        (Test-VoicePackTransactionCanBeRemoved -UpdateCompleted $false -RollbackCompleted $false) |
            Should Be $false
        (Test-VoicePackTransactionCanBeRemoved -UpdateCompleted $true -RollbackCompleted $false) |
            Should Be $true
        (Test-VoicePackTransactionCanBeRemoved -UpdateCompleted $false -RollbackCompleted $true) |
            Should Be $true

        $transactionPath = Join-Path $testEnvironment.Root '.agent-bell-runtime-update-test'
        (Get-VoicePackRecoveryDetail -TransactionPath $transactionPath) |
            Should Be "Recovery files were preserved at: $transactionPath"
    }

    It 'requires both explicit consents and runs preflight before install writes' {
        $source = [System.IO.File]::ReadAllText($voicePackInstallPath, $utf8NoBom)
        $rightsConsentIndex = $source.IndexOf('if (-not $ConfirmVoiceRights.IsPresent)')
        $consentIndex = $source.IndexOf('if (-not $ConfirmLargeDownload.IsPresent)')
        $preflightIndex = $source.LastIndexOf('Assert-VoicePackInstallPreflight')
        $firstInstallWriteIndex = $source.IndexOf('[System.IO.Directory]::CreateDirectory($fullInstallRoot)')
        $markerWriteIndex = $source.IndexOf('[System.IO.File]::WriteAllText(')
        $appCopyIndex = $source.IndexOf('Copy-Item -LiteralPath $sourcePath')
        $venvCreateIndex = $source.IndexOf("'venv',")
        $referencePath = Join-Path $testEnvironment.Root 'reference.wav'
        $installRoot = Join-Path $testEnvironment.Root 'unconfirmed-voice-pack'
        [System.IO.File]::WriteAllText($referencePath, 'test', $utf8NoBom)

        $source.Contains('[switch]$ConfirmLargeDownload') | Should Be $true
        ($rightsConsentIndex -ge 0) | Should Be $true
        ($consentIndex -ge 0) | Should Be $true
        ($preflightIndex -gt $consentIndex) | Should Be $true
        ($firstInstallWriteIndex -gt $preflightIndex) | Should Be $true
        ($markerWriteIndex -gt $preflightIndex) | Should Be $true
        ($appCopyIndex -gt $preflightIndex) | Should Be $true
        ($venvCreateIndex -gt $preflightIndex) | Should Be $true
        {
            & $voicePackInstallPath `
                -ConfirmVoiceRights `
                -ReferenceAudio $referencePath `
                -ReferenceText 'test' `
                -InstallRoot $installRoot
        } | Should Throw
        (Test-Path -LiteralPath $installRoot) | Should Be $false

        {
            & $voicePackInstallPath `
                -ConfirmLargeDownload `
                -ReferenceAudio $referencePath `
                -ReferenceText 'test' `
                -InstallRoot $installRoot
        } | Should Throw
        (Test-Path -LiteralPath $installRoot) | Should Be $false
    }

    It 'parses only CUDA device zero from nvidia-smi preflight output' {
        $profile = ConvertFrom-VoicePackNvidiaSmiOutput -Lines @(
            '1, GPU-11111111-1111-1111-1111-111111111111, 9.0, 24576',
            '0, GPU-00000000-0000-0000-0000-000000000000, 8.9, 8188'
        )

        $profile.Index | Should Be 0
        $profile.Uuid | Should Be 'GPU-00000000-0000-0000-0000-000000000000'
        $profile.ComputeCapability | Should Be 8.9
        $profile.VramMiB | Should Be 8188

        {
            ConvertFrom-VoicePackNvidiaSmiOutput -Lines @('0, not-a-gpu-uuid, 8.9, 8188')
        } | Should Throw
    }

    It 'rejects unsupported platforms and missing nvidia-smi before hardware queries' {
        {
            Assert-VoicePackPlatformPreflight -IsWindows $false -NvidiaSmiAvailable $true
        } | Should Throw
        {
            Assert-VoicePackPlatformPreflight -IsWindows $true -NvidiaSmiAvailable $false
        } | Should Throw
        {
            Assert-VoicePackPlatformPreflight -IsWindows $true -NvidiaSmiAvailable $true
        } | Should Not Throw
    }

    It 'enforces the new-install hardware and disk floors' {
        {
            Assert-VoicePackInstallPreflight `
                -ComputeCapability 8.0 `
                -VramMiB 6144 `
                -RamBytes 16GB `
                -AvailableDiskBytes 12GB `
                -CompleteExistingInstallation $false
        } | Should Not Throw

        {
            Assert-VoicePackInstallPreflight `
                -ComputeCapability 7.9 `
                -VramMiB 6144 `
                -RamBytes 16GB `
                -AvailableDiskBytes 12GB `
                -CompleteExistingInstallation $false
        } | Should Throw
        {
            Assert-VoicePackInstallPreflight `
                -ComputeCapability 8.0 `
                -VramMiB 6143 `
                -RamBytes 16GB `
                -AvailableDiskBytes 12GB `
                -CompleteExistingInstallation $false
        } | Should Throw
        {
            Assert-VoicePackInstallPreflight `
                -ComputeCapability 8.0 `
                -VramMiB 6144 `
                -RamBytes (16GB - 1) `
                -AvailableDiskBytes 12GB `
                -CompleteExistingInstallation $false
        } | Should Throw
        {
            Assert-VoicePackInstallPreflight `
                -ComputeCapability 8.0 `
                -VramMiB 6144 `
                -RamBytes 16GB `
                -AvailableDiskBytes (12GB - 1) `
                -CompleteExistingInstallation $false
        } | Should Throw
    }

    It 'uses the smaller disk floor only for a complete existing installation' {
        $installRoot = Join-Path $testEnvironment.Root 'existing-voice-pack'
        $requiredFiles = @(
            '.agent-bell-qwen-voice-pack',
            '.venv\Scripts\python.exe',
            '.venv\Lib\site-packages\torch\__init__.py',
            '.venv\Lib\site-packages\torchaudio\__init__.py',
            '.venv\Lib\site-packages\qwen_tts\__init__.py',
            'models\Qwen3-TTS-12Hz-0.6B-Base\config.json',
            'models\Qwen3-TTS-12Hz-0.6B-Base\model.safetensors',
            'models\Qwen3-TTS-12Hz-0.6B-Base\speech_tokenizer\config.json',
            'models\Qwen3-TTS-12Hz-0.6B-Base\speech_tokenizer\model.safetensors'
        )
        foreach ($relativePath in $requiredFiles) {
            $path = Join-Path $installRoot $relativePath
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
            [System.IO.File]::WriteAllText($path, 'test', $utf8NoBom)
        }

        (Test-CompleteVoicePackInstallation -InstallRoot $installRoot) | Should Be $true
        {
            Assert-VoicePackInstallPreflight `
                -ComputeCapability 8.0 `
                -VramMiB 6144 `
                -RamBytes 16GB `
                -AvailableDiskBytes 2GB `
                -CompleteExistingInstallation $true
        } | Should Not Throw
        {
            Assert-VoicePackInstallPreflight `
                -ComputeCapability 8.0 `
                -VramMiB 6144 `
                -RamBytes 16GB `
                -AvailableDiskBytes (2GB - 1) `
                -CompleteExistingInstallation $true
        } | Should Throw

        Remove-Item -LiteralPath (Join-Path $installRoot '.venv\Scripts\python.exe') -Force
        (Test-CompleteVoicePackInstallation -InstallRoot $installRoot) | Should Be $false
    }

    It 'disables the pip download cache for every installer pip install' {
        $source = [System.IO.File]::ReadAllText($voicePackInstallPath, $utf8NoBom)

        ([regex]::Matches($source, "'-m', 'pip', 'install'").Count) | Should Be 3
        ([regex]::Matches($source, "'--no-cache-dir'").Count) | Should Be 3
        $source.Contains('and torch.cuda.is_bf16_supported()') | Should Be $true
        $source.Contains('$env:CUDA_DEVICE_ORDER = ''PCI_BUS_ID''') | Should Be $true
        $source.Contains('$env:CUDA_VISIBLE_DEVICES = [string]$hardwareProfile.GpuUuid') | Should Be $true
    }
}
