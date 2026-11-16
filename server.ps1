$ErrorActionPreference = 'Stop'
# Git reports normal push progress on stderr; use LASTEXITCODE to determine success.
$PSNativeCommandUseErrorActionPreference = $false
$Port = 8765
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HtmlPath = Join-Path $AppDir 'index.html'
$ConfigDir = Join-Path $env:LOCALAPPDATA 'IELTSStudyLog'
$ConfigPath = Join-Path $ConfigDir 'config.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Find-HeaderEnd([byte[]]$Bytes) {
    for ($i = 0; $i -le $Bytes.Length - 4; $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { return $i }
    }
    return -1
}

function Read-HttpRequest($Stream) {
    $memory = New-Object System.IO.MemoryStream
    $chunk = New-Object byte[] 8192
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $count = $Stream.Read($chunk, 0, $chunk.Length)
        if ($count -le 0) { throw 'Client closed the connection.' }
        $memory.Write($chunk, 0, $count)
        if ($memory.Length -gt 1048576) { throw 'Request headers are too large.' }
        $headerEnd = Find-HeaderEnd $memory.ToArray()
    }
    $all = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $headerLines = $headerText -split "`r`n"
    $requestLine = $headerLines[0] -split ' ', 3
    if ($requestLine.Length -lt 2) { throw 'Invalid HTTP request.' }
    $headers = @{}
    foreach ($line in ($headerLines | Select-Object -Skip 1)) {
        $colon = $line.IndexOf(':')
        if ($colon -gt 0) { $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim() }
    }
    $contentLength = 0
    if ($headers.ContainsKey('content-length')) { $contentLength = [int]$headers['content-length'] }
    if ($contentLength -gt 262144) { throw 'Request body is too large.' }
    $bodyStart = $headerEnd + 4
    while ($memory.Length -lt ($bodyStart + $contentLength)) {
        $remaining = New-Object byte[] 8192
        $count = $Stream.Read($remaining, 0, $remaining.Length)
        if ($count -le 0) { throw 'Incomplete request body.' }
        $memory.Write($remaining, 0, $count)
    }
    $all = $memory.ToArray()
    $body = ''
    if ($contentLength -gt 0) {
        $bodyBytes = New-Object byte[] $contentLength
        [Array]::Copy($all, $bodyStart, $bodyBytes, 0, $contentLength)
        $body = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
    }
    $target = [string]$requestLine[1]
    $path = ($target -split '\?', 2)[0]
    return [pscustomobject]@{ Method = $requestLine[0].ToUpperInvariant(); Path = $path; Headers = $headers; Body = $body }
}

function Send-Bytes($Client, [int]$Status, [string]$Reason, [string]$ContentType, [byte[]]$Body) {
    $stream = $Client.GetStream()
    $header = "HTTP/1.1 $Status $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) { $stream.Write($Body, 0, $Body.Length) }
    $stream.Flush()
}

function Send-Json($Client, [int]$Status, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
    Send-Bytes $Client $Status 'OK' 'application/json; charset=utf-8' $Utf8NoBom.GetBytes($json)
}

function Read-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try { return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { return [pscustomobject]@{ repoPath = '' } }
    }
    return [pscustomobject]@{ repoPath = '' }
}

function Invoke-Git([string]$Repository, [string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Repository @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }
    finally { $ErrorActionPreference = $previousPreference }
}
function Get-RepoCandidates {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $roots.Add('D:\Project\Personal')
    $roots.Add((Join-Path $env:USERPROFILE 'source\repos'))
    $roots.Add((Join-Path $env:USERPROFILE 'Documents\GitHub'))
    if ($env:IELTSLOG_REPO_ROOTS) {
        foreach ($customRoot in ($env:IELTSLOG_REPO_ROOTS -split ';')) {
            if (-not [string]::IsNullOrWhiteSpace($customRoot)) { $roots.Add($customRoot.Trim()) }
        }
    }
    $found = @{}
    foreach ($searchRoot in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) { continue }
        $candidates = New-Object 'System.Collections.Generic.List[string]'
        if (Test-Path -LiteralPath (Join-Path $searchRoot '.git')) { $candidates.Add($searchRoot) }
        foreach ($directory in (Get-ChildItem -LiteralPath $searchRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $directory.FullName '.git')) { $candidates.Add($directory.FullName) }
        }
        foreach ($candidate in $candidates) {
            $gitResult = Invoke-Git -Repository $candidate -Arguments @('rev-parse', '--show-toplevel')
            if ($gitResult.ExitCode -eq 0) {
                $repoPath = [System.IO.Path]::GetFullPath((($gitResult.Output -join [Environment]::NewLine).Trim()))
                $found[$repoPath] = [pscustomobject]@{ name = (Split-Path -Leaf $repoPath); path = $repoPath }
            }
        }
    }
    return @($found.Values | Sort-Object name)
}

