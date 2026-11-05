#Requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'FFmpeg.psm1')
Import-Module (Join-Path $PSScriptRoot 'Quality.psm1')

function Get-PipelineProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Format-PipelineNumber {
    param([double]$Value)
    return $Value.ToString('0.############', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-PipelineFilterOptions {
    param([object]$Implementation, [object]$Clip, [object]$Configuration)
    $options = [ordered]@{}
    foreach ($property in $Implementation.filterOptions.PSObject.Properties) { $options[$property.Name] = $property.Value }
    $typeOptions = Get-PipelineProperty (Get-PipelineProperty $Implementation 'toneMappingOptions') $Clip.toneMappingType
    if ($null -ne $typeOptions) {
        foreach ($property in $typeOptions.PSObject.Properties) { $options[$property.Name] = $property.Value }
    }
    if ($options.Contains('apply_dovi')) { $options['apply_dovi'] = $(if ($Clip.toneMappingType -eq 'dovi-p5') { 1 } else { 0 }) }
    if ($options.Contains('apply_hdr10p')) { $options['apply_hdr10p'] = $(if ($Clip.toneMappingType -eq 'hdr10plus') { 1 } else { 0 }) }
    # The supplied CPU embytonemap exposes native NV12/YUV420P outputs but does
    # not implement the GPU family's format AVOption. Verify its native choice.
    if ($Implementation.filter -eq 'embytonemap' -and $options.Contains('format')) { $options.Remove('format') }
    return $options
}

function ConvertTo-PipelineFilter {
    param([string]$Name, [Collections.IDictionary]$Options)
    $parts = @(foreach ($key in $Options.Keys) {
        $value = $Options[$key]
        if ($value -is [double] -or $value -is [single] -or $value -is [decimal]) { $value = Format-PipelineNumber ([double]$value) }
        '{0}={1}' -f $key, $value
    })
    if ($parts.Count -eq 0) { return $Name }
    return $Name + '=' + ($parts -join ':')
}

function New-SuiteFFmpegArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Implementation,
        [Parameter(Mandatory = $true)][object]$Clip,
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][ValidateSet('performance-isolated', 'performance-transcode', 'quality')][string]$TestType,
        [Parameter(Mandatory = $true)][string]$MediaPath,
        [ValidateRange(0, [int]::MaxValue)][int]$FrameCount = 0,
        [ValidateRange(1, 1000)][int]$KeyframeLimit = 30,
        [ValidateRange(0, 30)][int]$KeyframeStep = 0,
        [double]$SeekSeconds = [double]::NaN,
        [double]$DurationSeconds = [double]::NaN,
        [string]$OutputPath,
        [switch]$Baseline,
        [switch]$SmokeTest,
        [switch]$DoviMetadataLoop,
        [ValidateRange(1, 100)][int]$DoviKeyframeStride = 5
    )
    if ((Get-PipelineProperty $Implementation 'pipelineStatus') -eq 'blocked') { throw [string](Get-PipelineProperty $Implementation 'pipelineBlocker') }
    if (@($Implementation.toneMappingTypes) -notcontains $Clip.toneMappingType) {
        throw "Implementation '$($Implementation.id)' does not support '$($Clip.toneMappingType)'."
    }
    if (@($Implementation.testTypes) -notcontains $TestType) { throw "Implementation '$($Implementation.id)' does not support '$TestType'." }
    if (-not [IO.Path]::IsPathRooted($MediaPath)) { throw 'MediaPath must be absolute.' }
    if ($Baseline -and $TestType -eq 'quality') { throw 'Quality output cannot be a baseline without tone mapping.' }
    if ([double]::IsNaN($SeekSeconds)) {
        $configuredSeek = if ($TestType -eq 'quality') { Get-PipelineProperty $Clip 'qualitySeekSeconds' } elseif ($TestType -eq 'performance-transcode' -or $Clip.toneMappingType -ne 'dovi-p5') { $performanceSeek = Get-PipelineProperty $Clip 'performanceSeekSeconds'; if ($null -ne $performanceSeek) { $performanceSeek } else { 0.0 } } else { $null }
        if ($null -eq $configuredSeek) { $configuredSeek = Get-PipelineProperty $Clip 'seekSeconds' }
        $SeekSeconds = if ($null -ne $configuredSeek) { [double]$configuredSeek } else { 0.0 }
    }
    if ([double]::IsInfinity($SeekSeconds) -or $SeekSeconds -lt 0) { throw 'SeekSeconds must be finite and nonnegative.' }
    if ([double]::IsNaN($DurationSeconds)) { $DurationSeconds = [double]$Configuration.benchmark.transcodeDurationSeconds }
    if ([double]::IsInfinity($DurationSeconds) -or $DurationSeconds -le 0) { throw 'DurationSeconds must be finite and positive.' }
    $knownDuration = Get-PipelineProperty $Clip 'durationSeconds'
    $actualDuration = $DurationSeconds
    if ($null -ne $knownDuration -and [double]$knownDuration -gt 0) {
        $remaining = [double]$knownDuration - $SeekSeconds
        if ($remaining -le 0) { throw 'SeekSeconds reaches or exceeds the known clip duration.' }
        $actualDuration = [Math]::Min($DurationSeconds, $remaining)
    }
    if ($TestType -eq 'performance-isolated' -and $FrameCount -eq 0) { $FrameCount = 1000 }
    if ($KeyframeStep -eq 0) {
        $configuredStep = Get-PipelineProperty $Clip 'qualityKeyframeStep'
        $KeyframeStep = if ($null -ne $configuredStep) { [int]$configuredStep } elseif ($Clip.toneMappingType -eq 'hdr10') { 5 } else { 3 }
        if ($KeyframeStep -lt 1 -or $KeyframeStep -gt 30) { throw 'Configured qualityKeyframeStep must be between 1 and 30.' }
    }
    if ($TestType -eq 'quality' -and $FrameCount -eq 0) { $FrameCount = $KeyframeLimit }
    # A bounded four-frame GPU smoke must exercise the hardware loop itself.
    if ($SmokeTest -and -not $PSBoundParameters.ContainsKey('FrameCount')) { $FrameCount = 1 }
    if ($SmokeTest -and ($FrameCount -lt 1 -or $FrameCount -gt 8)) { throw 'Smoke tests require one to eight frames.' }
    if ($TestType -eq 'performance-isolated' -and $FrameCount -lt 1) { throw 'Isolated tests require at least one output frame.' }
    if ($DoviMetadataLoop) {
        if ($TestType -ne 'performance-isolated' -or $Clip.toneMappingType -ne 'dovi-p5' -or $SmokeTest -or $Baseline) { throw 'The Dolby Vision metadata loop requires an isolated profile-5 mapper run.' }
        if ($FrameCount % 160 -ne 0) { throw 'The Dolby Vision metadata loop requires a whole number of 160-frame passes.' }
    }

    $arguments = New-Object 'Collections.Generic.List[string]'
    foreach ($argument in @('-hide_banner', '-nostdin', '-y', '-loglevel', $(if ($SmokeTest) { 'verbose' } else { 'info' }), '-nostats', '-progress', 'pipe:1')) { $arguments.Add($argument) }
    if (-not $SmokeTest -and $TestType -ne 'quality') { $arguments.Add('-benchmark') }
    $arguments.Add('-filter_complex_threads'); $arguments.Add([string]$Configuration.benchmark.filterThreads)
    $backend = $Implementation.backend
    $baseImplementationId = Get-PipelineProperty $Implementation 'catalogImplementationId'
    if (-not $baseImplementationId) { $baseImplementationId = $Implementation.id }
    $hardwareMapper = $backend -in @('cuda', 'opencl', 'vulkan')
    $hardwareTranscode = $hardwareMapper -and $TestType -eq 'performance-transcode'
    $hardwareIsolated = $hardwareMapper -and $TestType -eq 'performance-isolated'
    $amdOpenclTranscode = $backend -eq 'opencl' -and $hardwareTranscode -and $Configuration.devices.opencl.vendor -eq 'amd'
    $embyAmfTranscode = $amdOpenclTranscode -and $Implementation.source -eq 'emby'
    $decodeMode = 'software-original-bitstream'; $decoder = 'software-auto'
    $decodeFrameFormat = [string]$Clip.expected.pixelFormat
    $deviceArguments = New-Object 'Collections.Generic.List[string]'
    $deviceArgument = $null
    if ($backend -eq 'vulkan') { $deviceArgument = 'vulkan=tmdevice:' + $Configuration.devices.vulkan }
    elseif ($backend -eq 'cuda') { $deviceArgument = 'cuda=tmdevice:' + $Configuration.devices.cuda }
    elseif ($backend -eq 'opencl' -and $hardwareTranscode) {
        if ($Configuration.devices.opencl.vendor -notin @('intel', 'amd', 'any')) { throw 'No verified Windows GPU-only decode/OpenCL-map/scale/encode route exists for the selected OpenCL vendor; software transfers are not a fallback.' }
        # Vendor selection is independent of the global DXGI adapter index.
        $vendorId = if ($amdOpenclTranscode) { '0x1002' } else { '0x8086' }
        $adapter = Get-PipelineProperty $Configuration.devices 'd3d11Adapter'
        if ($amdOpenclTranscode -and $null -ne $adapter) { $deviceArguments.Add('d3d11va=source:' + $adapter) }
        else { $deviceArguments.Add('d3d11va=source:,vendor_id=' + $vendorId) }
        if (-not $amdOpenclTranscode) { $deviceArguments.Add('qsv=encoder@source') }
        if ($embyAmfTranscode) { $deviceArguments.Add('amf=amf@source'); $deviceArgument = 'opencl=tmdevice@amf' }
        else { $deviceArgument = 'opencl=tmdevice@source' }
    }
    elseif ($backend -eq 'opencl') {
        $opencl = $Configuration.devices.opencl
        if ($null -ne $opencl.platform -and $null -ne $opencl.device) {
            $deviceArgument = 'opencl=tmdevice:' + $opencl.platform + '.' + $opencl.device + ',device_type=gpu'
        }
        else {
            $deviceArgument = 'opencl=tmdevice:,device_type=gpu'
            $vendorNames = @{ intel = 'Intel'; amd = 'Advanced Micro Devices'; nvidia = 'NVIDIA' }
            if ($opencl.vendor -ne 'any') { $deviceArgument += ',device_vendor=' + $vendorNames[$opencl.vendor] }
        }
    }
    if ($null -ne $deviceArgument) {
        foreach ($initialization in $deviceArguments) { $arguments.Add('-init_hw_device'); $arguments.Add($initialization) }
        $arguments.Add('-init_hw_device'); $arguments.Add($deviceArgument)
        $arguments.Add('-filter_hw_device'); $arguments.Add('tmdevice')
    }
    if ($hardwareTranscode) {
        if ($backend -eq 'cuda') {
            $decodeMode = 'hardware-cuda-original-bitstream'; $decoder = [string]$Clip.expected.codecName; $decodeFrameFormat = 'cuda'
            foreach ($argument in @('-hwaccel', 'cuda', '-hwaccel_device', 'tmdevice', '-hwaccel_output_format', 'cuda', '-c:v', $decoder)) { $arguments.Add($argument) }
        }
        elseif ($backend -eq 'vulkan') {
            # Vulkan Video decode, processing and encode use the same selected
            # device. Missing codec/device extensions must block in preflight;
            # no D3D11/CUDA interop or host-transfer fallback is substituted.
            $decodeMode = 'hardware-vulkan-original-bitstream'; $decoder = [string]$Clip.expected.codecName; $decodeFrameFormat = 'vulkan'
            foreach ($argument in @('-hwaccel', 'vulkan', '-hwaccel_device', 'tmdevice', '-hwaccel_output_format', 'vulkan', '-c:v', $decoder, '-extra_hw_frames', '16')) { $arguments.Add($argument) }
        }
        elseif ($Implementation.source -eq 'emby' -and -not $amdOpenclTranscode) {
            # Native HEVC/D3D11 decoding in the supplied Emby build crashes on
            # the tested Intel driver. Its QSV decoder is a separate explicit
            # route, subject to its known source limitations and native mapper
            # metadata-application evidence from the processing smoke.
            $decodeMode = 'hardware-qsv-original-bitstream'; $decoder = [string]$Clip.expected.codecName + '_qsv'; $decodeFrameFormat = 'qsv'
            foreach ($argument in @('-hwaccel', 'qsv', '-hwaccel_device', 'encoder', '-hwaccel_output_format', 'qsv', '-c:v', $decoder, '-extra_hw_frames', '16')) { $arguments.Add($argument) }
        }
        else {
            $decodeMode = 'hardware-d3d11-original-bitstream'; $decoder = [string]$Clip.expected.codecName; $decodeFrameFormat = 'd3d11'
            foreach ($argument in @('-hwaccel', 'd3d11va', '-hwaccel_device', 'source', '-hwaccel_output_format', 'd3d11', '-c:v', $decoder, '-extra_hw_frames', $(if ($embyAmfTranscode) { '8' } else { '16' }))) { $arguments.Add($argument) }
        }
    }
    if ($SeekSeconds -gt 0) { $arguments.Add('-ss'); $arguments.Add((Format-PipelineNumber $SeekSeconds)) }
    if ($TestType -eq 'quality' -or $DoviMetadataLoop) { $arguments.Add('-skip_frame'); $arguments.Add('nokey') }
    # Quality asks the native decoder for keyframes, then bounds PNG extraction
    # by frame count. Disk sampling happens only after successful generation.
    $arguments.Add('-i'); $arguments.Add($MediaPath)

    $before = New-Object 'Collections.Generic.List[string]'
    $after = New-Object 'Collections.Generic.List[string]'
    if ($DoviMetadataLoop) { $before.Add("select='not(mod(n," + $DoviKeyframeStride + "))'") }
    # Native decoder frames enter the mapper without diagnostic wrappers.
    $decodedFormat = [string]$Clip.expected.pixelFormat
    if ($decodedFormat -notmatch '^[a-z0-9]+$') { throw 'The manifest must specify a valid decoded pixel format.' }
    $inputFormat = 'p010le'; $outputFormat = 'nv12'; $baselineMeaningful = $true
    $inputNominalPeakNits = $null
    $options = Get-PipelineFilterOptions -Implementation $Implementation -Clip $Clip -Configuration $Configuration
    if ($TestType -eq 'quality' -and $Implementation.filter -eq 'scale') {
        $flags = if ($options.Contains('flags')) { [string]$options['flags'] } else { '' }
        if ($flags -notmatch '(?:^|[+\-])accurate_rnd(?:$|[+\-])') { $options['flags'] = $flags + '+accurate_rnd' }
    }
    $mapper = ConvertTo-PipelineFilter -Name $Implementation.filter -Options $options
    if ($Implementation.filter -eq 'embytonemap') {
        $inputFormat = $decodedFormat; $outputFormat = 'nv12'; $baselineMeaningful = $false
        $mapper = ConvertTo-PipelineFilter -Name $Implementation.filter -Options $options
        if ($Baseline) { $mapper = 'null' }
    }
    elseif ($hardwareTranscode) {
        if ($backend -eq 'opencl') {
            $bgraMapper = $Implementation.filter -eq 'supertonemap_opencl'
            if ($bgraMapper) { $before.Add('vpp_qsv=format=bgra') }
            if ($embyAmfTranscode) { foreach ($step in @('hwmap=derive_device=amf', 'format=amf', 'vpp_amf=format=p010', 'format=amf', 'hwmap=derive_device=opencl')) { $before.Add($step) } }
            else { $before.Add('hwmap=derive_device=opencl:mode=read+direct') }
            # Any filter between this map and the mapper makes Jellyfin's AMD
            # mapping reject the decoder pool as not fixed-size.
            if (-not $amdOpenclTranscode) { $before.Add('format=opencl') }
            if ($bgraMapper) { $before.Add('setparams=colorspace=bt2020nc') }
        }
        elseif ($backend -eq 'vulkan') { $inputFormat = 'p010le' }
        if ($Baseline) { $mapper = 'null' }
    }
    elseif ($Implementation.filter -eq 'libplacebo' -and $backend -eq 'vulkan') {
        $inputFormat = $decodedFormat
        # The stock quality reference keeps its proven implicit GPU import and
        # PNG output. The Emby performance identity prepares P010 once before
        # the resident GPU loop; its source is selected by the catalog/config.
        if ($hardwareIsolated) {
            $inputFormat = 'p010le'
            if ($decodedFormat -ne 'p010le') { $before.Add('format=p010le') }
            $before.Add('hwupload')
            # wrapped_avframe accepts either host or GPU frames. Restrict
            # negotiation so libplacebo cannot download its measured output.
            $after.Add('format=vulkan')
            if ($Baseline) { $mapper = 'null' }
        } elseif ($Baseline) { $mapper = 'format=nv12' }
    }
    else { switch ($baseImplementationId) {
        'emby-embytonemap-vulkan' {
            # The native Vulkan implementation accepts only P010-backed
            # hardware images. Convert once before upload and repetition.
            $inputFormat = 'p010le'
            if ($decodedFormat -ne 'p010le') { $before.Add('format=p010le') }
            $before.Add('hwupload')
            if ($Baseline) { $mapper = 'null' }
            if ($TestType -eq 'quality') {
                $after.Add('hwdownload'); $after.Add($(if ($Baseline) { 'format=' + $decodedFormat } else { 'format=nv12' }))
            }
        }
        'stock-swscale' {
            $inputFormat = $decodedFormat; $outputFormat = 'yuv420p'; $baselineMeaningful = $false
            if ($Baseline) { $mapper = 'null' }
            $after.Add('format=yuv420p')
        }
        'stock-tonemap' {
            $inputFormat = 'gbrpf32le'; $outputFormat = 'yuv420p'
            $nominalWhite = 203
            $inputNominalPeakNits = $nominalWhite
            $before.Add('zscale=t=linear:npl=' + $nominalWhite)
            $before.Add('format=gbrpf32le'); $before.Add('zscale=p=bt709')
            if ($Baseline) { $mapper = 'null' }
            $after.Add('zscale=t=bt709:m=bt709:r=limited'); $after.Add('format=yuv420p')
        }
        'jellyfin-tonemapx' {
            $inputFormat = 'yuv420p10le'; $outputFormat = 'yuv420p'
            if ($decodedFormat -ne 'yuv420p10le') { $before.Add('format=yuv420p10le') }
            if ($Baseline) { $mapper = 'format=yuv420p' }
        }
        'plex-tonemap' {
            # Plex's integer PQ mapper requires P010 and returns native NV12.
            $inputFormat = 'p010le'; $outputFormat = 'nv12'
            if ($decodedFormat -ne 'p010le') { $before.Add('format=p010le') }
            if ($Baseline) { $mapper = 'format=nv12' }
        }
        'emby-supertonemap-opencl' {
            $inputFormat = 'bgra'
            # The filter asserts a BT.2020 or BT.709 input matrix; the BGRA conversion tags RGB.
            $before.Add('format=bgra'); $before.Add('setparams=colorspace=bt2020nc'); $before.Add('hwupload')
            $options['format'] = 'bgra'
            $mapper = ConvertTo-PipelineFilter -Name $Implementation.filter -Options $options
            if ($Baseline) { $mapper = 'null' }
            if (-not $hardwareIsolated) { $after.Add('hwdownload'); $after.Add('format=bgra'); $after.Add('format=nv12') }
        }
        default {
            $convertToP010 = $decodedFormat -ne 'p010le'
            if ($convertToP010) { $before.Add('format=p010le') }
            if ($backend -eq 'cuda') { $before.Add('hwupload_cuda') }
            elseif ($backend -eq 'opencl') { $before.Add('hwupload') }
            if ($Baseline) { $mapper = $(if ($backend -eq 'software' -or $backend -eq 'vulkan') { 'format=nv12' } else { 'null' }) }
            if ($hardwareMapper -and -not $hardwareIsolated) {
                $after.Add('hwdownload'); $after.Add($(if ($Baseline) { 'format=p010le' } else { 'format=nv12' }))
                if ($Baseline) { $after.Add('format=nv12') }
            }
            elseif (-not $hardwareIsolated) { $after.Add('format=nv12') }
        }
    } }
    if ($DoviMetadataLoop) {
        # Eight prepared scene frames stay on their mapper's device. fps
        # repeats each AVFrame twenty times before caching the 160-frame pass.
        $before.Add('settb=1/24'); $before.Add('setpts=N*20'); $before.Add('fps=24')
        $before.Add('loop=loop=-1:size=160:start=0')
    }
    elseif ($TestType -eq 'performance-isolated' -and $FrameCount -gt 1) {
        # Cache frames after required input preparation. Hardware upload and
        # software linearization/format conversion occur before repetition.
        $before.Add('loop=loop=' + ($FrameCount - 1) + ':size=1:start=0')
    }
    $graph = @($before.ToArray()) + @($mapper)
    $graph += @($after.ToArray())
    if ($hardwareTranscode -and $backend -eq 'opencl') {
        # Reverse mapping immediately after the mapper propagates ownership of
        # its output surfaces. Stock OpenCL has no direct Windows QSV
        # interop: allocate D3D11 surfaces, then map those surfaces to QSV.
        if ($embyAmfTranscode) {
            $graph += @('hwmap=derive_device=amf', 'format=amf')
        } elseif ($amdOpenclTranscode) {
            $graph += @('hwmap=derive_device=d3d11va:reverse=1:mode=write+direct:extra_hw_frames=16', 'format=d3d11')
        } elseif ($Implementation.source -in @('stock', 'plex')) {
            $graph += @('hwmap=derive_device=d3d11va:reverse=1:mode=write+direct:extra_hw_frames=16', 'format=d3d11', 'hwmap=derive_device=qsv:mode=read+direct', 'format=qsv')
        } else {
            $graph += @('hwmap=derive_device=qsv:reverse=1:mode=write+direct:extra_hw_frames=16', 'format=qsv')
        }
    }
    $encoder = 'wrapped_avframe'; $encodingMode = 'none'
    $scaler = $null
    # One mapper per decoded frame leaves hardware transcodes limited by the
    # decoder. Repeat each decoded frame before any interop map and keep one
    # of the repeats before the scaler, so that only map, tone mapping and
    # map back run per repeat. Reverse maps need the mapper's own surfaces.
    $transcodeRepeats = if ($hardwareTranscode -and -not $Baseline) { 5 } else { 1 }
    if ($hardwareTranscode) {
        $outputFormat = 'nv12'
        if ($transcodeRepeats -gt 1) { $graph = @('fps=source_fps*' + $transcodeRepeats) + $graph + @('fps=source_fps/' + $transcodeRepeats) }
        if ($backend -eq 'cuda') {
            $scaler = 'scale_cuda'
            $graph += 'scale_cuda=w=-2:h=720:interp_algo=bilinear:format=nv12'
            $encoder = 'h264_nvenc'; $encodingMode = 'hardware-nvenc'
        }
        elseif ($backend -eq 'vulkan') {
            $scaler = 'scale_vulkan'
            $width720 = 2 * [int][Math]::Round(([double]$Clip.expected.width * 720.0 / [double]$Clip.expected.height) / 2.0)
            $graph += ('scale_vulkan=w=' + $width720 + ':h=720:format=nv12')
            $encoder = 'h264_vulkan'; $encodingMode = 'hardware-vulkan'
        }
        elseif ($amdOpenclTranscode) {
            $width720 = 2 * [int][Math]::Round(([double]$Clip.expected.width * 720.0 / [double]$Clip.expected.height) / 2.0)
            if ($embyAmfTranscode) { $scaler = 'vpp_amf'; $graph += ('vpp_amf=w=' + $width720 + ':h=720') }
            else { $scaler = 'scale_d3d11'; $graph += ('scale_d3d11=width=' + $width720 + ':height=720:format=nv12') }
            $encoder = 'h264_amf'; $encodingMode = 'hardware-amf'
        } else {
            $scaler = 'scale_qsv'
            # QSV accepts -1 for aspect ratio, but not scale's -2 convention.
            $width720 = 2 * [int][Math]::Round(([double]$Clip.expected.width * 720.0 / [double]$Clip.expected.height) / 2.0)
            $graph += ('scale_qsv=w=' + $width720 + ':h=720:format=nv12:mode=low_power')
            $encoder = 'h264_qsv'; $encodingMode = 'hardware-qsv'
        }
    }
    elseif ($TestType -eq 'performance-transcode') {
        $graph += @('scale=w=-2:h=720:flags=fast_bilinear', 'format=yuv420p')
        $encoder = 'libx264'; $encodingMode = 'software-libx264'; $outputFormat = 'yuv420p'; $scaler = 'scale'
    }
    elseif ($TestType -eq 'quality') {
        $graph += @('scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=+accurate_rnd', 'format=rgb24')
        $outputFormat = 'rgb24'; $encoder = 'png'; $encodingMode = 'png-keyframes'
    }
    $filterGraph = ($graph -join ',') + '[mapped]'
    $filterGraphArgument = '-filter_complex'
    $sink = if ($hardwareIsolated) { 'GPU wrapped_avframe to null muxer; no pixel encode or download.' } elseif ($TestType -eq 'performance-isolated') { 'Software wrapped_avframe to null muxer.' } else { 'encoded output' }
    if ($backend -ne 'software') { $baselineMeaningful = $false }
    $arguments.Add($filterGraphArgument); $arguments.Add($filterGraph)
    foreach ($argument in @('-map', '[mapped]', '-an', '-sn', '-dn')) { $arguments.Add($argument) }
    if ($TestType -eq 'performance-transcode') { $arguments.Add('-t'); $arguments.Add((Format-PipelineNumber $actualDuration)) }
    if ($FrameCount -gt 0) { $arguments.Add('-frames:v'); $arguments.Add([string]$FrameCount) }
    if ($TestType -eq 'quality') { $arguments.Add('-fps_mode'); $arguments.Add('passthrough') }
    $arguments.Add('-c:v'); $arguments.Add($encoder)
    if ($hardwareTranscode -and $backend -eq 'cuda') {
        foreach ($argument in @('-preset', 'p1', '-tune', 'ull', '-rc', 'constqp', '-qp', '23', '-bf', '0')) { $arguments.Add($argument) }
    }
    elseif ($hardwareTranscode -and $backend -eq 'vulkan') {
        foreach ($argument in @('-rc_mode', 'cqp', '-qp', '23', '-tune', 'ull', '-usage', 'transcode', '-bf', '0')) { $arguments.Add($argument) }
    }
    elseif ($amdOpenclTranscode) {
        foreach ($argument in @('-usage', 'ultralowlatency', '-quality', 'speed', '-rc', 'cqp', '-qp_i', '23', '-qp_p', '23', '-bf', '0')) { $arguments.Add($argument) }
    }
    elseif ($hardwareTranscode) {
        foreach ($argument in @('-preset', 'veryfast', '-look_ahead', '0', '-global_quality', '23', '-bf', '0')) { $arguments.Add($argument) }
    }
    elseif ($TestType -eq 'performance-transcode') {
        foreach ($argument in @('-preset', 'ultrafast', '-crf', '23', '-tune', 'zerolatency', '-pix_fmt', 'yuv420p')) { $arguments.Add($argument) }
    }
    if ($SmokeTest -or $TestType -eq 'performance-isolated') {
        $arguments.Add('-f'); $arguments.Add('null'); $arguments.Add('-')
    }
    else {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw "OutputPath is required for $TestType." }
        if (-not [IO.Path]::IsPathRooted($OutputPath)) { throw 'OutputPath must be absolute.' }
        if ($TestType -eq 'quality' -and $OutputPath -notmatch '%(?:0\d+)?d') { throw 'Quality OutputPath must include a numbered image pattern such as %06d.png.' }
        $arguments.Add('-f'); $arguments.Add($(if ($TestType -eq 'quality') { 'image2' } else { 'matroska' })); $arguments.Add($OutputPath)
    }
    return [pscustomobject][ordered]@{
        Arguments = [string[]]$arguments.ToArray(); FilterGraph = $filterGraph; Backend = $backend
        InputFormat = $inputFormat; OutputFormat = $outputFormat; DecodeMode = $decodeMode
        ActualDurationSeconds = $(if ($TestType -eq 'performance-transcode') { $actualDuration } else { $null })
        EncodingMode = $encodingMode; Encoder = $encoder
        Settings = [pscustomobject][ordered]@{
            ImplementationId = $Implementation.id; Source = $Implementation.source; TestType = $TestType
            ToneMappingType = $Clip.toneMappingType
            IsolatedMethod = $(if ($DoviMetadataLoop) { 'dovi-eight-state' } elseif ($TestType -eq 'performance-isolated') { 'single-frame' } else { $null })
            IsolatedStates = $(if ($DoviMetadataLoop) { 8 } elseif ($TestType -eq 'performance-isolated') { 1 } else { $null })
            IsolatedRepetitionsPerState = $(if ($DoviMetadataLoop) { 20 } else { $null })
            IsolatedKeyframeStride = $(if ($DoviMetadataLoop) { $DoviKeyframeStride } else { $null })
            Curve = Get-PipelineProperty $Implementation 'comparisonCurve'
            KeyframeLimit = $(if ($TestType -eq 'quality') { $KeyframeLimit } else { $null })
            KeyframeStep = $(if ($TestType -eq 'quality') { $KeyframeStep } else { $null })
            FrameSelection = $(if ($TestType -eq 'quality') { 'decoder-skip-non-key' } else { $null })
            ImageRetention = $(if ($TestType -eq 'quality') { 'Post-generation: retain first keyframe, then every Nth; rename consecutively.' } else { $null })
            FilterOptions = [pscustomobject]$options; FilterThreads = $Configuration.benchmark.filterThreads
            SeekSeconds = $SeekSeconds; RequestedDurationSeconds = $(if ($TestType -eq 'quality') { $null } else { $DurationSeconds }); ActualDurationSeconds = $(if ($TestType -eq 'performance-transcode') { $actualDuration } else { $null })
            FrameCount = $FrameCount; Baseline = [bool]$Baseline; BaselineMeaningful = $baselineMeaningful
            BaselineNote = 'Identity/format/device-transfer control; colour conversion cost cannot always be separated from the tone mapper. Baseline pixels are not SDR quality results.'
            Decoder = $decoder; DecodeMode = $decodeMode; DecoderFrameFormat = $decodeFrameFormat; Encoder = $encoder; EncodingMode = $encodingMode; Scaler = $scaler
            Sink = $sink; TranscodeRepeats = $(if ($TestType -eq 'performance-transcode') { $transcodeRepeats } else { $null }); FilterGraphArgument = $filterGraphArgument
            OutputFormatSelection = $(if ($Implementation.filter -eq 'embytonemap') { 'Native default NV12 output; actual format recorded by preflight. Supplied CPU interface has no format AVOption.' } else { 'Filter or required encoder conversion, recorded in the graph.' })
            GPUResident = [bool]($hardwareTranscode -or $hardwareIsolated)
            GPUResidency = $(if ($hardwareTranscode -and $transcodeRepeats -gt 1) { 'Hardware decode -> each frame repeated ' + $transcodeRepeats + 'x through GPU mapping -> one repeat kept -> GPU 720p scale -> hardware encode; no host transfer filters.' } elseif ($hardwareTranscode) { 'Hardware decode -> GPU mapper -> GPU 720p scale -> hardware encode; no host transfer filters.' } elseif ($hardwareIsolated) { 'Upload before GPU frame loop; mapper and wrapped_avframe/null muxer retain hardware AVFrames.' } elseif ($TestType -eq 'quality' -and $hardwareMapper) { 'Software native keyframe decode; GPU mapping; download for native PNG output.' } else { 'Software AVFrames; backend-specific processing recorded separately.' })
            MapperInputFrameFormat = $(if ($hardwareMapper -and ($TestType -ne 'quality' -or $Implementation.filter -eq 'embytonemap_vulkan')) { $backend } else { $inputFormat })
            MapperOutputFrameFormat = $(if ($hardwareMapper -and ($TestType -ne 'quality' -or $Implementation.filter -eq 'embytonemap_vulkan')) { $backend } else { $outputFormat })
            UploadPlacement = $(if ($hardwareIsolated) { 'Before loop' } elseif ($hardwareTranscode) { 'None' } elseif ($hardwareMapper) { 'Before mapper' } else { 'None' })
            InputPreparationPlacement = $(if ($DoviMetadataLoop) { 'Every Nth decoder keyframe is prepared/uploaded once; eight states repeat twenty times each before the 160-frame pass loops.' } elseif ($TestType -eq 'performance-isolated') { 'Before isolated loop; one prepared frame is repeated.' } else { 'Before mapper on decoded frames.' })
            IsolatedCostScope = $(if ($TestType -eq 'performance-isolated') { 'Mapper plus required output conversions and wrapped_avframe/null traversal; required input preparation precedes repetition.' } else { $null })
            RequiredOutputConversions = @($after.ToArray())
            HardwareDeviceChain = @($deviceArguments.ToArray()) + @($deviceArgument)
            DeviceArgument = $deviceArgument
            TargetRange = 'tv'; TargetPrimaries = 'bt709'; TargetTransfer = 'bt709'
            SDRReferenceWhiteNits = $null; SDRTargetPeakNits = $null
            InputNominalPeakNits = $inputNominalPeakNits
            ValidationLimitations = @('SDR reference white and target peak inherited from build; not proven matched.', 'Algorithms and gamut mapping differ across implementations.', 'Pinned source integrity and a real processing smoke do not prove individual frame metadata or exact temporal correspondence.')
        }
    }
}

