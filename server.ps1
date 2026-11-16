$ErrorActionPreference = 'Stop'
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

function Escape-Md([string]$Text) {
    if ($null -eq $Text) { return '' }
    return ($Text.Trim() -replace '\|', '\|' -replace "`r?`n", '<br>')
}

function Handle-Request($Client, $Request) {
    $origin = $Request.Headers['origin']
    if ($origin -and $origin -ne "http://127.0.0.1:$Port" -and $origin -ne "http://localhost:$Port") {
        Send-Json $Client 403 @{ error = 'Yêu cầu từ origin không được phép.' }; return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/') {
        $html = [System.IO.File]::ReadAllBytes($HtmlPath)
        Send-Bytes $Client 200 'OK' 'text/html; charset=utf-8' $html; return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/api/config') {
        Send-Json $Client 200 (Read-Config); return
    }
    if ($Request.Method -eq 'GET' -and $Request.Path -eq '/api/version') {
        Send-Json $Client 200 @{ version = 2 }; return
    }
    if ($Request.Method -ne 'POST' -or $Request.Path -notin @('/api/config', '/api/pick-repo', '/api/save')) {
        Send-Json $Client 404 @{ error = 'Không tìm thấy đường dẫn.' }; return
    }
    try { $data = $Request.Body | ConvertFrom-Json }
    catch { Send-Json $Client 400 @{ error = 'Dữ liệu form không hợp lệ.' }; return }

    if ($Request.Path -eq '/api/pick-repo') {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Chọn thư mục Git repository đã clone'
            $dialog.ShowNewFolderButton = $false
            $existing = Read-Config
            if ($existing.repoPath -and (Test-Path -LiteralPath $existing.repoPath -PathType Container)) { $dialog.SelectedPath = [string]$existing.repoPath }
            try { $choice = $dialog.ShowDialog() }
            finally { $dialog.Dispose() }
            if ($choice -ne [System.Windows.Forms.DialogResult]::OK) { Send-Json $Client 200 @{ cancelled = $true }; return }
            $selectedPath = $dialog.SelectedPath
            $root = & git -C $selectedPath rev-parse --show-toplevel 2>&1
            if ($LASTEXITCODE -ne 0) { Send-Json $Client 400 @{ error = 'Thư mục đã chọn không phải Git repository. Hãy chọn thư mục repo đã clone.' }; return }
            $repoPath = ([string]$root).Trim()
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
            @{ repoPath = $repoPath } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
            Send-Json $Client 200 @{ repoPath = $repoPath; ok = $true }; return
        }
        catch { Send-Json $Client 500 @{ error = "Không mở được hộp thoại chọn repo: $($_.Exception.Message)" }; return }
    }

    if ($Request.Path -eq '/api/config') {
        $repoPath = [string]$data.repoPath
        if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) { Send-Json $Client 400 @{ error = 'Không tìm thấy thư mục repo.' }; return }
        $repoPath = (Resolve-Path -LiteralPath $repoPath).Path
        $root = & git -C $repoPath rev-parse --show-toplevel 2>&1
        if ($LASTEXITCODE -ne 0) { Send-Json $Client 400 @{ error = 'Đường dẫn này chưa phải Git repository.' }; return }
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        @{ repoPath = $repoPath } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        Send-Json $Client 200 @{ repoPath = $repoPath; ok = $true }; return
    }

    $config = Read-Config
    $repo = [string]$config.repoPath
    if (-not $repo -or -not (Test-Path -LiteralPath $repo -PathType Container)) { Send-Json $Client 400 @{ error = 'Chọn và lưu repository local trước.' }; return }
    $skillFiles = @{ Listening = 'listening'; Reading = 'reading'; Writing = 'writing'; Speaking = 'speaking' }
    $skill = [string]$data.skill
    if (-not $skillFiles.ContainsKey($skill)) { Send-Json $Client 400 @{ error = 'Kỹ năng không hợp lệ.' }; return }
    $dateValue = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$data.studyDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dateValue)) { Send-Json $Client 400 @{ error = 'Ngày học không hợp lệ.' }; return }
    $minutes = 0
    if (-not [int]::TryParse([string]$data.minutes, [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) { Send-Json $Client 400 @{ error = 'Thời lượng phải từ 1 đến 1440 phút.' }; return }
    if (-not [string]$data.source -or -not [string]$data.lesson) { Send-Json $Client 400 @{ error = 'Hãy điền nguồn học và tên bài.' }; return }

    $staged = & git -C $repo diff --cached --quiet 2>&1
    if ($LASTEXITCODE -eq 1) { Send-Json $Client 409 @{ error = 'Repo đang có thay đổi khác đã stage. Hãy commit hoặc unstage chúng rồi submit lại.' }; return }
    if ($LASTEXITCODE -gt 1) { Send-Json $Client 500 @{ error = "Không kiểm tra được Git staging: $($staged -join ' ')" }; return }

    $relative = "logs/$($skillFiles[$skill]).md"
    $destination = Join-Path $repo (Join-Path 'logs' "$($skillFiles[$skill]).md")
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $destination)) { [System.IO.File]::WriteAllText($destination, "# IELTS $skill log`r`n`r`n", $Utf8NoBom) }
    $time = Get-Date -Format 'HH:mm'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("## $($dateValue.ToString('yyyy-MM-dd')) — $(Escape-Md ([string]$data.source)) — $(Escape-Md ([string]$data.lesson)) ($time)")
    $lines.Add('')
    $lines.Add("- **Thời lượng:** $minutes phút")
    foreach ($detail in @($data.details)) {
        if ($detail.value -and $detail.label) { $lines.Add("- **$(Escape-Md ([string]$detail.label)):** $(Escape-Md ([string]$detail.value))") }
    }
    $lines.Add('')
    [System.IO.File]::AppendAllText($destination, (($lines -join "`r`n") + "`r`n"), $Utf8NoBom)

    $addOutput = & git -C $repo add -- $relative 2>&1
    if ($LASTEXITCODE -ne 0) { Send-Json $Client 500 @{ error = "Log đã ghi ở local nhưng git add lỗi: $($addOutput -join ' ')" }; return }
    $commitMessage = "Log IELTS $skill - $($dateValue.ToString('yyyy-MM-dd'))"
    $commitOutput = & git -C $repo commit -m $commitMessage 2>&1
    if ($LASTEXITCODE -ne 0) { Send-Json $Client 500 @{ error = "Log đã ghi ở local nhưng commit lỗi: $($commitOutput -join ' ') Kiểm tra git user.name và user.email." }; return }
    $pushOutput = & git -C $repo push 2>&1
    if ($LASTEXITCODE -ne 0) {
        Send-Json $Client 200 @{ saved = $true; pushed = $false; file = $relative; message = "Log đã ghi và commit local. Push lỗi: $($pushOutput -join ' ')" }; return
    }
    Send-Json $Client 200 @{ saved = $true; pushed = $true; file = $relative; message = 'Đã ghi log, commit và push thành công.' }
}

if (-not (Test-Path -LiteralPath $HtmlPath)) { Write-Error 'Không tìm thấy index.html.'; exit 1 }
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() }
catch { Write-Error "Không mở được cổng $Port. Có thể app đã chạy hoặc cổng đang được dùng."; exit 1 }
Write-Host "IELTS Study Log đang chạy tại http://127.0.0.1:$Port"
Write-Host 'Chỉ nghe trên máy này. Đóng cửa sổ CMD hoặc nhấn Ctrl+C để dừng.'
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
            try { Send-Json $client 500 @{ error = "Lỗi server: $($_.Exception.Message)" } } catch { }
            Write-Host $_.Exception.Message
        }
        finally { $client.Close() }
    }
}
finally { $listener.Stop() }
