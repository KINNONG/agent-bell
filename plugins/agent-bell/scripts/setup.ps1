[CmdletBinding()]
param(
    [ValidateSet('Initialize', 'Test', 'Doctor', 'EnableLocalDevelopment', 'UninstallLocalDevelopment')]
    [string]$Action = 'Initialize',
    [string]$PluginRoot,
    [string]$DataDir,
    [string]$CodexHome,
    [switch]$DryRun,
    [switch]$PurgeData,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:LocalHookMarkerPrefix = 'Agent Bell local development hook:'

function Resolve-AgentBellSetupPaths {
    param(
        [string]$RequestedPluginRoot,
        [string]$RequestedDataDir,
        [string]$RequestedCodexHome
    )

    $resolvedPluginRoot = if ([string]::IsNullOrWhiteSpace($RequestedPluginRoot)) {
        Split-Path -Parent $PSScriptRoot
    }
    else {
        $RequestedPluginRoot
    }
    $resolvedPluginRoot = [System.IO.Path]::GetFullPath($resolvedPluginRoot)

    $resolvedDataDir = if ([string]::IsNullOrWhiteSpace($RequestedDataDir)) {
        if (-not [string]::IsNullOrWhiteSpace($env:AGENT_BELL_DATA)) {
            $env:AGENT_BELL_DATA
        }
        else {
            Join-Path $env:LOCALAPPDATA 'AgentBell'
        }
    }
    else {
        $RequestedDataDir
    }
    $resolvedDataDir = [System.IO.Path]::GetFullPath($resolvedDataDir)

    $resolvedCodexHome = if ([string]::IsNullOrWhiteSpace($RequestedCodexHome)) {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $env:CODEX_HOME
        }
        else {
            Join-Path $HOME '.codex'
        }
    }
    else {
        $RequestedCodexHome
    }
    $resolvedCodexHome = [System.IO.Path]::GetFullPath($resolvedCodexHome)

    return [pscustomobject][ordered]@{
        PluginRoot = $resolvedPluginRoot
        DataDir = $resolvedDataDir
        CodexHome = $resolvedCodexHome
        UserHooksPath = Join-Path $resolvedCodexHome 'hooks.json'
        UserConfigPath = Join-Path $resolvedCodexHome 'config.toml'
    }
}

function Invoke-AgentBellHooksMutation {
    param([Parameter(Mandatory = $true)][scriptblock]$Operation)

    $mutex = New-Object System.Threading.Mutex($false, 'Local\AgentBellHooksSetup')
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            throw 'Timed out waiting for another Agent Bell setup operation to finish.'
        }
        return & $Operation
    }
    finally {
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Write-AgentBellSetupJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')

    try {
        $json = $Value | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $script:Utf8NoBom)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-AgentBellHookDocument {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{
            description = 'User-level Codex hooks.'
            hooks = [pscustomobject][ordered]@{}
        }
    }

    try {
        $document = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom) | ConvertFrom-Json
    }
    catch {
        throw "Codex hooks.json is invalid and was not changed: $($_.Exception.Message)"
    }

    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        throw 'Codex hooks.json must contain a JSON object.'
    }
    if ($null -eq $document.PSObject.Properties['hooks']) {
        $document | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject][ordered]@{})
    }
    elseif ($null -eq $document.hooks -or $document.hooks -isnot [pscustomobject]) {
        throw 'Codex hooks.json has a non-object hooks property and was not changed.'
    }

    return $document
}

function Get-AgentBellLocalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedPluginRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedDataDir
    )

    foreach ($value in @($ResolvedPluginRoot, $ResolvedDataDir)) {
        if ($value.Contains('"')) {
            throw 'Agent Bell paths cannot contain a double quote.'
        }
    }

    $enqueuePath = Join-Path $ResolvedPluginRoot 'hooks\enqueue.ps1'
    return ('powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PluginRoot "{1}" -DataDir "{2}"' -f $enqueuePath, $ResolvedPluginRoot, $ResolvedDataDir)
}