$script:BinaryInspectionCache = @{}

function Get-PipelineVideoFailure {
    param([object]$Run)
    if ($Run.TimedOut) { return 'Process timeout.' }
    if ($Run.ExitCode -eq -1073741819) { return 'Hardware video processing access violation (0xC0000005).' }
    if ($Run.StdErr -match '__nv_atan2f') { return 'CUDA PTX linker cannot resolve __nv_atan2f in the supplied mapper.' }
    $details = [regex]::Matches($Run.StdErr, '(?m)^\[[^\r\n]*\]\s*((?:Only [^\r\n]*(?:supported|required)[^\r\n]*|Trying to map[^\r\n]*|Texture array index[^\r\n]*|Failed to (?:map|create|initialise|get address of)[^\r\n]*|Error creating a MFX session[^\r\n]*|Error applying option[^\r\n]*|[^\r\n]*No parameter sets in the extradata[^\r\n]*))')
    if ($details.Count -gt 0) { return $details[0].Groups[1].Value.Trim() }
    return 'No successfully validated video output; see captured filter/decoder/encoder diagnostics.'
}

function Get-PipelineBinaryInspection {
    param([string]$FilePath, [string]$WorkingDirectory)
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Configured FFmpeg executable is unavailable: $FilePath" }
    # Replaced executables can retain their old timestamp and length. Cache
    # capability evidence by the bytes we actually inspect, not file metadata.
    $binaryHash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $key = $FilePath + ':' + $binaryHash
    $externalCodecs = $null
    if ([IO.Path]::GetFileName($FilePath) -match '(?i)plex') {
        $externalCodecs = Get-PlexExternalCodecs -FilePath $FilePath
        if ($externalCodecs) { $key += ':' + $externalCodecs.manifestSha256 }
    }
    if ($script:BinaryInspectionCache.ContainsKey($key)) { return $script:BinaryInspectionCache[$key] }
    $text = @{}
    foreach ($kind in @('version', 'filters', 'decoders', 'encoders')) {
        $run = Invoke-FFmpegProcess -FilePath $FilePath -Arguments @('-hide_banner', ('-' + $kind)) -WorkingDirectory $WorkingDirectory -TimeoutSeconds 30
        if ($run.TimedOut -or $run.ExitCode -ne 0) { throw "FFmpeg $kind inspection failed." }
        $text[$kind] = $run.StdOut + "`n" + $run.StdErr
    }
    $filters = @(foreach ($line in ($text.filters -split '\r?\n')) { if ($line -match '^\s+[TSC.]{2,3}\s+(\S+)\s+\S+->\S+') { $Matches[1] } })
    $decoders = @(foreach ($line in ($text.decoders -split '\r?\n')) { if ($line -match '^\s*[VAS][A-Z.]{5}\s+(\S+)\s') { $Matches[1] } })
    $encoders = @(foreach ($line in ($text.encoders -split '\r?\n')) { if ($line -match '^\s*[VAS][A-Z.]{5}\s+(\S+)\s') { $Matches[1] } })
    $inspection = [pscustomobject]@{
        FilePath = $FilePath; Version = @($text.version -split '\r?\n' | Where-Object { $_ -match '^ffmpeg version' })[0]
        Sha256 = $binaryHash
        Filters = $filters; Decoders = $decoders; Encoders = $encoders
        ExternalCodecs = $externalCodecs
    }
    $script:BinaryInspectionCache[$key] = $inspection
    return $inspection
}

