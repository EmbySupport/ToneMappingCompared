#Requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'FFmpeg.psm1')

function Get-QualityProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-QualityNativeRenderingFailure {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    # libplacebo can emit blank NV12 frames and exit zero after a rendering
    # failure. Require native rendering success in addition to process success.
    # Scope this to actual library/device log lines, not command text or normal
    # informational messages mentioning optional Vulkan features.
    $context = '(?:libplacebo|Parsed_libplacebo_\d+|embytonemap_vulkan|Parsed_embytonemap_vulkan_\d+|Vulkan)'
    $failure = '(?:.*\bVK_ERROR_(?:OUT_OF_DEVICE_MEMORY|OUT_OF_HOST_MEMORY|DEVICE_LOST)\b|Failed rendering image\b|Failed (?:creating|initializing|generating)[^\r\n]*\bLUT(?:s)?\b|Failed dispatching (?:intermediate pass|scaler|[^\r\n]*shader)\b|(?:Failed|Error) (?:compiling|linking|translating)[^\r\n]*(?:shader|SPIR-V)\b)'
    $match = [regex]::Match($Text, '^\[' + $context + '[^\]\r\n]*\]\s*(' + $failure + '[^\r\n]*)', [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $name=if($match.Value -match 'embytonemap_vulkan'){'Emby Vulkan'}else{'libplacebo'}
        return 'Native ' + $name + ' rendering failed: ' + $match.Groups[1].Value.Trim()
    }
    return $null
}

function Assert-QualityNativeRenderingSucceeded {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $failure = Get-QualityNativeRenderingFailure -Text $Text
    if ($failure) { throw $failure }
}

function Get-QualityReportWithInvalidReferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$InvalidReferences
    )
    if ((Get-QualityProperty $Report 'kind') -ne 'quality') { throw 'Only quality reports can invalidate reference comparisons.' }
    # Pure report transformation: never modify caller objects or stored assets.
    $copy = $Report | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    foreach ($failure in $InvalidReferences) {
        if ([string]::IsNullOrWhiteSpace([string](Get-QualityProperty $failure 'clipId')) -or [string]::IsNullOrWhiteSpace([string](Get-QualityProperty $failure 'curve')) -or [string]::IsNullOrWhiteSpace([string](Get-QualityProperty $failure 'reason'))) { throw 'Invalid reference records require clipId, curve and reason.' }
        $references = @($copy.results | Where-Object { $_.clipId -eq $failure.clipId -and $_.curve -eq $failure.curve -and $_.implementationId -eq 'stock-libplacebo' -and $_.isReference })
        if ($references.Count -ne 1) { throw 'Invalidation requires exactly one matching stock-libplacebo reference.' }
        foreach ($row in $copy.results | Where-Object { $_.clipId -eq $failure.clipId -and $_.curve -eq $failure.curve -and ($_.status -eq 'completed' -or $_.isReference) }) {
            $row.status = 'failed'
            $row.reason = if ($row.isReference) { $failure.reason } else { 'Quality comparison invalid: the matching stock-libplacebo reference failed native rendering. ' + $failure.reason }
            $row | Add-Member -NotePropertyName renderingValidation -NotePropertyValue ([pscustomobject]@{ passed = $false; reason = $failure.reason; referenceImplementationId = 'stock-libplacebo'; log = Get-QualityProperty $failure 'log' }) -Force
            foreach ($frame in @(Get-QualityProperty $row 'frames')) {
                foreach ($name in @('metrics','diffSigned','diffAbsolute','diffAbsoluteDisplay')) { if ($frame.PSObject.Properties[$name]) { $frame.$name = $null } }
            }
        }
    }
    $copy | Add-Member -NotePropertyName invalidReferences -NotePropertyValue @($InvalidReferences) -Force
    return $copy
}

function ConvertFrom-QualityNumber {
    param([string]$Value)
    if ($Value -match '^(?:inf|infinity)$') { return 'inf' }
    $number = 0.0
    if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "Invalid finite metric value: $Value" }
    return $number
}

function Get-QualityTextMetric {
    param([string]$Text, [string]$Name, [string]$Separator = ':')
    $match = [regex]::Match($Text, '(?:^|\s)' + [regex]::Escape($Name) + [regex]::Escape($Separator) + '(\S+)')
    if (-not $match.Success) { throw "Metric '$Name' was not reported by FFmpeg." }
    return ConvertFrom-QualityNumber $match.Groups[1].Value
}