function Test-AgentBellOwnedLocalHandler {
    param([object]$Handler)

    if ($null -eq $Handler) {
        return $false
    }
    $statusProperty = $Handler.PSObject.Properties['statusMessage']
    if ($null -eq $statusProperty) {
        return $false
    }
    return ([string]$statusProperty.Value).StartsWith($script:LocalHookMarkerPrefix, [StringComparison]::Ordinal)
}

function Get-AgentBellOwnedLocalHandlerCount {
    param([object]$Document)

    $count = 0
    foreach ($eventProperty in $Document.hooks.PSObject.Properties) {
        foreach ($group in @($eventProperty.Value)) {
            if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) {
                continue
            }
            foreach ($handler in @($group.hooks)) {
                if (Test-AgentBellOwnedLocalHandler -Handler $handler) {
                    $count++
                }
            }
        }
    }
    return $count
}

function Get-AgentBellLegacyHandlerCount {
    param([object]$Document)

    $count = 0
    foreach ($eventProperty in $Document.hooks.PSObject.Properties) {
        foreach ($group in @($eventProperty.Value)) {
            if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) {
                continue
            }
            foreach ($handler in @($group.hooks)) {
                $commandProperty = if ($null -ne $handler) { $handler.PSObject.Properties['command'] } else { $null }
                if ($null -ne $commandProperty -and [string]$commandProperty.Value -match '(?i)codex-voice-notifier\.ps1') {
                    $count++
                }
            }
        }
    }
    return $count
}

function Get-AgentBellLocalHookGroups {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedPluginRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedDataDir
    )

    $sourcePath = Join-Path $ResolvedPluginRoot 'hooks\hooks.json'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Agent Bell hook definition was not found: $sourcePath"
    }
    try {
        $source = [System.IO.File]::ReadAllText($sourcePath, $script:Utf8NoBom) | ConvertFrom-Json
    }
    catch {
        throw "Agent Bell hook definition is invalid: $($_.Exception.Message)"
    }
    if ($null -eq $source.PSObject.Properties['hooks']) {
        throw 'Agent Bell hook definition does not contain hooks.'
    }

    $command = Get-AgentBellLocalCommand -ResolvedPluginRoot $ResolvedPluginRoot -ResolvedDataDir $ResolvedDataDir
    $groups = New-Object System.Collections.ArrayList

    foreach ($eventProperty in $source.hooks.PSObject.Properties) {
        $eventName = [string]$eventProperty.Name
        foreach ($sourceGroup in @($eventProperty.Value)) {
            $sourceHandlers = if ($null -ne $sourceGroup.PSObject.Properties['hooks']) { @($sourceGroup.hooks) } else { @() }
            foreach ($sourceHandler in $sourceHandlers) {
                if ([string]$sourceHandler.type -ne 'command') {
                    continue
                }

                $markerSuffix = $eventName
                $group = [ordered]@{}
                if ($null -ne $sourceGroup.PSObject.Properties['matcher']) {
                    $group['matcher'] = [string]$sourceGroup.matcher
                    $markerSuffix += ':' + [string]$sourceGroup.matcher
                }
                $timeout = if ($null -ne $sourceHandler.PSObject.Properties['timeout']) { [int]$sourceHandler.timeout } else { 10 }
                $group['hooks'] = @(
                    [pscustomobject][ordered]@{
                        type = 'command'
                        command = $command
                        commandWindows = $command
                        timeout = $timeout
                        statusMessage = $script:LocalHookMarkerPrefix + $markerSuffix
                    }
                )
                [void]$groups.Add([pscustomobject][ordered]@{
                    EventName = $eventName
                    Group = [pscustomobject]$group
                    Marker = $script:LocalHookMarkerPrefix + $markerSuffix
                })
            }
        }
    }

    if ($groups.Count -eq 0) {
        throw 'Agent Bell hook definition contains no command handlers.'
    }
    return @($groups)
}

function Test-AgentBellUnsafePurgePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Paths
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $knownPaths = @(
        [System.IO.Path]::GetPathRoot($fullPath),
        $HOME,
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $Paths.CodexHome,
        $Paths.PluginRoot,
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments')
    )
    foreach ($knownPath in $knownPaths) {
        if (-not [string]::IsNullOrWhiteSpace($knownPath) -and
            $fullPath.Equals([System.IO.Path]::GetFullPath($knownPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    return $false
}

function Initialize-AgentBellData {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $markerPath = Join-Path $Paths.DataDir '.agent-bell-data'
    if ((Test-Path -LiteralPath $Paths.DataDir -PathType Container) -and
        -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        $allowedUnmarkedNames = @('queue', 'logs', 'state', 'cache', 'voices', 'voice-pack', 'config.json')
        $unknownItems = @(Get-ChildItem -LiteralPath $Paths.DataDir -Force -ErrorAction SilentlyContinue | Where-Object { $allowedUnmarkedNames -notcontains $_.Name })
        if ($unknownItems.Count -gt 0) {
            throw "Refusing to initialize Agent Bell inside a non-empty unmarked directory: $($Paths.DataDir)"
        }
    }

    $createdDirectories = 0
    foreach ($relativePath in @('queue\pending', 'queue\processing', 'queue\failed', 'logs', 'state', 'cache', 'voices')) {
        $directory = Join-Path $Paths.DataDir $relativePath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
            $createdDirectories++
        }
    }

    $installId = [Guid]::NewGuid().ToString('D')
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        try {
            $existingMarker = [System.IO.File]::ReadAllText($markerPath, $script:Utf8NoBom) | ConvertFrom-Json
            if ([string]$existingMarker.plugin_id -eq 'agent-bell' -and -not [string]::IsNullOrWhiteSpace([string]$existingMarker.install_id)) {
                $installId = [string]$existingMarker.install_id
            }
        }
        catch {
            # Migrate the early plain-text development marker below.
        }
    }
    $marker = [pscustomobject][ordered]@{
        schema_version = 1
        plugin_id = 'agent-bell'
        install_id = $installId
        data_dir = [System.IO.Path]::GetFullPath($Paths.DataDir)
    }
    Write-AgentBellSetupJsonAtomic -Path $markerPath -Value $marker

    $modulePath = Join-Path $Paths.PluginRoot 'scripts\AgentBell.Core.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Agent Bell core module was not found: $modulePath"
    }
    Import-Module $modulePath -Force -DisableNameChecking

    $configPath = Join-Path $Paths.DataDir 'config.json'
    $configCreated = $false
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $null = Get-AgentBellConfig -Path $configPath
    }
    else {
        $config = Get-AgentBellDefaultConfig
        Write-AgentBellJsonAtomic -Path $configPath -Value $config
        $configCreated = $true
    }

    return [pscustomobject][ordered]@{
        Action = 'Initialize'
        Success = $true
        Changed = ($createdDirectories -gt 0 -or $configCreated)
        CreatedDirectories = $createdDirectories
        ConfigCreated = $configCreated
        DataDir = $Paths.DataDir
        ConfigPath = $configPath
    }
}

