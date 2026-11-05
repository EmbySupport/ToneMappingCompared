#Requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-SuiteComparisonCurves {
    param([Parameter(Mandatory=$true)][object]$Catalog, [Parameter(Mandatory=$true)][string]$ToneMappingType)
    $profile = @($Catalog.qualityProfiles | Where-Object { $_.toneMappingType -eq $ToneMappingType })
    if ($profile.Count -ne 1) { throw "No quality comparison profile for $ToneMappingType." }
    return @($profile[0].curves)
}

function Set-SuiteImplementationCurve {
    param([Parameter(Mandatory=$true)][object]$Implementation, [Parameter(Mandatory=$true)][string]$Curve)
    if ($Curve -notin @($Implementation.supportedCurves)) { throw "$($Implementation.id) does not support tone mapping curve $Curve." }
    # Clone so performance defaults and later signal/curve runs cannot change.
    $copy = $Implementation | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    if ($copy.id -eq 'stock-swscale') {
        if ($Curve -ne 'spline') { throw 'swscale perceptual is included only in Spline quality comparisons.' }
        # This mapper has no curve AVOption. Its native perceptual behavior is
        # compared with Spline without adding an unsupported tonemap option.
        $copy | Add-Member -NotePropertyName comparisonCurve -NotePropertyValue $Curve -Force
        return $copy
    }
    $optionName = if ($copy.filter -eq 'libplacebo') { 'tonemapping' } else { 'tonemap' }
    $value = $Curve
    if ($copy.filter -eq 'libplacebo') {
        if ($Curve -eq 'bt2390') { $value = 'bt.2390' }
        if ($Curve -eq 'bt2446a') { $value = 'bt.2446a' }
    }
    $copy.filterOptions | Add-Member -NotePropertyName $optionName -NotePropertyValue $value -Force
    # Per-signal defaults must not replace the explicitly requested curve.
    if ($copy.PSObject.Properties['toneMappingOptions']) {
        foreach ($property in $copy.toneMappingOptions.PSObject.Properties) {
            if ($property.Value.PSObject.Properties[$optionName]) { $property.Value.$optionName = $value }
        }
    }
    $copy | Add-Member -NotePropertyName comparisonCurve -NotePropertyValue $Curve -Force
    return $copy
}

Export-ModuleMember -Function Get-SuiteComparisonCurves, Set-SuiteImplementationCurve
