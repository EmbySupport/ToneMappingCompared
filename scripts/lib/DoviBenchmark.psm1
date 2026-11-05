#Requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-DoviBenchmarkProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Test-DoviFiniteNumber {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [char] -or $Value -isnot [ValueType]) { return $false }
    try { $number = [double]$Value } catch { return $false }
    return -not ([double]::IsNaN($number) -or [double]::IsInfinity($number))
}

function Get-DoviProcessProblem {
    param([object]$Run, [int]$ExpectedFrames, [switch]$RequireBenchmark)
    if ($null -eq $Run) { return 'No FFmpeg process result.' }
    $timeout = Get-DoviBenchmarkProperty $Run 'TimedOut'
    if ($timeout -isnot [bool]) { return 'FFmpeg timeout status is missing.' }
    if ($timeout) { return 'FFmpeg timed out.' }
    $exitCode = Get-DoviBenchmarkProperty $Run 'ExitCode'
    if (-not (Test-DoviFiniteNumber $exitCode) -or $exitCode -ne 0) { return "FFmpeg exit code: $exitCode." }
    $capture = Get-DoviBenchmarkProperty $Run 'OutputCaptureComplete'
    if ($capture -isnot [bool] -or -not $capture) { return 'FFmpeg output capture was incomplete.' }
    $progress = Get-DoviBenchmarkProperty $Run 'Progress'
    $frames = Get-DoviBenchmarkProperty $progress 'Frame'
    if (-not (Test-DoviFiniteNumber $frames) -or $frames -ne $ExpectedFrames) { return "FFmpeg final frame count $frames differs from requested count $ExpectedFrames." }
    if ($RequireBenchmark) {
        $benchmark = Get-DoviBenchmarkProperty $Run 'Benchmark'
        $wall = Get-DoviBenchmarkProperty $benchmark 'WallSeconds'
        if (-not (Test-DoviFiniteNumber $wall) -or $wall -le 0) { return 'FFmpeg did not report a positive finite benchmark wall time.' }
    }
    return $null
}

function Get-DoviTimingWindowProblem {
    param([object]$ShortFrames, [object]$LongFrames, [object]$MinimumDeltaSeconds)
    foreach ($count in @($ShortFrames, $LongFrames)) {
        if (-not (Test-DoviFiniteNumber $count) -or $count -lt 160 -or $count -gt [int]::MaxValue -or $count % 160 -ne 0) {
            return 'Both DoVi timing windows must contain a positive Int32 multiple of 160 frames.'
        }
    }
    if ($LongFrames -le $ShortFrames) { return 'The long DoVi timing window must contain more frames than the short window.' }
    if (-not (Test-DoviFiniteNumber $MinimumDeltaSeconds) -or $MinimumDeltaSeconds -lt 0) { return 'The minimum DoVi paired wall-time difference must be finite and nonnegative.' }
    return $null
}



