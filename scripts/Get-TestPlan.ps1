#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('hlg', 'hdr10', 'hdr10plus', 'dovi-p5')][string]$ToneMappingType,
    [ValidateSet('performance-isolated', 'performance-transcode', 'quality')][string]$TestType,
    [ValidateSet('stock', 'emby', 'jellyfin', 'plex')][string]$Source,
    [string[]]$ClipId,
    [string]$UserConfigPath,
    [string]$OutputPath,
    [switch]$Detailed,
    [switch]$AsJson,
    [switch]$NoWrite
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\Configuration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\FFmpeg.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Comparisons.psm1') -Force
$configuration = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $UserConfigPath
$catalog = Read-SuiteJson -Path (Join-Path $repositoryRoot 'config\catalog.json')
$media = Read-SuiteJson -Path (Join-Path $repositoryRoot 'config\media.json')
$clips = @($media.clips | Where-Object { $ClipId -or $_.enabled })
if ($ToneMappingType) { $clips = @($clips | Where-Object { $_.toneMappingType -eq $ToneMappingType }) }
if ($ClipId) {
    foreach ($requestedId in $ClipId) {
        if ($requestedId -notin @($media.clips | ForEach-Object { $_.id })) { throw "Unknown clip ID: $requestedId" }
    }
    $clips = @($clips | Where-Object { $_.id -in $ClipId })
}
$testTypes = if ($TestType) { @($TestType) } else { @($catalog.testTypes | ForEach-Object { $_.id }) }

# Query each supplied binary sequentially. Feature listings establish availability,
# but they do not establish that a GPU or a complete pipeline can run.
$binaryChecks = @{}
foreach ($binarySource in @('stock', 'emby', 'jellyfin', 'plex')) {
    if ($Source -and $Source -ne $binarySource -and $binarySource -ne 'stock') { continue }
    $binaryPath = $configuration.binaries.$binarySource.ffmpegPath
    $check = [ordered]@{ source = $binarySource; filePath = $binaryPath; available = $false; version = $null; filters = @(); error = $null }
    if ([string]::IsNullOrWhiteSpace([string]$binaryPath)) { $check.error = 'Build is disabled in user configuration.' }
    elseif (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) { $check.error = 'Executable is missing.' }
    else {
        try {
            $version = Invoke-FFmpegProcess -FilePath $binaryPath -Arguments @('-version') -WorkingDirectory $repositoryRoot -TimeoutSeconds 30
            $inventory = Invoke-FFmpegProcess -FilePath $binaryPath -Arguments @('-hide_banner', '-filters') -WorkingDirectory $repositoryRoot -TimeoutSeconds 30
            if ($version.TimedOut -or $inventory.TimedOut) { $check.error = 'Binary inspection timed out.' }
            elseif ($version.ExitCode -ne 0 -or $inventory.ExitCode -ne 0) { $check.error = 'Binary inspection failed.' }
            else {
                $versionText = $version.StdOut + "`n" + $version.StdErr
                $check.version = @($versionText -split '\r?\n' | Where-Object { $_ -match '^ffmpeg version' } | Select-Object -First 1)[0]
                $filterText = $inventory.StdOut + "`n" + $inventory.StdErr
                $check.filters = @(
                    foreach ($line in ($filterText -split '\r?\n')) {
                        if ($line -match '^\s+[TSC.]{2,3}\s+(\S+)\s+\S+->\S+') { $Matches[1] }
                    }
                )
                $check.available = $true
            }
        } catch { $check.error = $_.Exception.Message }
    }
    $binaryChecks[$binarySource] = [pscustomobject]$check
}