function Get-QualityAnalysisContract {
    return [pscustomobject][ordered]@{
        input = 'Stored 8-bit RGB PNGs after tone mapping; not the original NV12 mapper outputs.'
        pixelFormat = 'yuv444p'; bitDepth = 8; range = 'pc'; colorMatrix = 'bt709'
        conversion = 'Each PNG is converted with the same fixed stock FFmpeg, full-range RGB to full-range BT.709 YUV 4:4:4. No resizing or chroma subsampling.'
        meaning = 'Agreement with the libplacebo reference after PNG storage and the stated analysis conversion; not absolute perceptual quality.'
        psnr = 'Y/U/V and equally weighted 4:4:4 average; inf is stored as a JSON string.'
        chroma = 'Combined U/V PSNR derived from per-plane PSNR text; printed metric precision applies.'
        shares = 'Fraction from 0 to 1 of samples with a nonzero absolute error, separately per full-resolution plane.'
        signedImage = 'Test minus reference in analysis YUV, grainextract then identical configurable gain on Y/U/V, default 2; 128 on every plane is equality. Full-range BT.709 to RGB PNG for display; large errors clip in the visualization.'
        absoluteImage = 'Exact unamplified Math.Abs(test - reference) separately on stored PNG R/G/B channels, using lossless planar RGB before PNG encoding. Equality is black.'
        absoluteDisplayImage = 'Separate display-only PNG: min(255, gain * exact RGB absolute error) on every R/G/B channel, default gain 8. Equality stays black; clipping and gain do not affect the raw asset or metrics.'
        precision = 'Numbers are parsed from FFmpeg logs using invariant culture; visual clipping does not affect metrics.'
    }
}

function ConvertTo-QualityAssetPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $absolute = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
    if ($absolute.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $absolute.Substring($root.Length).Replace('\', '/') }
    return (New-Object System.Uri($absolute)).AbsoluteUri
}

function Get-QualitySelectedFrames {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ImagePaths, [ValidateRange(1, 2147483647)][int]$FirstIndex = 1)
    if ($ImagePaths.Count -eq 0) { throw 'No keyframe PNGs were produced after the requested seek.' }
    for ($index = 0; $index -lt $ImagePaths.Count; $index++) {
        $path = $ImagePaths[$index]
        $name = [IO.Path]::GetFileName($path)
        if ($name -match '^(\d{6})\.png$' -and [int]$Matches[1] -ne $index + $FirstIndex) { throw 'Numbered PNG sequence is discontinuous.' }
        $header = New-Object byte[] 24
        $stream = [IO.File]::OpenRead($path)
        try { $read = $stream.Read($header, 0, $header.Length) } finally { $stream.Dispose() }
        if ($read -ne 24 -or [BitConverter]::ToString($header[0..7]) -ne '89-50-4E-47-0D-0A-1A-0A' -or [BitConverter]::ToString($header[12..15]) -ne '49-48-44-52') { throw "Quality asset is not a PNG with an IHDR header: $path" }
        $width = [long]$header[16] * 16777216 + [long]$header[17] * 65536 + [long]$header[18] * 256 + $header[19]
        $height = [long]$header[20] * 16777216 + [long]$header[21] * 65536 + [long]$header[22] * 256 + $header[23]
        if ($width -le 0 -or $height -le 0 -or $width -gt [int]::MaxValue -or $height -gt [int]::MaxValue) { throw 'Quality PNG dimensions must be positive supported integers.' }
        [pscustomobject][ordered]@{
            index = $index + $FirstIndex; width = [int]$width; height = [int]$height; imagePath = $path
        }
    }
}