function New-DoviIsolatedBenchmarkSample {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ShortResult,
        [AllowNull()][object]$LongResult,
        [ValidateRange(1, 1000)][int]$Repetition,
        [ValidateRange(0, 1000)][double]$SourceFrameRate = 24,
        [Parameter(Mandatory = $true)][int]$ShortFrames,
        [Parameter(Mandatory = $true)][int]$LongFrames,
        [double]$MinimumDeltaSeconds = 0
    )
    # Both windows exercise the same eight metadata states, repeated twenty
    # times each. Subtract whole-cycle windows so that no setup cost is
    # estimated from a different one-frame metadata case.
    $timingPolicy = if ($MinimumDeltaSeconds -gt 0) { 'time-sized-v2' } else { 'explicit-windows' }
    $pairedFrames = [long]$LongFrames - [long]$ShortFrames
    $problem = Get-DoviTimingWindowProblem $ShortFrames $LongFrames $MinimumDeltaSeconds
    if (-not $problem) { $problem = Get-DoviProcessProblem -Run $ShortResult -ExpectedFrames $ShortFrames -RequireBenchmark }
    if (-not $problem) { $problem = Get-DoviProcessProblem -Run $LongResult -ExpectedFrames $LongFrames -RequireBenchmark }
    $shortBenchmark = Get-DoviBenchmarkProperty $ShortResult 'Benchmark'
    $longBenchmark = Get-DoviBenchmarkProperty $LongResult 'Benchmark'
    $shortWall = Get-DoviBenchmarkProperty $shortBenchmark 'WallSeconds'
    $longWall = Get-DoviBenchmarkProperty $longBenchmark 'WallSeconds'
    $cost = $null; $fps = $null; $wallFps = $null; $speed = $null
    $wallDelta = $null; $measuredFps = $null; $windowTooShort = $false
    $cpuDelta = $null; $cpuCost = $null; $cpuProblem = $null
    if (-not $problem) {
        $wallDelta = [double]$longWall - [double]$shortWall
        if ($wallDelta -gt 0) { $measuredFps = $pairedFrames / $wallDelta }
        if ($wallDelta -lt $MinimumDeltaSeconds) {
            $problem = "Paired wall-time difference $wallDelta s is below the minimum $MinimumDeltaSeconds s; no isolated score."
            $windowTooShort = $true
        }
    }
    if (-not $problem) {
        $cost = $wallDelta / $pairedFrames
        if (-not (Test-DoviFiniteNumber $cost) -or $cost -le 0) {
            $problem = 'Paired wall-time difference is nonpositive or nonfinite; no isolated score.'
            $cost = $null; $windowTooShort = $true
        } else {
            $fps = 1.0 / $cost
            if (-not (Test-DoviFiniteNumber $fps)) { $problem = 'Paired wall-time difference cannot produce a finite FPS score.'; $cost = $null; $fps = $null }
            else {
                $wallFps = $LongFrames / [double]$longWall
                if ($SourceFrameRate -gt 0) { $speed = $fps / $SourceFrameRate }
                $cpuTimes = @((Get-DoviBenchmarkProperty $shortBenchmark 'UserSeconds'), (Get-DoviBenchmarkProperty $shortBenchmark 'SystemSeconds'), (Get-DoviBenchmarkProperty $longBenchmark 'UserSeconds'), (Get-DoviBenchmarkProperty $longBenchmark 'SystemSeconds'))
                if (@($cpuTimes | Where-Object { -not (Test-DoviFiniteNumber $_) -or $_ -lt 0 }).Count) {
                    $cpuProblem = 'FFmpeg did not report complete finite CPU times; no paired CPU-cost estimate.'
                } else {
                    $cpuDelta = ([double]$cpuTimes[2] + [double]$cpuTimes[3]) - ([double]$cpuTimes[0] + [double]$cpuTimes[1])
                    $cpuCost = $cpuDelta / $pairedFrames
                    if (-not (Test-DoviFiniteNumber $cpuCost)) { $cpuProblem = 'Paired CPU-time difference is nonfinite; no CPU-cost estimate.'; $cpuDelta = $null; $cpuCost = $null }
                    elseif ($cpuCost -lt 0) { $cpuProblem = 'Paired CPU-time difference is negative; retain the raw estimate as timing noise.' }
                }
            }
        }
    }
    return [pscustomobject][ordered]@{
        method = 'dovi-eight-state'; repetition = $Repetition; valid = -not [bool]$problem; reason = $problem
        frames = $LongFrames; shortFrames = $ShortFrames; pairedFrames = $pairedFrames
        timingPolicy = $timingPolicy; minimumDeltaSeconds = $MinimumDeltaSeconds; windowTooShort = $windowTooShort; measuredFps = $measuredFps
        metadataStates = 8; repeatsPerState = 20
        frameCostSeconds = $cost; fps = $fps; speed = $speed; speedReferenceFrameRate = $SourceFrameRate
        pairedWallDeltaSeconds = $wallDelta; shortWallSeconds = $shortWall; longWallSeconds = $longWall; wallSeconds = $longWall; wallFps = $wallFps
        pairedCpuDeltaSeconds = $cpuDelta; cpuSecondsPerFrame = $cpuCost; cpuProblem = $cpuProblem
        reportedPipelineSpeed = Get-DoviBenchmarkProperty (Get-DoviBenchmarkProperty $LongResult 'Progress') 'Speed'
        shortRun = $ShortResult; longRun = $LongResult
        # Existing isolated execution/log selection expects these aliases.
        singleFrameRun = $ShortResult; loopRun = $LongResult
    }
}

