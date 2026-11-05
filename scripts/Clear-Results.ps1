#Requires -Version 5.1
<#
.SYNOPSIS
Clears generated results, FFmpeg logs and validation caches without removing source videos.
#>
[CmdletBinding()]
param(
    [string]$UserConfigPath,
    [string]$RepositoryRoot,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'lib/Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/RunLock.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/ViewerData.psm1')
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char]92)
if ($RepositoryRoot -eq [IO.Path]::GetPathRoot($RepositoryRoot).TrimEnd([char]92)) { throw 'RepositoryRoot must be a suite directory, not a drive or share root.' }
$configuration = Get-SuiteConfiguration -RepositoryRoot $RepositoryRoot -UserConfigPath $UserConfigPath

function Get-ClearFullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([char]92)
}

function Test-ClearWithin {
    param([string]$Path, [string]$Parent)
    return $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent.TrimEnd([char]92) + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ClearNoReparsePath {
    param([string]$Path)
    $current = Get-ClearFullPath $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing cleanup through a junction or symbolic link: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-ClearFolder {
    param([string]$Path, [string]$Label, [string[]]$ProtectedPaths)
    $full = Get-ClearFullPath $Path
    $driveRoot = [IO.Path]::GetPathRoot($full).TrimEnd([char]92)
    if ($full -eq $driveRoot -or (Test-ClearWithin $RepositoryRoot $full)) {
        throw "Refusing $Label cleanup at a drive root or a folder containing the repository: $full"
    }
    foreach ($area in $script:sensitiveTrees) {
        if ((Test-ClearWithin $full $area) -or (Test-ClearWithin $area $full)) {
            throw "Refusing $Label cleanup in a Windows or application settings folder: $full"
        }
    }
    foreach ($area in $script:personalRoots) {
        if (Test-ClearWithin $area $full) { throw "Refusing $Label cleanup at a personal folder root: $full" }
    }
    foreach ($protected in $ProtectedPaths) {
        if ((Test-ClearWithin $full $protected) -or (Test-ClearWithin $protected $full)) {
            throw "Refusing $Label cleanup overlapping source, configuration, binaries or media: $full"
        }
    }
    Assert-ClearNoReparsePath $full
    return $full
}

function Get-ClearTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-ClearNoReparsePath $directory
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing cleanup of a tree containing a junction or symbolic link: $($item.FullName)"
            }
            $item
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function Test-ClearLogFile {
    param([IO.FileInfo]$File)
    # Current combined logs/native graphs, older split logs/command sidecars,
    # and failed analysis statistic logs are all generated artifacts.
    return $File.Name -match '(?i)^ffmpeg(?:[-_].*)?\.txt$|^graph(?:[-_].*)?\.html$|\.(?:stderr|stdout)\.(?:log|txt)$|[-_.]command\.json$' -or
        $File.Extension.Equals('.log', [StringComparison]::OrdinalIgnoreCase)
}

$lease = Enter-SuiteRun -RepositoryRoot $RepositoryRoot -Operation 'clear-results'
try {
    $catalog = Read-SuiteJson (Join-Path $RepositoryRoot 'config/catalog.json')
    $media = Read-SuiteJson (Join-Path $RepositoryRoot 'config/media.json')
    if ($catalog.schemaVersion -ne 1 -or $media.schemaVersion -ne 1) { throw 'Cleanup requires schemaVersion 1 catalog and media files.' }
    $payload = [ordered]@{
        schemaVersion = 1; exportedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        catalog = $catalog; clips = @(Get-ViewerCurrentClips -Media $media); performance = $null; quality = $null
        configuration = [ordered]@{ binaries = $configuration.binaries; paths = $configuration.paths; devices = $configuration.devices; exclude = $configuration.exclude; benchmark = $configuration.benchmark }
    }
    # Serialize before deleting anything, rather than exporting retained reports.
    $emptyViewer = 'window.TonemappingSuite = ' + ($payload | ConvertTo-Json -Depth 40) + ';'
    $script:sensitiveTrees = @(
        $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        $env:APPDATA, $env:LOCALAPPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-ClearFullPath $_ }
    $script:personalRoots = @(
        $env:USERPROFILE, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyPictures'), [Environment]::GetFolderPath('MyVideos'),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-ClearFullPath $_ }
    $protected = New-Object 'Collections.Generic.List[string]'
    foreach ($name in @('scripts', 'config', 'bin', 'viewer', 'docs', 'tests', '.git', '.agents', '.codex')) {
        $protected.Add((Get-ClearFullPath (Join-Path $RepositoryRoot $name)))
    }
    $protected.Add((Get-ClearFullPath $configuration.userConfigPath))
    foreach ($source in @('stock', 'emby', 'jellyfin', 'plex')) {
        $path = $configuration.binaries.$source.ffmpegPath
        if ($path) {
            $protected.Add((Get-ClearFullPath $path))
            $binaryDirectory = [IO.Path]::GetDirectoryName($path)
            if (Test-Path -LiteralPath $binaryDirectory -PathType Container) {
                foreach ($dll in Get-ChildItem -LiteralPath $binaryDirectory -Filter '*.dll' -File -Force) { $protected.Add((Get-ClearFullPath $dll.FullName)) }
            }
        }
    }
    $mediaRoot = Assert-ClearFolder $configuration.paths.mediaPath 'media-cache' $protected.ToArray()
    $tempRoot = Assert-ClearFolder $configuration.paths.tempOutputPath 'temporary-log' ($protected.ToArray() + @($mediaRoot))
    $viewerRoot = Get-ClearFullPath (Join-Path $RepositoryRoot 'results')
    $resultRoots = @((Get-ClearFullPath $configuration.paths.resultsPath), $viewerRoot) | Select-Object -Unique
    foreach ($root in $resultRoots) {
        [void](Assert-ClearFolder $root 'results' ($protected.ToArray() + @($mediaRoot)))
        if (Test-ClearWithin $tempRoot $root) { throw "Refusing results cleanup containing the configured temporary folder: $root" }
    }
    # Overlapping configured/default result roots are handled once at the parent.
    $outerResultRoots = @($resultRoots | Where-Object {
        $candidate = $_
        @($resultRoots | Where-Object { $_ -ne $candidate -and (Test-ClearWithin $candidate $_) }).Count -eq 0
    })
    $actions = New-Object 'Collections.Generic.List[object]'
    foreach ($root in $outerResultRoots) {
        [void]@(Get-ClearTree $root)
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($item in Get-ChildItem -LiteralPath $root -Force) {
                $actions.Add([pscustomobject]@{ Path = $item.FullName; Root = $root; Recursive = [bool]$item.PSIsContainer })
            }
        }
    }
    $tempItems = @(Get-ClearTree $tempRoot)
    $validationRoot = Get-ClearFullPath (Join-Path $tempRoot 'media-validation')
    if (Test-Path -LiteralPath $validationRoot -PathType Container) {
        $actions.Add([pscustomobject]@{ Path = $validationRoot; Root = $tempRoot; Recursive = $true })
    }
    foreach ($item in $tempItems) {
        if (-not $item.PSIsContainer -and (Test-ClearLogFile $item) -and -not (Test-ClearWithin $item.FullName $validationRoot)) {
            $actions.Add([pscustomobject]@{ Path = $item.FullName; Root = $tempRoot; Recursive = $false })
        }
    }
    if (Test-Path -LiteralPath $mediaRoot -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $mediaRoot -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (-not $item.PSIsContainer -and ($item.Name -like '*.validation.json' -or (Test-ClearLogFile $item))) {
                    throw "Refusing linked media-cache artifact: $($item.FullName)"
                }
                continue
            }
            if (-not $item.PSIsContainer -and ($item.Name -like '*.validation.json' -or (Test-ClearLogFile $item))) {
                $actions.Add([pscustomobject]@{ Path = $item.FullName; Root = $mediaRoot; Recursive = $false })
            }
        }
    }
    # Validate the complete plan before the first mutation; then recheck each
    # literal path immediately before removal. Never compose another shell.
    foreach ($action in $actions) {
        $absolute = Get-ClearFullPath $action.Path
        if ($absolute -eq $action.Root -and -not ($absolute -eq $validationRoot)) {
            throw "Refusing deletion of an output folder root: $absolute"
        }
        if (-not (Test-ClearWithin $absolute $action.Root)) { throw "Cleanup target escaped its intended output folder: $absolute" }
        Assert-ClearNoReparsePath $absolute
    }
    $deleted = New-Object 'Collections.Generic.List[string]'
    foreach ($action in $actions | Sort-Object { $_.Path.Length }) {
        if (-not (Test-Path -LiteralPath $action.Path)) { continue }
        Assert-ClearNoReparsePath $action.Path
        if ($action.Recursive) { [void]@(Get-ClearTree $action.Path); Remove-Item -LiteralPath $action.Path -Recurse -Force }
        else { Remove-Item -LiteralPath $action.Path -Force }
        $deleted.Add($action.Path)
        Write-Verbose "Cleared: $($action.Path)"
    }
    Assert-ClearNoReparsePath $viewerRoot
    [void][IO.Directory]::CreateDirectory($viewerRoot)
    $viewerPath = Join-Path $viewerRoot 'results-data.js'
    [IO.File]::WriteAllText($viewerPath, $emptyViewer, (New-Object Text.UTF8Encoding -ArgumentList $false))
    Write-Host ("Cleared {0} result/log/cache entries; reset viewer: {1}" -f $deleted.Count, $viewerPath)
    if ($PassThru) { [pscustomobject]@{ DeletedPaths = @($deleted.ToArray()); ViewerDataPath = $viewerPath; Result = 'PASS' } }
}
finally { Exit-SuiteRun -Lease $lease }