function Complete-QualityImageSampling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ImagesDirectory,
        [ValidateRange(1, 1000)][int]$GeneratedFrameLimit = 30,
        [ValidateRange(1, 30)][int]$KeyframeStep = 3
    )
    if (-not [IO.Path]::IsPathRooted($ImagesDirectory)) { throw 'Image sampling requires an absolute directory.' }
    $directory = Get-Item -LiteralPath ([IO.Path]::GetFullPath($ImagesDirectory)) -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Image sampling requires a regular directory, not a link.' }
    $images = @(Get-ChildItem -LiteralPath $directory.FullName -Filter '*.png' -File | Sort-Object Name)
    if ($images.Count -eq 0 -or $images.Count -gt $GeneratedFrameLimit) { throw 'Generated keyframe PNG count is empty or exceeds the extraction limit.' }
    for ($index = 0; $index -lt $images.Count; $index++) {
        if ($images[$index].Name -cne (($index + 1).ToString('D6', [Globalization.CultureInfo]::InvariantCulture) + '.png') -or ($images[$index].Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Raw PNG sequence must be consecutive regular files numbered from 000001.' }
    }
    # Validate the whole raw sequence before deleting any generated PNG.
    $null = @(Get-QualitySelectedFrames -ImagePaths @($images | ForEach-Object { $_.FullName }))
    $retained = New-Object 'Collections.Generic.List[object]'
    for ($index = 0; $index -lt $images.Count; $index++) {
        if (($index % $KeyframeStep) -eq 0) { $retained.Add([pscustomobject]@{ path = $images[$index].FullName; keyframeIndex = $index + 1 }) }
        else { Remove-Item -LiteralPath $images[$index].FullName -Force -ErrorAction Stop }
    }
    for ($index = 0; $index -lt $retained.Count; $index++) {
        $destination = Join-Path $directory.FullName (($index + 1).ToString('D6', [Globalization.CultureInfo]::InvariantCulture) + '.png')
        if ($retained[$index].path -ne $destination) { Move-Item -LiteralPath $retained[$index].path -Destination $destination -ErrorAction Stop }
        $retained[$index].path = $destination
    }
    $frames = @(Get-QualitySelectedFrames -ImagePaths @($retained | ForEach-Object { $_.path }))
    for ($index = 0; $index -lt $frames.Count; $index++) { $frames[$index] | Add-Member -NotePropertyName keyframeIndex -NotePropertyValue $retained[$index].keyframeIndex }
    return [pscustomobject]@{ GeneratedFrameCount = $images.Count; KeyframeStep = $KeyframeStep; Frames = $frames }
}

function Assert-QualityFrameAlignment {
    [CmdletBinding()]
    param([object[]]$ReferenceFrames, [object[]]$TestFrames, [ValidateRange(1, 2147483647)][int]$FirstIndex = 1)
    if ($ReferenceFrames.Count -eq 0 -or $ReferenceFrames.Count -ne $TestFrames.Count) { throw "Keyframe counts differ: reference $($ReferenceFrames.Count), test $($TestFrames.Count). No score is assigned." }
    for ($index = 0; $index -lt $ReferenceFrames.Count; $index++) {
        $reference = $ReferenceFrames[$index]; $test = $TestFrames[$index]
        if ($reference.index -ne $index + $FirstIndex -or $test.index -ne $index + $FirstIndex) { throw 'Selected-keyframe indices must be consecutive and correspond to the same ordinal.' }
        if ($reference.width -ne $test.width -or $reference.height -ne $test.height) { throw 'Native output dimensions differ from the reference.' }
    }
}

function Invoke-QualityAnalysisProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds, [string]$LogPrefix)
    $run = Invoke-FFmpegProcess -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPathPrefix $LogPrefix
    if ($run.TimedOut -or $run.ExitCode -ne 0 -or -not $run.OutputCaptureComplete) {
        $logPath = Get-QualityProperty $run.LogFiles 'Log'
        if ([string]::IsNullOrWhiteSpace($logPath)) { $logPath = Get-QualityProperty $run.LogFiles 'LogPath' }
        if ([string]::IsNullOrWhiteSpace($logPath)) { $logPath = Get-QualityProperty $run.LogFiles 'StdErr' }
        if ([string]::IsNullOrWhiteSpace($logPath)) { $logPath = $LogPrefix + '.stderr.log' }
        throw "FFmpeg quality analysis failed (exit $($run.ExitCode), timeout $($run.TimedOut)); inspect $logPath"
    }
    return $run
}

