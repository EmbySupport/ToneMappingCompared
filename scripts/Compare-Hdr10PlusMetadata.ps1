#Requires -Version 5.1
<#
.SYNOPSIS
Compares one HDR10+ keyframe with a separate libplacebo metadata-selection control.
.DESCRIPTION
Requires completed stock-libplacebo and emby-embytonemap-high HDR10+ quality rows.
Reads the current configuration, checks retained source/binary hashes, and preserves
production reports. All decoding and pixel work use the configured stock FFmpeg.
#>
[CmdletBinding()]
param(
    [string]$UserConfigPath,
    [Alias('ReportPath')][string]$QualityReportPath,
    [string]$ClipId,
    [ValidateRange(1, 1000000)][int]$FrameIndex = 1,
    [ValidateRange(1, 32)][int]$SignedGain = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
foreach ($module in @('Configuration', 'Quality', 'RunLock', 'FFmpeg')) {
    Import-Module (Join-Path $PSScriptRoot ('lib/' + $module + '.psm1'))
}

function Get-DiagnosticProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Resolve-DiagnosticAsset {
    param([string]$Path)
    if ($Path -match '^file:') {
        $uri = New-Object Uri($Path)
        if (-not $uri.IsFile) { throw 'Quality assets must be local files.' }
        return $uri.LocalPath
    }
    return Resolve-SuitePath -RepositoryRoot $root -Path $Path
}

function Get-DiagnosticArgumentIndex {
    param([string[]]$Arguments, [string]$Name)
    $indices = @($(for ($index = 0; $index -lt $Arguments.Count; $index++) { if ($Arguments[$index] -eq $Name) { $index } }))
    if ($indices.Count -ne 1 -or $indices[0] -ge $Arguments.Count - 1) { throw "Retained command must contain exactly one '$Name' value. Run quality again to obtain a supported reference command." }
    return [int]$indices[0] + 1
}

$configuration = Get-SuiteConfiguration -RepositoryRoot $root -UserConfigPath $UserConfigPath
$latestPath = Join-Path $configuration.paths.resultsPath 'quality.json'
if ([string]::IsNullOrWhiteSpace($QualityReportPath)) { $QualityReportPath = $latestPath }
$retainedPath = Resolve-SuitePath -RepositoryRoot $root -Path $QualityReportPath
$requestedClipId = $(if ([string]::IsNullOrWhiteSpace($ClipId)) { 'hdr10plus-hdclub-4k' } else { $ClipId })
$qualityFirst = "Run scripts/Run-Quality.ps1 -ClipId $requestedClipId -ImplementationId emby-embytonemap-high first, using the same -UserConfigPath and enough keyframes to include ordinal $FrameIndex."
if (-not (Test-Path -LiteralPath $retainedPath -PathType Leaf)) { throw "A completed quality report is required: $retainedPath. $qualityFirst" }

$lease = Enter-SuiteRun -RepositoryRoot $root -Operation 'HDR10+ one-frame metadata diagnostic'
$report = $null
$directory = $null
try {
    $retainedHash = (Get-FileHash -LiteralPath $retainedPath -Algorithm SHA256).Hash
    $latestHash = $(if (Test-Path -LiteralPath $latestPath -PathType Leaf) { (Get-FileHash -LiteralPath $latestPath -Algorithm SHA256).Hash } else { $null })
    $retained = Read-SuiteJson -Path $retainedPath
    if ((Get-DiagnosticProperty $retained 'schemaVersion') -ne 1 -or (Get-DiagnosticProperty $retained 'kind') -ne 'quality') { throw "A schema-version-1 real quality report is required. $qualityFirst" }
    if ((Get-DiagnosticProperty $retained 'methodVersion') -ne 5 -or (Get-DiagnosticProperty $retained 'dryRun')) { throw "This diagnostic requires an actual method-version-5 decoder-keyframe, post-sampled quality report. $qualityFirst" }
    $manifest = Read-SuiteJson -Path (Join-Path $root 'config/media.json')
    $references = @($retained.results | Where-Object {
        $candidate = $_
        $candidateFrames = @(Get-DiagnosticProperty $candidate 'frames')
        $enabledClip = @($manifest.clips | Where-Object { $_.id -eq $candidate.clipId -and $_.enabled -and $_.toneMappingType -eq 'hdr10plus' })
        $candidate.toneMappingType -eq 'hdr10plus' -and $candidate.implementationId -eq 'stock-libplacebo' -and $candidate.status -eq 'completed' -and
            $enabledClip.Count -eq 1 -and $candidateFrames.Count -gt 0 -and
            $candidateFrames[0].width -ge 3840 -and $candidateFrames[0].height -ge 2160 -and
            ([string]::IsNullOrWhiteSpace($ClipId) -or $candidate.clipId -eq $ClipId)
    })
    if ($references.Count -eq 0) { throw "A completed native-4K stock-libplacebo HDR10+ reference for an enabled clip is required. $qualityFirst" }
    if (-not [string]::IsNullOrWhiteSpace($ClipId) -and $references.Count -ne 1) { throw "The requested reference clip is ambiguous: $ClipId. $qualityFirst" }
    $reference = $references[0]
    $embyRows = @($retained.results | Where-Object { $_.clipId -eq $reference.clipId -and $_.implementationId -eq 'emby-embytonemap-high' -and $_.status -eq 'completed' })
    if ($embyRows.Count -ne 1 -or @($reference.frames).Count -lt $FrameIndex -or @($embyRows[0].frames).Count -lt $FrameIndex) { throw "Completed reference and Emby high HDR10+ frames at ordinal $FrameIndex are required. $qualityFirst" }
    $emby = $embyRows[0]
    $referenceFrame = $reference.frames[$FrameIndex - 1]
    $embyFrame = $emby.frames[$FrameIndex - 1]
    Assert-QualityFrameAlignment -ReferenceFrames @($referenceFrame) -TestFrames @($embyFrame) -FirstIndex $FrameIndex
    $referenceRequest = Get-DiagnosticProperty $reference 'sequenceRequest'
    $embyRequest = Get-DiagnosticProperty $emby 'sequenceRequest'
    if ($null -eq $referenceRequest -or $null -eq $embyRequest -or ($referenceRequest | ConvertTo-Json -Compress) -ne ($embyRequest | ConvertTo-Json -Compress)) { throw "Reference and Emby must use the same source, seek, decoder, keyframe extraction and post-generation retention. $qualityFirst" }
    $rawKeyframeIndex = [int](Get-DiagnosticProperty $referenceFrame 'keyframeIndex')
    if ($rawKeyframeIndex -lt 1 -or $rawKeyframeIndex -ne (Get-DiagnosticProperty $embyFrame 'keyframeIndex') -or $rawKeyframeIndex -ne 1 + ($FrameIndex - 1) * $referenceRequest.keyframeStep -or $referenceRequest.selection -ne 'decoder-skip-non-key' -or $rawKeyframeIndex -gt $referenceRequest.generatedFrameLimit) { throw 'Retained HDR10+ source keyframe ordinal does not match its decoder/post-sampling request.' }
    $referenceImage = Resolve-DiagnosticAsset -Path $referenceFrame.image
    $embyImage = Resolve-DiagnosticAsset -Path $embyFrame.image
    foreach ($imagePath in @($referenceImage, $embyImage)) {
        if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { throw "Retained quality PNG was not found: $imagePath. $qualityFirst" }
        $size = @(Get-QualitySelectedFrames -ImagePaths @($imagePath) -FirstIndex $FrameIndex)[0]
        if ($size.width -ne $referenceFrame.width -or $size.height -ne $referenceFrame.height) { throw 'Retained PNG dimensions do not match their frame-number report records.' }
    }

    $clipChoices = @($manifest.clips | Where-Object { $_.id -eq $reference.clipId -and $_.toneMappingType -eq 'hdr10plus' })
    if ($clipChoices.Count -ne 1) { throw 'The retained HDR10+ clip is missing or ambiguous in config/media.json.' }
    $clip = $clipChoices[0]
    $mediaPath = Join-Path $configuration.paths.mediaPath $clip.fileName
    $binaryPath = $configuration.binaries.stock.ffmpegPath
    if ([string]::IsNullOrWhiteSpace($binaryPath) -or -not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) { throw 'Configure an existing binaries.stock.ffmpegPath before running this diagnostic.' }
    $mediaHash = (Get-FileHash -LiteralPath $mediaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($clip.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $mediaHash -ne $clip.sha256 -or $mediaHash -ne $reference.input.sha256 -or $mediaHash -ne $emby.input.sha256) { throw 'Original source SHA256 must match both the pinned manifest and the retained reference/Emby inputs.' }
    $binaryHash = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $retainedBinaryHash = Get-DiagnosticProperty (Get-DiagnosticProperty $reference.preflight 'binary') 'sha256'
    if ($retainedBinaryHash -notmatch '^[a-fA-F0-9]{64}$' -or $binaryHash -ne $retainedBinaryHash) { throw "Configured stock FFmpeg differs from the retained reference binary hash. $qualityFirst" }
    $inputFingerprints = @(
        @{ path = ConvertTo-QualityAssetPath -Path $mediaPath -RepositoryRoot $root; sha256 = $mediaHash },
        @{ path = ConvertTo-QualityAssetPath -Path $binaryPath -RepositoryRoot $root; sha256 = $binaryHash },
        @{ path = ConvertTo-QualityAssetPath -Path $referenceImage -RepositoryRoot $root; sha256 = (Get-FileHash -LiteralPath $referenceImage -Algorithm SHA256).Hash.ToLowerInvariant() },
        @{ path = ConvertTo-QualityAssetPath -Path $embyImage -RepositoryRoot $root; sha256 = (Get-FileHash -LiteralPath $embyImage -Algorithm SHA256).Hash.ToLowerInvariant() }
    )

    $planned = Get-DiagnosticProperty $reference 'plannedCommand'
    $arguments = [string[]]@(Get-DiagnosticProperty $planned 'arguments')
    if ($arguments.Count -lt 2) { throw "Retained reference arguments are unavailable. $qualityFirst" }
    $graphIndex = Get-DiagnosticArgumentIndex -Arguments $arguments -Name '-filter_complex'
    $inputIndex = Get-DiagnosticArgumentIndex -Arguments $arguments -Name '-i'
    $frameArgumentIndex = Get-DiagnosticArgumentIndex -Arguments $arguments -Name '-frames:v'
    $skipArgumentIndex = Get-DiagnosticArgumentIndex -Arguments $arguments -Name '-skip_frame'
    if ($skipArgumentIndex -ge $inputIndex -or $arguments[$skipArgumentIndex] -ne 'nokey' -or $arguments -contains '-vf' -or $arguments -contains '-t') { throw "Retained reference must use decoder keyframes with a frame-count bound. $qualityFirst" }
    $originalGraph = $arguments[$graphIndex]
    if ($originalGraph -match '(?i)showinfo|select=|trim=' -or $originalGraph -notmatch '^.+\[mapped\]$') { throw "Retained graph does not use the current unsampled quality pipeline with a mapped output. $qualityFirst" }
    # Earlier immutable native commands explicitly named their sole input. The
    # diagnostic uses the implicit input requested for new generation commands.
    $controlBaseGraph = $originalGraph -replace '^\[0:v:0\]', ''
    $mapper = [regex]::Match($controlBaseGraph, '(?:(?<=\])|(?<=,)|^)libplacebo=[^,;\[\]]+')
    if (-not $mapper.Success -or $originalGraph.Contains('extra_opts=')) { throw 'Retained reference graph does not match the supported unmodified libplacebo metadata control.' }
    $arguments[$graphIndex] = $controlBaseGraph.Insert($mapper.Index + $mapper.Length, ':extra_opts=tone_map_metadata=hdr10plus')
    # Extract the same raw keyframe prefix as the retained reference. Keep the
    # requested source ordinal on disk after generation; no select/trim filter.
    $arguments[$inputIndex] = $mediaPath
    $arguments[$frameArgumentIndex] = $rawKeyframeIndex.ToString([Globalization.CultureInfo]::InvariantCulture)
    $seekSeconds = [double]$reference.input.seekSeconds
    if ($arguments -contains '-ss') {
        $seekIndex = Get-DiagnosticArgumentIndex -Arguments $arguments -Name '-ss'
        $commandSeek = [double]::Parse($arguments[$seekIndex], [Globalization.CultureInfo]::InvariantCulture)
        if ($commandSeek -ne $seekSeconds) { throw 'Retained command seek differs from its input record.' }
    } elseif ($seekSeconds -ne 0) { throw 'Retained nonzero seek is absent from the reference command.' }
    if ($arguments -contains '-init_hw_device') {
        $deviceIndex = Get-DiagnosticArgumentIndex -Arguments $arguments -Name '-init_hw_device'
        $currentDevice = 'vulkan=tmdevice:' + $configuration.devices.vulkan
        if ($arguments[$deviceIndex] -ne $currentDevice) { throw "Current Vulkan adapter setting differs from the retained reference command. $qualityFirst" }
    }

    $runId = 'hdr10plus-metadata-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $directory = Join-Path $configuration.paths.resultsPath ('diagnostics/' + $runId)
    $imageDirectory = Join-Path $directory 'images'
    $rawImageDirectory = Join-Path $directory 'raw-images'
    New-Item -ItemType Directory -Path $imageDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $rawImageDirectory -Force | Out-Null
    $arguments[$arguments.Count - 1] = Join-Path $rawImageDirectory '%06d.png'
    $report = [ordered]@{
        schemaVersion = 1; kind = 'diagnostic'; runId = $runId; createdUtc = [DateTime]::UtcNow.ToString('o')
        clipId = $clip.id; purpose = 'One-frame metadata-selection control; separate from production quality scores.'
        control = 'extra_opts=tone_map_metadata=hdr10plus'; status = 'failed'; reason = $null
        userConfigPath = ConvertTo-QualityAssetPath -Path $configuration.userConfigPath -RepositoryRoot $root
        retainedReport = ConvertTo-QualityAssetPath -Path $retainedPath -RepositoryRoot $root
        originalGraph = $originalGraph; controlGraph = $arguments[$graphIndex]
        operationalChanges = @('PNG extraction cap reduced to raw source keyframe ordinal ' + $rawKeyframeIndex + '.', 'After generation, keep only that raw PNG and rename it 000001.png; no filter-based selection.', 'Use implicit input while retaining the mapped output label.', 'Output/log directory changed to this separate diagnostic directory.', 'Media and stock-binary paths resolved from current configuration; hashes match retained inputs.')
        source = @{ path = ConvertTo-QualityAssetPath -Path $mediaPath -RepositoryRoot $root; sha256 = $mediaHash }
        binary = @{ path = ConvertTo-QualityAssetPath -Path $binaryPath -RepositoryRoot $root; sha256 = $binaryHash; retainedVersion = $reference.preflight.binary.version }
        inputFingerprints = $inputFingerprints; inputsPreserved = $null
        settings = @{ bezierSideDataRemoved = $false; metadataSelector = 'hdr10plus'; selectedKeyframeIndex = $FrameIndex; sourceKeyframeIndex = $rawKeyframeIndex; generatedFrameLimit = $rawKeyframeIndex; signedGain = $SignedGain; absoluteDisplayGain = 8 }
        sequenceRequest = $referenceRequest
        sources = @(
            @{ url = 'https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/vf_libplacebo.c'; supports = 'FFmpeg forwards extra_opts through pl_options_set_str.' },
            @{ url = 'https://raw.githubusercontent.com/haasn/libplacebo/master/src/options.c'; supports = 'tone_map_metadata selector enum: any, none, hdr10, hdr10plus, cie_y.' },
            @{ url = 'https://raw.githubusercontent.com/haasn/libplacebo/master/src/colorspace.c'; supports = 'ANY can prefer derived Y metadata; HDR10PLUS selects scene RGB metadata.' },
            @{ url = 'https://raw.githubusercontent.com/haasn/libplacebo/master/src/include/libplacebo/utils/libav_internal.h'; supports = 'Version-1 reserved 5/10 percentile slots are not ordinary CDF points; source Bezier data retained.' },
            @{ url = 'https://raw.githubusercontent.com/haasn/libplacebo/v7.360.0/src/shaders/colorspace.c'; supports = 'Preference applies to input nominal luminance; output uses HDR10 metadata. Guidance, not exact compiled source provenance.' }
        )
        analysis = Get-QualityAnalysisContract; originalEmbyVsDefaultMetrics = $embyFrame.metrics
        generation = $null; generatedFrameCount = 0; frame = $null; comparisons = @()
        limitation = 'The control uses the same source, seek and keyframe-skipping decoder, then keeps the requested raw source ordinal after generation. Source frame times are not collected, so ordinal and dimension checks do not prove exact temporal correspondence. Image changes show sensitivity to metadata selection on this frame; they are not absolute quality judgments or conclusions about other scenes.'
    }
    $generation = Invoke-FFmpegProcess -FilePath $binaryPath -Arguments $arguments -WorkingDirectory $directory -TimeoutSeconds $configuration.benchmark.processTimeoutSeconds -LogPathPrefix (Join-Path $directory 'generation')
    $report.generation = @{ exitCode = $generation.ExitCode; timedOut = $generation.TimedOut; elapsedSeconds = $generation.ElapsedSeconds; outputCaptureComplete = $generation.OutputCaptureComplete; commandLine = $generation.CommandLine; log = ConvertTo-QualityAssetPath -Path $generation.LogFiles.Log -RepositoryRoot $root; graph = $(if ($generation.LogFiles.Graph) { ConvertTo-QualityAssetPath -Path $generation.LogFiles.Graph -RepositoryRoot $root } else { $null }) }
    if ($generation.ExitCode -ne 0 -or $generation.TimedOut -or -not $generation.OutputCaptureComplete) { throw 'Metadata control was not accepted/completed; see generation stderr. No substitute was run.' }
    Assert-QualityNativeRenderingSucceeded -Text $generation.StdErr
    if ((Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $binaryHash) { throw 'The stock binary changed during control generation; no comparison analysis is started under stale provenance.' }
    $rawImages = @(Get-ChildItem -LiteralPath $rawImageDirectory -Filter '*.png' -File | Sort-Object Name | ForEach-Object { $_.FullName })
    $rawFrames = @(Get-QualitySelectedFrames -ImagePaths $rawImages)
    if ($rawFrames.Count -ne $rawKeyframeIndex) { throw 'Metadata control did not generate the requested raw keyframe prefix.' }
    $report.generatedFrameCount = $rawFrames.Count
    $image = Join-Path $imageDirectory '000001.png'
    for ($index = 0; $index -lt $rawImages.Count - 1; $index++) { Remove-Item -LiteralPath $rawImages[$index] -Force -ErrorAction Stop }
    Move-Item -LiteralPath $rawImages[$rawImages.Count - 1] -Destination $image -ErrorAction Stop
    Remove-Item -LiteralPath $rawImageDirectory -ErrorAction Stop
    $frames = @(Get-QualitySelectedFrames -ImagePaths @($image))
    $controlFrame = [pscustomobject]@{ index = $FrameIndex; width = $frames[0].width; height = $frames[0].height }
    Assert-QualityFrameAlignment -ReferenceFrames @($referenceFrame) -TestFrames @($controlFrame) -FirstIndex $FrameIndex
    $report.frame = @{ index = $FrameIndex; keyframeIndex = $rawKeyframeIndex; outputFileIndex = $frames[0].index; width = $frames[0].width; height = $frames[0].height; image = ConvertTo-QualityAssetPath -Path $image -RepositoryRoot $root }
    foreach ($pair in @(@{ id = 'control-vs-default'; reference = $referenceImage }, @{ id = 'control-vs-emby-high'; reference = $embyImage })) {
        $analysisDirectory = Join-Path $directory $pair.id
        $signed = Join-Path $analysisDirectory 'diff-signed.png'
        $absolute = Join-Path $analysisDirectory 'diff-absolute.png'
        $analysis = Invoke-QualityFrameAnalysis -ReferencePath $pair.reference -TestPath $image -FFmpegPath $binaryPath -WorkingDirectory $analysisDirectory -DiffSignedPath $signed -DiffAbsolutePath $absolute -Gain $SignedGain -TimeoutSeconds ([Math]::Min(3600, $configuration.benchmark.processTimeoutSeconds))
        $report.comparisons += @{ id = $pair.id; referenceImage = ConvertTo-QualityAssetPath -Path $pair.reference -RepositoryRoot $root; testImage = $report.frame.image; metrics = $analysis.Metrics; diffSigned = ConvertTo-QualityAssetPath -Path $signed -RepositoryRoot $root; signedGain = $analysis.SignedGain; diffAbsolute = ConvertTo-QualityAssetPath -Path $absolute -RepositoryRoot $root; diffAbsoluteDisplay = ConvertTo-QualityAssetPath -Path $analysis.DiffAbsoluteDisplayPath -RepositoryRoot $root; absoluteDisplayGain = $analysis.AbsoluteDisplayGain }
    }
    $report.status = 'completed'
} catch {
    if ($null -eq $report) { throw }
    $report.reason = $_.Exception.Message
} finally {
    try {
        if ($null -ne $report) {
            $report.inputsPreserved = $true
            foreach ($fingerprint in $report.inputFingerprints) {
                $fingerprintPath = Resolve-DiagnosticAsset -Path $fingerprint.path
                if (-not (Test-Path -LiteralPath $fingerprintPath -PathType Leaf) -or (Get-FileHash -LiteralPath $fingerprintPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $fingerprint.sha256) { $report.inputsPreserved = $false }
            }
            $report.retainedReportPreserved = (Get-FileHash -LiteralPath $retainedPath -Algorithm SHA256).Hash -eq $retainedHash
            $currentLatestHash = $(if (Test-Path -LiteralPath $latestPath -PathType Leaf) { (Get-FileHash -LiteralPath $latestPath -Algorithm SHA256).Hash } else { $null })
            $report.latestReportPreserved = $currentLatestHash -eq $latestHash
            if (-not $report.inputsPreserved -or -not $report.retainedReportPreserved -or -not $report.latestReportPreserved) { $report.status = 'failed'; $report.reason = 'A pinned source, stock binary, retained PNG or production quality report changed during the diagnostic.' }
            Write-QualityReportFile -Report ([pscustomobject]$report) -Path (Join-Path $directory 'report.json')
        }
    } finally { Exit-SuiteRun -Lease $lease }
}
[pscustomobject]@{ reportPath = Join-Path $directory 'report.json'; status = $report.status; reason = $report.reason; frame = $report.frame; comparisons = $report.comparisons; inputsPreserved = $report.inputsPreserved; retainedReportPreserved = $report.retainedReportPreserved; latestReportPreserved = $report.latestReportPreserved }
if ($report.status -ne 'completed') { throw "HDR10+ diagnostic failed: $($report.reason). See $(Join-Path $directory 'report.json')." }
