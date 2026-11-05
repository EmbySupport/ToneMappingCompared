#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('performance-isolated', 'performance-transcode', 'all')][string]$TestType = 'all',
    [string[]]$ClipId,
    [string[]]$ImplementationId,
    [string]$UserConfigPath,
    [ValidateRange(2, 100000000)][int]$FrameCount,
    [ValidateRange(1, 100)][int]$Repetitions,
    [ValidateRange(0.001, 86400)][double]$DurationSeconds,
    [ValidateRange(0, 86400)][double]$SeekSeconds,
    [ValidateRange(160, 100000000)][int]$DoviShortFrames,
    [ValidateRange(320, 100000000)][int]$DoviLongFrames,
    [switch]$DryRun,
    [switch]$NoPublish,
    [switch]$StopOnError,
    [switch]$PassThru,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-BenchmarkProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-NoOtherFFmpegProcess {
    $blockers = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName.IndexOf('ffmpeg', [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($blockers.Count) {
        $names = (@($blockers | Sort-Object Id | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', ')
        $failure = New-Object InvalidOperationException("Performance execution blocked by another FFmpeg process: $names")
        $failure.Data['FFmpegProcessConflict'] = $true
        throw $failure
    }
}

function Get-BenchmarkAssetPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $root = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd([char]92) + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($root.Length).Replace('\', '/') }
    return (New-Object Uri($full)).AbsoluteUri
}

function Get-BenchmarkExecution {
    param($Run)
    if ($null -eq $Run) { return $null }
    $files = Get-BenchmarkProperty $Run 'LogFiles'
    return [pscustomobject]@{
        commandLine = Get-BenchmarkProperty $Run 'CommandLine'
        log = Get-BenchmarkAssetPath (Get-BenchmarkProperty $files 'Log')
        graph = Get-BenchmarkAssetPath (Get-BenchmarkProperty $files 'Graph')
    }
}

function Get-BenchmarkProcessRecord {
    param($Run)
    if ($null -eq $Run) { return $null }
    $record = [ordered]@{}
    foreach ($property in $Run.PSObject.Properties) {
        if ($property.Name -notin @('StdOut', 'StdErr')) { $record[$property.Name] = $property.Value }
    }
    return [pscustomobject]$record
}

function Get-BenchmarkPreflightRecord {
    param($Preflight)
    $record = [ordered]@{}
    foreach ($property in $Preflight.PSObject.Properties) {
        if ($property.Name -eq 'Run') { $record[$property.Name] = Get-BenchmarkProcessRecord $property.Value }
        elseif ($property.Name -eq 'BinaryInspection') {
            $binary = $property.Value
            $record[$property.Name] = $(if ($binary) { [pscustomobject]@{ FilePath = $binary.FilePath; Version = $binary.Version; Sha256 = $binary.Sha256; ExternalCodecs = Get-BenchmarkProperty $binary 'ExternalCodecs' } } else { $null })
        }
        else { $record[$property.Name] = $property.Value }
    }
    return [pscustomobject]$record
}

function Test-BenchmarkFiniteNumber {
    param($Value)
    if ($null -eq $Value -or $Value -isnot [ValueType] -or $Value -is [bool] -or $Value -is [char]) { return $false }
    try { $number = [double]$Value } catch { return $false }
    return -not ([double]::IsNaN($number) -or [double]::IsInfinity($number))
}

function Get-BenchmarkProcessProblem {
    param($Result, [Nullable[int]]$ExpectedFrames)
    if ($null -eq $Result) { return 'No process result.' }
    if ($Result.TimedOut) { return 'FFmpeg timed out.' }
    if ($null -eq $Result.ExitCode -or $Result.ExitCode -ne 0) { return "FFmpeg exit code: $($Result.ExitCode)." }
    if (-not $Result.OutputCaptureComplete) { return 'FFmpeg output capture was incomplete.' }
    $renderFailure=Get-QualityNativeRenderingFailure -Text (Get-BenchmarkProperty $Result 'StdErr')
    if($renderFailure){return $renderFailure}
    if ($null -eq $Result.Benchmark -or $null -eq $Result.Benchmark.WallSeconds) {
        return 'FFmpeg did not report benchmark wall time.'
    }
    if (-not (Test-BenchmarkFiniteNumber $Result.Benchmark.WallSeconds)) { return 'FFmpeg reported nonfinite or invalid wall time.' }
    if ($Result.Benchmark.WallSeconds -lt 0) { return 'FFmpeg reported negative wall time.' }
    if ($null -eq $Result.Progress -or -not (Test-BenchmarkFiniteNumber $Result.Progress.Frame) -or $Result.Progress.Frame -le 0) {
        return 'FFmpeg did not report a positive final frame count.'
    }
    if ($null -ne $ExpectedFrames -and $Result.Progress.Frame -ne $ExpectedFrames) {
        return "Decoded/output frame count $($Result.Progress.Frame) differs from requested count $ExpectedFrames."
    }
    return $null
}

function New-IsolatedBenchmarkSample {
    param($SingleResult, $LoopResult, [int]$FrameCount, [int]$Repetition, [double]$SourceFrameRate = 0, [double]$MinimumDeltaSeconds = 0)
    $problem = Get-BenchmarkProcessProblem $SingleResult 1
    if (-not $problem) { $problem = Get-BenchmarkProcessProblem $LoopResult $FrameCount }
    $cost = $null
    $fps = $null
    $wallFps = $null
    $cpuCost = $null
    $speed = $null
    $delta = $null
    $measuredFps = $null
    $windowTooShort = $false
    if (-not $problem) {
        $delta = $LoopResult.Benchmark.WallSeconds - $SingleResult.Benchmark.WallSeconds
        if ($delta -gt 0 -and (Test-BenchmarkFiniteNumber (($FrameCount - 1) / $delta))) { $measuredFps = ($FrameCount - 1) / $delta }
        if ($delta -lt $MinimumDeltaSeconds) {
            $problem = "Paired wall-time difference $delta s is below the minimum $MinimumDeltaSeconds s; no isolated score."
            $windowTooShort = $true
        }
    }
    if (-not $problem) {
        $cost = $delta / ($FrameCount - 1)
        if (-not (Test-BenchmarkFiniteNumber $cost) -or $cost -le 0) { $problem = 'Paired wall-time difference is nonpositive or nonfinite; no isolated score.'; $cost = $null; $windowTooShort = $true }
        else {
            $fps = 1.0 / $cost
            if (-not (Test-BenchmarkFiniteNumber $fps)) { $problem = 'Paired wall-time difference cannot produce a finite FPS score.'; $cost = $null; $fps = $null }
            else {
                if ($LoopResult.Benchmark.WallSeconds -gt 0) { $wallFps = $FrameCount / $LoopResult.Benchmark.WallSeconds }
                if ($SourceFrameRate -gt 0) { $speed = $fps / $SourceFrameRate }
                $singleCpu = $SingleResult.Benchmark.UserSeconds + $SingleResult.Benchmark.SystemSeconds
                $loopCpu = $LoopResult.Benchmark.UserSeconds + $LoopResult.Benchmark.SystemSeconds
                $cpuCost = ($loopCpu - $singleCpu) / ($FrameCount - 1)
            }
        }
    }
    return [pscustomobject][ordered]@{
        repetition = $Repetition; valid = -not [bool]$problem; reason = $problem
        frames = $FrameCount; frameCostSeconds = $cost; fps = $fps; speed = $speed
        wallFps = $wallFps; cpuSecondsPerFrame = $cpuCost
        pairedWallDeltaSeconds = $delta; minimumDeltaSeconds = $MinimumDeltaSeconds; windowTooShort = $windowTooShort; measuredFps = $measuredFps
        wallSeconds = Get-BenchmarkProperty (Get-BenchmarkProperty $LoopResult 'Benchmark') 'WallSeconds'
        singleFrameWallSeconds = Get-BenchmarkProperty (Get-BenchmarkProperty $SingleResult 'Benchmark') 'WallSeconds'
        reportedPipelineSpeed = Get-BenchmarkProperty (Get-BenchmarkProperty $LoopResult 'Progress') 'Speed'
        singleFrameRun = $SingleResult; loopRun = $LoopResult
    }
}

function New-TranscodeBenchmarkSample {
    param($ProcessResult, $BaselineResult, [int]$Repetition, [double]$SourceFrameRate = 0, [int]$MapperRepeats = 1)
    if ($MapperRepeats -lt 1) { $MapperRepeats = 1 }
    $problem = Get-BenchmarkProcessProblem $ProcessResult $null
    $fps = $null
    $speed = $null
    $cpuCost = $null
    $cpuDelta = $null
    $baselineProblem = $null
    $baselineProcessProblem = $null
    $mediaSeconds = $null
    if (-not $problem -and $ProcessResult.Benchmark.WallSeconds -le 0) { $problem = 'Transcode wall time is nonpositive.' }
    if (-not $problem) {
        $fps = $ProcessResult.Progress.Frame / $ProcessResult.Benchmark.WallSeconds
        if (-not (Test-BenchmarkFiniteNumber $fps)) { $problem = 'Transcode timing cannot produce a finite FPS score.'; $fps = $null }
    }
    if (-not $problem) {
        if ($SourceFrameRate -gt 0) { $mediaSeconds = $ProcessResult.Progress.Frame / $SourceFrameRate }
        if ($null -ne $mediaSeconds -and $mediaSeconds -gt 0) { $speed = $mediaSeconds / $ProcessResult.Benchmark.WallSeconds }
        if ($null -ne $BaselineResult) {
            $baselineProcessProblem = Get-BenchmarkProcessProblem $BaselineResult ([int]$ProcessResult.Progress.Frame)
            if (-not $baselineProcessProblem -and $BaselineResult.Benchmark.WallSeconds -le 0) { $baselineProcessProblem = 'Control transcode wall time is nonpositive.' }
            $baselineProblem = $baselineProcessProblem
            if (-not $baselineProblem) {
                $cpuWith = $ProcessResult.Benchmark.UserSeconds + $ProcessResult.Benchmark.SystemSeconds
                $cpuWithout = $BaselineResult.Benchmark.UserSeconds + $BaselineResult.Benchmark.SystemSeconds
                $cpuDelta = $cpuWith - $cpuWithout
                if ($cpuDelta -gt 0) { $cpuCost = $cpuDelta / $ProcessResult.Progress.Frame }
                else { $baselineProblem = 'Paired CPU-time difference is nonpositive; no incremental CPU-cost estimate.' }
            }
        }
    }
    return [pscustomobject][ordered]@{
        repetition = $Repetition; valid = -not [bool]$problem; reason = $problem
        frames = Get-BenchmarkProperty (Get-BenchmarkProperty $ProcessResult 'Progress') 'Frame'
        fps = $fps; speed = $speed
        mapperRepeats = $MapperRepeats; mappedFps = $(if ($null -ne $fps) { $fps * $MapperRepeats } else { $null })
        wallSeconds = Get-BenchmarkProperty (Get-BenchmarkProperty $ProcessResult 'Benchmark') 'WallSeconds'
        mediaSeconds = $mediaSeconds; sourceFrameRate = $SourceFrameRate
        mediaDurationBasis = 'Output frame count divided by nominal input frame rate; no frame timestamps collected.'
        filterCpuSecondsPerFrame = $cpuCost; pairedCpuDeltaSeconds = $cpuDelta; baselineProblem = $baselineProblem; baselineProcessProblem = $baselineProcessProblem
        run = $ProcessResult; baselineRun = $BaselineResult
    }
}

function Get-BenchmarkSampleStopReason {
    param($Sample)
    if ($null -eq $Sample) { return 'No benchmark sample was produced.' }
    if (-not $Sample.valid) { return $(if ($Sample.reason) { $Sample.reason } else { 'Benchmark sample is invalid.' }) }
    $controlFailure = Get-BenchmarkProperty $Sample 'baselineProcessProblem'
    if ($controlFailure) { return 'Transcode control failed: ' + $controlFailure }
    return $null
}



function Get-BenchmarkAggregate {
    param([object[]]$Samples, [ValidateSet('best','median')][string]$Aggregation = 'best')
    $valid = @($Samples | Where-Object { $_.valid -and (Test-BenchmarkFiniteNumber $_.fps) -and $_.fps -gt 0 })
    if ($valid.Count -eq 0) {
        return [pscustomobject]@{ validCount = 0; invalidCount = @($Samples).Count; best = $null; min = $null; max = $null; spread = $null }
    }
    $ordered = @($valid | Sort-Object fps -Descending)
    $maximum = $ordered[0].fps
    $best = if ($Aggregation -eq 'median') { if($valid.Count -ge 3 -and $valid.Count % 2 -eq 1){$ordered[[int][Math]::Floor($valid.Count/2.0)]}else{$null} } else { $ordered[0] }
    $minimum = $ordered[$ordered.Count - 1].fps
    return [pscustomobject]@{
        validCount = $valid.Count; invalidCount = @($Samples).Count - $valid.Count; best = $best
        min = $minimum; max = $maximum; spread = 100.0 * ($maximum - $minimum) / $maximum
    }
}

function Get-BenchmarkRunOrder {
    param([object[]]$Implementations, [int]$Repetition)
    if ($Repetition % 2 -eq 1) { return $Implementations }
    for ($index = $Implementations.Count - 1; $index -ge 0; $index--) { $Implementations[$index] }
}

function Get-BenchmarkSystem {
    $unavailable = New-Object 'Collections.Generic.List[object]'
    $record = [ordered]@{
        computerName = $env:COMPUTERNAME; powershellVersion = $PSVersionTable.PSVersion.ToString()
        os = $null; cpu = @(); gpu = @(); powerPlan = $null; simdFlags = $null
    }
    foreach ($component in @(
        @{ name = 'os'; class = 'Win32_OperatingSystem'; properties = @('Caption', 'Version', 'BuildNumber', 'OSArchitecture') },
        @{ name = 'cpu'; class = 'Win32_Processor'; properties = @('Name', 'Manufacturer', 'NumberOfCores', 'NumberOfLogicalProcessors', 'MaxClockSpeed') },
        @{ name = 'gpu'; class = 'Win32_VideoController'; properties = @('Name', 'AdapterCompatibility', 'DriverVersion', 'PNPDeviceID') }
    )) {
        try {
            $items = @(Get-CimInstance -ClassName $component.class -ErrorAction Stop | Select-Object -Property $component.properties)
            $record[$component.name] = $items
        }
        catch { $unavailable.Add([pscustomobject]@{ component = $component.name; reason = $_.Exception.Message }) }
    }
    try {
        $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
        $plan = Invoke-CapturedProcess -FilePath $powercfg -Arguments @('/getactivescheme') -WorkingDirectory $repositoryRoot -TimeoutSeconds 15
        if ($plan.ExitCode -ne 0 -or $plan.TimedOut) { throw 'powercfg did not return the active power scheme.' }
        $record.powerPlan = $plan.StdOut.Trim()
    }
    catch { $unavailable.Add([pscustomobject]@{ component = 'powerPlan'; reason = $_.Exception.Message }) }
    $unavailable.Add([pscustomobject]@{ component = 'simdFlags'; reason = 'Detailed SIMD flags cannot be verified with the built-in PowerShell/CIM API; no CPUID helper or runtime is installed.' })
    $record.metadataUnavailable = @($unavailable.ToArray())
    return [pscustomobject]$record
}

function Write-BenchmarkReport {
    param($Report, [string]$Path)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $Report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-BenchmarkBinaryRecord {
    param([string]$Source, [string]$Path, [string]$Directory)
    $record = [ordered]@{ source = $Source; filePath = $Path; sha256 = $null; version = $null; error = $null; logPaths = @() }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) {
        $record.error = 'Binary disabled or missing.'
    }
    else {
        try {
            $record.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
            $result = Invoke-FFmpegProcess -FilePath $Path -Arguments @('-version') -WorkingDirectory $Directory `
                -TimeoutSeconds 30 -LogPathPrefix (Join-Path $Directory ('binary-' + $Source))
            if ($result.ExitCode -ne 0 -or $result.TimedOut -or -not $result.OutputCaptureComplete) { throw 'Binary version inspection failed.' }
            $lines = @(($result.StdOut + "`n" + $result.StdErr) -split '[\r\n]+' | Where-Object { $_ -match '^(ffmpeg version|Plex Transcoder)' })
            if ($lines.Count -gt 0) { $record.version = $lines[0] } else { $record.version = $result.StdOut.Trim() }
            $record.logPaths = @($result.LogFiles)
            $externalCodecs = Get-BenchmarkProperty $result 'ExternalCodecs'
            if ($externalCodecs) { $record['externalCodecs'] = $externalCodecs }
        }
        catch { $record.error = $_.Exception.Message }
    }
    return [pscustomobject]$record
}

function Get-BenchmarkSourceFrameRate {
    param($Preflight)
    $properties = Get-BenchmarkProperty $Preflight 'ObservedStreamProperties'
    $inputStream = Get-BenchmarkProperty $properties 'Input'
    $rate = Get-BenchmarkProperty $inputStream 'frameRate'
    if ($null -eq $rate) { $rate = Get-BenchmarkProperty $properties 'frameRate' }
    if ([string]$rate -match '^([0-9]+)/([0-9]+)$') {
        $denominator = [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
        if ($denominator -gt 0) {
            return [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) / $denominator
        }
    }
    $parsedRate = 0.0
    if ([double]::TryParse([string]$rate, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedRate) -and $parsedRate -gt 0 -and -not [double]::IsInfinity($parsedRate)) { return $parsedRate }
    return 0.0
}

function Assert-BenchmarkBinaryUnchanged {
    param([string]$FilePath, [string]$ExpectedHash)
    if ((Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedHash) {
        throw 'The FFmpeg executable changed during this run; retained logs are not scored under stale binary provenance.'
    }
}

function Get-BenchmarkRowKey {
    param($Row)
    return [string](Get-BenchmarkProperty $Row 'clipId') + '|' + [string](Get-BenchmarkProperty $Row 'implementationId') + '|' + [string](Get-BenchmarkProperty $Row 'testType')
}

function Get-PublishedBenchmarkRows {
    # Rows of the published matrix that are still current: the method version
    # of their test type and the binary that is configured for their source now.
    # Rows without their own version carry the version of the whole matrix.
    param([string]$Path, [hashtable]$CurrentBinaryHashes, [hashtable]$RowMethodVersions)
    $result = [pscustomobject]@{ rows = @(); binaries = @() }
    if (-not [IO.File]::Exists($Path)) { return $result }
    try { $published = Read-SuiteJson $Path } catch { return $result }
    if ((Get-BenchmarkProperty $published 'dryRun') -eq $true) { return $result }
    $matrixVersion = Get-BenchmarkProperty $published 'methodVersion'
    $current = @{}
    foreach ($record in @(Get-BenchmarkProperty $published 'binaries')) {
        $source = [string](Get-BenchmarkProperty $record 'source')
        if ($source -and $CurrentBinaryHashes.ContainsKey($source) -and [string](Get-BenchmarkProperty $record 'sha256') -eq [string]$CurrentBinaryHashes[$source]) { $current[$source] = $record }
    }
    $result.rows = @(foreach ($row in @(Get-BenchmarkProperty $published 'results')) {
        if ($null -eq $row -or -not $current.ContainsKey([string](Get-BenchmarkProperty $row 'source'))) { continue }
        $rowVersion = Get-BenchmarkProperty $row 'methodVersion'
        if ($null -eq $rowVersion) { $rowVersion = $matrixVersion }
        if ($null -eq $rowVersion -or $rowVersion -ne $RowMethodVersions[[string](Get-BenchmarkProperty $row 'testType')]) { continue }
        $row | Add-Member -NotePropertyName methodVersion -NotePropertyValue $rowVersion -Force
        if ((Get-BenchmarkProperty $row 'status') -eq 'running') {
            $row.status = 'failed'; $row.reason = 'The run that measured this row ended before the measurement completed.'
        }
        $row
    })
    $result.binaries = @($current.Values)
    return $result
}

function Publish-BenchmarkMatrix {
    # Rows of this run replace the published rows with the same key, whatever
    # their status; rows of other keys stay as published.
    param([string]$State)
    $keys = @{}
    foreach ($row in $entries) { $keys[(Get-BenchmarkRowKey $row)] = $true }
    $rows = New-Object 'Collections.Generic.List[object]'
    foreach ($row in $publishedBase.rows) { if (-not $keys.ContainsKey((Get-BenchmarkRowKey $row))) { $rows.Add($row) } }
    foreach ($row in $entries) { $rows.Add($row) }
    $binaries = @{}
    foreach ($record in $publishedBase.binaries) { $binaries[[string]$record.source] = $record }
    foreach ($record in $binaryRecords.Values) { $binaries[[string]$record.source] = $record }
    $matrix = [ordered]@{}
    foreach ($property in $report.PSObject.Properties) { $matrix[$property.Name] = $property.Value }
    $matrix['results'] = @($rows.ToArray())
    $matrix['binaries'] = @($binaries.Values | Sort-Object source)
    $matrix['state'] = $State
    $matrix['publishedUtc'] = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $matrix['runIds'] = @($rows | ForEach-Object { Get-BenchmarkProperty $_ 'runId' } | Where-Object { $_ } | Sort-Object -Unique)
    Write-BenchmarkReport ([pscustomobject]$matrix) $publishedPath
    [void](Export-SuiteViewerData -RepositoryRoot $repositoryRoot -Configuration $configuration -Catalog $catalog -Media $media)
}









$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\Configuration.psm1') -Force
$pipelineModule = Join-Path $PSScriptRoot 'lib\Pipelines.psm1'
$pipelineAvailable = Test-Path -LiteralPath $pipelineModule -PathType Leaf
if ($pipelineAvailable) { Import-Module $pipelineModule -Force }
elseif (-not $DryRun) { throw 'The pipeline module is missing: scripts/lib/Pipelines.psm1.' }
# Import into this script after the pipeline module's nested import so both
# runner commands remain available during early system-metadata collection.
Import-Module (Join-Path $PSScriptRoot 'lib\FFmpeg.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\RunLock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DoviBenchmark.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Quality.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\ViewerData.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\PerformanceWorkloads.psm1')
$configuration = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $UserConfigPath
$workloadsPath = Join-Path $repositoryRoot 'config/performance-workloads.json'
$fixedWorkloads = Read-SuitePerformanceWorkloads -Path $workloadsPath
$methodVersion = 8
$rowMethodVersions = @{ 'performance-isolated' = 6; 'performance-transcode' = 8 }
$publishedPath = Join-Path $configuration.paths.resultsPath 'performance.json'
$explicitDoviWindows = $PSBoundParameters.ContainsKey('DoviShortFrames')
if ($explicitDoviWindows -ne $PSBoundParameters.ContainsKey('DoviLongFrames')) { throw 'Supply both DoviShortFrames and DoviLongFrames.' }
if ($explicitDoviWindows -and ($DoviShortFrames % 160 -ne 0 -or $DoviLongFrames % 160 -ne 0 -or $DoviLongFrames -le $DoviShortFrames)) { throw 'Dolby Vision timing windows must be whole 160-frame passes, and the long window must be longer.' }
$catalog = Read-SuiteJson (Join-Path $repositoryRoot 'config\catalog.json')
$media = Read-SuiteJson (Join-Path $repositoryRoot 'config\media.json')
foreach ($id in $ClipId) { if ($id -notin @($media.clips.id)) { throw "Unknown clip ID: $id" } }
$performanceChoices = @(Expand-SuitePerformanceImplementations -Implementations @($catalog.implementations))
foreach ($id in $ImplementationId) { if ($id -notin @($catalog.implementations.id) -and $id -notin @($performanceChoices.id)) { throw "Unknown implementation ID: $id" } }
if (-not $PSBoundParameters.ContainsKey('Repetitions')) { $Repetitions = $configuration.benchmark.repetitions }
$workloadOverrides = @{}
foreach ($name in @('FrameCount','DoviShortFrames','DoviLongFrames','SeekSeconds','DurationSeconds')) {
    if ($PSBoundParameters.ContainsKey($name)) { $workloadOverrides[$name] = $PSBoundParameters[$name] }
}
$clips = @($media.clips | Where-Object { $ClipId -or $_.enabled })
if ($ClipId) { $clips = @($clips | Where-Object { $_.id -in $ClipId }) }
$testTypes = if ($TestType -eq 'all') { @('performance-isolated', 'performance-transcode') } else { @($TestType) }
$publishResults = -not $DryRun -and -not $NoPublish
$report = $null
$entries = New-Object 'Collections.Generic.List[object]'
$binaryRecords = @{}
$lease = $null
if (-not $DryRun) { $lease = Enter-SuiteRun -RepositoryRoot $repositoryRoot -Operation 'performance-benchmarks' }
try {
$publishedBase = [pscustomobject]@{ rows = @(); binaries = @() }
if ($publishResults) {
    $currentBinaryHashes = @{}
    foreach ($source in @('stock', 'emby', 'jellyfin', 'plex')) {
        $path = [string]$configuration.binaries.$source.ffmpegPath
        $currentBinaryHashes[$source] = if ($path -and [IO.File]::Exists($path)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    }
    $publishedBase = Get-PublishedBenchmarkRows -Path $publishedPath -CurrentBinaryHashes $currentBinaryHashes -RowMethodVersions $rowMethodVersions
}
$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = Join-Path $configuration.paths.resultsPath ('performance\' + $runId)
[void][IO.Directory]::CreateDirectory($runDirectory)
$reportPath = Join-Path $runDirectory 'report.json'
$report = [pscustomobject][ordered]@{
    schemaVersion = 1; methodVersion = $methodVersion; kind = 'performance'; createdUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    runId = $runId; dryRun = [bool]$DryRun; staged = [bool]$NoPublish; state = 'running'; userConfigPath = $configuration.userConfigPath
    system = $null; binaries = @(); results = @(); reportPath = $reportPath
    timing = [pscustomobject]@{ mode = 'checked-in-fixed-workloads'; workloadPath = 'config/performance-workloads.json'; workloadSha256 = (Get-FileHash -LiteralPath $workloadsPath -Algorithm SHA256).Hash.ToLowerInvariant(); overrides = [pscustomobject]$workloadOverrides }
    notes = @(
        'All process invocations are sequential. Repetition order alternates across implementations.',
        'Workloads use checked-in fixed frame counts and seeks on every machine. No timing calibration, automatic resizing, or results-history sizing is performed. Explicit CLI overrides are recorded.',
        'For signals other than Dolby Vision P5, isolated fps is 1 / ((rtime(N) - rtime(1)) / (N - 1)). Required input preparation and hardware upload occur once before the loop. Required output conversion remains in the measured chain; GPU rows have no per-iteration host transfer.',
        'Dolby Vision P5 isolated runs retain the recorded eight sampled keyframes, twenty repetitions per state, fixed seek and keyframe stride, with loop=-1 stopped by fixed whole 160-frame windows. No automatic metadata probe or seek/static fallback changes that workload.',
        'Three previously unsuccessful planned transcodes have only a recorded fixed 30-second media duration and no measured output count; those duration-only workloads remain explicit without invented frame counts.',
        'Full transcode fps is actual output frames / FFmpeg wall time. Hardware implementations decode, map, scale to 720p and encode on hardware with no hwupload/hwdownload. Hardware routes repeat each decoded frame five times before any interop map and keep one repeat before the scaler, so that mapping, tone mapping and mapping back run five times per output frame and the mapper rather than the decoder can limit throughput. Mapped fps is fps x 5. Software implementations use one pass and libx264 ultrafast.',
        'Each filter uses its recorded supported options.',
        'Dolby Vision P5 reports the median of three valid pairs; other signals report the best valid sample. Spread is retained for both. Differences below approximately 3-5 percent may be measurement noise.',
        'Missing metadata, unsupported devices and failed preflights never receive scores.',
        'The published matrix (performance.json) is updated after every sample. Each row of this run replaces the published row of the same clip, implementation and test type; rows measured with a binary that is no longer configured are removed.'
    )
}
if (-not $DryRun) { $report.system = Get-BenchmarkSystem }
$verifiedMedia = @{}
if (-not $DryRun) { Assert-NoOtherFFmpegProcess }

foreach ($originalClip in $clips) {
    $clipValues = [ordered]@{}
    foreach ($property in $originalClip.PSObject.Properties) { $clipValues[$property.Name] = $property.Value }
    $seek = 0.0
    if ($PSBoundParameters.ContainsKey('SeekSeconds')) { $seek = $SeekSeconds }
    $clipValues.seekSeconds = [double]$seek
    # Each job below supplies its checked-in seek, including the recorded
    # Dolby Vision eight-state window. Manifest/default timing cannot alter it.
    $clipValues.performanceSeekSeconds = $(if ($PSBoundParameters.ContainsKey('SeekSeconds')) { [double]$SeekSeconds } else { 0.0 })
    $clip = [pscustomobject]$clipValues
    $mediaPath = Join-Path $configuration.paths.mediaPath $clip.fileName
    $mediaProblem = $null
    if (-not $clip.enabled) { $mediaProblem = 'Clip is a disabled candidate.' }
    elseif ([string]$clip.sha256 -notmatch '^[a-fA-F0-9]{64}$') { $mediaProblem = 'Clip has no pinned SHA-256.' }
    elseif (-not [IO.File]::Exists($mediaPath)) { $mediaProblem = 'Media has not been downloaded.' }
    elseif ($seek -ge $clip.durationSeconds) { $mediaProblem = 'Seek is at or beyond the end of the clip.' }
    if (-not $DryRun -and -not $mediaProblem) {
        try {
            $validationResults = @(& (Join-Path $PSScriptRoot 'Get-TestMedia.ps1') -VerifyOnly -ClipId $clip.id -UserConfigPath $configuration.userConfigPath)
            if ($validationResults.Count -ne 1 -or -not $validationResults[0].validated -or -not $validationResults[0].hashPinned) {
                throw 'Pinned decoded-media validation did not succeed.'
            }
            $verifiedMedia[$clip.id] = Read-SuiteJson $validationResults[0].validationPath
        }
        catch { $mediaProblem = $_.Exception.Message }
    }

    foreach ($type in $testTypes) {
        $testSeek = if ($type -eq 'performance-isolated' -and $clip.toneMappingType -eq 'dovi-p5') { [double]$seek } else { [double]$clip.performanceSeekSeconds }
        $clip.seekSeconds = [double]$seek
        $doviIsolated = $type -eq 'performance-isolated' -and $clip.toneMappingType -eq 'dovi-p5'
        $doviLoop = $doviIsolated
        $typeRepetitions = if ($doviIsolated) { 3 } else { $Repetitions }
        $applicable = @(Get-SuiteApplicableImplementations -Catalog $catalog -ToneMappingType $clip.toneMappingType `
            -TestType $type -Configuration $configuration)
        $byId = @{}
        foreach ($item in $applicable) { $byId[$item.id] = $item }
        $choices = $applicable
        if ($ImplementationId) { $choices = @($performanceChoices | Where-Object { $_.id -in $ImplementationId -or (Get-BenchmarkProperty $_ 'catalogImplementationId') -in $ImplementationId }) }
        $active = New-Object 'Collections.Generic.List[object]'
        foreach ($choice in $choices) {
            if ($choice.id -notmatch '^[a-z0-9-]+$' -or $clip.id -notmatch '^[a-z0-9-]+$') { throw 'Clip and implementation IDs must be safe filename identifiers.' }
            $reason = $mediaProblem
            $implementation = $byId[$choice.id]
            if (-not $reason -and $null -eq $implementation) { $reason = 'Unsupported signal/test type or excluded by user configuration.' }
            if (-not $reason -and -not $implementation.binaryAvailable) { $reason = 'Configured executable is missing or disabled.' }
            $entry = [pscustomobject][ordered]@{
                clipId = $clip.id; clipLabel = $clip.label; toneMappingType = $clip.toneMappingType
                implementationId = $choice.id; source = $choice.source; filter = $choice.filter; backend = $choice.backend; testType = $type
                catalogImplementationId = $(if (Get-BenchmarkProperty $choice 'catalogImplementationId') { $choice.catalogImplementationId } else { $choice.id })
                implementationLabel = $choice.label; processing = $(if (Get-BenchmarkProperty $choice 'processing') { $choice.processing } else { $choice.backend })
                openclVendor = Get-BenchmarkProperty $choice 'openclVendor'
                status = 'skipped'; reason = $reason; inputFormat = $null; outputFormat = $null
                frames = $null; fps = $null; speed = $null; durationSeconds = $null; mediaDurationSeconds = $null
                samples = @(); min = $null; max = $null; spread = $null; validSamples = 0; invalidSamples = 0
                settings = $null; device = $null; preflight = $null; execution = $null; logPaths = @(); plannedRuns = @()
                isolatedMethod = $(if ($doviIsolated) { [pscustomobject]@{mode='dovi-eight-state';timingPolicy='fixed-workload';states=8;repetitionsPerState=20;framesPerPass=160;longFrames=$null;shortFrames=$null;pairedFrames=$null;timingPlan=$null;keyframeStride=$null;selfTest=$null;aggregation='median';reason=$null} } else { $null })
                timing = [pscustomobject]@{ mode = 'fixed-workload'; minimumDeltaSeconds = 0; frames = $null; workload = $null }
                runId = $runId; methodVersion = $rowMethodVersions[$type]
                input = [pscustomobject]@{ filePath = $mediaPath; sha256 = $clip.sha256; seekSeconds = $testSeek; validation = $verifiedMedia[$clip.id] }
                metric = if ($type -eq 'performance-isolated') { 'paired-pipeline-fps' } else { 'full-transcode-fps' }
                wallFps = $null; mappedFps = $null; implementationNotes = $choice.notes
            }
            $entries.Add($entry)
            if ($reason) { Write-Host "SKIP $($clip.id) / $($choice.id) / $type : $reason"; continue }
            try {
                if (-not $pipelineAvailable) { throw 'Pipeline module is unavailable; commands cannot be generated.' }
                $implementationConfiguration = Get-SuiteImplementationConfiguration -Configuration $configuration -Implementation $implementation
                $fixedArguments = @{ Workloads = $fixedWorkloads; ClipId = $clip.id; ImplementationId = $implementation.id; TestType = $type }
                foreach ($name in $workloadOverrides.Keys) {
                    if ($name -eq 'FrameCount' -and $type -ne 'performance-isolated') { continue }
                    if ($name -in @('DoviShortFrames','DoviLongFrames') -and -not $doviIsolated) { continue }
                    $fixedArguments[$name] = $workloadOverrides[$name]
                }
                $workload = Resolve-SuitePerformanceWorkload @fixedArguments
                $testSeek = $workload.seekSeconds; $clip.seekSeconds = $testSeek; $clip.performanceSeekSeconds = $testSeek
                $entry.input.seekSeconds = $testSeek
                $entry.timing.mode = $workload.mode; $entry.timing.frames = $workload.frames; $entry.timing.workload = $workload
                $doviLoop = [bool]$workload.doviMetadataLoop
                if ($doviLoop) {
                    $entry.isolatedMethod.shortFrames = $workload.shortFrames
                    $entry.isolatedMethod.longFrames = $workload.frames
                    $entry.isolatedMethod.pairedFrames = $entry.isolatedMethod.longFrames - $entry.isolatedMethod.shortFrames
                    $entry.isolatedMethod.keyframeStride = $workload.keyframeStride
                    $entry.isolatedMethod.timingPolicy = if ($workload.overrides.Count) { 'explicit-windows' } else { 'fixed-workload' }
                }
                $pipelineArguments = @{
                    Implementation = $implementation; Clip = $clip; Configuration = $implementationConfiguration; TestType = $type
                    MediaPath = $mediaPath; FrameCount = $workload.frames; SeekSeconds = $testSeek; DurationSeconds = $workload.durationSeconds
                    OutputPath = Join-Path $runDirectory ($clip.id + '-' + $implementation.id + '-planned.mkv')
                }
                if ($doviLoop) { $pipelineArguments.DoviMetadataLoop=$true;$pipelineArguments.DoviKeyframeStride=$workload.keyframeStride }
                $pipeline = New-SuiteFFmpegArguments @pipelineArguments
                $entry.inputFormat = $pipeline.InputFormat; $entry.outputFormat = $pipeline.OutputFormat
                $entry.settings = $pipeline.Settings
                $entry.plannedRuns = @([pscustomobject]@{ filePath = $implementation.ffmpegPath; arguments = $pipeline.Arguments; filterGraph = $pipeline.FilterGraph })
                if ($doviLoop) {
                    $shortArguments=@{}+$pipelineArguments;$shortArguments.FrameCount=$entry.isolatedMethod.shortFrames
                    $shortPipeline=New-SuiteFFmpegArguments @shortArguments
                    $entry.plannedRuns += [pscustomobject]@{filePath=$implementation.ffmpegPath;arguments=$shortPipeline.Arguments;filterGraph=$shortPipeline.FilterGraph}
                }
                if ($DryRun) {
                    $entry.reason = 'Dry run; command execution and runtime preflight were not performed.'
                    continue
                }
                if (-not $binaryRecords.ContainsKey($implementation.source)) {
                    $binaryRecords[$implementation.source] = Get-BenchmarkBinaryRecord $implementation.source $implementation.ffmpegPath $runDirectory
                }
                if ($binaryRecords[$implementation.source].error) { throw $binaryRecords[$implementation.source].error }
                Assert-BenchmarkBinaryUnchanged $implementation.ffmpegPath $binaryRecords[$implementation.source].sha256
                $preflightPrefix = Join-Path $runDirectory ($clip.id + '-' + $implementation.id + '-' + $type + '-preflight')
                Assert-NoOtherFFmpegProcess
                $preflight = Invoke-SuitePipelinePreflight -Implementation $implementation -Clip $clip -Configuration $implementationConfiguration `
                    -MediaPath $mediaPath -TestType $type -WorkingDirectory $runDirectory -LogPathPrefix $preflightPrefix
                $entry.preflight = Get-BenchmarkPreflightRecord $preflight; $entry.device = $preflight.DeviceInfo
                $entry.execution = Get-BenchmarkExecution $preflight.Run
                $preflightLogs = Get-BenchmarkProperty (Get-BenchmarkProperty $preflight 'Run') 'LogFiles'
                if ($null -ne $preflightLogs) { $entry.logPaths += $preflightLogs }
                if (-not $preflight.Passed) {
                    $entry.reason = $preflight.Reason
                    if ((Get-BenchmarkProperty $preflight 'FailureKind') -eq 'failed') { $entry.status = 'failed' }
                    Write-Host ("{0} {1} / {2} / {3} : {4}" -f $(if ($entry.status -eq 'failed') { 'FAIL' } else { 'SKIP' }), $clip.id, $choice.id, $type, $preflight.Reason)
                    if ($StopOnError) { throw $preflight.Reason }
                    continue
                }
                if ($preflight.BinaryInspection.Sha256 -ne $binaryRecords[$implementation.source].sha256) { throw 'The FFmpeg executable changed during preflight; no repetitions were started.' }
                $job = [pscustomobject]@{
                    implementation = $implementation; entry = $entry; pipelineArguments = $pipelineArguments; preflight = $preflight
                    doviLoop = $doviLoop; frames = $workload.frames; minimumDeltaSeconds = 0.0
                    rounds = 0; done = $false; binaryHash = $binaryRecords[$implementation.source].sha256
                    prefix = $clip.id + '-' + $implementation.id + '-' + $type
                    logContext = [pscustomobject]@{ Video = $clip.label; Filter = $implementation.label; Source = $implementation.source }
                }
                if ($type -eq 'performance-isolated') {
                    $entry.timing.minimumDeltaSeconds = $job.minimumDeltaSeconds
                    $entry.timing.frames = $workload.frames
                    $timedArguments = @{} + $pipelineArguments
                    $timedArguments.FrameCount = $entry.timing.frames
                    $pipeline = New-SuiteFFmpegArguments @timedArguments; $entry.settings = $pipeline.Settings
                    $entry.plannedRuns = @([pscustomobject]@{ filePath = $implementation.ffmpegPath; arguments = $pipeline.Arguments; filterGraph = $pipeline.FilterGraph })
                    if ($doviLoop) {
                        $shortArguments = @{} + $pipelineArguments; $shortArguments.FrameCount = $entry.isolatedMethod.shortFrames
                        $shortPipeline = New-SuiteFFmpegArguments @shortArguments
                        $entry.plannedRuns += [pscustomobject]@{ filePath = $implementation.ffmpegPath; arguments = $shortPipeline.Arguments; filterGraph = $shortPipeline.FilterGraph }
                    }
                    $windowText = if ($doviLoop) { "$($entry.isolatedMethod.shortFrames) / $($entry.isolatedMethod.longFrames) frames" } else { "1 / $($job.frames) frames" }
                    Write-Host "TIMING $($clip.id) / $($implementation.id): fixed $windowText"
                }
                $entry.status = 'running'
                $entry.reason = 'Waiting for sequential repetitions.'
                $active.Add($job)
            }
            catch {
                $entry.reason = $_.Exception.Message
                $entry.status = if ($entry.openclVendor -eq 'amd' -and $type -eq 'performance-transcode' -and $entry.reason -match 'No verified Windows GPU-only') { 'skipped' } else { 'failed' }
                if ($StopOnError -or $_.Exception.Data['FFmpegProcessConflict']) {
                    $report.results = @($entries.ToArray()); $report.binaries = @($binaryRecords.Values | Sort-Object source)
                    Write-BenchmarkReport $report $reportPath
                    throw "Benchmark stopped for $($implementation.id): $($entry.reason) Staged evidence: $reportPath"
                }
            }
        }

        if (-not $DryRun) {
            # Repeat the same fixed workload. Failed cases retain diagnostics;
            # no measurement changes a later job's input or frame windows.
            $requiredValid = $typeRepetitions
            $maximumRounds = $typeRepetitions + 2
            for ($rep = 1; $rep -le $maximumRounds; $rep++) {
                $ordered = @(Get-BenchmarkRunOrder -Implementations @($active.ToArray() | Where-Object { -not $_.done }) -Repetition $rep)
                if ($ordered.Count -eq 0) { break }
                foreach ($job in $ordered) {
                    $implementation = $job.implementation; $entry = $job.entry
                    $doviLoop = [bool]$job.doviLoop
                    $prefix = Join-Path $runDirectory ($clip.id + '-' + $implementation.id + '-' + $type + '-rep' + $rep)
                    $sample = $null
                    try {
                        $expectedBinaryHash = $binaryRecords[$implementation.source].sha256
                        Assert-BenchmarkBinaryUnchanged $implementation.ffmpegPath $expectedBinaryHash
                        $commands = @{}
                        $runResults = @{}
                        if ($type -eq 'performance-isolated') {
                            $shortName=if($doviLoop){'short'}else{'single'}
                            $names = if ($rep % 2 -eq 1) { @($shortName, 'loop') } else { @('loop', $shortName) }
                            foreach ($name in $names) {
                                $arguments = @{} + $job.pipelineArguments
                                $arguments.FrameCount = if ($doviLoop) { if($name -eq 'short'){$entry.isolatedMethod.shortFrames}else{$entry.isolatedMethod.longFrames} } elseif ($name -eq 'single') { 1 } else { $job.frames }
                                $commands[$name] = New-SuiteFFmpegArguments @arguments
                                Assert-NoOtherFFmpegProcess
                                $runResults[$name] = Invoke-FFmpegProcess -FilePath $implementation.ffmpegPath -Arguments $commands[$name].Arguments `
                                    -WorkingDirectory $runDirectory -TimeoutSeconds $configuration.benchmark.processTimeoutSeconds -LogPathPrefix ($prefix + '-' + $name) -LogContext ([pscustomobject]@{ Video = $clip.label; Filter = $implementation.label; Source = $implementation.source })
                                $entry.logPaths += $runResults[$name].LogFiles
                                Assert-BenchmarkBinaryUnchanged $implementation.ffmpegPath $expectedBinaryHash
                                $windowProblem=Get-BenchmarkProcessProblem $runResults[$name] $arguments.FrameCount
                                if($windowProblem -and $StopOnError){throw $windowProblem}
                            }
                            $sourceRate = Get-BenchmarkSourceFrameRate $job.preflight
                            $sample = if($doviLoop){New-DoviIsolatedBenchmarkSample -ShortResult $runResults.short -LongResult $runResults.loop -Repetition $rep -ShortFrames $entry.isolatedMethod.shortFrames -LongFrames $entry.isolatedMethod.longFrames -MinimumDeltaSeconds $job.minimumDeltaSeconds}else{New-IsolatedBenchmarkSample $runResults.single $runResults.loop $job.frames $rep $sourceRate $job.minimumDeltaSeconds}
                            if ($doviLoop) { $sample.timingPolicy = $entry.isolatedMethod.timingPolicy }
                            $sample.singleFrameRun = Get-BenchmarkProcessRecord $sample.singleFrameRun
                            $sample.loopRun = Get-BenchmarkProcessRecord $sample.loopRun
                            if($doviLoop){$sample.shortRun=Get-BenchmarkProcessRecord $sample.shortRun;$sample.longRun=Get-BenchmarkProcessRecord $sample.longRun}
                            $entry.execution = Get-BenchmarkExecution $runResults.loop
                        }
                        else {
                            $arguments = @{} + $job.pipelineArguments
                            $arguments.OutputPath = $prefix + '-tonemapped.mkv'
                            $commands['mapped'] = New-SuiteFFmpegArguments @arguments
                            $meaningfulBaseline = [bool](Get-BenchmarkProperty $commands.mapped.Settings 'BaselineMeaningful')
                            $names = @('mapped')
                            if ($meaningfulBaseline) {
                                $arguments.OutputPath = $prefix + '-baseline.mkv'
                                $commands['baseline'] = New-SuiteFFmpegArguments @arguments -Baseline
                                $names = if ($rep % 2 -eq 1) { @('baseline', 'mapped') } else { @('mapped', 'baseline') }
                            }
                            foreach ($name in $names) {
                                Assert-NoOtherFFmpegProcess
                                $runResults[$name] = Invoke-FFmpegProcess -FilePath $implementation.ffmpegPath -Arguments $commands[$name].Arguments `
                                    -WorkingDirectory $runDirectory -TimeoutSeconds $configuration.benchmark.processTimeoutSeconds -LogPathPrefix ($prefix + '-' + $name) -LogContext ([pscustomobject]@{ Video = $clip.label; Filter = $implementation.label; Source = $implementation.source })
                                $entry.logPaths += $runResults[$name].LogFiles
                                Assert-BenchmarkBinaryUnchanged $implementation.ffmpegPath $expectedBinaryHash
                            }
                            $sample = New-TranscodeBenchmarkSample $runResults.mapped $runResults['baseline'] $rep (Get-BenchmarkSourceFrameRate $job.preflight) ([int](Get-BenchmarkProperty $commands.mapped.Settings 'TranscodeRepeats'))
                            if ($job.frames -gt 0) {
                                $frameProblem = Get-BenchmarkProcessProblem $runResults.mapped $job.frames
                                if ($frameProblem) {
                                    $sample.valid = $false; $sample.reason = $frameProblem
                                    $sample.fps = $null; $sample.speed = $null; $sample.mappedFps = $null
                                }
                            }
                            $sample.run = Get-BenchmarkProcessRecord $sample.run
                            $sample.baselineRun = Get-BenchmarkProcessRecord $sample.baselineRun
                            $entry.execution = Get-BenchmarkExecution $runResults.mapped
                            $entry.mediaDurationSeconds = $commands.mapped.ActualDurationSeconds
                            if (-not $configuration.benchmark.keepOutputs) {
                                foreach ($name in $names) {
                                    $target = $prefix + $(if ($name -eq 'mapped') { '-tonemapped.mkv' } else { '-baseline.mkv' })
                                    if ([IO.File]::Exists($target)) { Remove-Item -LiteralPath $target -Force }
                                }
                            }
                        }
                    }
                    catch {
                        $sample = [pscustomobject]@{ repetition = $rep; valid = $false; reason = $_.Exception.Message; fps = $null }
                        if ($_.Exception.Data['FFmpegProcessConflict']) {
                            $entry.samples += $sample; $entry.invalidSamples++; $entry.status = 'failed'; $entry.reason = $sample.reason
                            $report.results = @($entries.ToArray()); $report.binaries = @($binaryRecords.Values | Sort-Object source)
                            Write-BenchmarkReport $report $reportPath
                            throw
                        }
                    }
                    $entry.samples += $sample
                    $job.rounds++
                    $summary = if($doviLoop){Get-DoviBenchmarkAggregate -Samples $entry.samples -ShortFrames $entry.isolatedMethod.shortFrames -LongFrames $entry.isolatedMethod.longFrames}elseif($doviIsolated){Get-BenchmarkAggregate $entry.samples -Aggregation median}else{Get-BenchmarkAggregate $entry.samples}
                    $job.done = $summary.validCount -ge $requiredValid -or $job.rounds -ge $maximumRounds -or ($job.rounds -ge $requiredValid -and -not $sample.valid)
                    $entry.validSamples = $summary.validCount; $entry.invalidSamples = $summary.invalidCount
                    $entry.min = $summary.min; $entry.max = $summary.max; $entry.spread = $summary.spread
                    if ($null -ne $summary.best) {
                        $entry.status = 'completed'; $entry.reason = $null
                        $entry.frames = $summary.best.frames; $entry.fps = $summary.best.fps; $entry.speed = $summary.best.speed
                        $entry.durationSeconds = $summary.best.wallSeconds
                        if ($type -eq 'performance-transcode') { $entry.mediaDurationSeconds = $summary.best.mediaSeconds }
                        $entry.wallFps = Get-BenchmarkProperty $summary.best 'wallFps'
                        $entry.mappedFps = Get-BenchmarkProperty $summary.best 'mappedFps'
                        $bestRun = if ($type -eq 'performance-isolated') { $summary.best.loopRun } else { $summary.best.run }
                        $entry.execution = Get-BenchmarkExecution $bestRun
                    }
                    elseif ($job.done) { $entry.status = 'failed'; $entry.reason = $(if($doviIsolated -and $summary.validCount -gt 0){'The median requires three valid paired samples.'}else{$sample.reason}) }
                    else { $entry.status = 'running'; $entry.reason = "Measuring: $($summary.validCount) of $requiredValid valid samples so far." }
                    $report.results = @($entries.ToArray()); $report.binaries = @($binaryRecords.Values | Sort-Object source)
                    Write-BenchmarkReport $report $reportPath
                    if ($publishResults) { Publish-BenchmarkMatrix -State 'running' }
                    if ($sample.valid) { Write-Host ("PASS {0} / {1} / {2} rep {3}: {4} fps" -f $clip.id, $implementation.id, $type, $rep, $sample.fps.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) }
                    else { Write-Host "FAIL $($clip.id) / $($implementation.id) / $type rep $rep : $($sample.reason)" }
                    $stopReason = Get-BenchmarkSampleStopReason $sample
                    if ($StopOnError -and $stopReason) {
                        throw "Benchmark stopped for $($implementation.id), repetition ${rep}: $stopReason Staged evidence: $reportPath"
                    }
                }
            }
        }
    }
}
$report.state = 'completed'
$report.results = @($entries.ToArray())
$report.binaries = @($binaryRecords.Values | Sort-Object source)
Write-BenchmarkReport $report $reportPath
if ($publishResults) { Publish-BenchmarkMatrix -State 'completed' }
if ($OutputPath) { Write-BenchmarkReport $report (Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $OutputPath) }
Write-Host ("Benchmarks finished: {0} completed, {1} failed, {2} skipped." -f @($report.results | Where-Object status -eq 'completed').Count, @($report.results | Where-Object status -eq 'failed').Count, @($report.results | Where-Object status -eq 'skipped').Count)
Write-Host "Saved benchmark report: $reportPath"
if ($PassThru) { Write-Output $report }
}
finally {
    if ($null -ne $report -and $report.state -ne 'completed' -and -not $DryRun) {
        foreach ($row in $entries) {
            if ($row.status -eq 'running') { $row.status = 'failed'; $row.reason = 'The benchmark run ended before this measurement completed.' }
        }
        $report.state = 'aborted'
        try {
            $report.results = @($entries.ToArray()); $report.binaries = @($binaryRecords.Values | Sort-Object source)
            Write-BenchmarkReport $report $reportPath
            if ($publishResults) { Publish-BenchmarkMatrix -State 'aborted' }
        }
        catch { Write-Warning "Could not publish the aborted run: $($_.Exception.Message)" }
    }
    if ($null -ne $lease) { Exit-SuiteRun -Lease $lease }
}
