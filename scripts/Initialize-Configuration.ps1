#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$UserConfigPath,
    [switch]$UseDefaults
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\Configuration.psm1') -Force
if ([string]::IsNullOrWhiteSpace($UserConfigPath)) {
    $UserConfigPath = Join-Path $repositoryRoot 'config\user.json'
}
$targetPath = Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $UserConfigPath
$sourcePath = if (Test-Path -LiteralPath $targetPath -PathType Leaf) { $targetPath } else { Join-Path $repositoryRoot 'config\user.example.json' }
$configuration = Read-SuiteJson -Path $sourcePath

function Read-Setting {
    param([string]$Label, $CurrentValue)
    $value = Read-Host ('{0} [{1}] (Enter keeps current)' -f $Label, $CurrentValue)
    if ([string]::IsNullOrWhiteSpace($value)) { return $CurrentValue }
    return $value
}

function Read-DeviceNumber {
    param([string]$Label, $CurrentValue)
    while ($true) {
        $value = Read-Setting -Label $Label -CurrentValue $CurrentValue
        $deviceNumber = 0
        if ([int]::TryParse([string]$value, [ref]$deviceNumber) -and $deviceNumber -ge 0) { return $deviceNumber }
        Write-Host 'Enter a non-negative device number.' -ForegroundColor Yellow
    }
}

function Read-Exclusion {
    param([string]$Label, [bool]$CurrentValue)
    $defaultAnswer = if ($CurrentValue) { 'yes' } else { 'no' }
    while ($true) {
        $value = Read-Setting -Label $Label -CurrentValue $defaultAnswer
        if ($value -match '^(y|yes|true|1)$') { return $true }
        if ($value -match '^(n|no|false|0)$') { return $false }
        Write-Host 'Enter yes or no.' -ForegroundColor Yellow
    }
}

function Read-OptionalDeviceNumber {
    param([string]$Label, $CurrentValue)
    while ($true) {
        $value = Read-Setting -Label $Label -CurrentValue $CurrentValue
        if ([string]::IsNullOrWhiteSpace([string]$value) -or $value -eq '-') { return $null }
        $deviceNumber = 0
        if ([int]::TryParse([string]$value, [ref]$deviceNumber) -and $deviceNumber -ge 0) { return $deviceNumber }
        Write-Host 'Enter a non-negative device number, or - to clear it.' -ForegroundColor Yellow
    }
}

if (-not $UseDefaults) {
    Write-Host 'Tone Mapping Compared - configuration'
    Write-Host 'Paths may be absolute or relative to the suite directory.'
    Write-Host ''
    try {
        $adapters = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Select-Object Name, DriverVersion)
        if ($adapters.Count -gt 0) {
            Write-Host 'Windows reports these display adapters (their order is not an FFmpeg device index):'
            $adapters | Format-Table -AutoSize | Out-Host
        }
    } catch { Write-Host 'Display-adapter information is unavailable; you can still enter device settings.' }

    foreach ($source in @('stock', 'emby', 'jellyfin', 'plex')) {
        $binary = $configuration.binaries.$source
        $binary.ffmpegPath = Read-Setting -Label ("$source FFmpeg executable") -CurrentValue $binary.ffmpegPath
    }
    $configuration.paths.mediaPath = Read-Setting -Label 'Downloaded media directory' -CurrentValue $configuration.paths.mediaPath
    $configuration.paths.tempOutputPath = Read-Setting -Label 'Temporary output directory' -CurrentValue $configuration.paths.tempOutputPath
    $configuration.paths.resultsPath = Read-Setting -Label 'Results directory' -CurrentValue $configuration.paths.resultsPath
    $configuration.devices.vulkan = Read-DeviceNumber -Label 'Vulkan device number' -CurrentValue $configuration.devices.vulkan
    $configuration.devices.cuda = Read-DeviceNumber -Label 'CUDA device number' -CurrentValue $configuration.devices.cuda
    foreach ($setting in @('platform', 'device')) {
        $configuration.devices.opencl.$setting = Read-OptionalDeviceNumber -Label ("OpenCL $setting (set both platform and device, '-' clears)") -CurrentValue $configuration.devices.opencl.$setting
    }
    do {
        $openclVendor = [string](Read-Setting -Label 'Quality OpenCL vendor (intel, amd, nvidia, any)' -CurrentValue $configuration.devices.opencl.vendor)
    } while ($openclVendor -notin @('intel', 'amd', 'nvidia', 'any'))
    $configuration.devices.opencl.vendor = $openclVendor.ToLowerInvariant()
    foreach ($vendor in @('intel','amd')) {
        foreach ($setting in @('platform','device','d3d11Adapter')) {
            $configuration.devices.performanceOpencl.$vendor.$setting = Read-OptionalDeviceNumber -Label ("Performance OpenCL $vendor $setting (optional override, '-' clears)") -CurrentValue $configuration.devices.performanceOpencl.$vendor.$setting
        }
    }
    foreach ($vendor in @('software', 'intel', 'amd', 'nvidia')) {
        $configuration.exclude.$vendor = Read-Exclusion -Label ("Exclude $vendor tests") -CurrentValue ([bool]$configuration.exclude.$vendor)
    }
}

$parentDirectory = Split-Path -Parent $targetPath
if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
}
# Validate before replacing the user's file. A failed edit leaves their prior configuration intact.
$temporaryPath = $targetPath + '.pending'
try {
    $configuration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    $null = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $temporaryPath
    Move-Item -LiteralPath $temporaryPath -Destination $targetPath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
}
Write-Host ("Saved configuration: $targetPath")
Write-Host 'Run 03-PreviewTests.cmd to inspect available binaries, clips, and planned comparisons.'