function Get-SuiteVideoStreamSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text, [ValidateSet('input', 'output')][string]$Direction = 'input')
    $heading = if ($Direction -eq 'input') { '(?m)^Input #0,' } else { '(?m)^Output #0,' }
    $start = [regex]::Match($Text, $heading)
    if (-not $start.Success) { return $null }
    $section = $Text.Substring($start.Index)
    $next = [regex]::Match($section.Substring($start.Length), '(?m)^(?:Input|Output) #|^Stream mapping:')
    if ($next.Success) { $section = $section.Substring(0, $start.Length + $next.Index) }
    $stream = [regex]::Match($section, '(?m)^\s*Stream #\d+:\d+[^\r\n]*?:\s*Video:\s*([^\s,]+)([^\r\n]*)')
    if (-not $stream.Success) { return $null }
    $line = $stream.Value.Trim()
    $format = [regex]::Match($line, ',\s*([a-z][a-z0-9_]*)(?:\(([^)]*)\))?,\s*(\d+)x(\d+)\b')
    $rate = [regex]::Match($line, '(?:,|\s)\s*(\d+(?:\.\d+)?)\s+fps\b')
    $range = $null; $space = $null; $primaries = $null; $transfer = $null; $chroma = $null
    if ($format.Success) {
        foreach ($tag in @($format.Groups[2].Value -split ',' | ForEach-Object { $_.Trim() })) {
            if ($tag -in @('tv', 'pc')) { $range = $tag }
            elseif ($tag -in @('left','center','topleft','top','bottomleft','bottom')) { $chroma = $tag }
            elseif ($tag -match '^(?:bt\d+[a-z]*|smpte\w*|arib\w*|gbr|rgb|unknown)(?:/[^\s]+)*$') {
                $colors = @($tag -split '/')
                $space = $colors[0]
                if ($colors.Count -eq 3) { $primaries = $colors[1]; $transfer = $colors[2] }
                elseif ($colors.Count -eq 1 -and $tag -in @('bt709','bt2020','unknown')) { $primaries = $tag; $transfer = $tag }
            }
        }
    }
    $profile = [regex]::Match($section, 'DOVI configuration record:[^\r\n]*?profile:\s*(\d+)')
    return [pscustomobject][ordered]@{
        evidence = 'Ordinary FFmpeg stream summary; not per-frame or metadata-delivery proof.'
        codecName = $stream.Groups[1].Value
        pixelFormat = $(if ($format.Success) { $format.Groups[1].Value } else { $null })
        width = $(if ($format.Success) { [int]$format.Groups[3].Value } else { $null })
        height = $(if ($format.Success) { [int]$format.Groups[4].Value } else { $null })
        colorRange = $range; colorSpace = $space; colorPrimaries = $primaries; colorTransfer = $transfer; chromaLocation = $chroma
        frameRate = $(if ($rate.Success) { [double]::Parse($rate.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) } else { $null })
        dolbyVisionProfile = $(if ($profile.Success) { [int]$profile.Groups[1].Value } else { $null })
        masteringDisplayMetadataAnnounced = [bool]($section -match 'Mastering display metadata')
        contentLightMetadataAnnounced = [bool]($section -match 'Content light level metadata')
        streamSummary = $line
    }
}
function Get-PipelineDeviceInfo {
    param([string]$Text, [object]$Pipeline, [object]$Configuration)
    $backend = $Pipeline.Backend
    if ($backend -eq 'software') { return [pscustomobject]@{ backend = $backend; vendor = 'software'; name = 'CPU'; verified = $true; evidence = 'Software pipeline.' } }
    $deviceName = $null
    if ($backend -eq 'vulkan') {
        $matchesFound = [regex]::Matches($Text, '(?m)^\[Vulkan[^\r\n]*\]\s*(?:Device \d+ selected:|Using device:)\s*([^\r\n]+)')
        if ($matchesFound.Count -gt 0) { $deviceName = $matchesFound[$matchesFound.Count - 1].Groups[1].Value.Trim() }
    }
    elseif ($backend -eq 'opencl') {
        $matchesFound = [regex]::Matches($Text, '(?m)^\[(?:OpenCL|AVHWDeviceContext)[^\r\n]*\]\s*\d+\.\d+:\s*([^\r\n]+)')
        $names = @($matchesFound | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)
        # OpenCL derived from AMF logs no platform/device line; it runs on the D3D11 device that AMF was derived from.
        if ($names.Count -eq 0 -and $Pipeline.Settings.DeviceArgument -eq 'opencl=tmdevice@amf') {
            $matchesFound = [regex]::Matches($Text, '(?m)^\[D3D11VA[^\r\n]*\]\s*Using device [0-9a-fA-F]{4}:[0-9a-fA-F]{4} \(([^\r\n]+)\)\.?\s*$')
            $names = @($matchesFound | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)
        }
        if ($names.Count -eq 1) { $deviceName = $names[0] }
    }
    elseif ($backend -eq 'cuda') {
        # A successful CUDA pipeline initializes NVIDIA's driver API; CUDA cannot
        # silently become an AMD/Intel device. Failures never reach this helper.
        return [pscustomobject]@{ backend = $backend; vendor = 'nvidia'; name = ('CUDA device ' + $Configuration.devices.cuda); verified = $true; evidence = 'Successful CUDA driver/device initialization and original-media mapping smoke.' }
    }
    $vendor = $null
    if ($deviceName -match 'NVIDIA|Quadro|GeForce|Tesla') { $vendor = 'nvidia' }
    elseif ($deviceName -match 'Advanced Micro Devices|\bAMD\b|Radeon') { $vendor = 'amd' }
    elseif ($deviceName -match 'Intel') { $vendor = 'intel' }
    return [pscustomobject]@{
        backend = $backend; vendor = $vendor; name = $deviceName
        verified = -not [string]::IsNullOrWhiteSpace($vendor)
        evidence = 'FFmpeg selected-device verbose log; adapter inventory order is not used.'
    }
}