function Invoke-QualityFrameAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$TestPath,
        [Parameter(Mandatory = $true)][string]$FFmpegPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$DiffSignedPath,
        [Parameter(Mandatory = $true)][string]$DiffAbsolutePath,
        [ValidateRange(1, 32)][int]$Gain = 2,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
        [string]$DiffAbsoluteDisplayPath,
        [ValidateRange(1, 32)][int]$AbsoluteDisplayGain = 8
    )
    if ([string]::IsNullOrWhiteSpace($DiffAbsoluteDisplayPath)) {
        $DiffAbsoluteDisplayPath = Join-Path ([IO.Path]::GetDirectoryName($DiffAbsolutePath)) ([IO.Path]::GetFileNameWithoutExtension($DiffAbsolutePath) + '.gain-' + $AbsoluteDisplayGain + '.png')
    }
    foreach ($path in @($ReferencePath, $TestPath, $FFmpegPath, $WorkingDirectory, $DiffSignedPath, $DiffAbsolutePath, $DiffAbsoluteDisplayPath)) {
        if (-not [IO.Path]::IsPathRooted($path)) { throw 'Quality analysis requires absolute filesystem paths.' }
    }
    foreach ($path in @($ReferencePath, $TestPath, $FFmpegPath, $DiffSignedPath, $DiffAbsolutePath)) {
        if ([IO.Path]::GetFullPath($path).Equals([IO.Path]::GetFullPath($DiffAbsoluteDisplayPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'Amplified absolute display must use a separate output path.' }
    }
    foreach ($path in @($ReferencePath, $TestPath, $FFmpegPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Quality input or binary was not found: $path" } }
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    foreach ($path in @($DiffSignedPath, $DiffAbsolutePath, $DiffAbsoluteDisplayPath)) { New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null }
    $analysisFormat = 'scale=flags=+accurate_rnd+bitexact+full_chroma_int:in_range=pc:out_range=pc:out_color_matrix=bt709,format=yuv444p,setparams=range=pc:colorspace=bt709:color_primaries=bt709:color_trc=bt709'
    $metricGraph = '[0:v]' + $analysisFormat + ',split=3[rp][rs][rd];[1:v]' + $analysisFormat + ',split=3[tp][ts][td];' +
        '[tp][rp]psnr=stats_file=psnr.log[ps];[ps]nullsink;' +
        '[ts][rs]ssim=stats_file=ssim.log[ss];[ss]nullsink;' +
        '[td][rd]blend=all_mode=difference,split=2[absolute][share];' +
        '[absolute]signalstats,metadata=mode=print:file=absolute.log[a];[a]nullsink;' +
        '[share]lutyuv=y=''gt(val,0)*255'':u=''gt(val,0)*255'':v=''gt(val,0)*255'',signalstats,metadata=mode=print:file=share.log[summary]'
    $metricPrefix = Join-Path $WorkingDirectory 'metrics'
    $metricRun = Invoke-QualityAnalysisProcess -FilePath $FFmpegPath -Arguments @('-hide_banner', '-nostdin', '-y', '-v', 'info', '-filter_complex_threads', '1', '-i', $ReferencePath, '-i', $TestPath, '-filter_complex', $metricGraph, '-map', '[summary]', '-frames:v', '1', '-c:v', 'wrapped_avframe', '-f', 'null', '-') -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPrefix $metricPrefix
    $psnrLines = @(Get-Content -LiteralPath (Join-Path $WorkingDirectory 'psnr.log') | Where-Object { $_ -match '^n:' })
    $ssimLines = @(Get-Content -LiteralPath (Join-Path $WorkingDirectory 'ssim.log') | Where-Object { $_ -match '^n:' })
    if ($psnrLines.Count -ne 1 -or $ssimLines.Count -ne 1) { throw 'Expected exactly one PSNR/SSIM record for one stored PNG comparison.' }
    $absoluteText = Get-Content -LiteralPath (Join-Path $WorkingDirectory 'absolute.log') -Raw
    $shareText = Get-Content -LiteralPath (Join-Path $WorkingDirectory 'share.log') -Raw
    $psnrU = Get-QualityTextMetric $psnrLines[0] 'psnr_u'; $psnrV = Get-QualityTextMetric $psnrLines[0] 'psnr_v'
    $mseU = if ($psnrU -eq 'inf') { 0.0 } else { 65025.0 / [Math]::Pow(10.0, ([double]$psnrU / 10.0)) }
    $mseV = if ($psnrV -eq 'inf') { 0.0 } else { 65025.0 / [Math]::Pow(10.0, ([double]$psnrV / 10.0)) }
    $chromaMse = ($mseU + $mseV) / 2.0
    $chromaPsnr = if ($chromaMse -eq 0) { 'inf' } else { 10.0 * [Math]::Log10(65025.0 / $chromaMse) }
    $metrics = [pscustomobject][ordered]@{
        psnrY = Get-QualityTextMetric $psnrLines[0] 'psnr_y'; psnrU = $psnrU; psnrV = $psnrV
        psnrAvg = Get-QualityTextMetric $psnrLines[0] 'psnr_avg'; psnrChroma = $chromaPsnr
        ssimY = Get-QualityTextMetric $ssimLines[0] 'Y'; ssimU = Get-QualityTextMetric $ssimLines[0] 'U'
        ssimV = Get-QualityTextMetric $ssimLines[0] 'V'; ssimAll = Get-QualityTextMetric $ssimLines[0] 'All'
        maxAbsY = Get-QualityTextMetric $absoluteText 'lavfi.signalstats.YMAX' '='
        maxAbsU = Get-QualityTextMetric $absoluteText 'lavfi.signalstats.UMAX' '='
        maxAbsV = Get-QualityTextMetric $absoluteText 'lavfi.signalstats.VMAX' '='
        shareDifferentY = (Get-QualityTextMetric $shareText 'lavfi.signalstats.YAVG' '=') / 255.0
        shareDifferentU = (Get-QualityTextMetric $shareText 'lavfi.signalstats.UAVG' '=') / 255.0
        shareDifferentV = (Get-QualityTextMetric $shareText 'lavfi.signalstats.VAVG' '=') / 255.0
        analysisPixelFormat = 'yuv444p'; analysisRange = 'pc'; analysisMatrix = 'bt709'
    }
    $signedGraph = '[0:v]' + $analysisFormat + '[r];[1:v]' + $analysisFormat + '[t];[t][r]blend=all_mode=grainextract,' +
        ('lutyuv=y=''clip(128+{0}*(val-128),0,255)'':u=''clip(128+{0}*(val-128),0,255)'':v=''clip(128+{0}*(val-128),0,255)'',' -f $Gain) +
        'setparams=range=pc:colorspace=bt709:color_primaries=bt709:color_trc=bt709,scale=in_range=pc:out_range=pc:in_color_matrix=bt709:flags=+accurate_rnd,format=rgb24[v]'
    $signedRun = Invoke-QualityAnalysisProcess -FilePath $FFmpegPath -Arguments @('-hide_banner', '-nostdin', '-y', '-v', 'info', '-filter_complex_threads', '1', '-i', $ReferencePath, '-i', $TestPath, '-filter_complex', $signedGraph, '-map', '[v]', '-frames:v', '1', '-c:v', 'png', '-update', '1', $DiffSignedPath) -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPrefix (Join-Path $WorkingDirectory 'signed-difference')
    # Planar RGB conversion is lossless. Unlike a zero U/V YUV difference, a
    # zero RGB difference displays as black without chroma-offset interpretation.
    $absoluteGraph = '[0:v]format=gbrp[r];[1:v]format=gbrp[t];[t][r]blend=all_mode=difference,split=2[raw][display];' +
        '[raw]format=rgb24[absolute];[display]' +
        ('lutrgb=r=''min(255,val*{0})'':g=''min(255,val*{0})'':b=''min(255,val*{0})'',format=rgb24[amplified]' -f $AbsoluteDisplayGain)
    $absoluteRun = Invoke-QualityAnalysisProcess -FilePath $FFmpegPath -Arguments @('-hide_banner', '-nostdin', '-y', '-v', 'info', '-filter_complex_threads', '1', '-i', $ReferencePath, '-i', $TestPath, '-filter_complex', $absoluteGraph, '-map', '[absolute]', '-frames:v', '1', '-c:v', 'png', '-update', '1', $DiffAbsolutePath, '-map', '[amplified]', '-frames:v', '1', '-c:v', 'png', '-update', '1', $DiffAbsoluteDisplayPath) -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPrefix (Join-Path $WorkingDirectory 'absolute-difference')
    # Report metrics contain the complete parsed values. Remove intermediate
    # metric files only after every comparison and difference image succeeded.
    foreach ($name in @('psnr.log', 'ssim.log', 'absolute.log', 'share.log')) {
        Remove-Item -LiteralPath (Join-Path $WorkingDirectory $name) -Force -ErrorAction Stop
    }
    return [pscustomobject][ordered]@{
        Metrics = $metrics; DiffSignedPath = $DiffSignedPath; DiffAbsolutePath = $DiffAbsolutePath; SignedGain = $Gain
        DiffAbsoluteDisplayPath = $DiffAbsoluteDisplayPath; AbsoluteDisplayGain = $AbsoluteDisplayGain
        Analysis = Get-QualityAnalysisContract
        LogFiles = @($metricRun.LogFiles, $signedRun.LogFiles, $absoluteRun.LogFiles)
        StatsFiles = @()
    }
}

function Write-QualityReportFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Report, [Parameter(Mandatory = $true)][string]$Path)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.partial'
    try {
        $Report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Resolve-QualityLocalAsset {
    param([string]$Path, [string]$RepositoryRoot)
    if ($Path -match '^file:') { $uri = New-Object Uri($Path); if (-not $uri.IsFile) { throw 'Reference assets must be local files.' }; return $uri.LocalPath }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path))
}

function Assert-QualityCompletedLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Reference invocation log is missing: $Path" }
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($pattern in @('(?m)^Started UTC: \S+', '(?m)^Finished UTC: \S+', '(?m)^Exit code: 0\s*$', '(?m)^Timed out: False\s*$', '(?m)^Capture complete: True\s*$')) {
        if ($text -notmatch $pattern) { throw "Reference invocation log is incomplete or unsuccessful: $Path" }
    }
    Assert-QualityNativeRenderingSucceeded -Text $text
    return $text
}

