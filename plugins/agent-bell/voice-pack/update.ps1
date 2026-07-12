[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'AgentBell\voice-pack'),
    [ValidateRange(30, 600)][int]$ReadyTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MarkerName = '.agent-bell-qwen-voice-pack'
$ServiceName = 'agent-bell-qwen-voice-pack'
$RequiredProtocolVersion = 1
$RequiredCapabilities = @('synthesize', 'prewarm', 'cached')
$RuntimeFiles = @('server.py', 'start.ps1', 'requirements.txt')
$HealthUri = [Uri]'http://127.0.0.1:17863/health'
$MaximumHealthBytes = 16KB

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
}

function Assert-VoicePackRuntimeDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Refusing to replace a non-file runtime destination: $FileName"
    }
    if (Test-ReparsePoint -Path $Path) {
        throw "Refusing to replace a reparse-point runtime file: $FileName"
    }
}

function Test-VoicePackTransactionCanBeRemoved {
    param(
        [bool]$UpdateCompleted,
        [bool]$RollbackCompleted
    )

    return $UpdateCompleted -or $RollbackCompleted
}

function Get-VoicePackRecoveryDetail {
    param([Parameter(Mandatory = $true)][string]$TransactionPath)

    return "Recovery files were preserved at: $TransactionPath"
}

function Test-LoopbackVoicePortListening {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connection = $client.ConnectAsync('127.0.0.1', 17863)
        return $connection.Wait(500) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-VoicePackHealthPayload {
    param([ValidateRange(1, 5)][int]$TimeoutSeconds = 2)

    $timeoutMilliseconds = $TimeoutSeconds * 1000
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $request = [System.Net.HttpWebRequest]::CreateHttp($HealthUri)
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
            throw 'Voice Pack health did not return HTTP 200.'
        }
        if ($response.ContentLength -gt $MaximumHealthBytes) {
            throw 'Voice Pack health response is too large.'
        }
        $stream = $response.GetResponseStream()
        while ($true) {
            $remainingMilliseconds = $timeoutMilliseconds - [int]$timer.ElapsedMilliseconds
            if ($remainingMilliseconds -le 0) {
                throw 'Voice Pack health response exceeded its total deadline.'
            }
            if ($stream.CanTimeout) {
                $stream.ReadTimeout = [Math]::Max(1, $remainingMilliseconds)
            }
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }
            if ($body.Length + $read -gt $MaximumHealthBytes) {
                throw 'Voice Pack health response is too large.'
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

function Test-CompatibleVoicePackHealth {
    param([Parameter(Mandatory = $true)][object]$Health)

    try {
        $protocolVersion = if ($null -ne $Health.PSObject.Properties['protocol_version']) {
            [int]$Health.protocol_version
        }
        else {
            0
        }
        $capabilities = if ($null -ne $Health.PSObject.Properties['capabilities']) {
            @($Health.capabilities | ForEach-Object { [string]$_ })
        }
        else {
            @()
        }
        return (
            [string]$Health.service -eq $ServiceName -and
            [string]$Health.status -eq 'ready' -and
            $protocolVersion -ge $RequiredProtocolVersion -and
            @($RequiredCapabilities | Where-Object { $capabilities -notcontains $_ }).Count -eq 0
        )
    }
    catch {
        return $false
    }
}

function Test-ReadyVoicePackHealth {
    param([Parameter(Mandatory = $true)][object]$Health)

    try {
        return [string]$Health.service -eq $ServiceName -and [string]$Health.status -eq 'ready'
    }
    catch {
        return $false
    }
}

function Start-OwnedVoicePackProcess {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$ServerPath,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $arguments = @("`"$ServerPath`"", '--install-root', "`"$Root`"")
    return Start-Process -FilePath $PythonPath `
        -ArgumentList $arguments `
        -WorkingDirectory $Root `
        -WindowStyle Hidden `
        -PassThru
}

function Wait-VoicePackReady {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [switch]$RequireLowLatency
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            return $null
        }
        try {
            $health = Get-VoicePackHealthPayload -TimeoutSeconds 2
            if (($RequireLowLatency.IsPresent -and (Test-CompatibleVoicePackHealth -Health $health)) -or
                (-not $RequireLowLatency.IsPresent -and (Test-ReadyVoicePackHealth -Health $health))) {
                return $health
            }
        }
        catch {
            # The server reserves its port while the model is still loading.
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Stop-OwnedSpawnedProcess {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return -not (Test-LoopbackVoicePortListening)
    }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            # This PID comes from Start-OwnedVoicePackProcess in this updater.
            # Python's Windows venv shim can own the real listener as a child,
            # so terminate only this known process tree rather than a listener
            # discovered by port or command-line scanning.
            & taskkill.exe /PID ([string]$Process.Id) /T /F *> $null
            $null = $Process.WaitForExit(10000)
        }
    }
    catch {
        # The caller verifies that the loopback listener is gone before rollback.
    }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-LoopbackVoicePortListening)) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return -not (Test-LoopbackVoicePortListening)
}

