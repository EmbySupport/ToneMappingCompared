#Requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-SuiteProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-SuiteObject {
    param([object]$Value, [string]$Name)
    if ($null -eq $Value -or (($Value -isnot [pscustomobject]) -and ($Value -isnot [System.Collections.IDictionary]))) {
        throw "Configuration '$Name' must be a JSON object."
    }
}

function Assert-SuiteInteger {
    param([object]$Value, [string]$Name, [int]$Minimum = 0, [int]$Maximum = [int]::MaxValue)
    if (($Value -isnot [int]) -and ($Value -isnot [long])) {
        throw "Configuration '$Name' must be an integer from $Minimum to $Maximum."
    }
    if ($Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "Configuration '$Name' must be an integer from $Minimum to $Maximum."
    }
}

function Assert-SuiteBoolean {
    param([object]$Value, [string]$Name)
    if ($Value -isnot [bool]) { throw "Configuration '$Name' must be true or false." }
}

function Read-SuiteJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file was not found: $Path" }
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "Cannot read JSON file '$Path': $($_.Exception.Message)" }
    if ($null -eq $value) { throw "JSON file '$Path' must contain an object or array." }
    return $value
}

function Resolve-SuitePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A suite path cannot be empty.' }
    # Drive-relative paths (C:foo) depend on process state, and root-relative paths
    # (\foo) depend on the current drive. Require absolute or repository-relative.
    if ($Path -match '^[A-Za-z]:(?![\\/])' -or $Path -match '^[\\/](?![\\/])') {
        throw "Path '$Path' must be fully qualified or relative to the repository root."
    }
    try {
        $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
        if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
        return [System.IO.Path]::GetFullPath((Join-Path -Path $root -ChildPath $Path))
    }
    catch { throw "Cannot resolve suite path '$Path': $($_.Exception.Message)" }
}