function Escape-Md([string]$Text) {
    if ($null -eq $Text) { return '' }
    return ($Text.Trim() -replace '\|', '\|' -replace "`r?`n", '<br>')
}

function Get-HistoryEntries([string]$Repo) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $skillSlugs = @{ Listening = 'listening'; Reading = 'reading'; Writing = 'writing'; Speaking = 'speaking' }
    foreach ($skill in @('Listening', 'Reading', 'Writing', 'Speaking')) {
        $folder = Join-Path $Repo (Join-Path 'logs' $skillSlugs[$skill])
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter '????-??-??.md' -File -ErrorAction SilentlyContinue)) {
            $current = $null
            $details = $null
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)) {
                if ($line -match '^## (?<date>\d{4}-\d{2}-\d{2}) — (?<source>.*?) — (?<lesson>.*?) \((?<time>\d{2}:\d{2})\)$') {
                    if ($null -ne $current) {
                        $current.details = @($details.ToArray())
                        $entries.Add([pscustomobject]$current)
                    }
                    $details = New-Object 'System.Collections.Generic.List[object]'
                    $current = [ordered]@{ date = $Matches.date; time = $Matches.time; skill = $skill; source = $Matches.source; lesson = $Matches.lesson; minutes = 0; details = @() }
                    continue
                }
                if ($null -ne $current -and $line -match '^- \*\*(?<label>[^*]+):\*\* (?<value>.*)$') {
                    if ($Matches.label -eq 'Duration') {
                        $parsedMinutes = 0
                        if ([int]::TryParse(($Matches.value -replace '\s+minutes?$', ''), [ref]$parsedMinutes)) { $current.minutes = $parsedMinutes }
                    }
                    else { $details.Add([pscustomobject]@{ label = $Matches.label; value = $Matches.value }) }
                }
            }
            if ($null -ne $current) {
                $current.details = @($details.ToArray())
                $entries.Add([pscustomobject]$current)
            }
        }
    }
    return @($entries | Sort-Object @{ Expression = 'date'; Descending = $true }, @{ Expression = 'time'; Descending = $true })
}
function Handle-Request($Client, $Request) {
    $origin = $Request.Headers['origin']
    if ($origin -and $origin -ne "http://127.0.0.1:$Port" -and $origin -ne "http://localhost:$Port") {
        Send-Json $Client 403 @{ error = 'Requests from this origin are not allowed.' }; return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/') {
        $html = [System.IO.File]::ReadAllBytes($HtmlPath)
        Send-Bytes $Client 200 'OK' 'text/html; charset=utf-8' $html; return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/favicon.svg') {
        $iconPath = Join-Path $AppDir 'favicon.svg'
        if (Test-Path -LiteralPath $iconPath) { Send-Bytes $Client 200 'OK' 'image/svg+xml; charset=utf-8' ([System.IO.File]::ReadAllBytes($iconPath)); return }
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/api/config') {
        Send-Json $Client 200 (Read-Config); return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/api/repos') {
        Send-Json $Client 200 @{ repositories = @(Get-RepoCandidates) }; return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/api/history') {
        $config = Read-Config
        $repo = [string]$config.repoPath
        if (-not $repo -or -not (Test-Path -LiteralPath $repo -PathType Container)) { Send-Json $Client 400 @{ error = 'Select and link a local repository first.' }; return }
        Send-Json $Client 200 @{ entries = @(Get-HistoryEntries $repo) }; return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/api/version') {
        Send-Json $Client 200 @{ version = 4 }; return
    }
    if ($Request.Method -ne 'POST' -or $Request.Path -notin @('/api/config', '/api/save')) {
        Send-Json $Client 404 @{ error = 'Endpoint not found.' }; return
    }
    try { $data = $Request.Body | ConvertFrom-Json }
    catch { Send-Json $Client 400 @{ error = 'Invalid form data.' }; return }

    if ($Request.Path -eq '/api/config') {
        $repoPath = [string]$data.repoPath
        if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) { Send-Json $Client 400 @{ error = 'Repository folder not found.' }; return }
        $repoPath = (Resolve-Path -LiteralPath $repoPath).Path
        $gitResult = Invoke-Git -Repository $repoPath -Arguments @('rev-parse', '--show-toplevel')
        if ($gitResult.ExitCode -ne 0) { Send-Json $Client 400 @{ error = 'The selected folder is not a Git repository.' }; return }
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        @{ repoPath = $repoPath } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        Send-Json $Client 200 @{ repoPath = $repoPath; ok = $true }; return
    }

    $config = Read-Config
    $repo = [string]$config.repoPath
    if (-not $repo -or -not (Test-Path -LiteralPath $repo -PathType Container)) { Send-Json $Client 400 @{ error = 'Select and link a local repository first.' }; return }
    $skillFiles = @{ Listening = 'listening'; Reading = 'reading'; Writing = 'writing'; Speaking = 'speaking' }
    $skill = [string]$data.skill
    if (-not $skillFiles.ContainsKey($skill)) { Send-Json $Client 400 @{ error = 'Invalid skill.' }; return }
    $dateValue = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$data.studyDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dateValue)) { Send-Json $Client 400 @{ error = 'Invalid study date.' }; return }
    $minutes = 0
    if (-not [int]::TryParse([string]$data.minutes, [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) { Send-Json $Client 400 @{ error = 'Duration must be between 1 and 1440 minutes.' }; return }
    if (-not [string]$data.source -or -not [string]$data.lesson) { Send-Json $Client 400 @{ error = 'Enter a source and lesson title.' }; return }

    $stagedResult = Invoke-Git -Repository $repo -Arguments @('diff', '--cached', '--quiet')
    if ($stagedResult.ExitCode -eq 1) { Send-Json $Client 409 @{ error = 'The repository has other staged changes. Commit or unstage them before submitting.' }; return }
    if ($stagedResult.ExitCode -gt 1) { Send-Json $Client 500 @{ error = "Could not inspect the Git staging area: $($stagedResult.Output -join ' ')" }; return }

    $relative = "logs/$($skillFiles[$skill])/$($dateValue.ToString('yyyy-MM-dd')).md"
    $destination = Join-Path $repo (Join-Path (Join-Path 'logs' $skillFiles[$skill]) "$($dateValue.ToString('yyyy-MM-dd')).md")
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $destination)) { [System.IO.File]::WriteAllText($destination, "# IELTS $skill — $($dateValue.ToString('yyyy-MM-dd'))`r`n`r`n", $Utf8NoBom) }
    $time = Get-Date -Format 'HH:mm'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("## $($dateValue.ToString('yyyy-MM-dd')) — $(Escape-Md ([string]$data.source)) — $(Escape-Md ([string]$data.lesson)) ($time)")
    $lines.Add('')
    $lines.Add("- **Duration:** $minutes minutes")
    foreach ($detail in @($data.details)) {
        if ($detail.value -and $detail.label) { $lines.Add("- **$(Escape-Md ([string]$detail.label)):** $(Escape-Md ([string]$detail.value))") }
    }
    $lines.Add('')
    [System.IO.File]::AppendAllText($destination, (($lines -join "`r`n") + "`r`n"), $Utf8NoBom)

    $addResult = Invoke-Git -Repository $repo -Arguments @('add', '--', $relative)
    if ($addResult.ExitCode -ne 0) { Send-Json $Client 500 @{ error = "The log was saved locally, but git add failed: $($addResult.Output -join ' ')" }; return }
    $commitMessage = "Log IELTS $skill - $($dateValue.ToString('yyyy-MM-dd'))"
    $commitResult = Invoke-Git -Repository $repo -Arguments @('commit', '-m', $commitMessage)
    if ($commitResult.ExitCode -ne 0) { Send-Json $Client 500 @{ error = "The log was saved locally, but commit failed: $($commitResult.Output -join ' ') Check git user.name and user.email." }; return }
    $pushResult = Invoke-Git -Repository $repo -Arguments @('push')
    if ($pushResult.ExitCode -ne 0) {
        Send-Json $Client 200 @{ saved = $true; pushed = $false; file = $relative; message = "The log was saved and committed locally, but push failed: $($pushResult.Output -join ' ')" }; return
    }
    Send-Json $Client 200 @{ saved = $true; pushed = $true; file = $relative; message = 'Log saved, committed, and pushed successfully.' }
}

if (-not (Test-Path -LiteralPath $HtmlPath)) { Write-Error 'index.html was not found.'; exit 1 }
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() }
catch { Write-Error "Could not open port $Port. The app may already be running or the port is in use."; exit 1 }
Write-Host "IELTS Study Log is running at http://127.0.0.1:$Port"
Write-Host 'Listening on this computer only. Close this Command Prompt window or press Ctrl+C to stop.'
Start-Process "http://127.0.0.1:$Port/"
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 15000
        try {
            $request = Read-HttpRequest $client.GetStream()
            Handle-Request $client $request
        }
        catch {
            try { Send-Json $client 500 @{ error = "Server error: $($_.Exception.Message)" } } catch { }
            Write-Host $_.Exception.Message
        }
        finally { $client.Close() }
    }
}
finally { $listener.Stop() }