function Restore-VoicePackRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$AppDirectory,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [Parameter(Mandatory = $true)][object[]]$Records
    )

    foreach ($record in @($Records | Sort-Object Sequence -Descending)) {
        if (-not [bool]$record.Replaced) {
            continue
        }
        $destination = Join-Path $AppDirectory ([string]$record.Name)
        Assert-VoicePackRuntimeDestination -Path $destination -FileName ([string]$record.Name)
        if ([bool]$record.HadOriginal) {
            $backup = Join-Path $BackupDirectory ([string]$record.Name)
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                throw 'A Voice Pack runtime rollback file is missing.'
            }
            $restoreTemporary = Join-Path $AppDirectory ('.agent-bell-restore-' + [Guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $backup -Destination $restoreTemporary
            try {
                # Move-Item -Force maps to the Windows replace-existing move and
                # works on Windows PowerShell 5.1, where File.Replace rejects a
                # null backup path on some .NET Framework builds.
                Move-Item -LiteralPath $restoreTemporary -Destination $destination -Force
            }
            finally {
                Remove-Item -LiteralPath $restoreTemporary -Force -ErrorAction SilentlyContinue
            }
        }
        elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
}

function Remove-VoicePackUpdateTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$TransactionPath
    )

    if (-not (Test-Path -LiteralPath $TransactionPath -PathType Container)) {
        return
    }
    $fullTransactionPath = [System.IO.Path]::GetFullPath($TransactionPath).TrimEnd('\')
    if (-not $fullTransactionPath.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not [System.IO.Path]::GetFileName($fullTransactionPath).StartsWith('.agent-bell-runtime-update-', [StringComparison]::Ordinal)) {
        throw 'Refusing to remove an unexpected update transaction path.'
    }
    $reparsePoints = @(Get-ChildItem -LiteralPath $fullTransactionPath -Recurse -Force -ErrorAction Stop | Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if ((Test-ReparsePoint -Path $fullTransactionPath) -or $reparsePoints.Count -gt 0) {
        throw 'Refusing to remove an update transaction containing a reparse point.'
    }
    [System.IO.Directory]::Delete($fullTransactionPath, $true)
}

if ($env:OS -ne 'Windows_NT') {
    throw 'The Agent Bell Voice Pack updater supports Windows only.'
}

$fullInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$volumeRoot = [System.IO.Path]::GetPathRoot($fullInstallRoot).TrimEnd('\')
if ($fullInstallRoot.Equals($volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallRoot cannot be a drive root.'
}
$markerPath = Join-Path $fullInstallRoot $MarkerName
if (-not (Test-Path -LiteralPath $fullInstallRoot -PathType Container) -or
    (Test-ReparsePoint -Path $fullInstallRoot) -or
    -not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
    (Test-ReparsePoint -Path $markerPath)) {
    throw 'InstallRoot is not a safe, marked Agent Bell Voice Pack installation.'
}
$marker = [System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8).Trim()
if ($marker -ne 'agent-bell-qwen-voice-pack') {
    throw 'The Agent Bell Voice Pack installation marker is invalid.'
}

$appDirectory = Join-Path $fullInstallRoot 'app'
$pythonPath = Join-Path $fullInstallRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $appDirectory -PathType Container) -or (Test-ReparsePoint -Path $appDirectory)) {
    throw 'The Voice Pack app directory is missing or unsafe.'
}
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf) -or (Test-ReparsePoint -Path $pythonPath)) {
    throw 'The isolated Voice Pack Python runtime is missing or unsafe.'
}

$sourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($fileName in $RuntimeFiles) {
    $source = Join-Path $sourceDirectory $fileName
    $destination = Join-Path $appDirectory $fileName
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Test-ReparsePoint -Path $source)) {
        throw "A shipped Voice Pack runtime file is missing or unsafe: $fileName"
    }
    if ([System.IO.Path]::GetFullPath($source).Equals([System.IO.Path]::GetFullPath($destination), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Run update.ps1 from the Agent Bell plugin, not from inside the installed Voice Pack app directory.'
    }
    Assert-VoicePackRuntimeDestination -Path $destination -FileName $fileName
}

if (Test-LoopbackVoicePortListening) {
    throw 'Stop the Voice Pack service before updating. This updater never terminates a pre-existing process because its ownership cannot be proven safely.'
}