function Assert-QualityReferenceFingerprints {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Proof, [Parameter(Mandatory=$true)][string]$RepositoryRoot)
    foreach ($file in $Proof.files) {
        $path = Resolve-QualityLocalAsset $file.path $RepositoryRoot
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw "Reused reference artifact changed or disappeared: $path" }
    }
}

function ConvertTo-QualityReferenceArguments {
    param([string[]]$Arguments)
    $normalized = [string[]]$Arguments.Clone()
    $inputPositions = @($(for ($index=0; $index -lt $normalized.Count; $index++) { if ($normalized[$index] -eq '-i') { $index } }))
    if ($normalized.Count -lt 3 -or $inputPositions.Count -ne 1 -or $inputPositions[0] -ge $normalized.Count-1 -or $normalized[-1] -notmatch '%(?:0\d+)?d\.png$') { throw 'Reference command must have one source input and a final numbered PNG output.' }
    $normalized[$inputPositions[0]+1] = '<pinned-source>'
    $normalized[-1] = '<numbered-png-output>'
    return ConvertTo-Json -InputObject $normalized -Compress
}

function Get-QualityReusableReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Report,
        [Parameter(Mandatory=$true)][string]$ReportPath,
        [Parameter(Mandatory=$true)][object]$Clip,
        [Parameter(Mandatory=$true)][object]$Pipeline,
        [Parameter(Mandatory=$true)][object]$SequenceRequest,
        [Parameter(Mandatory=$true)][string]$MediaPath,
        [Parameter(Mandatory=$true)][string]$FFmpegPath,
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [ValidateRange(1,32)][int]$SignedGain=2
    )
    if ($Report.schemaVersion -ne 1 -or $Report.kind -ne 'quality' -or $Report.methodVersion -ne 5 -or $Report.dryRun) { throw 'Reference reuse requires an actual method-version-5 decoder-keyframe, post-sampled quality report.' }
    if ($Report.settings.signedGain -ne $SignedGain -or $Report.settings.absoluteDisplayGain -ne 8) { throw 'Reference display gains differ from the requested contract.' }
    $choices = @($Report.results | Where-Object { $_.clipId -eq $Clip.id -and $_.curve -eq $SequenceRequest.curve -and $_.implementationId -eq 'stock-libplacebo' -and $_.isReference -and $_.status -eq 'completed' })
    if ($choices.Count -ne 1) { throw "Reference reuse requires exactly one completed stock reference for $($Clip.id)." }
    $reference = $choices[0]
    $binaryHash = (Get-FileHash -LiteralPath $FFmpegPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($binaryHash -ne $Report.analysisBinary.sha256 -or $binaryHash -ne $reference.preflight.binary.sha256) { throw 'Reference reuse rejected: fixed stock binary hash changed.' }
    $mediaHash = (Get-FileHash -LiteralPath $MediaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Clip.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $mediaHash -ne $Clip.sha256 -or $mediaHash -ne $reference.input.sha256) { throw 'Reference reuse rejected: pinned source hash changed.' }
    if (($reference.sequenceRequest | ConvertTo-Json -Compress) -ne ($SequenceRequest | ConvertTo-Json -Compress)) { throw 'Reference reuse rejected: source/seek/window/decoder/keyframe-selection request differs.' }
    if ($reference.plannedCommand.filterGraph -ne $Pipeline.FilterGraph -or $Pipeline.FilterGraph -match 'showinfo') { throw 'Reference reuse rejected: mapper/selection/conversion graph differs.' }
    $oldArguments = @($reference.plannedCommand.arguments); $newArguments = @($Pipeline.Arguments)
    if ((ConvertTo-QualityReferenceArguments $oldArguments) -ne (ConvertTo-QualityReferenceArguments $newArguments)) { throw 'Reference reuse rejected: full ordered processing arguments differ (only source/output artifact paths may differ).' }
    foreach ($option in @('-init_hw_device','-filter_hw_device')) {
        $oldIndex = [array]::IndexOf($oldArguments,$option); $newIndex = [array]::IndexOf($newArguments,$option)
        if (($oldIndex -lt 0) -ne ($newIndex -lt 0) -or ($oldIndex -ge 0 -and $oldArguments[$oldIndex+1] -ne $newArguments[$newIndex+1])) { throw 'Reference reuse rejected: configured device differs.' }
    }
    if ($reference.generation.exitCode -ne 0 -or $reference.generation.timedOut -or -not $reference.generation.outputCaptureComplete) { throw 'Reference generation did not complete.' }
    $generationLog = Resolve-QualityLocalAsset $reference.generation.log $RepositoryRoot
    $generationText = Assert-QualityCompletedLog $generationLog
    if (-not $generationText.Contains($reference.plannedCommand.filterGraph)) { throw 'Reference generation log does not contain its exact graph.' }
    $loggedCommand = [regex]::Match($generationText,'Command line \(Windows PowerShell\):\r?\n([^\r\n]+)').Groups[1].Value
    $recordedArguments = [string[]]@($reference.plannedCommand.arguments)
    if ($reference.generation.graph) { $recordedArguments = [string[]](@('-print_graphs_file',(Resolve-QualityLocalAsset $reference.generation.graph $RepositoryRoot),'-print_graphs_format','mermaidhtml') + @($recordedArguments)) }
    $expectedCommand = ConvertTo-PowerShellCommandLine -FilePath $reference.plannedCommand.filePath -Arguments $recordedArguments
    if ($loggedCommand -ne $reference.generation.commandLine -or $loggedCommand -ne $expectedCommand) { throw 'Reference generation log, recorded command and full ordered arguments differ.' }
    $frames = @($reference.frames)
    if ($frames.Count -eq 0 -or $reference.frameCount -ne $frames.Count) { throw 'Reference count is empty or inconsistent.' }
    $generationCounts = [regex]::Matches($generationText,'(?m)^frame=\s*(\d+)(?:\s|$)')
    $generatedFrameCount = Get-QualityProperty $reference 'generatedFrameCount'
    if ($null -eq $generatedFrameCount -or $generatedFrameCount -lt 1 -or $generatedFrameCount -gt $SequenceRequest.generatedFrameLimit -or $frames.Count -ne [int][Math]::Ceiling($generatedFrameCount / [double]$SequenceRequest.keyframeStep)) { throw 'Reference raw and retained counts do not match its post-generation sampling request.' }
    if ($generationCounts.Count -eq 0 -or [int]$generationCounts[$generationCounts.Count-1].Groups[1].Value -ne $generatedFrameCount) { throw 'Reference final generation count differs from its raw extraction count.' }
    $images = @($frames | ForEach-Object { Resolve-QualityLocalAsset $_.image $RepositoryRoot })
    $actualFrames = @(Get-QualitySelectedFrames -ImagePaths $images)
    Assert-QualityFrameAlignment -ReferenceFrames $frames -TestFrames $actualFrames
    $files = New-Object 'Collections.Generic.List[object]'
    $pathsSeen = @{}
    $fingerprint = {
        param([string]$Path)
        $absolute = Resolve-QualityLocalAsset $Path $RepositoryRoot
        if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { throw "Reference artifact missing: $absolute" }
        if (-not $pathsSeen.ContainsKey($absolute)) { $pathsSeen[$absolute]=$true; $files.Add([pscustomobject]@{path=ConvertTo-QualityAssetPath $absolute $RepositoryRoot;sha256=(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()}) }
    }
    & $fingerprint $ReportPath
    & $fingerprint $generationLog
    & $fingerprint $MediaPath
    & $fingerprint $FFmpegPath
    if ($reference.generation.graph) { & $fingerprint $reference.generation.graph }
    for ($index=0; $index -lt $frames.Count; $index++) {
        $frame = $frames[$index]
        if ($frame.keyframeIndex -ne 1 + $index * $SequenceRequest.keyframeStep) { throw 'Reference source keyframe ordinal differs from its retained sampling stride.' }
        $pattern = [string]$oldArguments[-1]
        $token = [regex]::Match($pattern,'%(?:0(\d+))?d')
        $digits = $(if ($token.Groups[1].Success) { 'D' + $token.Groups[1].Value } else { 'D' })
        $expectedImage = $pattern.Substring(0,$token.Index) + ($index+1).ToString($digits,[Globalization.CultureInfo]::InvariantCulture) + $pattern.Substring($token.Index+$token.Length)
        if ((Resolve-QualityLocalAsset $frame.image $RepositoryRoot) -ne (Resolve-QualityLocalAsset $expectedImage $RepositoryRoot)) { throw 'Reference image path does not correspond to its generation output pattern and frame number.' }
        if ($frame.width -ne $Clip.expected.width -or $frame.height -ne $Clip.expected.height -or $frame.signedGain -ne $SignedGain -or $frame.absoluteDisplayGain -ne 8) { throw 'Reference native dimensions or per-frame gains differ.' }
        foreach ($name in @('psnrY','psnrU','psnrV','psnrAvg','psnrChroma')) { if ($frame.metrics.$name -ne 'inf') { throw 'Reference identity PSNR is inconsistent.' } }
        foreach ($name in @('maxAbsY','maxAbsU','maxAbsV','shareDifferentY','shareDifferentU','shareDifferentV')) { if ($frame.metrics.$name -ne 0) { throw 'Reference identity errors are inconsistent.' } }
        if ($frame.metrics.ssimAll -ne 1) { throw 'Reference identity SSIM is inconsistent.' }
        foreach ($name in @('image','diffSigned','diffAbsolute','diffAbsoluteDisplay')) { & $fingerprint $frame.$name }
        if (@($frame.analysisLogPaths).Count -ne 3) { throw 'Reference requires all three completed analysis invocation logs.' }
        $kinds = @{}
        foreach ($log in $frame.analysisLogPaths) {
            $path = Resolve-QualityLocalAsset $log.Log $RepositoryRoot
            $text = Assert-QualityCompletedLog $path
            $name = [IO.Path]::GetFileName($path)
            if ($name -notin @('ffmpeg-metrics.txt','ffmpeg-signed-difference.txt','ffmpeg-absolute-difference.txt') -or $kinds.ContainsKey($name)) { throw 'Reference analysis requires one distinct metrics, signed-difference and absolute-difference log.' }
            $kinds[$name] = $true
            $command = [regex]::Match($text,'Command line \(Windows PowerShell\):\r?\n([^\r\n]+)').Groups[1].Value
            $image = Resolve-QualityLocalAsset $frame.image $RepositoryRoot
            $renderedInput = & (Get-Module FFmpeg) { param($inputPath) (@(foreach ($value in @('-i', $inputPath)) { ConvertTo-WindowsArgument $value }) -join ' ') } $image
            if ($command.StartsWith('& { ')) { $renderedInput = $renderedInput.Replace("'", "''") }
            $inputPattern = [regex]::Escape($renderedInput)
            if ([regex]::Matches($command,$inputPattern).Count -ne 2 -or -not $text.Contains('FFmpeg executable: ' + $FFmpegPath)) { throw 'Reference analysis command must use the fixed stock executable and the corresponding identical PNG twice.' }
            switch ($name) {
                'ffmpeg-metrics.txt' {
                    if ($text -notmatch 'PSNR y:inf u:inf v:inf average:inf' -or $text -notmatch 'SSIM Y:1\.000000.*All:1\.000000' -or -not $text.Contains('format=yuv444p,setparams=range=pc:colorspace=bt709') -or -not $text.Contains('blend=all_mode=difference')) { throw 'Reference metric log does not prove its completed identity comparison in the stated analysis format.' }
                }
                'ffmpeg-signed-difference.txt' {
                    if (-not $text.Contains('blend=all_mode=grainextract') -or -not $command.Contains((Resolve-QualityLocalAsset $frame.diffSigned $RepositoryRoot))) { throw 'Reference signed command does not match its display asset.' }
                    foreach ($plane in @('y','u','v')) { if (-not $text.Contains(($plane + "='clip(128+" + $SignedGain + "*(val-128),0,255)'"))) { throw 'Reference signed gain differs on an analysis plane.' } }
                }
                'ffmpeg-absolute-difference.txt' {
                    if (-not $text.Contains('format=gbrp[r]') -or -not $text.Contains('blend=all_mode=difference') -or -not $command.Contains((Resolve-QualityLocalAsset $frame.diffAbsolute $RepositoryRoot)) -or -not $command.Contains((Resolve-QualityLocalAsset $frame.diffAbsoluteDisplay $RepositoryRoot))) { throw 'Reference absolute command does not match exact RGB subtraction and both display assets.' }
                    foreach ($plane in @('r','g','b')) { if (-not $text.Contains(($plane + "='min(255,val*8)'"))) { throw 'Reference absolute display gain differs on an RGB plane.' } }
                }
            }
            & $fingerprint $path
            if ($log.Graph) { & $fingerprint $log.Graph }
        }
    }
    $proof = [pscustomobject][ordered]@{
        sourceRunId=$Report.runId; referenceReport=ConvertTo-QualityAssetPath $ReportPath $RepositoryRoot
        referenceReportSha256=(Get-FileHash -LiteralPath $ReportPath -Algorithm SHA256).Hash.ToLowerInvariant()
        stockBinarySha256=$binaryHash; sourceSha256=$mediaHash; sequenceRequest=$SequenceRequest
        frameCount=$frames.Count; generatedFrameCount=$generatedFrameCount; signedGain=$SignedGain; absoluteDisplayGain=8; freshGeneration=$false
        files=@($files.ToArray()); checkedBeforeUtc=[DateTime]::UtcNow.ToString('o'); checkedAfterUtc=$null
    }
    return [pscustomobject]@{Reference=$reference;Frames=$actualFrames;Proof=$proof}
}

Export-ModuleMember -Function Get-QualityNativeRenderingFailure, Assert-QualityNativeRenderingSucceeded, Get-QualityReportWithInvalidReferences, Get-QualityAnalysisContract, ConvertTo-QualityAssetPath, Get-QualitySelectedFrames, Complete-QualityImageSampling, Assert-QualityFrameAlignment, Invoke-QualityFrameAnalysis, Write-QualityReportFile, Resolve-QualityLocalAsset, Assert-QualityCompletedLog, Assert-QualityReferenceFingerprints, Get-QualityReusableReference