function Get-SuiteConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [string]$UserConfigPath
    )
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Repository root was not found: $root" }
    if ([string]::IsNullOrWhiteSpace($UserConfigPath)) {
        $UserConfigPath = Join-Path $root 'config/user.json'
        if (-not (Test-Path -LiteralPath $UserConfigPath -PathType Leaf)) {
            $UserConfigPath = Join-Path $root 'config/user.example.json'
        }
    }
    $configurationPath = Resolve-SuitePath -RepositoryRoot $root -Path $UserConfigPath
    $configuration = Read-SuiteJson -Path $configurationPath
    Assert-SuiteObject $configuration 'root'
    $schemaVersion = Get-SuiteProperty $configuration 'schemaVersion'
    Assert-SuiteInteger $schemaVersion 'schemaVersion' 1 1
    foreach ($name in @('binaries', 'paths', 'devices', 'exclude')) {
        Assert-SuiteObject (Get-SuiteProperty $configuration $name) $name
    }

    $diagnostics = New-Object 'System.Collections.Generic.List[object]'
    foreach ($source in @('stock', 'emby', 'jellyfin', 'plex')) {
        $binary = Get-SuiteProperty $configuration.binaries $source
        Assert-SuiteObject $binary "binaries.$source"
        $ffmpegPath = Get-SuiteProperty $binary 'ffmpegPath'
        # A null ffmpeg path explicitly disables a build without inventing a PATH fallback.
        if ($null -eq $ffmpegPath) { continue }
        if (($ffmpegPath -isnot [string]) -or [string]::IsNullOrWhiteSpace($ffmpegPath)) {
            throw "Configuration 'binaries.$source.ffmpegPath' must be a nonempty path or null."
        }
        $resolved = Resolve-SuitePath -RepositoryRoot $root -Path $ffmpegPath
        $binary | Add-Member -MemberType NoteProperty -Name 'ffmpegPath' -Value $resolved -Force
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $diagnostics.Add([pscustomobject]@{
                code = 'binary-missing'; path = $resolved; source = $source
                message = "Missing binaries.$source.ffmpegPath: $resolved. Extract the release binaries or update this path in $configurationPath."
            })
        }
    }
    foreach ($name in @('mediaPath', 'tempOutputPath', 'resultsPath')) {
        $value = Get-SuiteProperty $configuration.paths $name
        if (($value -isnot [string]) -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Configuration 'paths.$name' must be a nonempty path."
        }
        $resolved = Resolve-SuitePath -RepositoryRoot $root -Path $value
        $configuration.paths | Add-Member -MemberType NoteProperty -Name $name -Value $resolved -Force
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { throw "Configuration 'paths.$name' points to a file, but must point to a directory: $resolved" }
    }
    if (-not (Test-Path -LiteralPath $configuration.paths.mediaPath -PathType Container)) {
        $diagnostics.Add([pscustomobject]@{
            code = 'media-directory-missing'; path = $configuration.paths.mediaPath; source = $null
            message = "Media directory does not exist: $($configuration.paths.mediaPath). Run the media download script or set paths.mediaPath to your verified clips."
        })
    }

    foreach ($name in @('vulkan', 'cuda')) {
        Assert-SuiteInteger (Get-SuiteProperty $configuration.devices $name) "devices.$name"
    }
    $d3d11Adapter = Get-SuiteProperty $configuration.devices 'd3d11Adapter'
    if ($null -ne $d3d11Adapter) { Assert-SuiteInteger $d3d11Adapter 'devices.d3d11Adapter' }
    $opencl = Get-SuiteProperty $configuration.devices 'opencl'
    Assert-SuiteObject $opencl 'devices.opencl'
    $platform = Get-SuiteProperty $opencl 'platform'
    $device = Get-SuiteProperty $opencl 'device'
    if (($null -eq $platform) -xor ($null -eq $device)) {
        throw 'Set both devices.opencl.platform and devices.opencl.device, or leave both null for vendor selection.'
    }
    if ($null -ne $platform) {
        Assert-SuiteInteger $platform 'devices.opencl.platform'
        Assert-SuiteInteger $device 'devices.opencl.device'
    }
    $vendor = Get-SuiteProperty $opencl 'vendor'
    if (($vendor -isnot [string]) -or @('intel', 'amd', 'nvidia', 'any') -notcontains $vendor) {
        throw "Configuration 'devices.opencl.vendor' must be intel, amd, nvidia, or any."
    }
    $opencl.vendor = $vendor.ToLowerInvariant()
    # Quality keeps its single selected OpenCL device. Performance tests select
    # Intel and AMD independently, without replacing that saved selection.
    $performanceOpencl = Get-SuiteProperty $configuration.devices 'performanceOpencl'
    if ($null -eq $performanceOpencl) {
        $performanceOpencl = [pscustomobject]@{}
        $configuration.devices | Add-Member -NotePropertyName performanceOpencl -NotePropertyValue $performanceOpencl
    }
    Assert-SuiteObject $performanceOpencl 'devices.performanceOpencl'
    foreach ($performanceVendor in @('intel', 'amd')) {
        $selection = Get-SuiteProperty $performanceOpencl $performanceVendor
        if ($null -eq $selection) {
            $selection = [pscustomobject]@{ platform = $null; device = $null; d3d11Adapter = $null }
            $performanceOpencl | Add-Member -NotePropertyName $performanceVendor -NotePropertyValue $selection
        }
        Assert-SuiteObject $selection "devices.performanceOpencl.$performanceVendor"
        foreach ($name in @('platform', 'device', 'd3d11Adapter')) {
            $value = Get-SuiteProperty $selection $name
            if ($null -ne $value) { Assert-SuiteInteger $value "devices.performanceOpencl.$performanceVendor.$name" }
            elseif ($null -eq $selection.PSObject.Properties[$name]) { $selection | Add-Member -NotePropertyName $name -NotePropertyValue $null }
        }
        if (($null -eq $selection.platform) -xor ($null -eq $selection.device)) {
            throw "Set both devices.performanceOpencl.$performanceVendor.platform and device, or leave both null for vendor selection."
        }
    }
    foreach ($name in @('software', 'intel', 'amd', 'nvidia')) {
        Assert-SuiteBoolean (Get-SuiteProperty $configuration.exclude $name) "exclude.$name"
    }

    $benchmarkDefaults = [ordered]@{
        filterThreads = 0; repetitions = 3
        transcodeDurationSeconds = 30; processTimeoutSeconds = 300
        keepOutputs = $false
    }
    $benchmark = Get-SuiteProperty $configuration 'benchmark'
    if ($null -eq $benchmark) {
        $benchmark = [pscustomobject]$benchmarkDefaults
        $configuration | Add-Member -MemberType NoteProperty -Name 'benchmark' -Value $benchmark
    }
    Assert-SuiteObject $benchmark 'benchmark'
    foreach ($name in $benchmarkDefaults.Keys) {
        if ($null -eq (Get-SuiteProperty $benchmark $name)) {
            $benchmark | Add-Member -MemberType NoteProperty -Name $name -Value $benchmarkDefaults[$name] -Force
        }
    }
    Assert-SuiteInteger $benchmark.filterThreads 'benchmark.filterThreads' 0
    Assert-SuiteInteger $benchmark.repetitions 'benchmark.repetitions' 1
    Assert-SuiteInteger $benchmark.transcodeDurationSeconds 'benchmark.transcodeDurationSeconds' 1
    Assert-SuiteInteger $benchmark.processTimeoutSeconds 'benchmark.processTimeoutSeconds' 1
    Assert-SuiteBoolean $benchmark.keepOutputs 'benchmark.keepOutputs'
    $configuration | Add-Member -MemberType NoteProperty -Name 'repositoryRoot' -Value $root -Force
    $configuration | Add-Member -MemberType NoteProperty -Name 'userConfigPath' -Value $configurationPath -Force
    $configuration | Add-Member -MemberType NoteProperty -Name 'diagnostics' -Value @($diagnostics.ToArray()) -Force
    return $configuration
}