$transactionId = [Guid]::NewGuid().ToString('N')
$transactionRoot = Join-Path $fullInstallRoot ('.agent-bell-runtime-update-' + $transactionId)
$stagingDirectory = Join-Path $transactionRoot 'staged'
$backupDirectory = Join-Path $transactionRoot 'backup'
[System.IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
$records = New-Object System.Collections.ArrayList
$updatedProcess = $null
$replacementsStarted = $false
$completed = $false
$rollbackCompleted = $false

try {
    foreach ($fileName in $RuntimeFiles) {
        Copy-Item -LiteralPath (Join-Path $sourceDirectory $fileName) -Destination (Join-Path $stagingDirectory $fileName)
    }

    & $pythonPath -m py_compile (Join-Path $stagingDirectory 'server.py')
    if ($LASTEXITCODE -ne 0) {
        throw 'The shipped Voice Pack server failed Python syntax validation.'
    }
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $stagingDirectory 'start.ps1'),
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -gt 0) {
        throw 'The shipped Voice Pack start script failed PowerShell syntax validation.'
    }

    $sequence = 0
    foreach ($fileName in $RuntimeFiles) {
        $staged = Join-Path $stagingDirectory $fileName
        $destination = Join-Path $appDirectory $fileName
        Assert-VoicePackRuntimeDestination -Path $destination -FileName $fileName
        $hadOriginal = Test-Path -LiteralPath $destination -PathType Leaf
        if ($hadOriginal) {
            Copy-Item -LiteralPath $destination -Destination (Join-Path $backupDirectory $fileName)
        }
        [void]$records.Add([pscustomobject][ordered]@{
            Sequence = $sequence
            Name = $fileName
            HadOriginal = $hadOriginal
            Replaced = $false
        })
        $sequence++
        $replacementsStarted = $true
        Move-Item -LiteralPath $staged -Destination $destination -Force
        $records[$records.Count - 1].Replaced = $true
    }

    $updatedServerPath = Join-Path $appDirectory 'server.py'
    $updatedProcess = Start-OwnedVoicePackProcess -PythonPath $pythonPath -ServerPath $updatedServerPath -Root $fullInstallRoot
    $health = Wait-VoicePackReady -Process $updatedProcess -TimeoutSeconds $ReadyTimeoutSeconds -RequireLowLatency
    if ($null -eq $health) {
        throw 'The updated Voice Pack did not become ready with the required low-latency capabilities.'
    }

    $completed = $true
    Write-Output ([pscustomobject][ordered]@{
        Updated = $true
        Restarted = $true
        Ready = $true
        ProtocolVersion = [int]$health.protocol_version
        Capabilities = @($RequiredCapabilities)
        RuntimeFiles = @($RuntimeFiles)
    })
}
catch {
    $completed = $false
    $updateFailure = $_.Exception.Message
    $spawnedTreeStopped = Stop-OwnedSpawnedProcess -Process $updatedProcess
    if (-not $spawnedTreeStopped) {
        $recoveryDetail = Get-VoicePackRecoveryDetail -TransactionPath $transactionRoot
        throw "Voice Pack runtime update failed: $updateFailure The updater-owned process tree could not be stopped safely, so rollback was not attempted. Private voice and model data were not touched. $recoveryDetail"
    }
    $rollbackDetail = 'No installed runtime file was changed.'
    if ($replacementsStarted) {
        try {
            Restore-VoicePackRuntime -AppDirectory $appDirectory -BackupDirectory $backupDirectory -Records @($records)
            $rollbackCompleted = $true
            $rollbackDetail = 'The previous runtime was restored.'
        }
        catch {
            $recoveryDetail = Get-VoicePackRecoveryDetail -TransactionPath $transactionRoot
            $rollbackDetail = "Automatic rollback failed; private voice and model data were not touched. $recoveryDetail"
        }

        if ($rollbackCompleted) {
            try {
                $previousProcess = Start-OwnedVoicePackProcess `
                    -PythonPath $pythonPath `
                    -ServerPath (Join-Path $appDirectory 'server.py') `
                    -Root $fullInstallRoot
                $previousHealth = Wait-VoicePackReady -Process $previousProcess -TimeoutSeconds $ReadyTimeoutSeconds
                if ($null -eq $previousHealth) {
                    $previousTreeStopped = Stop-OwnedSpawnedProcess -Process $previousProcess
                    if ($previousTreeStopped) {
                        $rollbackDetail += ' Its service could not be restarted automatically.'
                    }
                    else {
                        $rollbackDetail += ' Its updater-owned process tree could not be stopped automatically.'
                    }
                }
                else {
                    $rollbackDetail += ' Its service was restarted.'
                }
            }
            catch {
                $rollbackDetail += ' Its service could not be restarted automatically.'
            }
        }
    }
    else {
        $rollbackCompleted = $true
    }
    throw "Voice Pack runtime update failed: $updateFailure $rollbackDetail"
}
finally {
    if (Test-VoicePackTransactionCanBeRemoved -UpdateCompleted $completed -RollbackCompleted $rollbackCompleted) {
        try {
            Remove-VoicePackUpdateTransaction -Root $fullInstallRoot -TransactionPath $transactionRoot
        }
        catch {
            Write-Warning 'The runtime operation completed safely, but its public temporary files could not be removed.'
        }
    }
}
