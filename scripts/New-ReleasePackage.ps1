#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$UserConfigPath,
    [string]$OutputPath,
    [switch]$OmitBinaries,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'lib/Configuration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/RunLock.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/ViewerData.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/FFmpeg.psm1')
# Load an existing Windows/.NET Framework assembly, without compiling helpers.
[void][Reflection.Assembly]::Load('System.IO.Compression, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
[void][Reflection.Assembly]::Load('System.IO.Compression.FileSystem, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char]92)
$configuration = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $UserConfigPath
$lease = Enter-SuiteRun -RepositoryRoot $repositoryRoot -Operation 'packaging'
$stagePath = $null; $partialPath = $null; $backupPath = $null
$encoding = New-Object Text.UTF8Encoding -ArgumentList $false
$files = @{}
$localSources = New-Object 'Collections.Generic.List[object]'

function Get-PackageProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-PackageStagePath {
    param([string]$Path)
    $workPrefix = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'work')).TrimEnd([char]92) + [char]92
    $absolute = [IO.Path]::GetFullPath($Path)
    if (-not $absolute.StartsWith($workPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^release-stage-[a-f0-9]{32}$') {
        throw "Refusing staging cleanup outside the checked workspace work directory: $absolute"
    }
    foreach ($candidate in @($workPrefix.TrimEnd([char]92), $absolute)) {
        if ((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Staging path must not be a junction or symbolic link: $candidate" }
    }
    return $absolute
}

function Copy-PackageFile {
    param([string]$SourcePath, [string]$RelativePath, [string]$Kind = 'suite', [string]$BuildSource)
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "Required package file is missing: $SourcePath" }
    if ((Get-Item -LiteralPath $SourcePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package source cannot be a symbolic link: $SourcePath" }
    $relative = $RelativePath.Replace([char]92, [char]47)
    $destination = [IO.Path]::GetFullPath((Join-Path $stagePath $RelativePath))
    if (-not $destination.StartsWith(($stagePath + [char]92), [StringComparison]::OrdinalIgnoreCase)) { throw 'Package entry escapes the staging directory.' }
    $hash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($files.ContainsKey($relative)) {
        if ($files[$relative].sha256 -ne $hash) { throw "Companion files collide with different contents: $relative. Keep each configured build's runtime files together." }
        return
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.File]::Copy($SourcePath, $destination, $true)
    $copiedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $copiedHash) { throw "Package source changed during copying: $RelativePath" }
    $files[$relative] = [pscustomobject][ordered]@{
        path = $relative; sha256 = $copiedHash; bytes = (Get-Item -LiteralPath $destination).Length
        kind = $Kind; buildSource = $BuildSource
    }
    $localSources.Add([pscustomobject]@{ archivePath = $relative; sourcePath = [IO.Path]::GetFullPath($SourcePath); sha256 = $copiedHash })
}

function Copy-PackageTree {
    param([string]$DirectoryName, [string[]]$Extensions)
    $directory = Join-Path $repositoryRoot $DirectoryName
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Required suite directory is missing: $directory" }
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Suite directory cannot be a junction or symbolic link: $directory" }
    $queue = New-Object 'Collections.Generic.Queue[string]'
    $queue.Enqueue($directory)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ($item.Name.StartsWith('.') -or $item.Name -match '^(?:private|secrets?|credentials?|media|results|work|node_modules)(?:[._-]|$)' -or $item.Name -match '\.private\.') { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Suite source tree contains a junction or symbolic link: $($item.FullName)" }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
            if ($Extensions -notcontains $item.Extension.ToLowerInvariant()) { continue }
            $relative = $item.FullName.Substring($repositoryRoot.Length).TrimStart([char]92)
            Copy-PackageFile -SourcePath $item.FullName -RelativePath $relative
        }
    }
}

function Add-PackageBinary {
    param([string]$Source, [string]$FilePath, [string]$RelativePath, [string]$Kind)
    Copy-PackageFile -SourcePath $FilePath -RelativePath $RelativePath -Kind $Kind -BuildSource $Source
    $parent = [IO.Path]::GetDirectoryName($FilePath)
    foreach ($dll in @(Get-ChildItem -LiteralPath $parent -File -Filter '*.dll')) {
        Copy-PackageFile -SourcePath $dll.FullName -RelativePath (Join-Path ([IO.Path]::GetDirectoryName($RelativePath)) $dll.Name) -Kind 'companion-dll' -BuildSource $Source
    }
    if ($Source -eq 'plex' -and $Kind -eq 'ffmpeg-executable') {
        $codecs = Get-PlexExternalCodecs -FilePath $FilePath
        if ($codecs) {
            $archiveRoot = Join-Path ([IO.Path]::GetDirectoryName($RelativePath)) 'codecs'
            Copy-PackageFile -SourcePath (Join-Path $parent 'codecs/manifest.json') -RelativePath (Join-Path $archiveRoot 'manifest.json') -Kind 'codec-manifest' -BuildSource $Source
            foreach ($codec in $codecs.modules) {
                Copy-PackageFile -SourcePath $codec.filePath -RelativePath (Join-Path (Join-Path $archiveRoot ([IO.Path]::GetFileName($codecs.directory))) $codec.name) -Kind 'external-codec' -BuildSource $Source
            }
        }
    }
}

function Write-PackageGeneratedFile {
    param([string]$RelativePath, [string]$Text)
    $destination = Join-Path $stagePath $RelativePath
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.File]::WriteAllText($destination, $Text, $encoding)
    $relative = $RelativePath.Replace([char]92, [char]47)
    $files[$relative] = [pscustomobject][ordered]@{
        path = $relative; sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $destination).Length; kind = 'generated'; buildSource = $null
    }
}