function Enable-AgentBellLocalDevelopmentHooks {
    param([Parameter(Mandatory = $true)][object]$Paths)

    [System.IO.Directory]::CreateDirectory($Paths.CodexHome) | Out-Null
    $document = Read-AgentBellHookDocument -Path $Paths.UserHooksPath
    $definitions = @(Get-AgentBellLocalHookGroups -ResolvedPluginRoot $Paths.PluginRoot -ResolvedDataDir $Paths.DataDir)
    $added = 0
    $updated = 0

    foreach ($definition in $definitions) {
        $eventName = [string]$definition.EventName
        $eventProperty = $document.hooks.PSObject.Properties[$eventName]
        if ($null -eq $eventProperty) {
            $document.hooks | Add-Member -MemberType NoteProperty -Name $eventName -Value @()
            $eventProperty = $document.hooks.PSObject.Properties[$eventName]
        }

        $alreadyPresent = $false
        foreach ($group in @($eventProperty.Value)) {
            if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) {
                continue
            }
            foreach ($handler in @($group.hooks)) {
                $statusProperty = if ($null -ne $handler) { $handler.PSObject.Properties['statusMessage'] } else { $null }
                if ($null -ne $statusProperty -and [string]$statusProperty.Value -eq [string]$definition.Marker) {
                    $alreadyPresent = $true
                    $expectedHandler = @($definition.Group.hooks)[0]
                    if ([string]$handler.command -ne [string]$expectedHandler.command -or
                        [string]$handler.commandWindows -ne [string]$expectedHandler.commandWindows -or
                        [int]$handler.timeout -ne [int]$expectedHandler.timeout) {
                        $handler.command = [string]$expectedHandler.command
                        $handler.commandWindows = [string]$expectedHandler.commandWindows
                        $handler.timeout = [int]$expectedHandler.timeout
                        $updated++
                    }
                    break
                }
            }
            if ($alreadyPresent) {
                break
            }
        }

        if (-not $alreadyPresent) {
            $eventProperty.Value = @($eventProperty.Value) + @($definition.Group)
            $added++
        }
    }

    if ($added -gt 0 -or $updated -gt 0) {
        if (Test-Path -LiteralPath $Paths.UserHooksPath -PathType Leaf) {
            Copy-Item -LiteralPath $Paths.UserHooksPath -Destination ($Paths.UserHooksPath + '.agent-bell.bak') -Force
        }
        Write-AgentBellSetupJsonAtomic -Path $Paths.UserHooksPath -Value $document
    }

    return [pscustomobject][ordered]@{
        Action = 'EnableLocalDevelopment'
        Success = $true
        Changed = ($added -gt 0 -or $updated -gt 0)
        AddedHandlers = $added
        UpdatedHandlers = $updated
        InstalledHandlers = Get-AgentBellOwnedLocalHandlerCount -Document $document
        HooksPath = $Paths.UserHooksPath
        TrustReviewRequired = $true
        TrustInstruction = 'Open /hooks in Codex and review the Agent Bell hook definitions.'
    }
}

