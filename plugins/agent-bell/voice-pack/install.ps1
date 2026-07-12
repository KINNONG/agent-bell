[CmdletBinding()]
param(
    [switch]$ConfirmVoiceRights,
    [switch]$ConfirmLargeDownload,
    [Parameter(Mandatory = $true)][string]$ReferenceAudio,
    [Parameter(Mandatory = $true)][string]$ReferenceText,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$VoiceId = 'default',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'AgentBell\voice-pack')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MarkerName = '.agent-bell-qwen-voice-pack'
$AllowedAudioExtensions = @('.wav', '.mp3', '.flac', '.ogg')
$MaximumReferenceAudioBytes = 50MB
$MaximumReferenceTextCharacters = 2000
$PythonVersion = '3.12'
$QwenTtsVersion = '0.1.1'
$TorchVersion = '2.11.0+cu128'
$TorchAudioVersion = '2.11.0+cu128'
$PyTorchIndex = 'https://download.pytorch.org/whl/cu128'

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-CompleteVoicePackInstallation {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

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
        if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $relativePath) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function ConvertFrom-VoicePackNvidiaSmiOutput {
    param([Parameter(Mandatory = $true)][object[]]$Lines)

    foreach ($lineValue in $Lines) {
        $parts = ([string]$lineValue).Split(',')
        if ($parts.Count -ne 4) {
            continue
        }

        [int]$index = -1
        if (-not [int]::TryParse($parts[0].Trim(), [ref]$index) -or $index -ne 0) {
            continue
        }

        $gpuUuid = $parts[1].Trim()
        if ($gpuUuid -notmatch '^GPU-[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$') {
            throw 'nvidia-smi returned an invalid UUID for CUDA device 0.'
        }

        [double]$computeCapability = 0
        [int64]$vramMiB = 0
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $numberStyle = [System.Globalization.NumberStyles]::Float
        if (-not [double]::TryParse($parts[2].Trim(), $numberStyle, $culture, [ref]$computeCapability) -or
            -not [int64]::TryParse($parts[3].Trim(), $numberStyle, $culture, [ref]$vramMiB)) {
            throw 'nvidia-smi returned invalid compute capability or memory data for CUDA device 0.'
        }

        return [pscustomobject][ordered]@{
            Index = $index
            Uuid = $gpuUuid
            ComputeCapability = $computeCapability
            VramMiB = $vramMiB
        }
    }

    throw 'nvidia-smi did not report CUDA device 0.'
}

function Assert-VoicePackPlatformPreflight {
    param(
        [Parameter(Mandatory = $true)][bool]$IsWindows,
        [Parameter(Mandatory = $true)][bool]$NvidiaSmiAvailable
    )

    if (-not $IsWindows) {
        throw 'This Voice Pack installer supports Windows only.'
    }
    if (-not $NvidiaSmiAvailable) {
        throw 'nvidia-smi was not found. A compatible NVIDIA GPU and driver are required before downloading the Voice Pack.'
    }
}

function Get-VoicePackHardwareProfile {
    param([Parameter(Mandatory = $true)][string]$NvidiaSmiPath)

    $gpuOutput = & $NvidiaSmiPath `
        '--query-gpu=index,uuid,compute_cap,memory.total' `
        '--format=csv,noheader,nounits' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'nvidia-smi could not query CUDA device 0. Update the NVIDIA driver before downloading the Voice Pack.'
    }
    $gpu = ConvertFrom-VoicePackNvidiaSmiOutput -Lines @($gpuOutput)

    $memoryModules = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
    [int64]$ramBytes = ($memoryModules | Measure-Object -Property Capacity -Sum).Sum
    if ($ramBytes -le 0) {
        throw 'Windows did not report installed physical memory.'
    }

    return [pscustomobject][ordered]@{
        ComputeCapability = [double]$gpu.ComputeCapability
        VramMiB = [int64]$gpu.VramMiB
        RamBytes = $ramBytes
        GpuUuid = [string]$gpu.Uuid
    }
}

