@echo off
setlocal
title T-FLEX MCP Secure Launcher
set "TFLEX_LAUNCHER=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:TFLEX_LAUNCHER); $p=$t -split '(?m)^# TFLEX_MCP_POWERSHELL\r?$',2; if($p.Count -ne 2){exit 1}; & ([scriptblock]::Create($p[1]))"
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
# TFLEX_MCP_POWERSHELL
$ErrorActionPreference = 'Stop'
$GatewayProcess = $null
$TunnelProcess = $null
$Ready = $false
$Key = $null
$Headers = $null
function Protect-File([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop

    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to change permissions on a reparse point.'
    }

    # Read and modify only access rules; do not change the owner.
    $acl = $item.GetAccessControl(
        [Security.AccessControl.AccessControlSections]::Access
    )

    $acl.SetAccessRuleProtection($true, $false)

    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')

    foreach ($sid in @($userSid, $systemSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }

    $item.SetAccessControl($acl)
}
function Read-Key([string]$Path) {
    $secure = (Get-Content -LiteralPath $Path -Raw).Trim() | ConvertTo-SecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Test-Endpoint([string]$Url, [string]$Label) {
    foreach ($mode in @('none','wrong','hash','valid')) {
        $h = @{Accept='application/json, text/event-stream'; 'ngrok-skip-browser-warning'='1'}
        if ($mode -eq 'wrong') { $h.Authorization = 'Bearer invalid-' + [Guid]::NewGuid().ToString('N') }
        if ($mode -eq 'hash') { $h.Authorization = 'Bearer ' + $AuthorizationHash }
        if ($mode -eq 'valid') { $h.Authorization = 'Bearer ' + $Key }
        $response = $null
        $status = 0
        try {
            $response = Invoke-WebRequest -Method Post -Uri $Url -ContentType 'application/json' -Headers $h -Body $Body -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 30
            $status = [int]$response.StatusCode
        } catch {
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        }
        if ($mode -ne 'valid') {
            if ($status -ne 401 -and $status -ne 403) { throw "$Label rejected-auth check failed ($mode, HTTP $status)." }
        } else {
            if ($status -ne 200 -or -not $response) { throw "$Label valid-auth check failed (HTTP $status)." }
            $text = $response.Content
            if ($text.TrimStart().StartsWith('{')) { $payload = $text | ConvertFrom-Json }
            else {
                $payload = $null
                foreach ($line in ($text -split "`n")) {
                    if ($line -match '^data:\s*(\{.*\})\s*$') {
                        $candidate = $Matches[1] | ConvertFrom-Json
                        if ($candidate.result.tools) { $payload = $candidate; break }
                    }
                }
            }
            if (-not $payload -or $payload.error -or -not $payload.result.tools) { throw "$Label invalid tools/list response." }
            $actual = @($payload.result.tools | ForEach-Object { $_.name } | Sort-Object)
            $expected = @($Tools | Sort-Object)
            if (Compare-Object $expected $actual) { throw "$Label tool list does not match configured allowlist." }
        }
        Write-Host "$Label auth $mode : HTTP $status"
    }
}
function Stop-Owned($Process) {
    if ($Process) {
        $Process.Refresh()
        if (-not $Process.HasExited) { & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null }
    }
}
try {
    $Port = 8765
    # Optional fixed HTTPS endpoint. Empty uses the agent's configured/default domain.
    $NgrokUrl = ''
    $Tools = @(
        'tflex_bridge_ping','tflex_bridge_call','tflex_active_document','tflex_create_document','tflex_open_document',
        'tflex_list_variables','tflex_set_variable','tflex_create_variable','tflex_rebuild',
        'tflex_save','tflex_save_as','tflex_export','tflex_execute_csharp','tflex_launch',
        'tflex_docs','tflex_query_model','tflex_create_lcs','tflex_model_operation','tflex_fragment','tflex_mate',
        'gui_list_windows','gui_focus_window','gui_screenshot_window','gui_click','gui_hotkey','gui_type_text'
    )
    $LauncherDir = Split-Path -LiteralPath $env:TFLEX_LAUNCHER
    $ServerJs = Join-Path $LauncherDir 'mcp\server.js'
    $KeyDir = Join-Path $env:APPDATA 'TFlexMcp'
    $KeyFile = Join-Path $KeyDir 'mcp-api-key.dpapi'
    $PolicyFile = Join-Path $KeyDir 'ngrok-traffic-policy.yaml'
    $PowerShellExe = Join-Path $PSHOME 'powershell.exe'
    foreach ($name in @('node','npx','ngrok','Get-NetTCPConnection')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Required command missing: $name" }
    }
    if (-not (Test-Path -LiteralPath $ServerJs -PathType Leaf)) { throw 'Put this launcher in the repository root, beside Start-TFlexMcp.cmd.' }
    if (Get-Process -Name ngrok -ErrorAction SilentlyContinue) { throw 'ngrok is already running. Close the old tunnel manually first. It has not been modified.' }
    foreach ($p in @($Port,4040)) {
        if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { throw "Port $p is busy. Existing services were not modified." }
    }
    $ping = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:38517/command' -ContentType 'application/json' -Body '{"command":"ping","args":{}}' -TimeoutSec 5
    if (-not $ping.ok) { throw 'T-FLEX bridge did not answer ok=true.' }
    Write-Host 'T-FLEX bridge: OK (internal bridge authentication unchanged)'
    if (-not (Test-Path -LiteralPath $KeyFile -PathType Leaf)) {
        throw 'Existing DPAPI API key not found. No replacement was created. Configure the original launcher/key first.'
    }
    if ((Get-Item -LiteralPath $KeyDir).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Key directory must not be a reparse point.' }
    foreach ($f in @($KeyFile,$PolicyFile)) {
        if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Key/policy file must not be a reparse point.' }
    }
    $Key = Read-Key $KeyFile
    if ($Key -notmatch '^[A-Za-z0-9_-]{32,256}$') { throw 'API key format unsupported by this launcher. Key not printed or changed.' }
    Protect-File $KeyFile
    # Create/protect an empty file BEFORE writing the plaintext token.
    if (-not (Test-Path -LiteralPath $PolicyFile)) {
        $stream = [IO.File]::Open($PolicyFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Dispose()
    }
    Protect-File $PolicyFile
    # Hash the entire Authorization value as UTF-8, no newline.
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $AuthorizationHash = ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('Bearer ' + $Key))
        )).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $policy = @"
on_http_request:
  - expressions:
      - "size(getReqHeader('Authorization')) != 1 ? true : hash.sha256(getReqHeader('Authorization')[0], 'hex') != '$AuthorizationHash'"
    actions:
      - type: deny
        config:
          status_code: 401
"@
    if ($policy.Contains($Key) -or $policy -match 'Bearer ') {
        throw 'Policy unexpectedly contains plaintext credentials. No tunnel started.'
    }
    [IO.File]::WriteAllText($PolicyFile,$policy,(New-Object Text.UTF8Encoding($false)))
    $writtenPolicy = [IO.File]::ReadAllText($PolicyFile)
    if ($writtenPolicy -cne $policy -or $writtenPolicy.Contains($Key)) {
        throw 'Written hash policy verification failed. No tunnel started.'
    }
    $writtenPolicy = $null
    $policy = $null
    Write-Host 'Traffic policy: SHA-256 verifier only; plaintext token not written; restricted ACL.'
    $toolArgs = ($Tools | ForEach-Object { '--tools ' + $_ }) -join ' '
    $serverLiteral = $ServerJs.Replace("'","''")
    $keyLiteral = $KeyFile.Replace("'","''")
    $child = @'
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'T-FLEX MCP secure gateway'
$secure = (Get-Content -LiteralPath '__KEY__' -Raw).Trim() | ConvertTo-SecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $env:SUPERGATEWAY_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
$server = '__SERVER__'
npx -y supergateway --stdio ('node "' + $server + '"') --outputTransport streamableHttp --port __PORT__ --host 127.0.0.1 __TOOLS__
exit $LASTEXITCODE
'@
    $child = $child.Replace('__KEY__',$keyLiteral).Replace('__SERVER__',$serverLiteral).Replace('__PORT__',[string]$Port).Replace('__TOOLS__',$toolArgs)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
    $GatewayProcess = Start-Process $PowerShellExe -ArgumentList @('-NoLogo','-NoProfile','-EncodedCommand',$encoded) -PassThru
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        if ($GatewayProcess.HasExited -or (Get-Date) -gt $deadline) { throw 'Gateway startup failed or timed out.' }
        Start-Sleep -Milliseconds 500
    }
    $Body = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    Test-Endpoint "http://127.0.0.1:$Port/mcp" 'Local gateway'
    $ngrokArgs = 'http ' + $Port + ' --traffic-policy-file "' + $PolicyFile + '" --inspect=false'
    if ($NgrokUrl) {
        if ($NgrokUrl -notmatch '^https://[A-Za-z0-9.-]+/?$') { throw 'Invalid fixed ngrok URL.' }
        $ngrokArgs += ' --url ' + $NgrokUrl
    }
    $TunnelProcess = Start-Process -FilePath (Get-Command ngrok -CommandType Application).Source -ArgumentList $ngrokArgs -PassThru
    $PublicUrl = $null
    $deadline = (Get-Date).AddSeconds(45)
    while (-not $PublicUrl -and (Get-Date) -lt $deadline) {
        if ($TunnelProcess.HasExited) { throw 'ngrok exited. Check policy support, account limits and agent configuration.' }
        Start-Sleep -Seconds 1
        try {
            $tunnels = Invoke-RestMethod 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 3
            $matching = @($tunnels.tunnels | Where-Object { $_.proto -eq 'https' -and $_.config.addr -match "^(https?://)?(127\.0\.0\.1|localhost):$Port/?$" })
            if ($matching.Count -eq 1) { $PublicUrl = $matching[0].public_url }
        } catch { }
    }
    if (-not $PublicUrl -or $PublicUrl -notmatch '^https://[A-Za-z0-9.-]+/?$') { throw 'Could not verify exactly one HTTPS tunnel to the gateway.' }
    Test-Endpoint ($PublicUrl.TrimEnd('/') + '/mcp') 'Public endpoint'
    $Ready = $true
    Write-Host ''
    Write-Host ('READY: ' + $PublicUrl.TrimEnd('/') + '/mcp') -ForegroundColor Green
    Write-Host 'Connector: Streamable HTTP / existing API Key (unchanged).'
    Write-Host 'ngrok was launched with Traffic Policy; HTTP tests alone do not independently attest edge enforcement.'
    Write-Host 'Full tool set remains enabled, including C#, raw bridge calls and GUI tools.' -ForegroundColor Yellow
    Write-Host 'This does not add authentication to the internal T-FLEX bridge.' -ForegroundColor Yellow
    Write-Host 'Keep this launcher open. Press Enter to stop ONLY the gateway/tunnel started here.'
    [void](Read-Host)
} catch {
    # Avoid echoing exception text that might include authorization headers/policy contents.
	Write-Host ('Startup/check failed at script line ' +    $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
Write-Host ('Exception type: ' + $_.Exception.GetType().FullName)
Write-Host ('Error ID: ' + $_.FullyQualifiedErrorId)
} finally {
    Stop-Owned $TunnelProcess
    Stop-Owned $GatewayProcess
    $Key = $null
    $Headers = $null
    $child = $null
}
if ($Ready) { exit 0 } else { exit 1 }