function Disable-AgentBellLocalDevelopmentHooks {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [switch]$RemoveData
    )

    $removed = 0
    if (Test-Path -LiteralPath $Paths.UserHooksPath -PathType Leaf) {
        $document = Read-AgentBellHookDocument -Path $Paths.UserHooksPath
        foreach ($eventName in @($document.hooks.PSObject.Properties.Name)) {
            $eventProperty = $document.hooks.PSObject.Properties[$eventName]
            $keptGroups = New-Object System.Collections.ArrayList

            foreach ($group in @($eventProperty.Value)) {
                if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) {
                    [void]$keptGroups.Add($group)
                    continue
                }

                $originalHandlers = @($group.hooks)
                $remainingHandlers = @($originalHandlers | Where-Object { -not (Test-AgentBellOwnedLocalHandler -Handler $_) })
                $removed += $originalHandlers.Count - $remainingHandlers.Count
                if ($remainingHandlers.Count -eq $originalHandlers.Count) {
                    [void]$keptGroups.Add($group)
                }
                elseif ($remainingHandlers.Count -gt 0) {
                    $group.hooks = $remainingHandlers
                    [void]$keptGroups.Add($group)
                }
            }

            if ($keptGroups.Count -eq 0) {
                $document.hooks.PSObject.Properties.Remove($eventName)
            }
            else {
                $eventProperty.Value = @($keptGroups)
            }
        }

        if ($removed -gt 0) {
            Copy-Item -LiteralPath $Paths.UserHooksPath -Destination ($Paths.UserHooksPath + '.agent-bell.bak') -Force
            Write-AgentBellSetupJsonAtomic -Path $Paths.UserHooksPath -Value $document
        }
    }

    $dataRemoved = $false
    if ($RemoveData.IsPresent -and (Test-Path -LiteralPath $Paths.DataDir -PathType Container)) {
        $markerPath = Join-Path $Paths.DataDir '.agent-bell-data'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "Refusing to purge an unmarked data directory: $($Paths.DataDir)"
        }
        $fullDataPath = [System.IO.Path]::GetFullPath($Paths.DataDir).TrimEnd('\')
        if (Test-AgentBellUnsafePurgePath -Path $fullDataPath -Paths $Paths) {
            throw "Refusing to purge an unsafe data path: $fullDataPath"
        }

        try {
            $marker = [System.IO.File]::ReadAllText($markerPath, $script:Utf8NoBom) | ConvertFrom-Json
        }
        catch {
            throw "Refusing to purge data with an invalid Agent Bell marker."
        }
        if ([string]$marker.plugin_id -ne 'agent-bell' -or
            [string]::IsNullOrWhiteSpace([string]$marker.install_id) -or
            -not $fullDataPath.Equals([System.IO.Path]::GetFullPath([string]$marker.data_dir).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to purge data whose marker does not match the requested directory."
        }

        foreach ($name in @('queue', 'logs', 'state', 'cache', 'voices', 'config.json')) {
            $ownedPath = Join-Path $fullDataPath $name
            if (-not (Test-Path -LiteralPath $ownedPath)) {
                continue
            }
            $ownedItem = Get-Item -LiteralPath $ownedPath -Force
            if (($ownedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to purge a reparse point: $ownedPath"
            }
            $ownedFullPath = [System.IO.Path]::GetFullPath($ownedPath)
            if (-not $ownedFullPath.StartsWith($fullDataPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to purge a path outside the Agent Bell data directory."
            }
            Remove-Item -LiteralPath $ownedFullPath -Recurse -Force
        }
        Remove-Item -LiteralPath $markerPath -Force
        if (@(Get-ChildItem -LiteralPath $fullDataPath -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $fullDataPath -Force
        }
        $dataRemoved = $true
    }

    return [pscustomobject][ordered]@{
        Action = 'UninstallLocalDevelopment'
        Success = $true
        Changed = ($removed -gt 0 -or $dataRemoved)
        RemovedHandlers = $removed
        HooksPath = $Paths.UserHooksPath
        DataRemoved = $dataRemoved
        DataPreserved = -not $dataRemoved
        DataDir = $Paths.DataDir
    }
}

function Invoke-AgentBellSetupTest {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [switch]$SkipAudio
    )

    $null = Initialize-AgentBellData -Paths $Paths
    $pipelineDataDir = Join-Path $env:TEMP ('agent-bell-pipeline-test-' + [Guid]::NewGuid().ToString('N'))
    $pipelinePaths = [pscustomobject][ordered]@{
        PluginRoot = $Paths.PluginRoot
        DataDir = $pipelineDataDir
        CodexHome = $Paths.CodexHome
        UserHooksPath = $Paths.UserHooksPath
        UserConfigPath = $Paths.UserConfigPath
    }
    $null = Initialize-AgentBellData -Paths $pipelinePaths
    $payload = [ordered]@{
        hook_event_name = 'PermissionRequest'
        session_id = '00000000-0000-0000-0000-000000000001'
        turn_id = 'agent-bell-setup-test'
        cwd = $Paths.PluginRoot
        tool_name = 'Bash'
        tool_input = [ordered]@{ description = 'Agent Bell local setup test' }
    } | ConvertTo-Json -Compress -Depth 5

    $enqueuePath = Join-Path $Paths.PluginRoot 'hooks\enqueue.ps1'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $enqueuePath,
        '-PluginRoot', $Paths.PluginRoot,
        '-DataDir', $pipelineDataDir,
        '-RunWorkerSynchronously',
        '-WorkerDryRun'
    )

    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $Paths.CodexHome
        $payload | & powershell.exe @arguments | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Agent Bell hook pipeline test exited with code $LASTEXITCODE."
        }
    }
    finally {
        $env:CODEX_HOME = $previousCodexHome
        Remove-Item -LiteralPath $pipelineDataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $provider = 'dry-run'
    if (-not $SkipAudio.IsPresent) {
        $modulePath = Join-Path $Paths.PluginRoot 'scripts\AgentBell.Core.psm1'
        Import-Module $modulePath -Force -DisableNameChecking
        $config = Get-AgentBellConfig -Path (Join-Path $Paths.DataDir 'config.json')
        $announcement = Get-AgentBellAnnouncement -Kind 'complete' -Title 'Agent Bell' -Config $config
        $provider = Invoke-AgentBellSpeech -Message $announcement -Config $config -CacheDirectory (Join-Path $Paths.DataDir 'cache')
    }

    return [pscustomobject][ordered]@{
        Action = 'Test'
        Success = $true
        Pipeline = 'ok'
        AudioPlayed = -not $SkipAudio.IsPresent
        Provider = $provider
        DataDir = $Paths.DataDir
    }
}

