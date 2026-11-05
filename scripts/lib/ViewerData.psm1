#Requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-ViewerProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Test-ViewerSourceHash {
    param([object]$Hash, [object]$Expected)
    return $Hash -is [string] -and $Hash -match '^[a-fA-F0-9]{64}$' -and
        $Expected -is [string] -and $Expected -match '^[a-fA-F0-9]{64}$' -and
        $Hash.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ViewerCurrentClips {
    [CmdletBinding()]
    param([object]$Media)
    $ids = @{}
    foreach ($clip in @(Get-ViewerProperty $Media 'clips')) {
        $enabled = Get-ViewerProperty $clip 'enabled'
        $id = Get-ViewerProperty $clip 'id'
        $hash = Get-ViewerProperty $clip 'sha256'
        if ($enabled -isnot [bool] -or -not $enabled -or [string]::IsNullOrWhiteSpace($id) -or
            -not (Test-ViewerSourceHash $hash $hash)) { continue }
        if ($ids.ContainsKey($id)) { throw "Duplicate enabled, pinned viewer clip identity: $id" }
        $ids[$id] = $true
        $clip
    }
}

function Get-ViewerCurrentReport {
    [CmdletBinding()]
    param(
        [object]$Report,
        [AllowEmptyCollection()][object[]]$Clips = @(),
        [AllowEmptyCollection()][string[]]$ImplementationIds = @(),
        [hashtable]$SupportedSignals,
        [switch]$Performance
    )
    if ($null -eq $Report) { return $null }
    $expectedKind = if ($Performance) { 'performance' } else { 'quality' }
    if ((Get-ViewerProperty $Report 'kind') -cne $expectedKind) { return $null }
    # Keep archived reports, but export only the current method: prepared GPU
    # loops and quality frame ordinals without source frame-time collection.
    $method = Get-ViewerProperty $Report 'methodVersion'
    $minimumMethod = if ($Performance) { 3 } else { 4 }
    if (($method -isnot [int] -and $method -isnot [long]) -or $method -lt $minimumMethod) { return $null }
    $current = @{}
    foreach ($clip in @(Get-ViewerCurrentClips ([pscustomobject]@{ clips = $Clips }))) { $current[$clip.id] = $clip }
    $rows = New-Object 'Collections.Generic.List[object]'
    $rowKeys = @{}; $referenceClips = @{}; $referenceHashes = @{}
    foreach ($row in @(Get-ViewerProperty $Report 'results')) {
        $clipId = Get-ViewerProperty $row 'clipId'
        $implementationId = Get-ViewerProperty $row 'implementationId'
        $knownImplementation = $ImplementationIds -ccontains $implementationId
        if (-not $knownImplementation -and $Performance) {
            $baseId = Get-ViewerProperty $row 'catalogImplementationId'
            $vendor = Get-ViewerProperty $row 'openclVendor'
            # Performance variants retain the catalog filter identity. Permit
            # only the exact Intel/AMD suffix and matching recorded processing;
            # unknown filters and Quality variants remain outside this gate.
            $knownImplementation = $ImplementationIds -ccontains $baseId -and $vendor -cin @('intel', 'amd') -and
                $implementationId -ceq ($baseId + '-' + $vendor) -and
                (Get-ViewerProperty $row 'backend') -ceq 'opencl' -and
                (Get-ViewerProperty $row 'processing') -ceq ('opencl-' + $vendor)
        }
        if ([string]::IsNullOrWhiteSpace($clipId) -or -not $current.ContainsKey($clipId) -or
            -not $knownImplementation -or
            ($Performance -and $implementationId -eq 'stock-libplacebo')) { continue }
        $clip = $current[$clipId]
        $inputHash = Get-ViewerProperty (Get-ViewerProperty $row 'input') 'sha256'
        if ($clipId -cne $clip.id -or -not (Test-ViewerSourceHash $inputHash $clip.sha256)) { continue }
        $signal = Get-ViewerProperty $row 'toneMappingType'
        $currentSignal = Get-ViewerProperty $clip 'toneMappingType'
        if ($signal -and $currentSignal -and $signal -cne $currentSignal) { continue }
        if ($null -ne $SupportedSignals) {
            $catalogId = if ($ImplementationIds -ccontains $implementationId) { $implementationId } else { Get-ViewerProperty $row 'catalogImplementationId' }
            if ($SupportedSignals.ContainsKey($catalogId) -and @($SupportedSignals[$catalogId]) -cnotcontains $currentSignal) { continue }
        }
        $sequence = Get-ViewerProperty $row 'sequenceRequest'
        if ($null -ne $sequence -and -not (Test-ViewerSourceHash (Get-ViewerProperty $sequence 'sha256') $clip.sha256)) { continue }
        # input.sha256 is recorded before preflight. Do not require decoded
        # properties: a current-source eligibility failure is useful evidence.
        $rows.Add($row)
        $rowKeys[$clipId + '|' + $implementationId] = $true
        if ((Get-ViewerProperty $row 'isReference') -eq $true -and (Get-ViewerProperty $row 'status') -eq 'completed') {
            $referenceClips[$clipId] = $clip
            $referenceHashes[$clip.sha256] = $true
        }
    }
    # Copy the report shell instead of rewriting the caller's historical data.
    $copy = [ordered]@{}
    if ($Report -is [Collections.IDictionary]) {
        foreach ($name in $Report.Keys) { $copy[$name] = $Report[$name] }
    } else {
        foreach ($property in $Report.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    }
    $copy['results'] = @($rows.ToArray())
    if ($copy.Contains('canonicalKeys')) {
        $copy['canonicalKeys'] = @($copy['canonicalKeys'] | Where-Object { $rowKeys.ContainsKey([string]$_) })
    }
    if ($copy.Contains('referenceEqualityChecks')) {
        $copy['referenceEqualityChecks'] = @($copy['referenceEqualityChecks'] | Where-Object {
            $id = Get-ViewerProperty $_ 'clipId'
            $sequenceHash = Get-ViewerProperty (Get-ViewerProperty $_ 'sequenceRequest') 'sha256'
            $id -and $referenceClips.ContainsKey($id) -and $id -ceq $referenceClips[$id].id -and
                (Test-ViewerSourceHash $sequenceHash $referenceClips[$id].sha256)
        })
    }
    foreach ($name in @('referenceReuseChecks', 'referenceAssemblyChecks')) {
        if ($copy.Contains($name)) {
            $copy[$name] = @($copy[$name] | Where-Object {
                $hash = Get-ViewerProperty $_ 'sourceSha256'
                $sequenceHash = Get-ViewerProperty (Get-ViewerProperty $_ 'sequenceRequest') 'sha256'
                $hash -is [string] -and $referenceHashes.ContainsKey($hash) -and (Test-ViewerSourceHash $sequenceHash $hash)
            })
        }
    }
    if ($copy.Contains('referenceImplementationId') -and $ImplementationIds -cnotcontains $copy['referenceImplementationId']) {
        $copy['referenceImplementationId'] = $null
    }
    return [pscustomobject]$copy
}

function Read-ViewerReport {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Export-SuiteViewerData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][object]$Media
    )
    $performance = Read-ViewerReport (Join-Path $Configuration.paths.resultsPath 'performance.json')
    $quality = Read-ViewerReport (Join-Path $Configuration.paths.resultsPath 'quality.json')
    $clips = @(Get-ViewerCurrentClips -Media $Media)
    $implementationIds = @($Catalog.implementations.id)
    $supportedSignals = @{}
    foreach ($implementation in @($Catalog.implementations)) {
        $signals = Get-ViewerProperty $implementation 'toneMappingTypes'
        if ($null -ne $signals) { $supportedSignals[$implementation.id] = @($signals) }
    }
    $payload = [ordered]@{
        schemaVersion = 1
        exportedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        catalog = $Catalog
        clips = $clips
        configuration = [ordered]@{ binaries = $Configuration.binaries; paths = $Configuration.paths; devices = $Configuration.devices; exclude = $Configuration.exclude; benchmark = $Configuration.benchmark }
        performance = Get-ViewerCurrentReport -Report $performance -Clips $clips -ImplementationIds $implementationIds -SupportedSignals $supportedSignals -Performance
        quality = Get-ViewerCurrentReport -Report $quality -Clips $clips -ImplementationIds $implementationIds -SupportedSignals $supportedSignals
    }
    # Always export beside the viewer, including when raw reports are stored elsewhere.
    # Loading a script works from file:// in Edge without a server or local JSON fetch.
    $viewerResultsPath = Join-Path $RepositoryRoot 'results'
    if (-not (Test-Path -LiteralPath $viewerResultsPath -PathType Container)) { New-Item -ItemType Directory -Path $viewerResultsPath -Force | Out-Null }
    $destination = Join-Path $viewerResultsPath 'results-data.js'
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $json = $payload | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($destination, ('window.TonemappingSuite = ' + $json + ';'), $encoding)
    return $destination
}

Export-ModuleMember -Function Get-ViewerCurrentClips, Get-ViewerCurrentReport, Export-SuiteViewerData
