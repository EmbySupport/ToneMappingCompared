#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$ImplementationId,
    [string[]]$ClipId,
    [string[]]$Curve,
    [ValidateSet('performance-isolated', 'performance-transcode', 'quality')][string]$TestType = 'performance-isolated',
    [string]$UserConfigPath,
    [string]$OutputPath,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Configuration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Pipelines.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/RunLock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Comparisons.psm1') -Force
$configuration = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $UserConfigPath
$catalog = Read-SuiteJson -Path (Join-Path $repositoryRoot 'config/catalog.json')
$manifest = Read-SuiteJson -Path (Join-Path $repositoryRoot 'config/media.json')
$performanceChoices = @(Expand-SuitePerformanceImplementations -Implementations @($catalog.implementations))
foreach ($id in $ImplementationId) { if ($id -notin @($catalog.implementations.id) -and ($TestType -notin @('performance-isolated', 'performance-transcode') -or $id -notin @($performanceChoices.id))) { throw "Unknown implementation ID: $id" } }
foreach ($id in $ClipId) { if ($id -notin @($manifest.clips.id)) { throw "Unknown clip ID: $id" } }
foreach ($id in $Curve) { if ($id -notin @($catalog.curves.id)) { throw "Unknown curve: $id" } }
$clips = @($manifest.clips | Where-Object { ($ClipId -and $_.id -in $ClipId) -or (-not $ClipId -and $_.enabled) })
$entries = New-Object 'Collections.Generic.List[object]'
$logDirectory = Join-Path $configuration.paths.resultsPath ('preflight-logs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$lease = Enter-SuiteRun -RepositoryRoot $repositoryRoot -Operation 'preflight'
try {
[void][IO.Directory]::CreateDirectory($logDirectory)
foreach ($clip in $clips) {
    $mediaPath = Join-Path $configuration.paths.mediaPath $clip.fileName
    $implementations = @(Get-SuiteApplicableImplementations -Catalog $catalog -ToneMappingType $clip.toneMappingType -TestType $TestType -Configuration $configuration | Where-Object { -not $ImplementationId -or $_.id -in $ImplementationId -or ($_.PSObject.Properties['catalogImplementationId'] -and $_.catalogImplementationId -in $ImplementationId) } | Sort-Object @{ Expression = { $_.id -ne $catalog.referenceImplementationId } }, id)
    $profileCurves = @($null)
    if ($TestType -eq 'quality') { $profileCurves = @(Get-SuiteComparisonCurves $catalog $clip.toneMappingType); if ($Curve) { $profileCurves = @($profileCurves | Where-Object { $_ -in $Curve }) } }
    foreach ($currentCurve in $profileCurves) {
    foreach ($choice in $implementations) {
        if ($currentCurve -and $currentCurve -notin @($choice.supportedCurves)) { continue }
        $implementation = if ($currentCurve) { Set-SuiteImplementationCurve $choice $currentCurve } else { $choice }
        Write-Host ("Preflight: {0} / {1}" -f $clip.id, $implementation.id)
        $implementationConfiguration = Get-SuiteImplementationConfiguration -Configuration $configuration -Implementation $implementation
        $entry = Invoke-SuitePipelinePreflight -Implementation $implementation -Clip $clip -Configuration $implementationConfiguration -MediaPath $mediaPath -TestType $TestType -WorkingDirectory $repositoryRoot -LogPathPrefix (Join-Path $logDirectory ($clip.id + '--' + $currentCurve + '--' + $implementation.id))
        $entry | Add-Member -NotePropertyName curve -NotePropertyValue $currentCurve -Force
        foreach ($property in @('catalogImplementationId', 'openclVendor', 'processing')) {
            if ($implementation.PSObject.Properties[$property]) { $entry | Add-Member -NotePropertyName $property -NotePropertyValue $implementation.$property -Force }
        }
        # Full process text is stored in logs. Keep the JSON report small enough to inspect.
        if ($null -ne $entry.Run) {
            $runSummary = $entry.Run | Select-Object FilePath, Arguments, ExitCode, TimedOut, OutputCaptureComplete, Progress, LogFiles
            $entry.Run = $runSummary
        }
        $entries.Add($entry)
    }
    }
}
$report = [pscustomobject][ordered]@{
    schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('o'); testType = $TestType
    note = 'Sequential original-media one-frame smoke checks. No benchmark scores or quality metrics are produced.'
    entries = @($entries.ToArray()); passed = @($entries.ToArray() | Where-Object { $_.Passed }).Count
    blocked = @($entries.ToArray() | Where-Object { -not $_.Passed }).Count
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $configuration.paths.resultsPath 'preflight.json' }
$OutputPath = Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $OutputPath
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
$report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$entries.ToArray() | Select-Object clipId, implementationId, status, Reason | Format-Table -Wrap -AutoSize | Out-Host
Write-Host ("Saved preflight: {0}" -f $OutputPath)
if ($PassThru) { $report }
}
finally { Exit-SuiteRun -Lease $lease }
