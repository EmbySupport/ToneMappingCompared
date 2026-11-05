#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$ClipId,
    [string[]]$ImplementationId,
    [string[]]$Curve,
    [string]$UserConfigPath,
    [ValidateRange(0.001, 86400)][double]$DurationSeconds,
    [ValidateRange(1, 1000)][int]$MaxFrames = 30,
    [ValidateRange(0, 86400)][double]$SeekSeconds,
    [ValidateRange(1, 32)][int]$SignedGain = 2,
    [string]$ReferenceReportPath,
    [switch]$DryRun,
    [switch]$NoPublish,
    [switch]$StopOnError,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repositoryRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in @('Configuration', 'Pipelines', 'Quality', 'RunLock', 'FFmpeg', 'Comparisons')) {
    Import-Module (Join-Path $PSScriptRoot ('lib\' + $module + '.psm1'))
}

function Get-RunQualityProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-RunQualityLogPaths {
    param([object]$LogFiles)
    if ($null -eq $LogFiles) { return $null }
    $paths = [ordered]@{}
    foreach ($property in $LogFiles.PSObject.Properties) {
        if ($property.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($property.Value)) {
            $paths[$property.Name] = ConvertTo-QualityAssetPath -Path $property.Value -RepositoryRoot $repositoryRoot
        }
    }
    return [pscustomobject]$paths
}

function Get-RunQualityProcessRecord {
    param([object]$Run)
    if ($null -eq $Run) { return $null }
    return [pscustomobject][ordered]@{
        exitCode = $Run.ExitCode; timedOut = $Run.TimedOut; elapsedSeconds = $Run.ElapsedSeconds
        outputCaptureComplete = $Run.OutputCaptureComplete; logPaths = Get-RunQualityLogPaths $Run.LogFiles
        commandLine = $Run.CommandLine; log = $(if ($Run.LogFiles) { ConvertTo-QualityAssetPath $Run.LogFiles.Log $repositoryRoot } else { $null })
        graph = $(if ($Run.LogFiles -and $Run.LogFiles.Graph) { ConvertTo-QualityAssetPath $Run.LogFiles.Graph $repositoryRoot } else { $null })
        externalCodecs = Get-RunQualityProperty $Run 'ExternalCodecs'
    }
}

function Get-RunQualityPreflightRecord {
    param([object]$Preflight)
    $binary = Get-RunQualityProperty $Preflight 'BinaryInspection'
    return [pscustomobject][ordered]@{
        passed = $Preflight.Passed; reason = $Preflight.Reason; checks = $Preflight.Checks
        sourceIntegrity = Get-RunQualityProperty $Preflight 'SourceIntegrity'
        expectedInputProperties = Get-RunQualityProperty $Preflight 'ExpectedInputProperties'
        observedStreamProperties = Get-RunQualityProperty $Preflight 'ObservedStreamProperties'; deviceInfo = $Preflight.DeviceInfo
        binary = $(if ($null -ne $binary) { [pscustomobject]@{ filePath = $binary.FilePath; version = $binary.Version; sha256 = $binary.Sha256; externalCodecs = Get-RunQualityProperty $binary 'ExternalCodecs' } } else { $null })
        run = Get-RunQualityProcessRecord $Preflight.Run; limitations = Get-RunQualityProperty $Preflight 'limitations'
    }
}

function Get-RunQualitySettings {
    param([object]$Settings)
    $values = [ordered]@{}
    foreach ($name in @('ImplementationId', 'Source', 'TestType', 'ToneMappingType', 'Curve', 'KeyframeLimit', 'KeyframeStep', 'FrameSelection', 'ImageRetention', 'FilterOptions', 'FilterThreads', 'SeekSeconds', 'RequestedDurationSeconds', 'ActualDurationSeconds', 'FrameCount', 'Decoder', 'DecodeMode', 'DecoderFrameFormat', 'Encoder', 'EncodingMode', 'DeviceArgument', 'TargetRange', 'TargetPrimaries', 'TargetTransfer')) {
        $value = Get-RunQualityProperty $Settings $name
        if ($null -ne $value) { $values[$name] = $value }
    }
    return [pscustomobject]$values
}

function Get-RunQualityRequest {
    param([object]$Pipeline, [object]$Clip, [double]$Seek)
    return [pscustomobject][ordered]@{
        sha256 = $Clip.sha256; seekSeconds = $Seek
        decoder = $Pipeline.Settings.Decoder; decodeMode = $Pipeline.DecodeMode; decoderFrameFormat = $Pipeline.Settings.DecoderFrameFormat
        codec = $Clip.expected.codecName; selection = 'decoder-skip-non-key'; generatedFrameLimit = $Pipeline.Settings.FrameCount
        keyframeStep = $Pipeline.Settings.KeyframeStep; retention = 'post-generation-first-then-every-nth'; curve = $Pipeline.Settings.Curve
    }
}

$configuration = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $UserConfigPath
$referenceReport = $null; $resolvedReferenceReportPath = $null
if (-not [string]::IsNullOrWhiteSpace($ReferenceReportPath)) {
    $resolvedReferenceReportPath = Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $ReferenceReportPath
    $referenceReport = Read-SuiteJson -Path $resolvedReferenceReportPath
}
if (-not $PSBoundParameters.ContainsKey('DurationSeconds')) { $DurationSeconds = $configuration.benchmark.transcodeDurationSeconds }
$catalog = Read-SuiteJson (Join-Path $repositoryRoot 'config\catalog.json')
$manifest = Read-SuiteJson (Join-Path $repositoryRoot 'config\media.json')
if ($manifest.schemaVersion -ne 1 -or $catalog.schemaVersion -ne 1) { throw 'Quality requires schemaVersion 1 media and catalog files.' }
foreach ($id in $ClipId) { if ($id -notin @($manifest.clips.id)) { throw "Unknown clip ID: $id" } }
foreach ($id in $ImplementationId) { if ($id -notin @($catalog.implementations.id)) { throw "Unknown implementation ID: $id" } }
$referenceId = 'stock-libplacebo'
foreach ($curveId in $Curve) { if ($curveId -notin @($catalog.curves.id)) { throw "Unknown curve: $curveId" } }
$kind = 'quality'
$testType = 'quality'
if ($catalog.referenceImplementationId -ne $referenceId -or $catalog.analysisSource -ne 'stock') { throw 'Quality requires stock-libplacebo as reference and the stock binary for analysis.' }
$referenceChoices = @($catalog.implementations | Where-Object { $_.id -eq $referenceId })
if ($referenceChoices.Count -ne 1) { throw 'The stock-libplacebo reference must occur exactly once in the catalog.' }
if ($referenceChoices[0].source -ne 'stock' -or $referenceChoices[0].filter -ne 'libplacebo') { throw 'The libplacebo reference must use the stock FFmpeg executable.' }
$clips = @($manifest.clips | Where-Object { ($ClipId -and $_.id -in $ClipId) -or (-not $ClipId -and $_.enabled) })
if ($clips.Count -eq 0) { throw 'No selected enabled media clips are available.' }
if ($PSBoundParameters.ContainsKey('SeekSeconds') -and ([double]::IsNaN($SeekSeconds) -or [double]::IsInfinity($SeekSeconds))) { throw 'SeekSeconds must be finite.' }
if ([double]::IsNaN($DurationSeconds) -or [double]::IsInfinity($DurationSeconds)) { throw 'DurationSeconds must be finite.' }

$lease = $null
if (-not $DryRun) { $lease = Enter-SuiteRun -RepositoryRoot $repositoryRoot -Operation 'quality' }
try {
    $runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $runDirectory = Join-Path $configuration.paths.resultsPath ($kind + '\' + $runId)
    $reportPath = Join-Path $runDirectory 'report.json'
    $latestPath = Join-Path $configuration.paths.resultsPath ($kind + $(if ($DryRun) { '-plan.json' } else { '.json' }))
    $customPath = $(if ([string]::IsNullOrWhiteSpace($OutputPath)) { $null } else { Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $OutputPath })
    $publicationPaths = @(foreach ($name in @('quality.json','quality-plan.json')) { Join-Path $configuration.paths.resultsPath $name })
    if ($NoPublish -and $customPath -in $publicationPaths) { throw 'NoPublish requires a separate output report path, not a latest report or plan.' }
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $report = [pscustomobject][ordered]@{
        schemaVersion = 1; kind = $kind; runId = $runId
        createdUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        dryRun = [bool]$DryRun; staged = [bool]$NoPublish; userConfigPath = $configuration.userConfigPath
        referenceImplementationId = $referenceId; analysisBinary = $null; analysis = Get-QualityAnalysisContract
        reportPath = ConvertTo-QualityAssetPath -Path $reportPath -RepositoryRoot $repositoryRoot
        methodVersion = 5
        settings = [pscustomobject]@{ maxFrames = $MaxFrames; keyframeStep = 3; hdr10KeyframeStep = 5; signedGain = $SignedGain; absoluteDisplayGain = 8; frameSelection = 'decoder-skip-non-key'; imageRetention = 'post-generation-first-then-every-nth'; comparison = 'selected-keyframe-index' }
        notes = @(
            'Each clip requires stock-libplacebo first, including when implementation filters omit it. Default references are freshly generated; explicit reference-report reuse must pass hash, request, graph, native-PNG, complete-log and display-contract gates. All FFmpeg processes are sequential under the suite run lock.',
            'The native decoder skips non-keyframes before tone mapping the original pinned bitstream at native resolution. Separate binary decoders and PNG conversion are part of this comparison.',
            'Image generation is bounded only by the raw frame count. DurationSeconds is a legacy compatibility parameter and does not limit quality extraction.',
            'Comparison uses retained-keyframe ordinal after equal pinned source, seek, decoder and selection requests; native PNG dimensions and sequence counts must match.',
            'Source frame times are not collected. Ordinal/count/dimension checks do not establish exact temporal correspondence across separate decoders.',
            'After extracting up to 30 keyframes, retain 1, 4, 7, ... and rename consecutively. HDR10 starts at 160 seconds and retains 1, 6, 11, ... instead. Short sources keep fewer frames; no frames are fabricated.',
            'Failed GPU initialization, failed integrity/decode smoke, or unavailable references receive diagnostics and no score.'
        )
        results = @()
    }
    $entries = New-Object 'Collections.Generic.List[object]'
    $referenceProofs = New-Object 'Collections.Generic.List[object]'

    foreach ($originalClip in $clips) {
        if ($originalClip.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Clip IDs must be safe filename identifiers.' }
        $clipValues = [ordered]@{}
        foreach ($property in $originalClip.PSObject.Properties) { $clipValues[$property.Name] = $property.Value }
        $seek = Get-RunQualityProperty $originalClip 'qualitySeekSeconds'
        if ($null -eq $seek) { $seek = Get-RunQualityProperty $originalClip 'seekSeconds' }
        if ($null -eq $seek) { $seek = 0.0 }
        if ($PSBoundParameters.ContainsKey('SeekSeconds')) { $seek = $SeekSeconds }
        $clipValues.seekSeconds = [double]$seek
        $clip = [pscustomobject]$clipValues
        $mediaPath = Join-Path $configuration.paths.mediaPath $clip.fileName
        $mediaProblem = $null; $validation = $null
        if (-not $clip.enabled) { $mediaProblem = 'Clip is a disabled candidate.' }
        elseif ([string]$clip.sha256 -notmatch '^[a-fA-F0-9]{64}$') { $mediaProblem = 'Clip has no pinned SHA-256.' }
        elseif (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) { $mediaProblem = 'Media has not been downloaded.' }
        elseif ([double]$seek -ge [double]$clip.durationSeconds) { $mediaProblem = 'Seek is at or beyond the end of the clip.' }
        if (-not $DryRun -and -not $mediaProblem) {
            try {
                $verified = @(& (Join-Path $PSScriptRoot 'Get-TestMedia.ps1') -VerifyOnly -ClipId $clip.id -UserConfigPath $configuration.userConfigPath)
                if ($verified.Count -ne 1 -or -not $verified[0].validated -or -not $verified[0].hashPinned) { throw 'Pinned media integrity and decode smoke did not succeed.' }
                $validation = Read-SuiteJson $verified[0].validationPath
            }
            catch { $mediaProblem = $_.Exception.Message }
        }
        $profileCurves = @(Get-SuiteComparisonCurves -Catalog $catalog -ToneMappingType $clip.toneMappingType)
        if ($Curve) { $profileCurves = @($profileCurves | Where-Object { $_ -in $Curve }) }
        foreach ($currentCurve in $profileCurves) {
        $applicable = @(Get-SuiteApplicableImplementations -Catalog $catalog -ToneMappingType $clip.toneMappingType -TestType quality -Configuration $configuration | Where-Object { $currentCurve -in @($_.supportedCurves) })
        $byId = @{}
        foreach ($implementation in $applicable) { $byId[$implementation.id] = $implementation }
        $choices = @($referenceChoices[0])
        if ($ImplementationId) { $choices += @($catalog.implementations | Where-Object { $_.id -in $ImplementationId -and $_.id -ne $referenceId -and $currentCurve -in @($_.supportedCurves) }) }
        else { $choices += @($applicable | Where-Object { $_.id -ne $referenceId }) }
        $referenceFrames = @(); $referencePassed = $false; $referenceRequest = $null

        foreach ($choice in $choices) {
            if ($choice.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Implementation IDs must be safe filename identifiers.' }
            $isReference = $choice.id -eq $referenceId
            $implementation = $byId[$choice.id]
            if ($null -ne $implementation) { $implementation = Set-SuiteImplementationCurve -Implementation $implementation -Curve $currentCurve }
            $reason = $mediaProblem
            if (-not $reason -and $null -eq $implementation) { $reason = 'Unsupported signal/test type or excluded by user configuration.' }
            if (-not $reason -and -not $implementation.binaryAvailable) { $reason = 'Configured executable is missing or disabled.' }
            if (-not $reason -and -not $DryRun -and -not $isReference -and -not $referencePassed) { $reason = 'The mandatory stock-libplacebo reference did not complete; no comparison score.' }
            $entry = [pscustomobject][ordered]@{
                clipId = $clip.id; clipLabel = $clip.label; toneMappingType = $clip.toneMappingType; testType = $testType; curve = $currentCurve
                implementationId = $choice.id; source = $choice.source; filter = $choice.filter; backend = $choice.backend
                status = 'skipped'; reason = $reason; isReference = $isReference; frames = @(); frameCount = 0; generatedFrameCount = 0
                inputFormat = $null; outputFormat = $null; settings = $null; device = $null; preflight = $null; generation = $null; execution = $null
                plannedCommand = $null; sequenceRequest = $null; referenceReuse = $null; sourceRunId = $runId
                input = [pscustomobject]@{ filePath = ConvertTo-QualityAssetPath -Path $mediaPath -RepositoryRoot $repositoryRoot; sha256 = $clip.sha256; seekSeconds = [double]$seek; validation = $validation }
                analysis = Get-QualityAnalysisContract
            }
            $entries.Add($entry)
            if ($reason) { Write-Host "SKIP $($clip.id) / $($choice.id): $reason"; continue }
            try {
                $entryDirectory = Join-Path $runDirectory ($clip.id + '\' + $currentCurve + '\' + $choice.id)
                $imagesDirectory = Join-Path $entryDirectory 'images'
                $configuredStep = Get-RunQualityProperty $clip 'qualityKeyframeStep'
                $keyframeStep = if ($null -ne $configuredStep) { [int]$configuredStep } elseif ($clip.toneMappingType -eq 'hdr10') { 5 } else { 3 }
                $pipeline = New-SuiteFFmpegArguments -Implementation $implementation -Clip $clip -Configuration $configuration -TestType quality -MediaPath $mediaPath -SeekSeconds ([double]$seek) -FrameCount $MaxFrames -KeyframeLimit $MaxFrames -KeyframeStep $keyframeStep -OutputPath (Join-Path $imagesDirectory '%06d.png')
                $entry.settings = Get-RunQualitySettings $pipeline.Settings; $entry.inputFormat = $pipeline.InputFormat; $entry.outputFormat = $pipeline.OutputFormat
                $entry.sequenceRequest = Get-RunQualityRequest -Pipeline $pipeline -Clip $clip -Seek ([double]$seek)
                if (-not $isReference -and $referencePassed -and ($entry.sequenceRequest | ConvertTo-Json -Compress) -ne ($referenceRequest | ConvertTo-Json -Compress)) { throw 'Source/seek/window/decoder/keyframe-selection request differs from the reference; no ordinal comparison is made.' }
                $entry.plannedCommand = [pscustomobject]@{ filePath = $implementation.ffmpegPath; arguments = $pipeline.Arguments; filterGraph = $pipeline.FilterGraph }
                if ($DryRun) { $entry.reason = 'Dry run; hash/decode validation, runtime preflight and image generation were not performed.'; continue }
                if ($isReference -and $null -ne $referenceReport) {
                    $reuse = Get-QualityReusableReference -Report $referenceReport -ReportPath $resolvedReferenceReportPath -Clip $clip -Pipeline $pipeline -SequenceRequest $entry.sequenceRequest -MediaPath $mediaPath -FFmpegPath $configuration.binaries.stock.ffmpegPath -RepositoryRoot $repositoryRoot -SignedGain $SignedGain
                    $entry.frames = @($reuse.Reference.frames); $entry.frameCount = $entry.frames.Count
                    $entry.generatedFrameCount = $reuse.Reference.generatedFrameCount
                    $entry.preflight = $reuse.Reference.preflight; $entry.device = $reuse.Reference.device
                    $entry.generation = $reuse.Reference.generation; $entry.execution = $reuse.Reference.execution
                    $entry.plannedCommand = $reuse.Reference.plannedCommand; $entry.referenceReuse = $reuse.Proof; $entry.sourceRunId = $referenceReport.runId
                    $entry.status = 'completed'; $entry.reason = $null
                    $referenceFrames = @($reuse.Frames); $referenceRequest = $entry.sequenceRequest; $referencePassed = $true
                    $report.analysisBinary = $entry.preflight.binary; $referenceProofs.Add($reuse.Proof)
                    $report.results = @($entries.ToArray()); Write-QualityReportFile -Report $report -Path $reportPath
                    Write-Host "REUSE $($clip.id) / stock-libplacebo: $($entry.frameCount) verified native keyframes; all source artifacts hashed"
                    continue
                }
                New-Item -ItemType Directory -Path $imagesDirectory -Force | Out-Null
                $preflight = Invoke-SuitePipelinePreflight -Implementation $implementation -Clip $clip -Configuration $configuration -MediaPath $mediaPath -TestType quality -WorkingDirectory $entryDirectory -LogPathPrefix (Join-Path $entryDirectory 'preflight') -SkipHashCheck
                $entry.preflight = Get-RunQualityPreflightRecord $preflight; $entry.device = $preflight.DeviceInfo
                $entry.execution = $entry.preflight.run
                if (-not $preflight.Passed) {
                    if ($StopOnError) { throw $preflight.Reason }
                    $entry.reason = $preflight.Reason; Write-Host "SKIP $($clip.id) / $($choice.id): $($entry.reason)"; continue
                }
                Assert-QualityNativeRenderingSucceeded -Text $preflight.Run.StdErr
                if ($isReference) { $report.analysisBinary = $entry.preflight.binary }
                $generationBinaryHash = (Get-FileHash -LiteralPath $implementation.ffmpegPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($generationBinaryHash -ne $entry.preflight.binary.sha256) { throw 'The executable changed after preflight; no generation was started under stale binary provenance.' }
                Write-Host "Generating native keyframe PNGs: $($clip.id) / $($choice.id)"
                $run = Invoke-FFmpegProcess -FilePath $implementation.ffmpegPath -Arguments $pipeline.Arguments -WorkingDirectory $entryDirectory -TimeoutSeconds $configuration.benchmark.processTimeoutSeconds -LogPathPrefix (Join-Path $entryDirectory 'generation') -LogContext ([pscustomobject]@{ Video = $clip.label; Filter = $implementation.label; Source = $implementation.source })
                $entry.generation = Get-RunQualityProcessRecord $run
                $entry.execution = $entry.generation
                if ($run.TimedOut -or $run.ExitCode -ne 0 -or -not $run.OutputCaptureComplete) { throw "PNG generation failed (exit $($run.ExitCode), timeout $($run.TimedOut)); open the FFmpeg log." }
                Assert-QualityNativeRenderingSucceeded -Text $run.StdErr
                if ((Get-FileHash -LiteralPath $implementation.ffmpegPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $generationBinaryHash) { throw 'The executable changed during generation; artifacts are preserved without a score.' }
                $sampling = Complete-QualityImageSampling -ImagesDirectory $imagesDirectory -GeneratedFrameLimit $MaxFrames -KeyframeStep $keyframeStep
                $entry.generatedFrameCount = $sampling.GeneratedFrameCount
                $selectedFrames = @($sampling.Frames)
                foreach ($frame in $selectedFrames) {
                    if ($frame.width -ne $clip.expected.width -or $frame.height -ne $clip.expected.height) { throw 'Generated quality frames are not at native source dimensions.' }
                }
                $entry.frameCount = $selectedFrames.Count
                $frameRecords = New-Object 'Collections.Generic.List[object]'
                foreach ($frame in $selectedFrames) {
                    $frameRecords.Add([pscustomobject][ordered]@{
                        index = $frame.index; keyframeIndex = $frame.keyframeIndex; width = $frame.width; height = $frame.height
                        image = ConvertTo-QualityAssetPath -Path $frame.imagePath -RepositoryRoot $repositoryRoot
                        diffSigned = $null; diffAbsolute = $null; diffAbsoluteDisplay = $null; absoluteDisplayGain = 8; signedGain = $SignedGain; metrics = $null; analysisLogPaths = @(); analysisStatsPaths = @()
                    })
                }
                $entry.frames = @($frameRecords.ToArray())
                if (-not $isReference) { Assert-QualityFrameAlignment -ReferenceFrames $referenceFrames -TestFrames $selectedFrames }
                $analysisBinaryHash = (Get-FileHash -LiteralPath $configuration.binaries.stock.ffmpegPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($analysisBinaryHash -ne $report.analysisBinary.sha256) { throw 'The fixed stock analysis executable changed; no analysis was started under stale binary provenance.' }
                for ($index = 0; $index -lt $selectedFrames.Count; $index++) {
                    $frame = $selectedFrames[$index]
                    $referencePath = $(if ($isReference) { $frame.imagePath } else { $referenceFrames[$index].imagePath })
                    $number = ($index + 1).ToString('D6', [Globalization.CultureInfo]::InvariantCulture)
                    $analysisDirectory = Join-Path $entryDirectory ('analysis\' + $number)
                    $analysis = Invoke-QualityFrameAnalysis -ReferencePath $referencePath -TestPath $frame.imagePath -FFmpegPath $configuration.binaries.stock.ffmpegPath -WorkingDirectory $analysisDirectory -DiffSignedPath (Join-Path $entryDirectory ('diff-signed\' + $number + '.png')) -DiffAbsolutePath (Join-Path $entryDirectory ('diff-absolute\' + $number + '.png')) -Gain $SignedGain -TimeoutSeconds $configuration.benchmark.processTimeoutSeconds
                    $entry.frames[$index].diffSigned = ConvertTo-QualityAssetPath -Path $analysis.DiffSignedPath -RepositoryRoot $repositoryRoot
                    $entry.frames[$index].diffAbsolute = ConvertTo-QualityAssetPath -Path $analysis.DiffAbsolutePath -RepositoryRoot $repositoryRoot
                    $entry.frames[$index].diffAbsoluteDisplay = ConvertTo-QualityAssetPath -Path $analysis.DiffAbsoluteDisplayPath -RepositoryRoot $repositoryRoot
                    $entry.frames[$index].absoluteDisplayGain = $analysis.AbsoluteDisplayGain
                    $entry.frames[$index].metrics = $analysis.Metrics
                    $entry.frames[$index].analysisLogPaths = @($analysis.LogFiles | ForEach-Object { Get-RunQualityLogPaths $_ })
                    $entry.frames[$index].analysisStatsPaths = @($analysis.StatsFiles | ForEach-Object { ConvertTo-QualityAssetPath -Path $_ -RepositoryRoot $repositoryRoot })
                }
                if ((Get-FileHash -LiteralPath $configuration.binaries.stock.ffmpegPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $analysisBinaryHash) { throw 'The stock executable changed during analysis; artifacts are preserved without a score.' }
                $entry.status = 'completed'; $entry.reason = $null
                if ($isReference) { $referenceFrames = $selectedFrames; $referenceRequest = $entry.sequenceRequest; $referencePassed = $true }
                $report.results = @($entries.ToArray()); Write-QualityReportFile -Report $report -Path $reportPath
                Write-Host "DONE $($clip.id) / $($choice.id): $($entry.frameCount) selected keyframe(s), compared by sequence index"
            }
            catch {
                $entry.status = 'failed'; $entry.reason = $_.Exception.Message
                foreach ($frame in $entry.frames) { if ($frame.PSObject.Properties['metrics']) { $frame.metrics = $null } }
                Write-Host "FAIL $($clip.id) / $($choice.id): $($entry.reason)"
                $report.results = @($entries.ToArray()); Write-QualityReportFile -Report $report -Path $reportPath
                if ($StopOnError) { throw "Quality stopped for $($choice.id): $($entry.reason) Staged evidence: $reportPath" }
            }
        }
        }
        $report.results = @($entries.ToArray())
        Write-QualityReportFile -Report $report -Path $reportPath
    }
    $report.results = @($entries.ToArray())
    $referenceFailure = $null
    foreach ($proof in $referenceProofs) {
        try { Assert-QualityReferenceFingerprints -Proof $proof -RepositoryRoot $repositoryRoot; $proof.checkedAfterUtc = [DateTime]::UtcNow.ToString('o') }
        catch {
            $referenceFailure = $_.Exception.Message
            foreach ($entry in $report.results | Where-Object { $_.input.sha256 -eq $proof.sourceSha256 }) {
                $entry.status = 'failed'; $entry.reason = 'Reused reference artifact changed; comparison scores rejected. ' + $referenceFailure
                foreach ($frame in $entry.frames) { if ($frame.PSObject.Properties['metrics']) { $frame.metrics = $null } }
            }
        }
    }
    Write-QualityReportFile -Report $report -Path $reportPath
    if (-not $NoPublish) { Write-QualityReportFile -Report $report -Path $latestPath }
    if ($customPath -and $customPath -ne $latestPath -and $customPath -ne $reportPath) { Write-QualityReportFile -Report $report -Path $customPath }
    if (-not $DryRun -and -not $NoPublish) { & (Join-Path $PSScriptRoot 'Export-Results.ps1') -UserConfigPath $configuration.userConfigPath | Out-Null }
    Write-Host "Quality report: $reportPath"
    if ($NoPublish) { Write-Host 'Staged report only; latest report and viewer data were preserved.' } else { Write-Host "Latest: $latestPath" }
    Write-Host ("Completed {0}; skipped {1}; failed {2}." -f @($report.results | Where-Object { $_.status -eq 'completed' }).Count, @($report.results | Where-Object { $_.status -eq 'skipped' }).Count, @($report.results | Where-Object { $_.status -eq 'failed' }).Count)
    if ($referenceFailure) { throw "Quality reference integrity failed; unscored diagnostics saved: $referenceFailure" }
}
finally { if ($null -ne $lease) { Exit-SuiteRun -Lease $lease } }
