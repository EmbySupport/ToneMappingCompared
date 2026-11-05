#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$PreparedImagesManifest,
    [string[]]$ExcludeClipId = @('hdr10plus-iss-4k'),
    [string]$HalfTimelineClipId = '',
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$destination = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd([char]92)
if ($destination -eq $root -or $root.StartsWith($destination+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Output must not contain the benchmark repository.' }
if (Test-Path -LiteralPath $destination) {
    if ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Output must not be a junction or symbolic link.' }
    if (@(Get-ChildItem -LiteralPath $destination -Force).Count) { throw 'Preserving existing output: select an empty destination.' }
}
Import-Module (Join-Path $PSScriptRoot 'lib/RunLock.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/ViewerData.psm1')
$releaseLease = (Get-Command Exit-SuiteRun).ScriptBlock
$lease = Enter-SuiteRun -RepositoryRoot $root -Operation 'hosted results snapshot'
try {
    $dataPath = Join-Path $root 'results/results-data.js'
    $dataHash = (Get-FileHash -LiteralPath $dataPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $text = [IO.File]::ReadAllText($dataPath)
    $prefix = 'window.TonemappingSuite = '
    if (-not $text.StartsWith($prefix) -or -not $text.TrimEnd().EndsWith(';')) { throw 'Unsupported viewer data wrapper.' }
    $payload = $text.Substring($prefix.Length).Trim().TrimEnd(';') | ConvertFrom-Json
    # Historical source reports remain archived, but the public viewer exposes
    # only performance and reference-based quality comparisons.
    if ($payload.PSObject.Properties['curves']) { $payload.PSObject.Properties.Remove('curves') }
    $imageManifestPath = [IO.Path]::GetFullPath($PreparedImagesManifest)
    $imageRoot = Split-Path -Parent $imageManifestPath
    $prepared = [IO.File]::ReadAllText($imageManifestPath) | ConvertFrom-Json
    if ($prepared.sourceViewerSha256 -ne $dataHash -or $prepared.width -ne 1920 -or $prepared.height -ne 1080 -or $prepared.quality -ne 95 -or $prepared.format -ne 'webp') { throw 'Prepared images do not match this export or its 1080p quality-95 preset.' }
    $preparedBySource = @{}
    foreach ($image in $prepared.images) {
        if ($preparedBySource.ContainsKey($image.sourceRelative)) { throw 'Duplicate prepared image.' }
        $preparedBySource[$image.sourceRelative] = $image
    }
    $payload.clips = @($payload.clips | Where-Object { $ExcludeClipId -notcontains $_.id })
    $implementationIds = @($payload.catalog.implementations | ForEach-Object { $_.id })
    $payload.performance = Get-ViewerCurrentReport $payload.performance $payload.clips $implementationIds -Performance
    $payload.quality = Get-ViewerCurrentReport $payload.quality $payload.clips $implementationIds
    # Source fingerprints describe the native benchmark. Exported image hashes
    # are recorded separately in site-manifest.json.
    foreach ($report in @($payload.performance,$payload.quality) | Where-Object { $null -ne $_ }) {
        foreach ($row in $report.results) {
            if ($row.PSObject.Properties['referenceReuse'] -and $row.referenceReuse) { $row.referenceReuse.PSObject.Properties.Remove('files') }
        }
        if ($report.PSObject.Properties['assembly'] -and $report.assembly) {
            $report.assembly.PSObject.Properties.Remove('files')
            if ($report.assembly.PSObject.Properties['artifactCount']) {
                $report.assembly | Add-Member -NotePropertyName sourceArtifactCount -NotePropertyValue $report.assembly.artifactCount
                $report.assembly.PSObject.Properties.Remove('artifactCount')
            }
        }
        if ($report.PSObject.Properties['referenceAssemblyChecks']) {
            foreach ($check in $report.referenceAssemblyChecks) { $check.PSObject.Properties.Remove('files') }
        }
    }
    $selectedImages = @{}
    $frameCount = 0
    foreach ($imageReport in @($payload.quality) | Where-Object { $null -ne $_ }) {
    foreach ($row in $imageReport.results) {
        if ($row.frames -isnot [Array]) { continue }
        $row | Add-Member -NotePropertyName sourceFrameCount -NotePropertyValue $row.frameCount
        if ($HalfTimelineClipId -and $row.clipId -eq $HalfTimelineClipId) {
            $originalFrames = @($row.frames)
            $row.frames = @(for ($index=0; $index -lt $originalFrames.Count; $index+=2) { $originalFrames[$index] })
        }
        $row.frameCount = @($row.frames).Count
        foreach ($frame in $row.frames) {
            $frameCount++
            $frame | Add-Member -NotePropertyName sourceWidth -NotePropertyValue $frame.width
            $frame | Add-Member -NotePropertyName sourceHeight -NotePropertyValue $frame.height
            $frame.width = 1920; $frame.height = 1080
            $frame.PSObject.Properties.Remove('analysisLogPaths')
            $frame.PSObject.Properties.Remove('analysisStatsPaths')
            foreach ($key in @('image','diffSigned','diffAbsolute','diffAbsoluteDisplay')) {
                if ($frame.PSObject.Properties[$key] -and $frame.$key) { $selectedImages[$frame.$key.Replace('\','/')] = $true }
            }
        }
    }
    }
    if ($selectedImages.Count -ne $preparedBySource.Count) { throw 'Prepared image count differs from selected frame images.' }
    $assets = @{}
    # Only explicitly hash-linked performance/quality source reports may become JSON
    # assets. Copy their original bytes; rewriting their contents would break
    # the native report fingerprints used by the combined matrix.
    $resultsRoot = [IO.Path]::GetFullPath((Join-Path $root 'results')).TrimEnd([char]92)
    foreach ($reportKind in @('performance','quality')) {
    $reportSources = if ($payload.$reportKind -and $payload.$reportKind.PSObject.Properties['sourceRuns']) { @($payload.$reportKind.sourceRuns) } else { @() }
    foreach ($sourceRecord in $reportSources) {
        $sourceValue = if ($sourceRecord.PSObject.Properties['report'] -and $sourceRecord.report) { [string]$sourceRecord.report }
            elseif ($sourceRecord.PSObject.Properties['reportPath'] -and $sourceRecord.reportPath) { [string]$sourceRecord.reportPath }
            else { throw 'A source report has no usable report path.' }
        $expectedHash = if ($sourceRecord.PSObject.Properties['sha256']) { [string]$sourceRecord.sha256 } else { '' }
        if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'A source report has no valid recorded SHA-256.' }
        if ($sourceValue -match '^file:') {
            $sourceUri = New-Object Uri($sourceValue)
            if (-not $sourceUri.IsFile) { throw 'A source report must be a local file.' }
            $source = $sourceUri.LocalPath
        } elseif ([IO.Path]::IsPathRooted($sourceValue)) { $source = $sourceValue }
        else { $source = Join-Path $root $sourceValue }
        $source = [IO.Path]::GetFullPath($source)
        if (-not $source.StartsWith($resultsRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($source) -ine '.json') { throw 'A source report must be JSON inside the repository results tree.' }
        # Checking the leaf alone misses junctions in its parent directories.
        $cursor = $source
        while ($cursor) {
            $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse source report path rejected: $cursor" }
            if ($cursor -eq $source -and ($entry -isnot [IO.FileInfo])) { throw 'A source report must be an ordinary file.' }
            if ($cursor.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { break }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
        $file = Get-Item -LiteralPath $source -Force
        $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw "Source report fingerprint changed: $source" }
        $originalReport = [IO.File]::ReadAllText($source) | ConvertFrom-Json
        if ($originalReport.schemaVersion -ne 1 -or $originalReport.kind -ne $reportKind -or $originalReport.dryRun) { throw "A provenance asset must be an actual $reportKind report, not configuration or a dry run." }
        if ($sourceRecord.PSObject.Properties['runId'] -and $sourceRecord.runId -ne $originalReport.runId) { throw 'Source report run ID differs from its provenance record.' }
        $relative = $source.Substring($root.Length+1).Replace('\','/')
        $target = 'assets/execution/'+$relative
        if ($assets.ContainsKey($source)) {
            if ($assets[$source].expectedSha256 -ne $actualHash) { throw 'Conflicting source report fingerprints.' }
        } else {
            $assets[$source] = [pscustomobject]@{ source=$source; sourceRelative=$relative; sourceSha256=$actualHash; path=$target; kind='execution'; bytes=$file.Length; expectedSha256=$actualHash; sha256=$null }
        }
        $sourceRecord | Add-Member -NotePropertyName report -NotePropertyValue $target -Force
    }
    }
    function Convert-WebAsset {
        param([string]$Value)
        if ($Value -notmatch '(?i)^(?:results[\\/]|work[\\/]|file:|[a-z]:[\\/])' -or $Value -notmatch '(?i)\.(?:png|html|txt)$') { return $Value }
        $source = if ($Value -match '^file:') { (New-Object Uri($Value)).LocalPath } elseif ([IO.Path]::IsPathRooted($Value)) { $Value } else { Join-Path $root $Value }
        $source = [IO.Path]::GetFullPath($source)
        if (-not $source.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($source)) { return $Value }
        $relative = $source.Substring($root.Length+1).Replace('\','/')
        if ($relative -notmatch '^(?:results|work)/') { return $Value }
        $extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
        $kind = if ($extension -eq '.png') { 'images' } else { 'execution' }
        $sourceSha = $null; $expectedSha = $null
        if ($kind -eq 'images') {
            if (-not $selectedImages.ContainsKey($relative) -or -not $preparedBySource.ContainsKey($relative)) { throw "Unselected or unprepared image: $relative" }
            $image = $preparedBySource[$relative]
            $copySource = [IO.Path]::GetFullPath((Join-Path $imageRoot $image.targetRelative))
            if (-not $copySource.StartsWith($imageRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Prepared image escaped its directory.' }
            $target = 'assets/images/'+$image.targetRelative
            $expectedSha = $image.sha256; $sourceSha = $image.sourceSha256
            if ((Get-Item -LiteralPath $source).Length -ne $image.sourceBytes) { throw 'Native source image changed.' }
        } else { $copySource = $source; $target = 'assets/execution/'+$relative }
        if (-not $assets.ContainsKey($source)) {
            $file = Get-Item -LiteralPath $copySource
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse asset rejected: $relative" }
            if ($kind -eq 'images' -and $file.Length -ne $image.bytes) { throw 'Prepared image length changed.' }
            $assets[$source] = [pscustomobject]@{ source=$copySource; sourceRelative=$relative; sourceSha256=$sourceSha; path=$target; kind=$kind; bytes=$file.Length; expectedSha256=$expectedSha; sha256=$null }
        }
        return $target
    }
    function Convert-WebValues {
        param([object]$Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [string]) { return Convert-WebAsset $Value }
        if ($Value -is [Collections.IDictionary]) { foreach ($key in @($Value.Keys)) { $Value[$key] = Convert-WebValues $Value[$key] } }
        elseif ($Value -is [pscustomobject]) { foreach ($property in @($Value.PSObject.Properties)) { $property.Value = Convert-WebValues $property.Value } }
        elseif ($Value -is [Collections.IList]) { for ($index=0; $index -lt $Value.Count; $index++) { $Value[$index] = Convert-WebValues $Value[$index] } }
        return ,$Value
    }
    $payload = Convert-WebValues $payload
    foreach ($report in @($payload.performance,$payload.quality) | Where-Object { $null -ne $_ }) {
        foreach ($row in $report.results) {
            if ($row.PSObject.Properties['execution'] -and $row.execution) {
                foreach ($key in @('log','graph')) { if ($row.execution.$key -and $row.execution.$key -notmatch '^assets/execution/') { throw "Unresolved $key for $($row.clipId)/$($row.implementationId)." } }
            }
        }
    }
    if ($payload.performance) { $payload.performance.reportPath = 'reports/performance.json' }
    if ($payload.quality) { $payload.quality.reportPath = 'reports/quality.json' }
    $stride = @{}; if ($HalfTimelineClipId) { $stride[$HalfTimelineClipId] = 2 }
    $hosting = [ordered]@{ imageFormat='webp'; imageWidth=1920; imageHeight=1080; webpQuality=95; excludedClipIds=$ExcludeClipId; timelineStride=$stride; metrics='Measured on native 4K sources; not recomputed from the hosted images.' }
    $payload | Add-Member -NotePropertyName hosting -NotePropertyValue ([pscustomobject]$hosting)
    $orderedAssets = @($assets.Values | Sort-Object path)
    $imageAssets = @($orderedAssets | Where-Object kind -eq images)
    $rowCounts = @{}; foreach ($kind in @('performance','quality')) { $rowCounts[$kind] = if ($payload.$kind) { @($payload.$kind.results).Count } else { 0 } }
    $summary = [ordered]@{ schemaVersion=1; createdUtc=[DateTime]::UtcNow.ToString('o'); sourceViewerSha256=$dataHash; performanceRows=$rowCounts.performance; qualityRows=$rowCounts.quality; frames=$frameCount; imageFiles=$imageAssets.Count; imageBytes=($imageAssets | Measure-Object bytes -Sum).Sum; referencedFiles=$orderedAssets.Count; assetBytes=($orderedAssets | Measure-Object bytes -Sum).Sum; pagesMaximumBytes=1000000000; hosting=$hosting }
    if ($PlanOnly) { [pscustomobject]$summary | ConvertTo-Json -Depth 8; return }
    [void][IO.Directory]::CreateDirectory($destination)
    $utf8 = New-Object Text.UTF8Encoding -ArgumentList $false
    function Write-WebFile {
        param([string]$Relative,[string]$Contents)
        $path = Join-Path $destination $Relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path,$Contents,$utf8)
    }
    Copy-Item -LiteralPath (Join-Path $root 'viewer') -Destination $destination -Recurse
    $html = [IO.File]::ReadAllText((Join-Path $root 'index.html')).Replace('Metrics describe agreement with libplacebo. Every quality image uses native source dimensions.','Images: 1080p WebP, quality 95. Metrics describe agreement with libplacebo measured on the native 4K sources.')
    Write-WebFile 'index.html' $html
    Write-WebFile '.nojekyll' ''
    Write-WebFile '.gitignore' "_site/`n"
    Write-WebFile 'results/results-data.js' ('window.TonemappingSuite = '+($payload | ConvertTo-Json -Depth 64 -Compress)+';')
    Write-WebFile 'reports/performance.json' ($payload.performance | ConvertTo-Json -Depth 64 -Compress)
    Write-WebFile 'reports/quality.json' ($payload.quality | ConvertTo-Json -Depth 64 -Compress)
    Write-WebFile 'README.md' @'
# Tone Mapping Compared

This folder is a self-contained static results viewer. Open `index.html` locally, or serve the folder at any URL prefix. It contains the performance and quality results, all displayed images, and the FFmpeg logs and native execution graphs used by the viewer's buttons. The layout and controls match the local benchmark viewer.

## Image preparation

Displayed images are 1920 x 1080 WebP, quality 95, resized with Lanczos3 from native 3840 x 2160 PNGs. ISS results are excluded. Native runs extract up to 30 decoder-selected keyframes, retain the first then every third, or every fifth for HDR10 from 160 seconds. The export preserves that complete retained selection. Quality comparisons retain the selected tone-mapping curve, stock reference, metrics and difference images.

Performance measurements, quality metrics, timestamps, gains and commands describe the original 4K benchmark runs. Image resizing and lossy compression do not recalculate these measurements. `reports/` contains the filtered report snapshots. The original native artifacts and source reports remain in the benchmark repository. Per-frame internal analysis logs are omitted; the actual generation/transcode logs and graphs remain available in the viewer.

`site-manifest.json` records the prepared assets and their SHA-256 hashes, along with the native image fingerprints and the source viewer's fingerprint. No FFmpeg binaries, source videos or benchmark runtime are needed to view this site. Native graph HTML uses its FFmpeg-provided CDN renderer scripts, so viewing a graph requires Internet access.

## GitHub Pages

Commit this entire folder, including `assets/images/`, to the Pages repository. In repository Settings > Pages, select **GitHub Actions**. Run **Deploy results to Pages** manually from Actions. The workflow stages only the published files, checks that the site is below 1 GB, and deploys it. Images, logs, reports and graph HTML are served together; separate image storage is unnecessary.

The prepared site has not been uploaded or published automatically. See the official workflow documentation: https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
'@
    Write-WebFile '.github/workflows/pages.yml' @'
name: Deploy results to Pages
on:
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency:
  group: pages
  cancel-in-progress: false
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - uses: actions/checkout@v6
      - uses: actions/configure-pages@v5
      - name: Prepare static site
        run: |
          python3 - <<'PY'
          import pathlib, shutil
          out = pathlib.Path('_site')
          out.mkdir()
          for name in ['index.html', '.nojekyll', 'viewer', 'results', 'reports', 'assets', 'site-manifest.json']:
              src = pathlib.Path(name)
              if name == 'site-manifest.json' and not src.exists(): continue
              if src.is_dir(): shutil.copytree(src, out / name)
              else: shutil.copy2(src, out / name)
          total = sum(p.stat().st_size for p in out.rglob('*') if p.is_file())
          if total > 1_000_000_000: raise SystemExit('Published site exceeds the 1 GB GitHub Pages limit.')
          print(f'Complete Pages payload: {total} bytes.')
          PY
      - uses: actions/upload-pages-artifact@v4
        with:
          path: _site
      - name: Deploy
        id: deployment
        uses: actions/deploy-pages@v4
'@
    if (-not ('WebResultCopy' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
public static class WebResultCopy {
    public static string Copy(string source, string target, long expected) {
        using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (var hash = SHA256.Create()) {
            byte[] buffer = new byte[1024 * 1024]; long total = 0; int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) > 0) { output.Write(buffer, 0, count); hash.TransformBlock(buffer, 0, count, buffer, 0); total += count; }
            hash.TransformFinalBlock(buffer, 0, 0);
            if (total != expected) throw new IOException("Source length changed during export.");
            return BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
        }
    }
}
'@ }
    $copied = 0
    foreach ($asset in $orderedAssets) {
        $target = [IO.Path]::GetFullPath((Join-Path $destination $asset.path))
        if (-not $target.StartsWith($destination+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Asset escaped output directory.' }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        $asset.sha256 = [WebResultCopy]::Copy($asset.source,$target,$asset.bytes)
        if ($asset.expectedSha256 -and $asset.sha256 -ne $asset.expectedSha256) { throw "Prepared asset fingerprint changed: $($asset.path)" }
        $copied++
        if ($copied % 500 -eq 0) { Write-Host "Copied and fingerprinted $copied / $($orderedAssets.Count) result assets." }
    }
    if ((Get-FileHash -LiteralPath $dataPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dataHash) { throw 'Viewer export changed during the snapshot.' }
    $summary['assets'] = @($orderedAssets | Select-Object sourceRelative,sourceSha256,path,kind,bytes,sha256)
    $summary['pagesPayloadBytes'] = 0
    # Include the manifest's own changing byte-count field.
    for ($index=0; $index -lt 3; $index++) {
        Write-WebFile 'site-manifest.json' ($summary | ConvertTo-Json -Depth 8 -Compress)
        $summary.pagesPayloadBytes = (Get-ChildItem -LiteralPath $destination -Recurse -File -Force | Measure-Object Length -Sum).Sum
    }
    Write-WebFile 'site-manifest.json' ($summary | ConvertTo-Json -Depth 8 -Compress)
    if ($summary.pagesPayloadBytes -gt $summary.pagesMaximumBytes) { throw "Published copy is too large: $($summary.pagesPayloadBytes) bytes." }
    [pscustomobject]@{ outputDirectory=$destination; performanceRows=$summary.performanceRows; qualityRows=$summary.qualityRows; curveRows=$summary.curveRows; frames=$summary.frames; imageFiles=$summary.imageFiles; imageBytes=$summary.imageBytes; pagesPayloadBytes=$summary.pagesPayloadBytes } | ConvertTo-Json
} finally { & $releaseLease -Lease $lease }
