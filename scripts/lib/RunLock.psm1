#Requires -Version 5.1
Set-StrictMode -Version 2.0

function Enter-SuiteRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Operation
    )
    $normalizedRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char]92).ToUpperInvariant()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $rootHash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedRoot))).Replace('-', '') }
    finally { $hasher.Dispose() }
    $mutexName = 'Local\TonemappingCompared_' + $rootHash
    $mutex = New-Object System.Threading.Mutex -ArgumentList @($false, $mutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another suite run is active. Wait for it to finish before starting benchmarks, quality output, or GPU checks.' }
        return [pscustomobject]@{ Mutex = $mutex; Owned = $true; Operation = $Operation }
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-SuiteRun {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Lease)
    if ($Lease.Owned) {
        try { $Lease.Mutex.ReleaseMutex() }
        finally { $Lease.Owned = $false; $Lease.Mutex.Dispose() }
    }
}

Export-ModuleMember -Function Enter-SuiteRun, Exit-SuiteRun