function Get-PipelineKnownRouteFailure {
    param([string]$BinarySha256, [object]$Implementation, [object]$Clip, [string]$TestType)
    if ($BinarySha256 -ne 'c3ad270ec6997e218828f59ea732554e40a1bb4d4128e4df733ffbded2b11500') { return $null }
    if ($Implementation.backend -eq 'opencl' -and $TestType -eq 'performance-transcode' -and $Clip.toneMappingType -eq 'hdr10plus' -and $Clip.sha256 -eq '16ccad4a6fd19d3d3c72513a2c07a04a9ce3be71f5238d8e6bd3e058cfff0338') {
        return 'This supplied Emby binary/QSV decode route previously failed HDR10+ metadata delivery for the pinned Beverly Hills source. No replacement proof is available for that source; its known route remains blocked.'
    }
    if ($Implementation.filter -eq 'tonemap_cuda') { return 'This supplied legacy Emby CUDA mapper previously returned retained PQ/BT.2020 tags without verified SDR output controls; removing diagnostics does not validate that route.' }
    return $null
}

function Invoke-SuitePipelinePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Implementation,
        [Parameter(Mandatory = $true)][object]$Clip,
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$MediaPath,
        [string]$LogPathPrefix,
        [ValidateSet('performance-isolated', 'performance-transcode', 'quality')][string]$TestType = 'performance-isolated',
        [string]$WorkingDirectory,
        [switch]$SkipHashCheck
    )
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = $Configuration.repositoryRoot }
    $blockers = New-Object 'Collections.Generic.List[string]'
    $checks = New-Object 'Collections.Generic.List[object]'
    $pipeline = $null; $run = $null; $deviceInfo = $null; $inspection = $null; $mediaHash = $null
    $inputStream = $null; $outputStream = $null; $graphPath = $null; $metadataMessage = $null
    $smokeStarted = $false; $smokeChecked = $false
    try {
        if (-not $Clip.enabled) { throw 'Clip is a disabled candidate.' }
        if (@($Implementation.toneMappingTypes) -notcontains $Clip.toneMappingType) { throw 'The implementation does not support this signal.' }
        if ($Implementation.backend -eq 'software' -and $Configuration.exclude.software) { throw 'Software tests are excluded.' }
        if ($Implementation.backend -eq 'cuda' -and $Configuration.exclude.nvidia) { throw 'NVIDIA tests are excluded.' }
        if ($Implementation.backend -eq 'opencl' -and $Configuration.devices.opencl.vendor -ne 'any' -and $Configuration.exclude.($Configuration.devices.opencl.vendor)) { throw 'Configured OpenCL vendor is excluded.' }
        if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) { throw "Media is missing: $MediaPath. Run 01-DownloadTestMedia.cmd or import the configured local source." }
        if ([string]$Clip.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Clip has no valid pinned SHA-256.' }
        if (-not $SkipHashCheck) {
            $mediaHash = (Get-FileHash -LiteralPath $MediaPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($mediaHash -ne $Clip.sha256) { throw 'Media SHA-256 differs from the manifest; original bytes are required.' }
        } else { $mediaHash = $Clip.sha256 }
        $checks.Add([pscustomobject]@{ name = 'media-hash'; passed = $true; note = $(if ($SkipHashCheck) { 'Caller already checked original bytes for this group.' } else { 'Pinned SHA-256 matched original bytes.' }) })
        $filePath = [string]$Configuration.binaries.($Implementation.source).ffmpegPath
        $inspection = Get-PipelineBinaryInspection -FilePath $filePath -WorkingDirectory $WorkingDirectory
        # Removing instrumentation does not overturn already established failures.
        $knownFailure = Get-PipelineKnownRouteFailure -BinarySha256 $inspection.Sha256 -Implementation $Implementation -Clip $Clip -TestType $TestType
        if ($null -ne $knownFailure) { throw $knownFailure }
        $smokeFrames = if ($TestType -eq 'performance-isolated' -and $Implementation.backend -in @('cuda', 'opencl', 'vulkan')) { 4 } else { 1 }
        $pipeline = New-SuiteFFmpegArguments -Implementation $Implementation -Clip $Clip -Configuration $Configuration -MediaPath $MediaPath -TestType $TestType -FrameCount $smokeFrames -SmokeTest
        $hardwareTranscode = $TestType -eq 'performance-transcode' -and $Implementation.backend -in @('cuda', 'opencl', 'vulkan')
        $hardwareIsolated = $TestType -eq 'performance-isolated' -and $Implementation.backend -in @('cuda', 'opencl', 'vulkan')
        $neededFilters = @([regex]::Matches($pipeline.FilterGraph, '(?:^|[,;])(?:\[[^\]]+\])*([a-z0-9_]+)(?:@[a-z0-9_]+)?(?=[=,;\[]|$)') | ForEach-Object { $_.Groups[1].Value })
        foreach ($filter in @($neededFilters | Select-Object -Unique)) { if ($inspection.Filters -notcontains $filter) { throw "Binary is missing required filter '$filter'." } }
        $requiredDecoder = if ($hardwareTranscode) { $pipeline.Settings.Decoder } else { $Clip.expected.codecName }
        if ($inspection.Decoders -notcontains $requiredDecoder) { throw "Binary is missing configured decoder '$requiredDecoder'; no fallback is permitted." }
        if ($inspection.Encoders -notcontains $pipeline.Encoder) { throw "Binary is missing output encoder '$($pipeline.Encoder)'." }
        $help = Invoke-FFmpegProcess -FilePath $filePath -Arguments @('-hide_banner', '-h', ('filter=' + $Implementation.filter)) -WorkingDirectory $WorkingDirectory -TimeoutSeconds 30
        if ($help.TimedOut -or $help.ExitCode -ne 0) { throw 'Tone-mapper help inspection failed.' }
        $helpText = $help.StdOut + "`n" + $help.StdErr
        foreach ($property in $pipeline.Settings.FilterOptions.PSObject.Properties) {
            if ($helpText -notmatch ('(?m)^\s+-?' + [regex]::Escape($property.Name) + '\s+<')) { throw "Binary filter '$($Implementation.filter)' lacks required option '$($property.Name)'." }
        }
        $checks.Add([pscustomobject]@{ name = 'binary-capabilities'; passed = $true; note = 'Actual binary filter/options and requested decoder/encoder checked.' })
        if ([string]::IsNullOrWhiteSpace($LogPathPrefix)) { $LogPathPrefix = Join-Path $Configuration.paths.tempOutputPath ('pipeline-smoke-' + [guid]::NewGuid().ToString('N')) }
        $smokeStarted = $true
        $run = Invoke-FFmpegProcess -FilePath $filePath -Arguments $pipeline.Arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds ([Math]::Min(60, $Configuration.benchmark.processTimeoutSeconds)) -LogPathPrefix $LogPathPrefix
        if ($run.TimedOut) { throw "Filter '$($Implementation.filter)'/$TestType processing smoke timed out." }
        if ($run.ExitCode -ne 0 -or -not $run.OutputCaptureComplete) { throw "Filter '$($Implementation.filter)'/$TestType processing failed (exit $($run.ExitCode)): $(Get-PipelineVideoFailure $run)" }
        Assert-QualityNativeRenderingSucceeded -Text $run.StdErr
        $actualFrames = Get-PipelineProperty (Get-PipelineProperty $run 'Progress') 'Frame'
        if ($actualFrames -ne $smokeFrames) { throw "Processing smoke produced '$actualFrames' frames; expected $smokeFrames." }
        if ($run.StdErr -match 'Tonemapping works on .* only|Unsupported (?:input )?(?:transfer|color)|No such filter|Error applying|Failed to configure') { throw 'Pipeline reported a transfer/filter error despite its exit status.' }
        $smokeChecked = $true
        $inputStream = Get-SuiteVideoStreamSummary -Text $run.StdErr -Direction input
        $outputStream = Get-SuiteVideoStreamSummary -Text $run.StdErr -Direction output
        if ($null -eq $inputStream -or $null -eq $outputStream) { throw 'Ordinary input/output video stream summaries are absent.' }
        if ($inputStream.codecName -ne $Clip.expected.codecName -or $inputStream.width -ne $Clip.expected.width -or $inputStream.height -ne $Clip.expected.height) { throw 'Original input stream codec/dimensions differ from the manifest.' }
        $expectedHeight = if ($TestType -eq 'performance-transcode') { 720 } else { [int]$Clip.expected.height }
        if ($outputStream.height -ne $expectedHeight -or ($TestType -ne 'performance-transcode' -and $outputStream.width -ne $Clip.expected.width)) { throw 'Output stream dimensions differ from the requested native/720p route.' }
        $expectedRange = if ($TestType -eq 'quality') { 'pc' } else { 'tv' }
        $expectedMatrix = if ($TestType -eq 'quality') { 'gbr' } else { 'bt709' }
        if ($outputStream.colorRange -ne $expectedRange -or $outputStream.colorSpace -ne $expectedMatrix -or $outputStream.colorPrimaries -ne 'bt709' -or $outputStream.colorTransfer -ne 'bt709') {
            if ($TestType -eq 'quality') { throw 'Ordinary output stream tags do not announce the required SDR colour/range. No corrective retagging is added.' }
            $checks.Add([pscustomobject]@{ name = 'output-tags'; passed = $true; note = ('Output tags {0}/{1}/{2}/{3} do not announce SDR; performance does not depend on them.' -f $outputStream.colorRange, $outputStream.colorSpace, $outputStream.colorPrimaries, $outputStream.colorTransfer) })
        }
        if ($Implementation.filter -eq 'embytonemap' -and $TestType -eq 'performance-isolated') {
            if ($outputStream.pixelFormat -ne 'nv12') { throw 'Native CPU Emby output does not announce its expected NV12 format.' }
            $pipeline.Settings | Add-Member -NotePropertyName ObservedOutputFormat -NotePropertyValue $outputStream.pixelFormat -Force
        }
        $graphPath = Get-PipelineProperty (Get-PipelineProperty $run 'LogFiles') 'Graph'
        if ($hardwareTranscode) {
            if ($pipeline.FilterGraph -match 'hwupload|hwdownload|(?:^|,)scale=') { throw 'Hardware transcode contains a host transfer or software scale.' }
            $hardwareFormat = [string]$pipeline.Settings.DecoderFrameFormat
            if ($Implementation.source -eq 'plex') {
                # This Plex build has no print_graphs support. Require native
                # hardware encoder frames and a successful explicit GPU chain.
                if ($outputStream.pixelFormat -ne $hardwareFormat -or $run.StdErr -match 'auto_scale_') { throw 'Plex native encoder input does not prove the requested GPU frame route.' }
                $checks.Add([pscustomobject]@{ name = 'gpu-residency'; passed = $true; note = 'Plex native output summary announces hardware encoder frames; successful hardware decode/map/720scale/encode, no host transfers or auto-scale. This build cannot export graph HTML.'; graph = $null; log = $run.LogFiles.Log })
            } else {
                if ([string]::IsNullOrWhiteSpace($graphPath) -or -not [IO.File]::Exists($graphPath)) { throw 'Hardware processing smoke has no native execution graph for residency inspection.' }
                $graphText = [IO.File]::ReadAllText($graphPath)
                if ($graphText -match 'filter_name">(?:hwupload|hwdownload|auto_scale)') { throw 'Native hardware graph contains an unexpected host conversion.' }
                if ($graphText -notmatch ('<span>' + $hardwareFormat + '\s*\|')) { throw 'Native graph does not announce the required hardware frame format.' }
                $checks.Add([pscustomobject]@{ name = 'gpu-residency'; passed = $true; note = 'Successful native hardware decoder/map/720scale/encoder graph; direct mapping requested, no host transfer filters.'; graph = $graphPath })
            }
        } elseif ($hardwareIsolated) {
            if ($outputStream.pixelFormat -ne $Implementation.backend -or $pipeline.FilterGraph -match 'hwdownload' -or $pipeline.FilterGraph.IndexOf('hwupload') -gt $pipeline.FilterGraph.IndexOf('loop=')) { throw 'Isolated hardware smoke did not retain uploaded GPU frames through the loop/null output.' }
            $checks.Add([pscustomobject]@{ name = 'gpu-loop'; passed = $true; note = 'Four GPU wrapped_avframe/null output frames; single upload precedes loop, no download.'; graph = $graphPath })
        }
        if ($Clip.toneMappingType -in @('hdr10plus','dovi-p5')) {
            $signal = if ($Clip.toneMappingType -eq 'hdr10plus') { 'HDR10\+' } else { '(?:Dolby Vision|DOVI)' }
            $message = [regex]::Match($run.StdErr, ('(?m)^\[[^\r\n]*' + [regex]::Escape($Implementation.filter) + '[^\r\n]*\][^\r\n]*' + $signal + '[^\r\n]*(?:applied|applying|processing)[^\r\n]*'))
            if ($message.Success) { $metadataMessage = $message.Value.Trim() }
            if ($Implementation.filter -match '^embytonemap' -and $Clip.toneMappingType -eq 'hdr10plus' -and $null -eq $metadataMessage) { throw 'Native Emby mapper did not report applying HDR10+ metadata during the smoke. Option enablement alone is not application proof.' }
            $checks.Add([pscustomobject]@{ name = 'dynamic-metadata-evidence'; passed = $true; nativeMapperMessage = $metadataMessage; note = $(if ($null -ne $metadataMessage) { 'Native mapper reports metadata application during bounded smoke; not an individual-frame delivery guarantee.' } else { 'Documented signal options, original pinned bitstream and known route limitations retained; current per-frame metadata delivery is unobserved.' }) })
        }
        $checks.Add([pscustomobject]@{ name = 'output-stream'; passed = $true; note = 'Ordinary output summary announces requested dimensions; no per-frame instrumentation or time collection.' })
        $deviceInfo = Get-PipelineDeviceInfo -Text $run.StdErr -Pipeline $pipeline -Configuration $Configuration
        if (-not $deviceInfo.verified) { throw 'Selected GPU vendor could not be established from native verbose logs.' }
        if ($Implementation.backend -ne 'software') {
            if ($Configuration.exclude.($deviceInfo.vendor)) { throw "Actual selected GPU vendor '$($deviceInfo.vendor)' is excluded." }
            if (@($Implementation.deviceVendors) -notcontains $deviceInfo.vendor) { throw "Filter requires a different GPU vendor; selected '$($deviceInfo.vendor)'." }
            if ($Implementation.backend -eq 'opencl' -and $Configuration.devices.opencl.vendor -ne 'any' -and $Configuration.devices.opencl.vendor -ne $deviceInfo.vendor) { throw 'Actual OpenCL vendor differs from configured vendor.' }
            if ($hardwareTranscode -and $Implementation.backend -eq 'opencl' -and $null -ne $Configuration.devices.opencl.platform -and $null -ne $Configuration.devices.opencl.device) {
                $selectedIndex = [string]$Configuration.devices.opencl.platform + '.' + [string]$Configuration.devices.opencl.device
                if ($run.StdErr -notmatch ('(?m)^\[OpenCL[^\r\n]*\]\s*' + [regex]::Escape($selectedIndex) + ':\s*' + [regex]::Escape($deviceInfo.name))) { throw 'Explicit OpenCL indices differ from decoder-derived device.' }
            }
        }
        $checks.Add([pscustomobject]@{ name = 'device-and-smoke'; passed = $true; note = 'Requested frame count and actual device/vendor exclusions checked.' })
    } catch { $blockers.Add($_.Exception.Message) }
    $passed = $blockers.Count -eq 0
    # 'failed': the smoke process ran and crashed, timed out or misbehaved.
    # 'blocked': capability, configuration or route checks rejected the row.
    $failureKind = if ($passed) { $null } elseif ($smokeStarted -and -not $smokeChecked) { 'failed' } else { 'blocked' }
    return [pscustomobject][ordered]@{
        Passed = $passed; FailureKind = $failureKind; Reason = $blockers.ToArray() -join ' '; DeviceInfo = $deviceInfo
        SourceIntegrity = [pscustomobject]@{ sha256 = $mediaHash; expectedSha256 = $Clip.sha256; matched = $null -ne $mediaHash -and $mediaHash -eq $Clip.sha256; callerVerified = [bool]$SkipHashCheck }
        ExpectedInputProperties = $Clip.expected
        ObservedStreamProperties = [pscustomobject]@{ Input = $inputStream; Output = $outputStream; evidence = 'Ordinary stream summaries, not frame properties.' }
        MetadataApplicationEvidence = $metadataMessage
        Pipeline = $pipeline; Run = $run; Checks = @($checks.ToArray()); BinaryInspection = $inspection
        clipId = $Clip.id; implementationId = $Implementation.id; testType = $TestType
        status = $(if ($passed) { 'pass' } else { 'blocked' }); blockers = @($blockers.ToArray())
        runtimeVerified = $passed; deviceVendor = $(if ($null -ne $deviceInfo) { $deviceInfo.vendor } else { $null })
        Settings = $(if ($null -ne $pipeline) { $pipeline.Settings } else { $null })
        clipSha256 = $mediaHash; expectedClipSha256 = $Clip.sha256
        binarySha256 = $(if ($null -ne $inspection) { $inspection.Sha256 } else { $null })
        limitations = @('Pinned integrity, capabilities and bounded processing smoke do not prove individual-frame metadata delivery or exact temporal correspondence.', 'No source download diagnostic, frame-property filters, or frame-time collection is performed.', 'Existing binary/device failures remain blocked; stream tags alone do not establish mapped pixel semantics.')
    }
}

Export-ModuleMember -Function New-SuiteFFmpegArguments, Invoke-SuitePipelinePreflight, Get-SuiteVideoStreamSummary
