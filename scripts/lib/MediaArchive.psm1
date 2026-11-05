#Requires -Version 5.1
Set-StrictMode -Version 2.0

function Expand-SuiteMediaArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][string]$DestinationPath,
        [Parameter(Mandatory=$true)][object]$Archive,
        [Parameter(Mandatory=$true)][long]$MediaSizeBytes
    )
    if ($Archive.format -ne 'zip' -or $Archive.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Archive.sizeBytes -le 0) { throw 'A ZIP download requires a pinned archive hash and size.' }
    $member = [string]$Archive.member
    # Select one original file, never extract a directory tree from a download.
    if ([string]::IsNullOrWhiteSpace($member) -or $member -ne [IO.Path]::GetFileName($member) -or $member.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $member.EndsWith('.') -or $member.EndsWith(' ') -or $member -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Archive member must be a safe root-level filename.' }
    if ($MediaSizeBytes -le 0) { throw 'An archive member requires a pinned original media size.' }
    if ((Get-Item -LiteralPath $ArchivePath).Length -ne [long]$Archive.sizeBytes) { throw 'Downloaded archive size differs from the manifest.' }
    if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $Archive.sha256) { throw 'Downloaded archive SHA-256 differs from the manifest.' }
    if (Test-Path -LiteralPath $DestinationPath) { throw 'Archive extraction destination already exists; it was preserved.' }
    [void][Reflection.Assembly]::Load('System.IO.Compression, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
    [void][Reflection.Assembly]::Load('System.IO.Compression.FileSystem, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArchivePath))
    $created = $false
    try {
        $entries = @($zip.Entries | Where-Object { [string]::Equals($_.FullName, $member, [StringComparison]::Ordinal) })
        if ($entries.Count -ne 1) { throw 'The pinned media member is missing or duplicated in the archive.' }
        if ($entries[0].Length -ne $MediaSizeBytes) { throw 'Archive member size differs from the pinned original media size.' }
        $inputStream = $entries[0].Open()
        try {
            # CreateNew prevents a concurrently appearing destination from being overwritten.
            $outputStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $created = $true
            try {
                $buffer = New-Object byte[] 1048576
                $written = [long]0
                while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $written += $read
                    if ($written -gt $MediaSizeBytes) { throw 'Extracted media exceeds the pinned size.' }
                    $outputStream.Write($buffer, 0, $read)
                }
                if ($written -ne $MediaSizeBytes) { throw 'Extracted media is shorter than the pinned size.' }
            } finally { $outputStream.Dispose() }
        } finally { $inputStream.Dispose() }
    } catch {
        if ($created -and (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) { Remove-Item -LiteralPath $DestinationPath -Force }
        throw
    } finally { $zip.Dispose() }
}

Export-ModuleMember -Function Expand-SuiteMediaArchive