function Expand-SuitePerformanceImplementations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Implementations)
    foreach ($implementation in $Implementations) {
        if ((Get-SuiteProperty $implementation 'backend') -ne 'opencl') { $implementation; continue }
        $vendors = @(Get-SuiteProperty $implementation 'deviceVendors')
        foreach ($vendor in @('intel', 'amd')) {
            if ($vendors.Count -gt 0 -and $vendors -notcontains $vendor) { continue }
            $copy = $implementation | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json
            $baseId = [string]$implementation.id
            $vendorLabel = if ($vendor -eq 'intel') { 'Intel' } else { 'AMD' }
            $copy.id = $baseId + '-' + $vendor
            $copy.label = [string]$implementation.label + ' (' + $vendorLabel + ')'
            $copy | Add-Member -NotePropertyName catalogImplementationId -NotePropertyValue $baseId -Force
            $copy | Add-Member -NotePropertyName openclVendor -NotePropertyValue $vendor -Force
            $copy | Add-Member -NotePropertyName processing -NotePropertyValue ('opencl-' + $vendor) -Force
            $copy.deviceVendors = @($vendor)
            $copy.testTypes = @($implementation.testTypes | Where-Object { $_ -in @('performance-isolated', 'performance-transcode') })
            $copy
        }
    }
}

function Get-SuiteImplementationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][object]$Implementation
    )
    $vendor = Get-SuiteProperty $Implementation 'openclVendor'
    if ($Implementation.backend -ne 'opencl' -or $vendor -notin @('intel', 'amd')) { return $Configuration }
    $copy = $Configuration | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json
    $selection = Get-SuiteProperty (Get-SuiteProperty $Configuration.devices 'performanceOpencl') $vendor
    $platform = Get-SuiteProperty $selection 'platform'
    $device = Get-SuiteProperty $selection 'device'
    # Existing explicit indices apply only to their saved vendor; never carry
    # an Intel index into the AMD variant (or the reverse).
    if ($null -eq $platform -and $Configuration.devices.opencl.vendor -eq $vendor) {
        $platform = $Configuration.devices.opencl.platform
        $device = $Configuration.devices.opencl.device
    }
    $copy.devices.opencl.vendor = $vendor
    $copy.devices.opencl.platform = $platform
    $copy.devices.opencl.device = $device
    $adapter = Get-SuiteProperty $selection 'd3d11Adapter'
    if ($null -eq $adapter -and $vendor -eq 'intel') { $adapter = Get-SuiteProperty $Configuration.devices 'd3d11Adapter' }
    $copy.devices | Add-Member -NotePropertyName d3d11Adapter -NotePropertyValue $adapter -Force
    return $copy
}