function Get-DoviBenchmarkAggregate {
    # Samples measured with other windows (before a resize) are superseded.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Samples, [int]$ShortFrames = 0, [int]$LongFrames = 0)
    [object[]]$all = @()
    if ($null -ne $Samples) { $all = [object[]]$Samples.Clone() }
    $valid = @(foreach ($sample in $all) {
        $isValid = Get-DoviBenchmarkProperty $sample 'valid'
        if ($isValid -isnot [bool] -or -not $isValid -or (Get-DoviBenchmarkProperty $sample 'method') -ne 'dovi-eight-state') { continue }
        $cost = Get-DoviBenchmarkProperty $sample 'frameCostSeconds'
        if (-not (Test-DoviFiniteNumber $cost) -or $cost -le 0 -or -not (Test-DoviFiniteNumber (1.0 / [double]$cost))) { continue }
        if ($ShortFrames -gt 0 -and ((Get-DoviBenchmarkProperty $sample 'shortFrames') -ne $ShortFrames -or (Get-DoviBenchmarkProperty $sample 'frames') -ne $LongFrames)) { continue }
        $sample
    })
    $sameWindows = $true
    foreach ($candidate in $valid) {
        if ($candidate.shortFrames -ne $valid[0].shortFrames -or $candidate.frames -ne $valid[0].frames) { $sameWindows = $false; break }
    }
    $minimum = $null; $maximum = $null; $spread = $null
    if ($valid.Count -and $sameWindows) {
        $frameRates = @($valid | ForEach-Object { 1.0 / [double]$_.frameCostSeconds } | Sort-Object)
        $minimum = $frameRates[0]; $maximum = $frameRates[-1]
        $spread = 100.0 * ($maximum - $minimum) / $maximum
    }
    $usable = $sameWindows -and $valid.Count -ge 3
    $reason = if (-not $sameWindows) { 'Median DoVi samples must use identical frame windows.' }
        elseif ($valid.Count -lt 3) { 'At least three valid paired samples are required; no median performance score.' } else { $null }
    $representative = $null; $medianCost = $null; $fps = $null; $speed = $null
    if ($usable) {
        $ordered = @($valid | Sort-Object @{ Expression = { $_.frameCostSeconds } }, @{ Expression = { $_.repetition } })
        $representative = $ordered[[int][Math]::Floor($ordered.Count / 2.0)]
        $medianCost = [double]$representative.frameCostSeconds
        $fps = 1.0 / $medianCost
        $rate = Get-DoviBenchmarkProperty $representative 'speedReferenceFrameRate'
        if ((Test-DoviFiniteNumber $rate) -and $rate -gt 0) { $speed = $fps / [double]$rate }
    }
    return [pscustomobject][ordered]@{
        method = 'dovi-eight-state'; aggregation = 'median-paired-frame-cost'; requiredValidSamples = 3
        usable = $usable; valid = $usable; reason = $reason; validCount = $valid.Count; invalidCount = $all.Count - $valid.Count
        frameCostSeconds = $medianCost; fps = $fps; speed = $speed; representative = $representative
        timingPolicy = Get-DoviBenchmarkProperty $representative 'timingPolicy'
        shortFrames = Get-DoviBenchmarkProperty $representative 'shortFrames'; frames = Get-DoviBenchmarkProperty $representative 'frames'; pairedFrames = Get-DoviBenchmarkProperty $representative 'pairedFrames'
        minimumDeltaSeconds = Get-DoviBenchmarkProperty $representative 'minimumDeltaSeconds'
        # Compatibility with the runner's existing execution/duration access.
        best = $representative; min = $minimum; max = $maximum; spread = $spread
        wallSeconds = Get-DoviBenchmarkProperty $representative 'wallSeconds'
        cpuSecondsPerFrame = Get-DoviBenchmarkProperty $representative 'cpuSecondsPerFrame'
    }
}

function Get-DoviMetadataSelfTestResult {
    [CmdletBinding()]
    param([AllowNull()][object]$Run, [ValidateSet(160, 960)][int]$Frames = 960)
    $expectedUpdates = [int]($Frames / 20)
    $processProblem = Get-DoviProcessProblem -Run $Run -ExpectedFrames $Frames
    $problem = $processProblem
    $actualFrames = Get-DoviBenchmarkProperty (Get-DoviBenchmarkProperty $Run 'Progress') 'Frame'
    $text = Get-DoviBenchmarkProperty $Run 'StdErr'
    # Match an actual CPU-filter av_log line, never command text, GPU filters
    # or other libraries.
    $pattern = '(?m)^\[(?:embytonemap(?:@[A-Za-z0-9_.-]+)?|Parsed_embytonemap_\d+)\s+@\s+[^\]\r\n]+\]\s+(?:LUT built in cache slot|Table built in slot) (\d+)\s*$'
    $updates = [regex]::Matches([string]$text, $pattern)
    $unexpected = @($updates | Where-Object { [int]$_.Groups[1].Value -ge 4 }).Count
    if (-not $problem -and $unexpected) { $problem = 'Native debug output reports an unexpected update.' }
    if (-not $problem -and $updates.Count -ne $expectedUpdates) { $problem = "Native update count $($updates.Count) differs from expected $expectedUpdates ($Frames frames / 20 repeats)." }
    $healthyStatic = -not [bool]$processProblem -and $actualFrames -eq 960 -and $updates.Count -eq 1 -and $unexpected -eq 0
    return [pscustomobject][ordered]@{
        method = 'dovi-eight-state'; passed = -not [bool]$problem; verified = -not [bool]$problem; reason = $problem
        processSucceeded = -not [bool]$processProblem; healthyStatic = $healthyStatic; frames = $actualFrames; expectedFrames = $Frames; actualFrames = $actualFrames
        expectedUpdates = $expectedUpdates; actualUpdates = $updates.Count; repeatsPerState = 20; expectedMetadataStates = 8
        evidence = 'Native Emby CPU debug output and completed output frame count; no frame-time collection.'
        run = $Run
    }
}

Export-ModuleMember -Function New-DoviIsolatedBenchmarkSample, Get-DoviBenchmarkAggregate, Get-DoviMetadataSelfTestResult
