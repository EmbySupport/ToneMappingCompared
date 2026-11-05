#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ManifestPath = 'config/media.json',
    [string]$UserConfigPath,
    [string[]]$ClipId,
    [switch]$List,
    [switch]$VerifyOnly,
    [switch]$AllowUnpinned,
    [switch]$ReplaceInvalid,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\Configuration.psm1')

function Get-MediaProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-MediaManifest {
    param([object]$Manifest)
    if ((Get-MediaProperty $Manifest 'schemaVersion') -ne 1) { throw 'Media manifest schemaVersion must be 1.' }
    $knownIds = @{}
    $knownNames = @{}
    foreach ($clip in @(Get-MediaProperty $Manifest 'clips')) {
        if ($null -eq $clip) { throw 'Media manifest clips must be an array.' }
        $id = [string](Get-MediaProperty $clip 'id')
        if ($id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $knownIds.ContainsKey($id)) { throw "Invalid or duplicate clip ID: $id" }
        $knownIds[$id] = $true
        if (@('hlg', 'hdr10', 'hdr10plus', 'dovi-p5') -notcontains (Get-MediaProperty $clip 'toneMappingType')) { throw "Invalid toneMappingType for $id." }
        $name = [string](Get-MediaProperty $clip 'fileName')
        if ([string]::IsNullOrWhiteSpace($name) -or $name -ne [IO.Path]::GetFileName($name) -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name.EndsWith('.') -or $name.EndsWith(' ') -or $name -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw "fileName for $id must be a safe filename without directories." }
        if ($knownNames.ContainsKey($name)) { throw "Duplicate media fileName: $name" }
        $knownNames[$name] = $true
        $hash = Get-MediaProperty $clip 'sha256'
        if ($null -ne $hash -and [string]$hash -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid SHA-256 for $id." }
        if ((Get-MediaProperty $clip 'enabled') -isnot [bool]) { throw "enabled must be a boolean for $id." }
        if ($null -eq (Get-MediaProperty $clip 'expected')) { throw "Expected properties are missing for $id." }
        $archive = Get-MediaProperty $clip 'downloadArchive'
        if ($null -ne $archive) {
            if ((Get-MediaProperty $archive 'format') -ne 'zip' -or [string](Get-MediaProperty $archive 'sha256') -notmatch '^[a-fA-F0-9]{64}$' -or (Get-MediaProperty $archive 'sizeBytes') -le 0 -or (Get-MediaProperty $clip 'sizeBytes') -le 0) { throw "A ZIP download for $id requires pinned archive and original media sizes and archive SHA-256." }
            $member = [string](Get-MediaProperty $archive 'member')
            if ([string]::IsNullOrWhiteSpace($member) -or $member -ne [IO.Path]::GetFileName($member) -or $member.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $member.EndsWith('.') -or $member.EndsWith(' ') -or $member -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw "Archive member for $id must be a safe root-level filename." }
        }
    }
}

function Get-MediaObservation {
    param([string]$Path, [object]$Configuration, [string]$LogPrefix)
    $binary = $Configuration.binaries.stock
    $ffmpegPath = [string]$binary.ffmpegPath
    # Minimal original-bitstream decode: no diagnostic filter, forced format,
    # frame-property export, or frame-time collection.
    $run = Invoke-FFmpegProcess -FilePath $ffmpegPath -Arguments @('-hide_banner', '-nostdin', '-v', 'info', '-nostats', '-progress', 'pipe:1', '-i', $Path, '-map', '0:v:0', '-frames:v', '1', '-an', '-sn', '-dn', '-c:v', 'wrapped_avframe', '-f', 'null', '-') -WorkingDirectory $repositoryRoot -TimeoutSeconds $TimeoutSeconds -LogPathPrefix ($LogPrefix + '.ffmpeg')
    if ($run.TimedOut -or $run.ExitCode -ne 0 -or -not $run.OutputCaptureComplete -or $run.Progress.Frame -ne 1) { throw "Original-bitstream decode smoke failed for $Path. See its recorded FFmpeg log." }
    $input = Get-SuiteVideoStreamSummary -Text $run.StdErr -Direction input
    $output = Get-SuiteVideoStreamSummary -Text $run.StdErr -Direction output
    if ($null -eq $input -or $null -eq $output) { throw "Could not read ordinary video stream summaries for $Path." }
    return [pscustomobject][ordered]@{
        method = 'ffmpeg-stream-summary-and-decode-smoke'
        codecName = $input.codecName; pixelFormat = $output.pixelFormat
        width = $output.width; height = $output.height; frameRate = $input.frameRate
        colorRange = $output.colorRange; colorSpace = $output.colorSpace
        colorPrimaries = $output.colorPrimaries; colorTransfer = $output.colorTransfer
        dolbyVisionProfile = $input.dolbyVisionProfile
        inputStream = $input; outputStream = $output
        decodedFrameMetadataVerified = $false
        limitations = @('Pinned SHA-256 establishes original-source identity. Ordinary stream summaries and one decoded output frame do not prove per-frame HDR metadata delivery, chroma-location preservation, or whole-clip decoder behavior.', 'No frame-property filters or frame-time collection is performed. Manifest signal metadata remains an expectation from the pinned source evidence.')
    }
}

function Assert-MediaObservation {
    param([object]$Clip, [object]$Observation)
    foreach ($name in @('codecName', 'pixelFormat', 'width', 'height')) {
        $expected = Get-MediaProperty $Clip.expected $name
        if ($null -ne $expected -and (Get-MediaProperty $Observation $name) -ne $expected) { throw "Clip '$($Clip.id)' stream property '$name' differs from '$expected'." }
    }
    # Compare only tags actually announced by the decoded output stream. Missing
    # announcements are not promoted to per-frame or dynamic-metadata proof.
    foreach ($name in @('colorTransfer', 'colorPrimaries', 'colorSpace', 'colorRange', 'dolbyVisionProfile')) {
        $expected = Get-MediaProperty $Clip.expected $name
        $actual = Get-MediaProperty $Observation $name
        if ($null -ne $expected -and $null -ne $actual -and $actual -ne $expected) { throw "Clip '$($Clip.id)' announced '$name' is '$actual'; expected '$expected'." }
    }
}
$manifestFullPath = Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $ManifestPath
$manifest = Read-SuiteJson -Path $manifestFullPath
Assert-MediaManifest $manifest
$clips = @($manifest.clips)
if ($ClipId) {
    foreach ($id in $ClipId) { if ($id -notin @($clips | ForEach-Object { $_.id })) { throw "Unknown clip ID '$id'. Use -List to inspect the manifest." } }
    $clips = @($clips | Where-Object { $_.id -in $ClipId })
}
if ($List) {
    $clips | Select-Object id, label, toneMappingType, enabled, sizeBytes, durationSeconds, @{ Name = 'pinned'; Expression = { -not [string]::IsNullOrWhiteSpace([string]$_.sha256) } }
    return
}
if (-not $ClipId) { $clips = @($clips | Where-Object { $_.enabled }) }
if ($clips.Count -eq 0) { throw 'No enabled media clips are available. Use -List to inspect candidates, or supply -ClipId explicitly.' }
foreach ($clip in $clips) {
    if ([string]::IsNullOrWhiteSpace([string]$clip.sha256) -and -not $AllowUnpinned) { throw "Clip '$($clip.id)' has no pinned SHA-256. Obtain and pin a verified hash, or explicitly pass -AllowUnpinned for research." }
}
$configuration = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $UserConfigPath
if ([string]::IsNullOrWhiteSpace([string]$configuration.binaries.stock.ffmpegPath) -or -not (Test-Path -LiteralPath $configuration.binaries.stock.ffmpegPath -PathType Leaf)) { throw 'The configured stock FFmpeg is required for the minimal decode smoke. Extract the release binaries or update binaries.stock.ffmpegPath.' }
Import-Module (Join-Path $PSScriptRoot 'lib\RunLock.psm1')
# Retain the release function before imports invoked by nested coordinators.
# The named mutex is reentrant on the same Windows PowerShell thread.
$exitMediaLease = (Get-Command Exit-SuiteRun).ScriptBlock
$mediaLease = Enter-SuiteRun -RepositoryRoot $repositoryRoot -Operation 'test-media-import-or-verify'
try {
Import-Module (Join-Path $PSScriptRoot 'lib\FFmpeg.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Pipelines.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\MediaArchive.psm1')
$mediaPath = $configuration.paths.mediaPath
$logPath = Join-Path $configuration.paths.tempOutputPath 'media-validation'
New-Item -ItemType Directory -Path $mediaPath -Force | Out-Null
New-Item -ItemType Directory -Path $logPath -Force | Out-Null
$previousTls = [Net.ServicePointManager]::SecurityProtocol
$previousProgress = $ProgressPreference
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    foreach ($clip in $clips) {
        $target = Join-Path $mediaPath $clip.fileName
        $localSource = [string](Get-MediaProperty $clip 'localSourcePath')
        $url = [string](Get-MediaProperty $clip 'url')
        $sourceHash = $null
        $replacementOriginalHash = $null
        $pinned = -not [string]::IsNullOrWhiteSpace([string]$clip.sha256)
        if (-not $pinned) { Write-Warning "Clip '$($clip.id)' is unpinned research media; it is not reproducible benchmark input." }
        $needsDownload = -not (Test-Path -LiteralPath $target -PathType Leaf)
        if (-not $needsDownload) {
            $existingHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($pinned -and $existingHash -ne $clip.sha256) {
                if ($VerifyOnly -or -not $ReplaceInvalid -or -not [string]::IsNullOrWhiteSpace($localSource)) {
                    $reason = "Existing file fails SHA-256: $target. It was preserved."
                    if (-not [string]::IsNullOrWhiteSpace($localSource)) { $reason += ' Local imports only copy into an absent workspace destination.' }
                    elseif (-not $VerifyOnly) { $reason += ' Pass -ReplaceInvalid to validate a public-download replacement before replacing it.' }
                    throw $reason
                }
                $needsDownload = $true
                $replacementOriginalHash = $existingHash
            }
        }
        if ($needsDownload -and -not [string]::IsNullOrWhiteSpace($localSource)) {
            $localSource = Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $localSource
            if (-not (Test-Path -LiteralPath $localSource -PathType Leaf)) {
                $reason = "Optional local source is missing: $localSource. Supply that original file or import it at $target; no download URL is invented."
                if ((Get-MediaProperty $clip 'localOptional') -eq $true -and -not $ClipId) {
                    Write-Warning $reason
                    [pscustomobject]@{ clipId = $clip.id; filePath = $target; hashPinned = $pinned; validated = $false; skipped = $true; reason = $reason }
                    continue
                }
                throw $reason
            }
        }
        if ($VerifyOnly -and $needsDownload) { throw "Media file was not found: $target. Run the media importer with the original local source or configured HTTPS download." }
        $partialPath = $null
        $archivePartialPath = $null
        try {
            $inputPath = $target
            if ($needsDownload) {
                $partialPath = $target + '.' + [guid]::NewGuid().ToString('N') + '.partial'
                if (-not [string]::IsNullOrWhiteSpace($localSource)) {
                    $sourceHash = (Get-FileHash -LiteralPath $localSource -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($pinned -and $sourceHash -ne $clip.sha256) { throw "Local original SHA-256 mismatch for '$($clip.id)'; the source and destination were preserved." }
                    Write-Host "Importing original local source for $($clip.id)..."
                    Copy-Item -LiteralPath $localSource -Destination $partialPath
                } else {
                    if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https://') { throw "Clip '$($clip.id)' has no usable local source or direct HTTPS download URL." }
                    Write-Host "Downloading $($clip.id)..."
                    $archive = Get-MediaProperty $clip 'downloadArchive'
                    if ($null -eq $archive) {
                        Invoke-WebRequest -Uri $url -OutFile $partialPath -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                    } else {
                        $archivePartialPath = $partialPath + '.zip'
                        Invoke-WebRequest -Uri $url -OutFile $archivePartialPath -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                        Expand-SuiteMediaArchive -ArchivePath $archivePartialPath -DestinationPath $partialPath -Archive $archive -MediaSizeBytes $clip.sizeBytes
                    }
                }
                $inputPath = $partialPath
            }
            $actualHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($null -ne $sourceHash -and $sourceHash -ne $actualHash) { throw "Local source changed during import for '$($clip.id)'; the destination was not replaced." }
            if ($pinned -and $actualHash -ne $clip.sha256) { throw "SHA-256 mismatch for '$($clip.id)'. Expected $($clip.sha256), received $actualHash. The final file was not replaced." }
            $expectedSize = Get-MediaProperty $clip 'sizeBytes'
            if ($null -ne $expectedSize -and (Get-Item -LiteralPath $inputPath).Length -ne [long]$expectedSize) { throw "Original media size differs from the manifest for '$($clip.id)'. The final file was not replaced." }
            $observation = Get-MediaObservation -Path $inputPath -Configuration $configuration -LogPrefix (Join-Path $logPath $clip.id)
            Assert-MediaObservation -Clip $clip -Observation $observation
            if ($needsDownload) {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    if (-not $ReplaceInvalid -or -not [string]::IsNullOrWhiteSpace($localSource)) { throw "A destination file appeared during download/import and was preserved: $target" }
                    if ([string]::IsNullOrWhiteSpace($replacementOriginalHash) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $replacementOriginalHash) { throw "The destination appeared or changed during download and was preserved: $target" }
                    # Windows PowerShell converts a normal $null to an empty
                    # string for this overload. NullString preserves a null
                    # backup filename for the .NET Framework API.
                    [IO.File]::Replace($partialPath, $target, [NullString]::Value)
                }
                else { [IO.File]::Move($partialPath, $target) }
                $partialPath = $null
            }
            $report = [ordered]@{
                schemaVersion = 1; clipId = $clip.id; filePath = $target
                manifestPath = $manifestFullPath; sourceUrl = $url; localSourcePath = $localSource
                downloadArchive = Get-MediaProperty $clip 'downloadArchive'
                checkedAtUtc = [datetime]::UtcNow.ToString('o')
                sha256 = $actualHash; hashPinned = $pinned; expectedPropertiesMatched = $null
                validationLevel = 'pinned-integrity-and-stream-decode-smoke'; streamPropertiesMatched = $true
                decodedFrameMetadataVerified = $false; expected = $clip.expected
                observed = $observation
            }
            $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath ($target + '.validation.json') -Encoding UTF8
            Write-Host "Validated $($clip.id): $($observation.codecName), $($observation.width)x$($observation.height), $($observation.colorTransfer), SHA-256 $actualHash"
            [pscustomobject]@{ clipId = $clip.id; filePath = $target; hashPinned = $pinned; validated = $true; validationPath = $target + '.validation.json' }
        }
        finally {
            if ($partialPath -and (Test-Path -LiteralPath $partialPath -PathType Leaf)) { Remove-Item -LiteralPath $partialPath -Force }
            if ($archivePartialPath -and (Test-Path -LiteralPath $archivePartialPath -PathType Leaf)) { Remove-Item -LiteralPath $archivePartialPath -Force }
        }
    }
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
    $ProgressPreference = $previousProgress
}
}
finally { & $exitMediaLease -Lease $mediaLease }
