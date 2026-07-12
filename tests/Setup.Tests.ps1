$ErrorActionPreference = 'Stop'

$setupPath = Join-Path $PSScriptRoot '..\plugins\agent-bell\scripts\setup.ps1'
$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\plugins\agent-bell'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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
}