try {
    $workPath = Join-Path $repositoryRoot 'work'
    if ((Test-Path -LiteralPath $workPath) -and ((Get-Item -LiteralPath $workPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Workspace work directory cannot be a junction or symbolic link.' }
    [void][IO.Directory]::CreateDirectory($workPath)
    $stagePath = Assert-PackageStagePath (Join-Path $workPath ('release-stage-' + [Guid]::NewGuid().ToString('N')))
    [void][IO.Directory]::CreateDirectory($stagePath)
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $workPath ('releases/TonemappingCompared-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.zip') }
    $OutputPath = Resolve-SuitePath -RepositoryRoot $repositoryRoot -Path $OutputPath
    if ([IO.Path]::GetExtension($OutputPath) -ne '.zip') { throw 'OutputPath must name a .zip file.' }
    if (Test-Path -LiteralPath $OutputPath -PathType Container) { throw 'OutputPath points to a directory.' }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath))
    $partialPath = $OutputPath + '.' + [Guid]::NewGuid().ToString('N') + '.partial.zip'

    foreach ($name in @('index.html', 'README.md')) { Copy-PackageFile -SourcePath (Join-Path $repositoryRoot $name) -RelativePath $name }
    foreach ($launcher in @(Get-ChildItem -LiteralPath $repositoryRoot -File -Filter '*.cmd' | Where-Object { $_.Name -match '^\d\d-[A-Za-z][\w-]*\.cmd$' })) { Copy-PackageFile -SourcePath $launcher.FullName -RelativePath $launcher.Name }
    Copy-PackageTree 'scripts' @('.ps1', '.psm1', '.psd1')
    if (Test-Path -LiteralPath (Join-Path $repositoryRoot 'tests') -PathType Container) { Copy-PackageTree 'tests' @('.ps1', '.psm1', '.psd1') }
    Copy-PackageTree 'viewer' @('.html', '.js', '.css', '.svg', '.png', '.woff', '.woff2', '.txt')
    Copy-PackageTree 'docs' @('.md', '.txt', '.json', '.html', '.css', '.js', '.svg', '.png')
    foreach ($name in @('catalog.json', 'media.json')) { Copy-PackageFile -SourcePath (Join-Path $repositoryRoot ('config/' + $name)) -RelativePath ('config/' + $name) }
    foreach ($notice in @(Get-ChildItem -LiteralPath $repositoryRoot -File | Where-Object { $_.Name -match '^(?:LICENSE|COPYING|NOTICE)(?:[._-]|$)' })) { Copy-PackageFile -SourcePath $notice.FullName -RelativePath $notice.Name -Kind 'license-notice' }
    $originPath = Join-Path $repositoryRoot 'bin/binaries-info.txt'
    if (Test-Path -LiteralPath $originPath -PathType Leaf) { Copy-PackageFile -SourcePath $originPath -RelativePath 'bin/binaries-info.txt' -Kind 'provenance' }

    $evidencePath = Join-Path $repositoryRoot 'docs/filter-evidence/sources.json'
    $evidence = if (Test-Path -LiteralPath $evidencePath -PathType Leaf) { Read-SuiteJson -Path $evidencePath } else { $null }
    $packageBinaries = [ordered]@{}
    $builds = New-Object 'Collections.Generic.List[object]'
    $binaryPaths = @{ stock = 'bin/stock-ffmpeg.exe'; emby = 'bin/emby-ffmpeg.exe'; jellyfin = 'bin/jellyfin-ffmpeg.exe'; plex = 'bin/plex/Plex Transcoder.exe' }
    foreach ($source in @('stock', 'emby', 'jellyfin', 'plex')) {
        $configured = $configuration.binaries.$source
        $enabled = -not [string]::IsNullOrWhiteSpace([string]$configured.ffmpegPath)
        $relativeExecutable = $binaryPaths[$source]
        $packageBinaries[$source] = [ordered]@{ ffmpegPath = $(if ($enabled) { $relativeExecutable } else { $null }) }
        $build = [ordered]@{ source = $source; status = $(if (-not $enabled) { 'disabled' } elseif ($OmitBinaries) { 'omitted' } else { 'included' }); archiveExecutable = $(if ($enabled) { $relativeExecutable } else { $null }); sha256 = $null; version = $null; versionEvidenceStatus = 'unavailable'; licenseFiles = @() }
        if ($enabled -and -not $OmitBinaries) {
            Add-PackageBinary -Source $source -FilePath $configured.ffmpegPath -RelativePath $relativeExecutable -Kind 'ffmpeg-executable'
            $build.sha256 = $files[$relativeExecutable].sha256
            $captured = @()
            $capturedSources = Get-PackageProperty $evidence 'sources'
            if ($null -ne $capturedSources) {
                $captured = @($capturedSources | Where-Object {
                    $null -ne $_ -and (Get-PackageProperty $_ 'source') -eq $source -and (Get-PackageProperty $_ 'sha256') -eq $build.sha256
                })
            }
            if ($captured.Count -eq 1) {
                $versionLines = @([string]$captured[0].version -split '\r?\n' | Where-Object { $_ -match '^ffmpeg version' } | Select-Object -First 1)
                if ($versionLines.Count -gt 0) {
                    $build.version = $versionLines[0]
                    $build.versionEvidenceStatus = 'captured-binary-hash-matched'
                }
            }
            $licenseFiles = New-Object 'Collections.Generic.List[string]'
            $binaryDirectory = [IO.Path]::GetDirectoryName($configured.ffmpegPath)
            $noticeDirectories = @($binaryDirectory, [IO.Path]::GetDirectoryName($binaryDirectory)) | Select-Object -Unique
            $level = 0
            foreach ($noticeDirectory in $noticeDirectories) {
                foreach ($notice in @(Get-ChildItem -LiteralPath $noticeDirectory -File | Where-Object { $_.Name -match '^(?:LICENSE|COPYING|NOTICE)(?:[._-]|$)' })) {
                    $relativeNotice = 'bin/licenses/' + $source + '/' + $level + '-' + $notice.Name
                    Copy-PackageFile -SourcePath $notice.FullName -RelativePath $relativeNotice -Kind 'license-notice' -BuildSource $source
                    $licenseFiles.Add($relativeNotice)
                }
                $level++
            }
            $build.licenseFiles = @($licenseFiles.ToArray())
        }
        $builds.Add([pscustomobject]$build)
    }
    $example = [ordered]@{
        schemaVersion = 1; binaries = $packageBinaries
        paths = [ordered]@{ mediaPath = 'media'; tempOutputPath = 'work'; resultsPath = 'results' }
        devices = [ordered]@{ vulkan = 0; d3d11Adapter = $null; cuda = 0; opencl = [ordered]@{ platform = $null; device = $null; vendor = 'intel' } }
        exclude = [ordered]@{ software = $false; intel = $false; amd = $false; nvidia = $false }
        benchmark = [ordered]@{ filterThreads = 0; isolatedTargetSeconds = 5; repetitions = 3; transcodeDurationSeconds = 30; processTimeoutSeconds = 300; keepOutputs = $false }
    }
    Write-PackageGeneratedFile -RelativePath 'config/user.example.json' -Text ($example | ConvertTo-Json -Depth 12)
    $viewerData = [ordered]@{
        schemaVersion = 1; exportedUtc = [DateTime]::UtcNow.ToString('o')
        catalog = Read-SuiteJson -Path (Join-Path $stagePath 'config/catalog.json')
        clips = @(Get-ViewerCurrentClips -Media (Read-SuiteJson -Path (Join-Path $stagePath 'config/media.json')))
        configuration = $example
        performance = $null; quality = $null
    }
    Write-PackageGeneratedFile -RelativePath 'results/results-data.js' -Text ('window.TonemappingSuite = ' + ($viewerData | ConvertTo-Json -Depth 40) + ';')
    $manifest = [ordered]@{
        schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('o'); binaryMode = $(if ($OmitBinaries) { 'source-only' } else { 'configured-builds' })
        builds = @($builds.ToArray()); files = @($files.Values | Sort-Object path)
        exclusions = @('config/user.json', 'downloaded media', 'generated reports and image outputs', 'work directories', 'private/hidden source files', 'Git and agent metadata')
        legalStatus = 'Local review package only. Found notices are included; redistribution permission, complete license obligations, and corresponding-source requirements have not been verified. No permission is inferred from possession or public download URLs.'
        versionEvidence = 'Captured source-version evidence is used only when its binary SHA-256 matches. No configured executable is invoked during packaging.'
        hashScope = 'files lists every staged file except this manifest itself; the final archive SHA-256 is returned to the local caller.'
    }
    [IO.File]::WriteAllText((Join-Path $stagePath 'release-manifest.json'), ($manifest | ConvertTo-Json -Depth 24), $encoding)
    # .NET Framework CreateFromDirectory can write Windows separators in entry
    # names. Write explicit forward-slash names for a portable ZIP instead.
    $writer = [IO.Compression.ZipFile]::Open($partialPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in @($files.Keys | Sort-Object) + @('release-manifest.json')) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($writer, (Join-Path $stagePath $name), $name, [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $writer.Dispose() }
    $archive = [IO.Compression.ZipFile]::OpenRead($partialPath)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace([char]92, [char]47) })
        foreach ($name in @($files.Keys) + @('release-manifest.json')) { if ($names -notcontains $name) { throw "Archive verification found a missing entry: $name" } }
        if ($names.Count -ne ($files.Count + 1)) { throw 'Archive verification found unexpected entries.' }
    }
    finally { $archive.Dispose() }
    $archiveHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        $backupPath = $OutputPath + '.' + [Guid]::NewGuid().ToString('N') + '.backup'
        [IO.File]::Replace($partialPath, $OutputPath, $backupPath)
    }
    else { [IO.File]::Move($partialPath, $OutputPath) }
    $partialPath = $null
    if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) { Remove-Item -LiteralPath $backupPath -Force; $backupPath = $null }
    $result = [pscustomobject][ordered]@{
        OutputPath = $OutputPath; Sha256 = $archiveHash; Bytes = (Get-Item -LiteralPath $OutputPath).Length
        FileCount = $files.Count + 1; BinaryMode = $manifest.binaryMode; Builds = @($builds.ToArray())
        LocalSourceLocations = @($localSources.ToArray()); Published = $false
    }
    Write-Host ("Created local package: {0}" -f $OutputPath)
    Write-Host ("SHA-256: {0}" -f $archiveHash)
    if ($PassThru) { $result }
}
finally {
    try {
    if ($null -ne $partialPath -and (Test-Path -LiteralPath $partialPath -PathType Leaf)) { Remove-Item -LiteralPath $partialPath -Force }
    if ($null -ne $stagePath -and (Test-Path -LiteralPath $stagePath -PathType Container)) {
        $checkedStagePath = Assert-PackageStagePath $stagePath
        Remove-Item -LiteralPath $checkedStagePath -Recurse -Force
    }
    }
    finally { Exit-SuiteRun -Lease $lease }
}
