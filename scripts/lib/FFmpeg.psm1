# Windows PowerShell 5.1 / .NET Framework only. No jobs or script callbacks run
# on background threads: the framework reads both redirected pipes concurrently.
Set-StrictMode -Version 2.0

function Test-AbsoluteWindowsPath {
    param([string]$Value)
    # IsPathRooted also accepts C:relative and \root-relative on .NET Framework.
    return $Value -match '^(?:[a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))'
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)

    # Plain switches, numbers and paths do not need quotes. Retain CRT escaping
    # only for empty values, whitespace and literal quotes.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    # Use the Windows C runtime argv rules. In a quoted argument, backslashes
    # only need doubling before a literal quote and before the closing quote.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $slashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (2 * $slashes + 1))
        }
        elseif ($slashes -gt 0) {
            [void]$builder.Append([char]92, $slashes)
        }
        [void]$builder.Append($character)
        $slashes = 0
    }
    if ($slashes -gt 0) {
        [void]$builder.Append([char]92, (2 * $slashes))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function ConvertFrom-InvariantNumber {
    param([string]$Value)
    $number = 0.0
    if ([double]::TryParse($Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    return $null
}

function Get-FFmpegBenchmark {
    param([string]$Text)
    $pattern = 'bench:\s+utime=([0-9.eE+\-]+)s\s+stime=([0-9.eE+\-]+)s\s+rtime=([0-9.eE+\-]+)s'
    $items = [regex]::Matches($Text, $pattern)
    if ($items.Count -eq 0) { return $null }
    $item = $items[$items.Count - 1]
    return [pscustomobject][ordered]@{
        UserSeconds = ConvertFrom-InvariantNumber $item.Groups[1].Value
        SystemSeconds = ConvertFrom-InvariantNumber $item.Groups[2].Value
        WallSeconds = ConvertFrom-InvariantNumber $item.Groups[3].Value
    }
}

function Get-FFmpegProgress {
    param([string]$Text)
    $last = $null
    $block = @{}
    foreach ($line in ($Text -split '[\r\n]+')) {
        # -progress pipe:1 (or pipe:2) output has one key=value per line.
        if ($line -match '^([a-z_]+)=([^\s\r\n]*)$') {
            $block[$Matches[1]] = $Matches[2].Trim()
            if ($Matches[1] -eq 'progress') {
                $last = [pscustomobject][ordered]@{
                    Frame = if ($block.ContainsKey('frame')) { ConvertFrom-InvariantNumber $block.frame } else { $null }
                    Fps = if ($block.ContainsKey('fps')) { ConvertFrom-InvariantNumber $block.fps } else { $null }
                    Speed = if ($block.ContainsKey('speed')) { ConvertFrom-InvariantNumber ($block.speed -replace 'x$', '') } else { $null }
                    State = $block.progress
                    Source = 'progress'
                }
                $block = @{}
            }
            continue
        }
        # Standard -stats output is separated by CR and ends in a final frame=.
        if ($line -match '^\s*frame=\s*([0-9]+)\s+fps=\s*([0-9.eE+\-]+)') {
            $frame = ConvertFrom-InvariantNumber $Matches[1]
            $fps = ConvertFrom-InvariantNumber $Matches[2]
            $speed = $null
            if ($line -match '\bspeed=\s*([0-9.eE+\-]+)x') {
                $speed = ConvertFrom-InvariantNumber $Matches[1]
            }
            $last = [pscustomobject][ordered]@{
                Frame = $frame
                Fps = $fps
                Speed = $speed
                State = $null
                Source = 'stats'
            }
        }
    }
    return $last
}

function ConvertTo-PowerShellCommandLine {
    param([string]$FilePath, [string[]]$Arguments, [Collections.IDictionary]$Environment)
    $argumentLine = (@(foreach ($value in $Arguments) { ConvertTo-WindowsArgument $value }) -join ' ')
    $executableLiteral = "'" + $FilePath.Replace("'", "''") + "'"
    $executable = if ($FilePath -match '^[a-zA-Z]:[\\/][a-zA-Z0-9_./:\\+\-]+$') { $FilePath } else { $executableLiteral }
    # --% is built into Windows PowerShell 5.1 and preserves native CRT quoting,
    # including empty arguments and embedded quotes. Avoid its %ENV% expansion
    # for the uncommon command containing a literal environment-variable token.
    $environmentNames = @(if ($Environment) { @($Environment.Keys | Sort-Object) })
    if (@($environmentNames | Where-Object { [string]$_ -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' }).Count -gt 0 -or $argumentLine -match '%[A-Za-z_][A-Za-z0-9_()]*%' -or $argumentLine -match '[\r\n|]' -or @($Arguments | Where-Object { $_.Contains('"') }).Count -gt 0) {
        $literal = "'" + $argumentLine.Replace("'", "''") + "'"
        $environmentCode = @(if ($Environment) { foreach ($name in @($Environment.Keys | Sort-Object)) {
            "`$i.EnvironmentVariables['" + ([string]$name).Replace("'", "''") + "'] = '" + ([string]$Environment[$name]).Replace("'", "''") + "';"
        } }) -join ' '
        if ($environmentCode) { $environmentCode += ' ' }
        return "& { `$i = New-Object Diagnostics.ProcessStartInfo; `$i.FileName = $executableLiteral; `$i.Arguments = $literal; `$i.UseShellExecute = `$false; $environmentCode`$p = [Diagnostics.Process]::Start(`$i); `$p.WaitForExit(); `$p.Dispose() }"
    }
    $environmentPrefix = (@(foreach ($name in $environmentNames) { "`$env:$name = '" + ([string]$Environment[$name]).Replace("'", "''") + "'; " }) -join '')
    return $environmentPrefix + "& $executable --% $argumentLine"
}

function Get-PlexExternalCodecs {
    param([string]$FilePath)
    $codecRoot = Join-Path ([IO.Path]::GetDirectoryName($FilePath)) 'codecs'
    $manifestPath = Join-Path $codecRoot 'manifest.json'
    if (-not [IO.File]::Exists($manifestPath)) { return $null }
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.directoryName -notmatch '^[a-zA-Z0-9_-]+$' -or $manifest.executableSha256 -ne (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Plex external codec manifest does not match the configured executable.'
    }
    $directory = Join-Path $codecRoot $manifest.directoryName
    $modules = @(foreach ($entry in $manifest.modules) {
        if ($entry.name -notmatch '^[a-zA-Z0-9_-]+\.dll$' -or $entry.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid Plex codec manifest entry.' }
        $modulePath = Join-Path $directory $entry.name
        if (-not [IO.File]::Exists($modulePath) -or (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { throw "Plex external codec hash mismatch or missing file: $($entry.name)" }
        [pscustomobject]@{ name = $entry.name; filePath = $modulePath; sha256 = $entry.sha256; source = $entry.source }
    })
    if ($modules.Count -eq 0) { throw 'Plex external codec manifest contains no modules.' }
    $actualNames = @(Get-ChildItem -LiteralPath $directory -File -Filter '*.dll' | Select-Object -ExpandProperty Name | Sort-Object)
    if (($actualNames -join '|') -cne (@($modules.name | Sort-Object) -join '|')) { throw 'Plex codec directory contains unrecorded modules.' }
    # Plex parses a colon-separated av_get_token list. A trailing slash tells
    # its loader to scan a directory, rather than load the path as one DLL.
    $value = ($directory.TrimEnd([char]92) + '\').Replace('\', '\\').Replace(':', '\:').Replace("'", "\'").Replace(' ', '\ ')
    return [pscustomobject]@{ version = $manifest.codecVersion; manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant(); directory = $directory; environmentValue = $value; modules = $modules }
}

function Get-ProcessLogPaths {
    param([string]$LogPathPrefix, [string]$WorkingDirectory)
    if ([string]::IsNullOrWhiteSpace($LogPathPrefix)) { return $null }
    if (-not [IO.Path]::IsPathRooted($LogPathPrefix)) { $LogPathPrefix = Join-Path $WorkingDirectory $LogPathPrefix }
    $prefix = [IO.Path]::GetFullPath($LogPathPrefix)
    $directory = [IO.Path]::GetDirectoryName($prefix)
    [void][IO.Directory]::CreateDirectory($directory)
    $name = [IO.Path]::GetFileName($prefix)
    $logName = if ($name -match '^ffmpeg(?:[-_]|$)') { $name } else { 'ffmpeg-' + $name }
    return [pscustomobject]@{ Log = Join-Path $directory ($logName + '.txt'); StdErr = Join-Path $directory ($logName + '.txt'); Graph = Join-Path $directory ('graph-' + $name + '.html') }
}

function Get-ProcessArgumentValue {
    param([string[]]$Arguments, [string]$Name)
    for ($index = 0; $index -lt $Arguments.Count - 1; $index++) { if ($Arguments[$index] -eq $Name) { return $Arguments[$index + 1] } }
    return $null
}

function Get-ProcessLogHeader {
    param([string]$FilePath, [string[]]$Arguments, [string]$CommandLine, [string]$WorkingDirectory, [object]$LogContext)
    $video = Get-ProcessArgumentValue $Arguments '-i'
    $filter = Get-ProcessArgumentValue $Arguments '-vf'
    if (-not $filter) { $filter = Get-ProcessArgumentValue $Arguments '-filter_complex' }
    $source = [IO.Path]::GetFileName($FilePath)
    if ($null -ne $LogContext) {
        foreach ($property in @('Video', 'Filter', 'Source')) {
            $item = $LogContext.PSObject.Properties[$property]
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.Value)) {
                switch ($property) { 'Video' { $video = $item.Value } 'Filter' { $filter = $item.Value } 'Source' { $source = $item.Value } }
            }
        }
    }
    if (-not $video) { $video = '(no video input; inspection or utility command)' }
    if (-not $filter) { $filter = '(no filter graph)' }
    return "Filter: $filter`r`nVideo: $video`r`nFFmpeg source: $source`r`nFFmpeg executable: $FilePath`r`nCommand line (Windows PowerShell):`r`n$CommandLine`r`nWorking directory: $WorkingDirectory`r`nStarted UTC: $([DateTime]::UtcNow.ToString('o'))`r`n`r`n"
}

$script:ffmpegGraphLogo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\viewer\assets\ffmpeg-logo.png'))

function Update-FFmpegGraphLogo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $remote = 'https://trac.ffmpeg.org/ffmpeg-logo.png'
    if (-not [IO.File]::Exists($Path) -or -not [IO.File]::Exists($script:ffmpegGraphLogo)) { return }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if (-not $text.Contains($remote)) { return }
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)).TrimEnd([char]92) + '\'
    $relative = (New-Object Uri($directory)).MakeRelativeUri((New-Object Uri($script:ffmpegGraphLogo))).ToString()
    [IO.File]::WriteAllText($Path, $text.Replace($remote, $relative), (New-Object Text.UTF8Encoding -ArgumentList $false))
}

function Invoke-CapturedProcess {
    <#
    .SYNOPSIS
    Runs an absolute executable with simultaneous stdout/stderr capture.
    .DESCRIPTION
    Returns a result even on a nonzero exit or timeout. Invalid input and a
    failure to start throw. Output is text; use output files for binary media.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [ValidateRange(1, 2147483)][int]$TimeoutSeconds = 120,
        [string]$LogPathPrefix,
        [object]$LogContext,
        [Collections.IDictionary]$Environment,
        [string]$ProgressActivity,
        [ValidateRange(1,60)][int]$ProgressIntervalSeconds=5
    )

    if (-not (Test-AbsoluteWindowsPath $FilePath)) {
        throw 'FilePath must be an absolute executable path.'
    }
    if (-not (Test-AbsoluteWindowsPath $WorkingDirectory)) {
        throw 'WorkingDirectory must be an absolute directory path.'
    }
    $FilePath = [IO.Path]::GetFullPath($FilePath)
    $WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not [IO.File]::Exists($FilePath)) { throw "Executable not found: $FilePath" }
    if (-not [IO.Directory]::Exists($WorkingDirectory)) {
        throw "Working directory not found: $WorkingDirectory"
    }
    foreach ($argument in $Arguments) {
        if ($null -eq $argument -or $argument.IndexOf([char]0) -ge 0) {
            throw 'Arguments must contain strings without NUL characters.'
        }
    }
    $quoted = @(foreach ($argument in $Arguments) { ConvertTo-WindowsArgument $argument })
    $argumentLine = $quoted -join ' '
    $commandLine = ConvertTo-PowerShellCommandLine -FilePath $FilePath -Arguments $Arguments -Environment $Environment
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $argumentLine
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    if ($Environment) { foreach ($name in @($Environment.Keys)) { $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name] } }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stopwatch = New-Object System.Diagnostics.Stopwatch
    $started = $false
    $timedOut = $false
    $terminationError = $null
    $captureError = $null
    $exitCode = $null
    $stdOut = ''
    $stdErr = ''
    $captureComplete = $false
    $startedAt = [DateTime]::UtcNow
    $logFiles = Get-ProcessLogPaths -LogPathPrefix $LogPathPrefix -WorkingDirectory $WorkingDirectory
    if ($null -ne $logFiles) {
        $requestedGraph = Get-ProcessArgumentValue $Arguments '-print_graphs_file'
        if ($requestedGraph) {
            $logFiles.Graph = if ([IO.Path]::IsPathRooted($requestedGraph)) { $requestedGraph } else { Join-Path $WorkingDirectory $requestedGraph }
        }
    }
    $logStream = $null
    $logHeader = ''
    try {
        if ($null -ne $logFiles) {
            $logHeader = Get-ProcessLogHeader -FilePath $FilePath -Arguments $Arguments -CommandLine $commandLine -WorkingDirectory $WorkingDirectory -LogContext $LogContext
            [IO.File]::WriteAllText($logFiles.Log, $logHeader, (New-Object Text.UTF8Encoding -ArgumentList $false))
            $logStream = New-Object IO.FileStream($logFiles.Log, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        }
        $stopwatch.Start()
        $started = $process.Start()
        if (-not $started) { throw "Failed to start executable: $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        # stderr streams directly to the one log; stdout is only retained in
        # memory for progress/help parsing. No command JSON or stdout sidecar.
        $stderrTask = if ($null -ne $logStream) { $process.StandardError.BaseStream.CopyToAsync($logStream) } else { $process.StandardError.ReadToEndAsync() }
        $process.StandardInput.Close()
        $exited=$false
        if ([string]::IsNullOrWhiteSpace($ProgressActivity)) {
            $exited=$process.WaitForExit($TimeoutSeconds * 1000)
        } else {
            Write-Host ("    {0} started (PID {1}; timeout {2} s)." -f $ProgressActivity,$process.Id,$TimeoutSeconds)
            $nextProgress=[double]$ProgressIntervalSeconds
            while (-not $exited) {
                $remainingMs=$TimeoutSeconds*1000-$stopwatch.ElapsedMilliseconds
                if ($remainingMs -le 0) { break }
                $exited=$process.WaitForExit([int][math]::Min(500,$remainingMs))
                if (-not $exited -and $stopwatch.Elapsed.TotalSeconds -ge $nextProgress) {
                    Write-Host ("    {0}: running, {1:0} s elapsed (PID {2})." -f $ProgressActivity,$stopwatch.Elapsed.TotalSeconds,$process.Id)
                    $nextProgress=$stopwatch.Elapsed.TotalSeconds+$ProgressIntervalSeconds
                }
            }
        }
        if (-not $exited) {
            $timedOut = $true
            try { $process.Kill() }
            catch { $terminationError = $_.Exception.Message }
            # Windows PowerShell 5.1 has no Kill(entireProcessTree). Our FFmpeg
            # pipelines do not launch child tools. Do not wait indefinitely.
            [void]$process.WaitForExit(5000)
        }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        try {
            $tasks = [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
            $captureComplete = [System.Threading.Tasks.Task]::WaitAll($tasks, 5000)
        }
        catch { $captureError = $_.Exception.Message }
        if ($stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $stdOut = $stdoutTask.Result
        }
        if ($stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            if ($null -eq $logStream) { $stdErr = $stderrTask.Result }
        }
        if (-not $captureComplete -and $null -eq $captureError) {
            $captureError = 'Redirected output did not close within the bounded drain wait.'
        }
    }
    finally {
        $stopwatch.Stop()
        if ($started -and -not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        $process.Dispose()
        if ($null -ne $logStream) { $logStream.Dispose() }
    }
    if ($null -ne $logFiles) {
        $stdErr = [IO.File]::ReadAllText($logFiles.Log, [Text.Encoding]::UTF8).Substring($logHeader.Length)
    }
    $result = [pscustomobject][ordered]@{
        FilePath = $FilePath
        Arguments = [string[]]@($Arguments)
        CommandLine = $commandLine
        WorkingDirectory = $WorkingDirectory
        TimeoutSeconds = $TimeoutSeconds
        ExitCode = $exitCode
        TimedOut = $timedOut
        StdOut = $stdOut
        StdErr = $stdErr
        ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
        StartedAtUtc = $startedAt.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        FinishedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        OutputCaptureComplete = $captureComplete
        TerminationError = $terminationError
        CaptureError = $captureError
        Benchmark = Get-FFmpegBenchmark $stdErr
        Progress = Get-FFmpegProgress ($stdErr + "`n" + $stdOut)
        LogFiles = $logFiles
    }
    if ($null -ne $logFiles) {
        $footer = "`r`nFinished UTC: $($result.FinishedAtUtc)`r`nExit code: $exitCode`r`nTimed out: $timedOut`r`nCapture complete: $captureComplete`r`n"
        [IO.File]::AppendAllText($logFiles.Log, $footer, (New-Object Text.UTF8Encoding -ArgumentList $false))
        if (-not [IO.File]::Exists($logFiles.Graph)) { $logFiles.Graph = $null }
        else { try { Update-FFmpegGraphLogo -Path $logFiles.Graph } catch { } }
    }
    return $result
}

function Invoke-FFmpegProcess {
    <#
    .SYNOPSIS
    Runs FFmpeg without console input, preserving exact argv and diagnostics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [ValidateRange(1, 2147483)][int]$TimeoutSeconds = 120,
        [string]$LogPathPrefix,
        [object]$LogContext
    )
    if ($Arguments -contains '-stdin') {
        throw 'Scripted FFmpeg calls cannot use -stdin; use file inputs.'
    }
    $effectiveArguments = [string[]]@($Arguments)
    if ($Arguments -notcontains '-nostdin') {
        $effectiveArguments = [string[]](@('-nostdin') + @($Arguments))
    }
    $plex = [IO.Path]::GetFileName($FilePath) -match '(?i)plex'
    if ($null -ne $LogContext -and $null -ne $LogContext.PSObject.Properties['Source'] -and $LogContext.Source -match '(?i)plex') { $plex = $true }
    $environment = @{}; $externalCodecs = $null
    if ($plex) {
        $externalCodecs = Get-PlexExternalCodecs -FilePath $FilePath
        # Do not inherit an unrecorded codec cache from a server/shell process.
        $environment['FFMPEG_EXTERNAL_LIBS'] = $(if ($externalCodecs) { $externalCodecs.environmentValue } else { '' })
    }
    if (-not [string]::IsNullOrWhiteSpace($LogPathPrefix) -and -not $plex -and $effectiveArguments -notcontains '-print_graphs_file') {
        $graphPaths = Get-ProcessLogPaths -LogPathPrefix $LogPathPrefix -WorkingDirectory $WorkingDirectory
        $effectiveArguments = [string[]](@('-print_graphs_file', $graphPaths.Graph, '-print_graphs_format', 'mermaidhtml') + @($effectiveArguments))
    }
    $result = Invoke-CapturedProcess -FilePath $FilePath -Arguments $effectiveArguments `
        -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPathPrefix $LogPathPrefix -LogContext $LogContext -Environment $environment
    if ($externalCodecs) {
        $after = Get-PlexExternalCodecs -FilePath $FilePath
        if ($after.manifestSha256 -ne $externalCodecs.manifestSha256) { throw 'Plex codec manifest changed during the invocation.' }
        $result | Add-Member -NotePropertyName ExternalCodecs -NotePropertyValue $externalCodecs
    }
    $result | Add-Member -NotePropertyName RequestedArguments -NotePropertyValue ([string[]]@($Arguments))
    return $result
}

Export-ModuleMember -Function Invoke-CapturedProcess, Invoke-FFmpegProcess, ConvertTo-PowerShellCommandLine, Get-PlexExternalCodecs, Update-FFmpegGraphLogo