$entries = New-Object System.Collections.Generic.List[object]
foreach ($clip in $clips) {
    $mediaPath = Join-Path $configuration.paths.mediaPath $clip.fileName
    $mediaProblems = New-Object System.Collections.Generic.List[string]
    if (-not $clip.enabled) { $mediaProblems.Add('Clip is a disabled candidate.') }
    if ([string]::IsNullOrWhiteSpace([string]$clip.sha256)) { $mediaProblems.Add('Clip has no pinned SHA-256.') }
    if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) { $mediaProblems.Add('Media has not been downloaded.') }
    elseif ($clip.sha256) {
        $actualHash = (Get-FileHash -LiteralPath $mediaPath -Algorithm SHA256).Hash
        if ($actualHash -ne $clip.sha256) { $mediaProblems.Add('Media SHA-256 does not match the manifest.') }
    }
    foreach ($testTypeId in $testTypes) {
        $implementations = @(Get-SuiteApplicableImplementations -Catalog $catalog -ToneMappingType $clip.toneMappingType -TestType $testTypeId -Configuration $configuration)
        $curves = @($null)
        if ($testTypeId -eq 'quality') { $curves = @(Get-SuiteComparisonCurves $catalog $clip.toneMappingType) }
        foreach ($curve in $curves) {
        foreach ($implementation in $implementations) {
            if ($curve -and $curve -notin @($implementation.supportedCurves)) { continue }
            if ($Source -and $implementation.source -ne $Source) { continue }
            $problems = New-Object System.Collections.Generic.List[string]
            foreach ($problem in $mediaProblems) { $problems.Add($problem) }
            if ($implementation.pipelineStatus -eq 'blocked') { $problems.Add([string]$implementation.pipelineBlocker) }
            if ($implementation.deviceSelectionRequired) { $problems.Add('Select and confirm the required OpenCL device vendor.') }
            if ($implementation.deviceVendorCheckRequired) { $problems.Add('Actual GPU vendor and exclusions require confirmation.') }
            $binaryCheck = $binaryChecks[$implementation.source]
            if (-not $binaryCheck -or -not $binaryCheck.available) { $problems.Add('FFmpeg executable is unavailable or failed inspection.') }
            else {
                foreach ($requiredFilter in @($implementation.requiredFilters)) {
                    if ($requiredFilter -notin $binaryCheck.filters) { $problems.Add("Binary is missing filter '$requiredFilter'.") }
                }
            }
            if ($implementation.backend -ne 'software') { $problems.Add('Configured GPU requires a pipeline smoke test.') }
            if ($testTypeId -eq 'quality') {
                $referenceCheck = $binaryChecks['stock']
                if (-not $referenceCheck -or -not $referenceCheck.available -or 'libplacebo' -notin $referenceCheck.filters) { $problems.Add('Stock libplacebo reference is unavailable.') }
                $problems.Add('Libplacebo reference requires a Vulkan pipeline smoke test.')
            }
            $status = if ($problems.Count -eq 0) { 'ready-for-preflight' } else { 'needs-preflight' }
            $entries.Add([pscustomobject][ordered]@{
                clipId = $clip.id
                toneMappingType = $clip.toneMappingType
                testType = $testTypeId
                curve = $curve
                implementationId = $implementation.id
                catalogImplementationId = $(if ($implementation.PSObject.Properties['catalogImplementationId']) { $implementation.catalogImplementationId } else { $implementation.id })
                implementationLabel = $implementation.label
                processing = $(if ($implementation.PSObject.Properties['processing']) { $implementation.processing } else { $implementation.backend })
                openclVendor = $(if ($implementation.PSObject.Properties['openclVendor']) { $implementation.openclVendor } else { $null })
                source = $implementation.source
                filter = $implementation.filter
                backend = $implementation.backend
                referenceImplementationId = $(if ($testTypeId -eq 'quality') { 'stock-libplacebo' } else { $null })
                mediaPath = $mediaPath
                status = $status
                blockers = @($problems.ToArray())
            })
        }
        }
    }
}
$orderedEntries = @($entries.ToArray() | Sort-Object clipId, testType, @{ Expression = { $_.implementationId -ne 'stock-libplacebo' } }, implementationId)
$plan = [pscustomobject][ordered]@{
    schemaVersion = 1
    createdUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    stage = 'execution'
    executionImplemented = $true
    benchmarksExecuted = $false
    note = 'Benchmark and quality runners are available. This preview produces no measurements; each execution checks its original media, source-specific pipeline, and selected device before scoring.'
    userConfigPath = $configuration.userConfigPath
    qualityReferenceImplementationId = 'stock-libplacebo'
    binaryChecks = @($binaryChecks.Values | Sort-Object source)
    entries = $orderedEntries
}
$json = $plan | ConvertTo-Json -Depth 20
if (-not $NoWrite) {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $configuration.paths.resultsPath 'test-plan.json' }
    $OutputPath = Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $OutputPath
    $parentDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) { New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null }
    $json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}
if ($AsJson) { Write-Output $json }
else {
    Write-Host 'Tone Mapping Compared - test plan preview'
    Write-Host 'No benchmarks are executed by this preview.'
    $plan.binaryChecks | Select-Object source, available, version, error | Format-Table -Wrap -AutoSize | Out-Host
    if ($orderedEntries.Count -eq 0) { Write-Host 'No comparisons match the selected clips, dimensions, and exclusions.' -ForegroundColor Yellow }
    elseif ($Detailed) { $orderedEntries | Select-Object clipId, testType, implementationId, status, @{ Name = 'blockers'; Expression = { $_.blockers -join ' ' } } | Format-Table -Wrap | Out-Host }
    else {
        $summary = @(
            foreach ($group in @($orderedEntries | Group-Object toneMappingType, testType)) {
                [pscustomobject][ordered]@{
                    signal = $group.Group[0].toneMappingType
                    test = $group.Group[0].testType
                    choices = $group.Count
                    prerequisitesMet = @($group.Group | Where-Object { $_.status -eq 'ready-for-preflight' }).Count
                    needsPreflight = @($group.Group | Where-Object { $_.status -eq 'needs-preflight' }).Count
                }
            }
        )
        $summary | Format-Table -AutoSize | Out-Host
        Write-Host 'Use -Detailed for each comparison and its blockers, or inspect the saved JSON plan.'
    }
    Write-Host $plan.note
    if (-not $NoWrite) { Write-Host ("Saved plan: $OutputPath") }
}