function Get-VoicePackAvailableDiskBytes {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $volumeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($InstallRoot))
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
        throw 'The Voice Pack installation volume could not be determined.'
    }
    $drive = New-Object System.IO.DriveInfo($volumeRoot)
    if (-not $drive.IsReady) {
        throw "The Voice Pack installation volume is not ready: $volumeRoot"
    }
    return [int64]$drive.AvailableFreeSpace
}

function Assert-VoicePackInstallPreflight {
    param(
        [Parameter(Mandatory = $true)][double]$ComputeCapability,
        [Parameter(Mandatory = $true)][int64]$VramMiB,
        [Parameter(Mandatory = $true)][int64]$RamBytes,
        [Parameter(Mandatory = $true)][int64]$AvailableDiskBytes,
        [Parameter(Mandatory = $true)][bool]$CompleteExistingInstallation
    )

    if ($ComputeCapability -lt 8.0) {
        throw "The Voice Pack requires NVIDIA compute capability 8.0 or newer; CUDA device 0 reported $ComputeCapability."
    }
    if ($VramMiB -lt 6144) {
        throw "The Voice Pack requires at least 6 GiB of VRAM on CUDA device 0; nvidia-smi reported $VramMiB MiB."
    }
    if ($RamBytes -lt 16GB) {
        throw 'The Voice Pack requires at least 16 GiB of installed RAM.'
    }

    [int64]$requiredDiskBytes = if ($CompleteExistingInstallation) { 2GB } else { 12GB }
    if ($AvailableDiskBytes -lt $requiredDiskBytes) {
        $requiredGiB = [int]($requiredDiskBytes / 1GB)
        $availableGiB = [Math]::Round($AvailableDiskBytes / 1GB, 1)
        throw "The Voice Pack requires at least $requiredGiB GiB free on the installation volume; only $availableGiB GiB is available."
    }
}

if (-not $ConfirmVoiceRights.IsPresent) {
    throw 'Installation requires -ConfirmVoiceRights. Only clone a voice you own or have explicit permission to use.'
}
if (-not $ConfirmLargeDownload.IsPresent) {
    throw 'Installation requires -ConfirmLargeDownload because the optional model and CUDA environment download several gigabytes.'
}
$nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
Assert-VoicePackPlatformPreflight `
    -IsWindows ($env:OS -eq 'Windows_NT') `
    -NvidiaSmiAvailable ($null -ne $nvidiaSmi)
if ([string]::IsNullOrWhiteSpace($ReferenceText)) {
    throw 'ReferenceText cannot be empty.'
}
$ReferenceText = $ReferenceText.Trim()
if ($ReferenceText.Length -gt $MaximumReferenceTextCharacters) {
    throw "ReferenceText cannot exceed $MaximumReferenceTextCharacters characters."
}
if (-not (Test-Path -LiteralPath $ReferenceAudio -PathType Leaf)) {
    throw "Reference audio was not found: $ReferenceAudio"
}

$referenceItem = Get-Item -LiteralPath $ReferenceAudio
$referenceExtension = [System.IO.Path]::GetExtension($referenceItem.Name).ToLowerInvariant()
if ($AllowedAudioExtensions -notcontains $referenceExtension) {
    throw "Reference audio must use one of: $($AllowedAudioExtensions -join ', ')."
}
if ($referenceItem.Length -le 0 -or $referenceItem.Length -gt $MaximumReferenceAudioBytes) {
    throw 'Reference audio must be non-empty and no larger than 50 MiB.'
}