function Get-AgentBellVoicePackHealthPayload {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    $maximumResponseBytes = 16KB
    $timeoutMilliseconds = 2000
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $request = [System.Net.HttpWebRequest]::CreateHttp($Uri)
    $request.Method = 'GET'
    $request.Accept = 'application/json'
    $request.AllowAutoRedirect = $false
    $request.Proxy = $null
    $request.Timeout = $timeoutMilliseconds
    $request.ReadWriteTimeout = $timeoutMilliseconds
    $response = $null
    $stream = $null
    $buffer = New-Object byte[] 4096
    $body = New-Object System.IO.MemoryStream
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        if ([int]$response.StatusCode -ne 200) {
            throw 'The Voice Pack health endpoint did not return HTTP 200.'
        }
        if ($response.ContentLength -gt $maximumResponseBytes) {
            throw 'The Voice Pack health response is too large.'
        }
        $stream = $response.GetResponseStream()
        while ($true) {
            $remainingMilliseconds = $timeoutMilliseconds - [int]$timer.ElapsedMilliseconds
            if ($remainingMilliseconds -le 0) {
                throw 'The Voice Pack health response exceeded its total deadline.'
            }
            if ($stream.CanTimeout) {
                $stream.ReadTimeout = [Math]::Max(1, $remainingMilliseconds)
            }
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }
            if ($body.Length + $read -gt $maximumResponseBytes) {
                throw 'The Voice Pack health response is too large.'
            }
            $body.Write($buffer, 0, $read)
        }
        $json = [System.Text.Encoding]::UTF8.GetString($body.ToArray())
        return ($json | ConvertFrom-Json)
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
        $body.Dispose()
    }
}