function Get-SuiteApplicableImplementations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][string]$ToneMappingType,
        [Parameter(Mandatory = $true)][string]$TestType,
        [Parameter(Mandatory = $true)][object]$Configuration
    )
    if ((Get-SuiteProperty $Catalog 'schemaVersion') -ne 1) { throw 'Unsupported catalog schemaVersion; expected 1.' }
    if (@($Catalog.toneMappingTypes.id) -notcontains $ToneMappingType) { throw "Unknown tone mapping type: $ToneMappingType" }
    if (@($Catalog.testTypes.id) -notcontains $TestType) { throw "Unknown test type: $TestType" }
    $implementations = @($Catalog.implementations)
    if ($TestType -in @('performance-isolated', 'performance-transcode')) {
        $implementations = @(Expand-SuitePerformanceImplementations -Implementations $implementations)
    }
    foreach ($implementation in $implementations) {
        if (@($implementation.testTypes) -notcontains $TestType) { continue }
        if (@($implementation.toneMappingTypes) -notcontains $ToneMappingType) { continue }
        if ($implementation.backend -eq 'software' -and $Configuration.exclude.software) { continue }
        $vendors = @(Get-SuiteProperty $implementation 'deviceVendors')
        if ($implementation.backend -eq 'cuda' -and $Configuration.exclude.nvidia) { continue }
        if ($implementation.backend -eq 'opencl') {
            $selectedVendor = Get-SuiteProperty $implementation 'openclVendor'
            if (-not $selectedVendor) { $selectedVendor = $Configuration.devices.opencl.vendor }
            if ($selectedVendor -ne 'any') {
                if (Get-SuiteProperty $Configuration.exclude $selectedVendor) { continue }
                if ($vendors.Count -gt 0 -and $vendors -notcontains $selectedVendor) { continue }
            }
        }
        if ($implementation.backend -ne 'software') {
            $allowedVendors = @($vendors | Where-Object { $_ -and -not (Get-SuiteProperty $Configuration.exclude $_) })
            if ($vendors.Count -gt 0 -and $allowedVendors.Count -eq 0) { continue }
        }
        $binary = Get-SuiteProperty $Configuration.binaries $implementation.source
        $ffmpegPath = Get-SuiteProperty $binary 'ffmpegPath'
        $binaryAvailable = $false
        if (-not [string]::IsNullOrWhiteSpace($ffmpegPath)) {
            $binaryAvailable = Test-Path -LiteralPath $ffmpegPath -PathType Leaf
        }
        $result = [ordered]@{}
        foreach ($property in $implementation.PSObject.Properties) { $result[$property.Name] = $property.Value }
        $result['ffmpegPath'] = $ffmpegPath
        $result['eligibilityStatus'] = 'preflight-required'
        if (-not $binaryAvailable) { $result['eligibilityStatus'] = 'binary-missing' }
        if ([string]::IsNullOrWhiteSpace($ffmpegPath)) { $result['eligibilityStatus'] = 'disabled' }
        $result['binaryAvailable'] = $binaryAvailable
        $result['deviceVendorCheckRequired'] = $implementation.backend -ne 'software'
        $result['deviceSelectionRequired'] = $implementation.backend -eq 'opencl' -and -not (Get-SuiteProperty $implementation 'openclVendor') -and $Configuration.devices.opencl.vendor -eq 'any' -and $vendors.Count -eq 1
        if ($result['deviceSelectionRequired'] -and $binaryAvailable) {
            $result['eligibilityStatus'] = 'device-selection-required'
        }
        $result['runtimeVerified'] = $false
        [pscustomobject]$result
    }
}

Export-ModuleMember -Function Read-SuiteJson, Resolve-SuitePath, Get-SuiteConfiguration, Get-SuiteApplicableImplementations, Expand-SuitePerformanceImplementations, Get-SuiteImplementationConfiguration