$fullInstallRoot = Get-FullPath -Path $InstallRoot
$volumeRoot = [System.IO.Path]::GetPathRoot($fullInstallRoot).TrimEnd('\')
if ($fullInstallRoot.Equals($volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallRoot cannot be a drive root.'
}

$markerPath = Join-Path $fullInstallRoot $MarkerName
if (Test-Path -LiteralPath $fullInstallRoot -PathType Container) {
    $existingItems = @(Get-ChildItem -LiteralPath $fullInstallRoot -Force -ErrorAction Stop)
    if ($existingItems.Count -gt 0 -and -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Refusing to install into a non-empty unmarked directory: $fullInstallRoot"
    }
}

$hardwareProfile = Get-VoicePackHardwareProfile -NvidiaSmiPath $nvidiaSmi.Source
$completeExistingInstallation = Test-CompleteVoicePackInstallation -InstallRoot $fullInstallRoot
$availableDiskBytes = Get-VoicePackAvailableDiskBytes -InstallRoot $fullInstallRoot
Assert-VoicePackInstallPreflight `
    -ComputeCapability ([double]$hardwareProfile.ComputeCapability) `
    -VramMiB ([int64]$hardwareProfile.VramMiB) `
    -RamBytes ([int64]$hardwareProfile.RamBytes) `
    -AvailableDiskBytes $availableDiskBytes `
    -CompleteExistingInstallation $completeExistingInstallation

# Keep Python validation and the service on the same physical GPU inspected by
# nvidia-smi, even when the parent process has a different CUDA visibility map.
$env:CUDA_DEVICE_ORDER = 'PCI_BUS_ID'
$env:CUDA_VISIBLE_DEVICES = [string]$hardwareProfile.GpuUuid

if (-not (Test-Path -LiteralPath $fullInstallRoot -PathType Container)) {
    [System.IO.Directory]::CreateDirectory($fullInstallRoot) | Out-Null
}

[System.IO.File]::WriteAllText(
    $markerPath,
    "agent-bell-qwen-voice-pack`r`n",
    (New-Object System.Text.UTF8Encoding($false))
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDirectory = Join-Path $fullInstallRoot 'app'
$voicesDirectory = Join-Path $fullInstallRoot 'voices'
$voiceDirectory = Join-Path $voicesDirectory $VoiceId
if ((Test-Path -LiteralPath $voicesDirectory) -and
    ((Get-Item -Force -LiteralPath $voicesDirectory).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'The Voice Pack voices directory cannot be a reparse point.'
}
foreach ($directory in @(
    $appDirectory,
    $voicesDirectory,
    (Join-Path $fullInstallRoot 'hf-home'),
    (Join-Path $fullInstallRoot 'models')
)) {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
}

foreach ($fileName in @('server.py', 'start.ps1', 'requirements.txt', 'README.md')) {
    $sourcePath = Join-Path $scriptRoot $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Voice Pack source file is missing: $fileName"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $appDirectory $fileName) -Force
}

$pythonLauncher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
if ($null -eq $pythonLauncher) {
    throw 'Python Launcher for Windows was not found. Install Python 3.12, then run this installer again.'
}
Invoke-CheckedCommand -FilePath $pythonLauncher.Source -Arguments @(
    '-3.12',
    '-c',
    'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)'
) -Description 'Python 3.12 validation'

$venvDirectory = Join-Path $fullInstallRoot '.venv'
$venvPython = Join-Path $venvDirectory 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    Invoke-CheckedCommand -FilePath $pythonLauncher.Source -Arguments @(
        '-3.12',
        '-m',
        'venv',
        $venvDirectory
    ) -Description 'Virtual environment creation'
}
Invoke-CheckedCommand -FilePath $venvPython -Arguments @(
    '-c',
    'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)'
) -Description 'Isolated Python version validation'

Invoke-CheckedCommand -FilePath $venvPython -Arguments @(
    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--no-cache-dir', '--upgrade', 'pip'
) -Description 'pip upgrade'

# Install the CUDA pair first. The later qwen-tts install will recognize these
# exact wheels as satisfying its torch dependencies instead of fetching CPU wheels.
Invoke-CheckedCommand -FilePath $venvPython -Arguments @(
    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--no-cache-dir',
    '--index-url', $PyTorchIndex,
    "torch==$TorchVersion",
    "torchaudio==$TorchAudioVersion"
) -Description 'CUDA PyTorch installation'

$requirementsPath = Join-Path $appDirectory 'requirements.txt'
Invoke-CheckedCommand -FilePath $venvPython -Arguments @(
    '-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--no-cache-dir',
    '--index-url', 'https://pypi.org/simple',
    '--requirement', $requirementsPath
) -Description "qwen-tts $QwenTtsVersion installation"

$cudaValidation = @'
import json
import torch
import torchaudio

expected_torch = "2.11.0+cu128"
expected_audio = "2.11.0+cu128"
valid = (
    torch.__version__ == expected_torch
    and torchaudio.__version__ == expected_audio
    and torch.cuda.is_available()
    and torch.cuda.is_bf16_supported()
)
payload = {
    "torch": torch.__version__,
    "torchaudio": torchaudio.__version__,
    "cuda_available": torch.cuda.is_available(),
    "bf16_supported": torch.cuda.is_bf16_supported() if torch.cuda.is_available() else False,
    "device": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
}
print(json.dumps(payload, ensure_ascii=True))
raise SystemExit(0 if valid else 1)
'@
$cudaInfo = & $venvPython -c $cudaValidation
if ($LASTEXITCODE -ne 0) {
    throw "CUDA validation failed. Reported runtime: $cudaInfo"
}
Write-Host "CUDA runtime ready: $cudaInfo"

Invoke-CheckedCommand -FilePath $venvPython -Arguments @(
    '-m', 'pip', 'check', '--disable-pip-version-check'
) -Description 'Python dependency validation'

$serverPath = Join-Path $appDirectory 'server.py'
$transactionId = [Guid]::NewGuid().ToString('N')
$stagingVoiceId = 'staging-' + $transactionId
$stagingVoiceDirectory = Join-Path $voicesDirectory $stagingVoiceId
$backupVoiceDirectory = Join-Path $voicesDirectory ('.backup-' + $transactionId)
[System.IO.Directory]::CreateDirectory($stagingVoiceDirectory) | Out-Null
try {
    $stagedReferenceAudio = Join-Path $stagingVoiceDirectory "reference$referenceExtension"
    Copy-Item -LiteralPath $referenceItem.FullName -Destination $stagedReferenceAudio -Force
    [System.IO.File]::WriteAllText(
        (Join-Path $stagingVoiceDirectory 'reference.txt'),
        $ReferenceText,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Invoke-CheckedCommand -FilePath $venvPython -Arguments @(
        $serverPath,
        '--install-root', $fullInstallRoot,
        '--prepare-voice',
        '--voice-id', $stagingVoiceId
    ) -Description 'Private reference audio preparation'

    if (Test-Path -LiteralPath $voiceDirectory) {
        $existingVoice = Get-Item -Force -LiteralPath $voiceDirectory
        if ($existingVoice.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to replace a reparse-point voice directory: $voiceDirectory"
        }
        Move-Item -LiteralPath $voiceDirectory -Destination $backupVoiceDirectory
    }
    try {
        Move-Item -LiteralPath $stagingVoiceDirectory -Destination $voiceDirectory
    }
    catch {
        if ((Test-Path -LiteralPath $backupVoiceDirectory) -and -not (Test-Path -LiteralPath $voiceDirectory)) {
            Move-Item -LiteralPath $backupVoiceDirectory -Destination $voiceDirectory
        }
        throw
    }
    if (Test-Path -LiteralPath $backupVoiceDirectory) {
        Remove-Item -LiteralPath $backupVoiceDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch {
    if (Test-Path -LiteralPath $stagingVoiceDirectory) {
        Remove-Item -LiteralPath $stagingVoiceDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Test-Path -LiteralPath $backupVoiceDirectory) -and -not (Test-Path -LiteralPath $voiceDirectory)) {
        Move-Item -LiteralPath $backupVoiceDirectory -Destination $voiceDirectory -ErrorAction SilentlyContinue
    }
    throw
}

Invoke-CheckedCommand -FilePath $venvPython -Arguments @(
    $serverPath,
    '--install-root', $fullInstallRoot,
    '--download-model'
) -Description 'Official Qwen3-TTS model download'

$startPath = Join-Path $appDirectory 'start.ps1'
Write-Output ([pscustomobject][ordered]@{
    Installed = $true
    InstallRoot = $fullInstallRoot
    Python = $venvPython
    VoiceId = $VoiceId
    Model = 'Qwen/Qwen3-TTS-12Hz-0.6B-Base'
    StartForeground = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$startPath`" -InstallRoot `"$fullInstallRoot`""
    StartHidden = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$startPath`" -InstallRoot `"$fullInstallRoot`" -Hidden"
})