function Invoke-AgentBellDoctor {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $checks = New-Object System.Collections.ArrayList
    function Add-DoctorCheck {
        param([string]$Name, [bool]$Passed, [string]$Detail)
        [void]$checks.Add([pscustomobject][ordered]@{
            Name = $Name
            Passed = $Passed
            Detail = $Detail
        })
    }

    Add-DoctorCheck -Name 'windows' -Passed ($env:OS -eq 'Windows_NT') -Detail 'Agent Bell v0.1 requires Windows.'

    foreach ($relativePath in @('hooks\hooks.json', 'hooks\enqueue.ps1', 'scripts\AgentBell.Core.psm1', 'scripts\worker.ps1', 'scripts\prewarm.ps1', 'voice-pack\update.ps1')) {
        $path = Join-Path $Paths.PluginRoot $relativePath
        Add-DoctorCheck -Name ('plugin:' + $relativePath) -Passed (Test-Path -LiteralPath $path -PathType Leaf) -Detail $path
    }

    $hookDefinitionPath = Join-Path $Paths.PluginRoot 'hooks\hooks.json'
    try {
        $hookDefinition = [System.IO.File]::ReadAllText($hookDefinitionPath, $script:Utf8NoBom) | ConvertFrom-Json
        $events = @($hookDefinition.hooks.PSObject.Properties.Name)
        $eventsValid = @('UserPromptSubmit', 'PermissionRequest', 'Stop') | Where-Object { $events -notcontains $_ }
        Add-DoctorCheck -Name 'plugin-hook-events' -Passed (@($eventsValid).Count -eq 0) -Detail ($events -join ', ')
    }
    catch {
        Add-DoctorCheck -Name 'plugin-hook-events' -Passed $false -Detail $_.Exception.Message
    }

    $configPath = Join-Path $Paths.DataDir 'config.json'
    $runtimeConfig = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            Import-Module (Join-Path $Paths.PluginRoot 'scripts\AgentBell.Core.psm1') -Force -DisableNameChecking
            $runtimeConfig = Get-AgentBellConfig -Path $configPath
            Add-DoctorCheck -Name 'runtime-config' -Passed $true -Detail $configPath
        }
        catch {
            Add-DoctorCheck -Name 'runtime-config' -Passed $false -Detail $_.Exception.Message
        }
    }
    else {
        Add-DoctorCheck -Name 'runtime-config' -Passed $false -Detail 'Run Initialize to create the local config.'
    }

    if ($null -ne $runtimeConfig -and [string]$runtimeConfig.voice.provider -eq 'http') {
        $requiredCapabilities = @('synthesize', 'prewarm', 'cached')
        try {
            $healthUri = Resolve-AgentBellLoopbackUri -Endpoint ([string]$runtimeConfig.voice.http.endpoint) -Path '/health'
            $health = Get-AgentBellVoicePackHealthPayload -Uri $healthUri
            $protocolVersion = 0
            if ($null -ne $health.PSObject.Properties['protocol_version']) {
                $protocolVersion = [int]$health.protocol_version
            }
            $capabilities = if ($null -ne $health.PSObject.Properties['capabilities']) {
                @($health.capabilities | ForEach-Object { [string]$_ })
            }
            else {
                @()
            }
            $missingCapabilities = @($requiredCapabilities | Where-Object { $capabilities -notcontains $_ })
            $compatible = (
                [string]$health.service -eq 'agent-bell-qwen-voice-pack' -and
                [string]$health.status -eq 'ready' -and
                $protocolVersion -ge 1 -and
                $missingCapabilities.Count -eq 0
            )
            $detail = if ($compatible) {
                "Voice Pack protocol $protocolVersion supports synthesize, prewarm, and cached playback."
            }
            else {
                'The Voice Pack is outdated or incompatible. Stop it, then run voice-pack\update.ps1; the updater restarts it.'
            }
            Add-DoctorCheck -Name 'voice-pack-low-latency' -Passed $compatible -Detail $detail
        }
        catch {
            Add-DoctorCheck -Name 'voice-pack-low-latency' -Passed $false -Detail 'The configured Voice Pack is unavailable. Start it, or stop it and run voice-pack\update.ps1.'
        }
    }

    try {
        $userHooks = Read-AgentBellHookDocument -Path $Paths.UserHooksPath
        $localHandlerCount = Get-AgentBellOwnedLocalHandlerCount -Document $userHooks
        $legacyHandlerCount = Get-AgentBellLegacyHandlerCount -Document $userHooks
        Add-DoctorCheck -Name 'codex-hooks-json' -Passed $true -Detail ("Valid JSON; local development handlers: $localHandlerCount")
    }
    catch {
        Add-DoctorCheck -Name 'codex-hooks-json' -Passed $false -Detail $_.Exception.Message
        $localHandlerCount = 0
        $legacyHandlerCount = 0
    }

    $failedChecks = @($checks | Where-Object { -not $_.Passed })
    $warnings = @()
    if ($legacyHandlerCount -gt 0) {
        $warnings += 'A legacy codex-voice-notifier.ps1 hook is still configured. Remove it after the Agent Bell plugin hook is trusted.'
    }
    return [pscustomobject][ordered]@{
        Action = 'Doctor'
        Success = $failedChecks.Count -eq 0
        Healthy = $failedChecks.Count -eq 0
        Checks = @($checks)
        LocalDevelopmentHandlers = $localHandlerCount
        LegacyCompatibilityHandlers = $legacyHandlerCount
        Warnings = $warnings
        TrustState = 'not modified or inferred'
        TrustInstruction = 'Open /hooks in Codex to review and trust the current Agent Bell hook definitions.'
        NotifyOrConfigTomlModified = $false
    }
}

$paths = Resolve-AgentBellSetupPaths -RequestedPluginRoot $PluginRoot -RequestedDataDir $DataDir -RequestedCodexHome $CodexHome

$result = switch ($Action) {
    'Initialize' {
        Initialize-AgentBellData -Paths $paths
        break
    }
    'Test' {
        Invoke-AgentBellSetupTest -Paths $paths -SkipAudio:$DryRun
        break
    }
    'Doctor' {
        Invoke-AgentBellDoctor -Paths $paths
        break
    }
    'EnableLocalDevelopment' {
        $null = Initialize-AgentBellData -Paths $paths
        Invoke-AgentBellHooksMutation -Operation { Enable-AgentBellLocalDevelopmentHooks -Paths $paths }
        break
    }
    'UninstallLocalDevelopment' {
        Invoke-AgentBellHooksMutation -Operation { Disable-AgentBellLocalDevelopmentHooks -Paths $paths -RemoveData:$PurgeData }
        break
    }
}

if ($AsJson.IsPresent) {
    $result | ConvertTo-Json -Depth 20
}
else {
    $result
}
