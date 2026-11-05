#Requires -Version 5.1
Set-StrictMode -Version 2.0

function Read-SuitePerformanceWorkloads {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $data=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if($data.schemaVersion -ne 1){throw 'Performance workloads require schemaVersion 1.'}
    $keys=@{}
    foreach($case in $data.cases){
        $key=$case.clipId+'|'+$case.implementationId+'|'+$case.testType
        if($keys.ContainsKey($key)){throw "Duplicate fixed performance workload: $key"};$keys[$key]=$true
        if($case.testType -notin @('performance-isolated','performance-transcode')){throw "Invalid fixed workload type: $key"}
        if([double]::IsNaN([double]$case.seekSeconds) -or [double]::IsInfinity([double]$case.seekSeconds) -or $case.seekSeconds -lt 0){throw "Invalid fixed seek: $key"}
        if($case.durationSeconds -le 0){throw "Missing fixed duration: $key"}
        if($case.testType -eq 'performance-isolated'){
            if($case.frames -le $case.shortFrames -or $case.shortFrames -lt 1){throw "Invalid fixed frame windows: $key"}
            if($case.doviMetadataLoop -and ($case.shortFrames%160 -ne 0 -or $case.frames%160 -ne 0 -or $case.keyframeStride -lt 1)){throw "Invalid fixed Dolby Vision workload: $key"}
        }elseif($null -eq $case.frames){
            if($case.mode -ne 'fixed-duration'){throw "A duration-only workload must be explicit: $key"}
        }elseif($case.frames -lt 1){throw "Invalid fixed output frame count: $key"}
    }
    return $data
}

function Resolve-SuitePerformanceWorkload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Workloads,
        [Parameter(Mandatory=$true)][string]$ClipId,
        [Parameter(Mandatory=$true)][string]$ImplementationId,
        [Parameter(Mandatory=$true)][ValidateSet('performance-isolated','performance-transcode')][string]$TestType,
        [int]$FrameCount,
        [int]$DoviShortFrames,
        [int]$DoviLongFrames,
        [double]$SeekSeconds,
        [double]$DurationSeconds
    )
    $matches=@($Workloads.cases|Where-Object{$_.clipId -eq $ClipId -and $_.implementationId -eq $ImplementationId -and $_.testType -eq $TestType})
    if($matches.Count -ne 1){throw "No fixed performance workload for $ClipId / $ImplementationId / $TestType. Add an explicit checked-in workload; no automatic sizing or history fallback is available."}
    $case=$matches[0]
    $overrides=New-Object 'Collections.Generic.List[string]'
    $frames=if($null -ne $case.frames){[int]$case.frames}else{0}
    $short=if($null -ne $case.shortFrames){[int]$case.shortFrames}else{0}
    $seek=[double]$case.seekSeconds;$duration=[double]$case.durationSeconds
    if($PSBoundParameters.ContainsKey('FrameCount')){if($FrameCount -lt 2){throw 'FrameCount must be at least two.'};$frames=$FrameCount;$overrides.Add('FrameCount')}
    if($PSBoundParameters.ContainsKey('DurationSeconds')){
        if([double]::IsNaN($DurationSeconds) -or [double]::IsInfinity($DurationSeconds) -or $DurationSeconds -le 0){throw 'DurationSeconds must be finite and positive.'}
        $duration=$DurationSeconds;$overrides.Add('DurationSeconds')
        if($TestType -eq 'performance-transcode' -and -not $PSBoundParameters.ContainsKey('FrameCount')){$frames=0}
    }
    if($PSBoundParameters.ContainsKey('SeekSeconds')){if([double]::IsNaN($SeekSeconds) -or [double]::IsInfinity($SeekSeconds) -or $SeekSeconds -lt 0){throw 'SeekSeconds must be finite and nonnegative.'};$seek=$SeekSeconds;$overrides.Add('SeekSeconds')}
    if($PSBoundParameters.ContainsKey('DoviShortFrames') -ne $PSBoundParameters.ContainsKey('DoviLongFrames')){throw 'Supply both Dolby Vision frame-window overrides.'}
    if($PSBoundParameters.ContainsKey('DoviShortFrames')){
        if(-not $case.doviMetadataLoop){throw 'Dolby Vision frame-window overrides require a fixed eight-state workload.'}
        $short=$DoviShortFrames;$frames=$DoviLongFrames;$overrides.Add('DoviShortFrames');$overrides.Add('DoviLongFrames')
    }
    if($case.doviMetadataLoop -and ($short -lt 160 -or $frames -le $short -or $short%160 -ne 0 -or $frames%160 -ne 0)){throw 'Dolby Vision frame windows must be whole 160-frame passes, with a longer long window.'}
    return [pscustomobject][ordered]@{
        mode=$(if($overrides.Count){'explicit-cli'}else{$case.mode});clipId=$ClipId;implementationId=$ImplementationId;testType=$TestType
        frames=$frames;shortFrames=$short;seekSeconds=$seek;durationSeconds=$duration
        doviMetadataLoop=[bool]$case.doviMetadataLoop;keyframeStride=$case.keyframeStride
        overrides=@($overrides.ToArray());origin=$case.origin
    }
}
Export-ModuleMember -Function Read-SuitePerformanceWorkloads,Resolve-SuitePerformanceWorkload
