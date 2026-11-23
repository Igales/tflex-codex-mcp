@echo off
setlocal
title T-FLEX MCP - Launcher
set "TFLEX_LAUNCHER=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$text = [IO.File]::ReadAllText($env:TFLEX_LAUNCHER); $parts = $text -split '(?m)^# TFLEX_MCP_POWERSHELL\r?$', 2; if ($parts.Count -ne 2) { Write-Error 'Launcher payload not found'; exit 1 }; & ([scriptblock]::Create($parts[1]))"
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" echo Startup failed. Read the messages above. Existing processes were not stopped.
pause
exit /b %RESULT%
# TFLEX_MCP_POWERSHELL
$ErrorActionPreference = 'Stop'
try {
    # ---- Settings ----
    $Port      = 8765
    $BridgeUrl = 'http://127.0.0.1:38517/command'
    $Tools     = @(
        'tflex_bridge_ping', 'tflex_bridge_call', 'tflex_active_document', 'tflex_open_document',
        'tflex_list_variables', 'tflex_set_variable', 'tflex_create_variable', 'tflex_rebuild',
        'tflex_save', 'tflex_save_as', 'tflex_export', 'tflex_execute_csharp', 'tflex_launch',
        'tflex_docs',
        'tflex_query_model', 'tflex_create_lcs', 'tflex_model_operation', 'tflex_fragment', 'tflex_mate',
        'gui_list_windows', 'gui_focus_window', 'gui_screenshot_window', 'gui_click', 'gui_hotkey', 'gui_type_text'
    )
    # ------------------

    $LauncherDir = Split-Path -LiteralPath $env:TFLEX_LAUNCHER
    $ServerJs    = Join-Path $LauncherDir 'mcp\server.js'
    $KeyDir      = Join-Path $env:APPDATA 'TFlexMcp'
    $KeyFile     = Join-Path $KeyDir 'mcp-api-key.dpapi'
    $PowerShellExe = Join-Path $PSHOME 'powershell.exe'

    if (-not (Test-Path -LiteralPath $ServerJs -PathType Leaf)) { throw ('Required file missing: ' + $ServerJs) }
    foreach ($Name in @('node', 'npx', 'ngrok', 'Get-NetTCPConnection')) {
        if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw ('Required command not found: ' + $Name) }
    }

    # T-FLEX bridge must already be running inside T-FLEX CAD
    try {
        $Ping = Invoke-RestMethod -Method Post -Uri $BridgeUrl -ContentType 'application/json' -Body '{"command":"ping","args":{}}' -TimeoutSec 5
        if (-not $Ping.ok) { throw 'bridge answered ok=false' }
    } catch { throw 'T-FLEX bridge is not reachable on 127.0.0.1:38517. Start T-FLEX CAD with the plugin first. No process started.' }
    Write-Host 'T-FLEX bridge: OK'

    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        throw ("Port $Port is busy. The gateway may already be running. No process started.")
    }

    # API key (DPAPI, current Windows user only)
    if (-not (Test-Path -LiteralPath $KeyFile -PathType Leaf)) {
        New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
        $chars = [char[]]'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
        $bytes = New-Object byte[] 40
        $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
        $rng.GetBytes($bytes)
        $NewKey = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
        ConvertTo-SecureString $NewKey -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $KeyFile
        Set-Clipboard -Value $NewKey
        Write-Host 'New API key created and copied to clipboard. Paste it into the Perplexity connector (API Key) now.' -ForegroundColor Yellow
        $NewKey = $null
    }
    $Sec = (Get-Content -LiteralPath $KeyFile -Raw).Trim() | ConvertTo-SecureString
    $Key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Sec))

    # Gateway window
    $ToolArgs = ($Tools | ForEach-Object { '--tools ' + $_ }) -join ' '
    $ServerScript = @'
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'T-FLEX MCP gateway'
$sec = (Get-Content -LiteralPath '__KEYFILE__' -Raw).Trim() | ConvertTo-SecureString
$env:SUPERGATEWAY_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
Write-Host 'Gateway 127.0.0.1:__PORT__ | tools: __TOOLS__'
npx -y supergateway --stdio "node __SERVERJS__" --outputTransport streamableHttp --port __PORT__ --host 127.0.0.1 __TOOLARGS__
'@
    $ServerScript = $ServerScript.Replace('__KEYFILE__', $KeyFile).Replace('__PORT__', [string]$Port).Replace('__TOOLS__', ($Tools -join ', ')).Replace('__SERVERJS__', $ServerJs).Replace('__TOOLARGS__', $ToolArgs)
    $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ServerScript))
    Write-Host 'Starting gateway (full tool set)...'
    $ServerProcess = Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoLogo', '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $Encoded) -PassThru

    $Deadline = (Get-Date).AddSeconds(90)
    while (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        if ($ServerProcess.HasExited) { throw 'Gateway window closed before the port opened. No tunnel started.' }
        if ((Get-Date) -ge $Deadline) { throw 'Gateway startup timeout. Inspect the gateway window. No process was killed.' }
        Start-Sleep -Milliseconds 500
    }

    # Authenticated local check
    $Url = "http://127.0.0.1:$Port/mcp"
    $Body = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    $NoKeyCode = 0
    try { Invoke-WebRequest -Method Post -Uri $Url -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream' } -Body $Body -UseBasicParsing -TimeoutSec 15 | Out-Null; $NoKeyCode = 200 }
    catch { if ($_.Exception.Response) { $NoKeyCode = [int]$_.Exception.Response.StatusCode } }
    if ($NoKeyCode -ne 401 -and $NoKeyCode -ne 403) { throw ("Gateway accepted a request WITHOUT a key (code $NoKeyCode). Stop it and inspect. No tunnel started.") }
    $Headers = @{ Accept = 'application/json, text/event-stream'; Authorization = ('Bearer ' + $Key) }
    $Resp = Invoke-WebRequest -Method Post -Uri $Url -ContentType 'application/json' -Headers $Headers -Body $Body -UseBasicParsing -TimeoutSec 20
    $Count = ([regex]::Matches($Resp.Content, '"name":"')).Count
    if ($Count -ne $Tools.Count) { throw ("Gateway exposes $Count tools, expected $($Tools.Count). No tunnel started.") }
    Write-Host ("Gateway check: no key = $NoKeyCode, with key = $Count tools.")

    # Tunnel
    $PublicUrl = $null
    if (Get-Process -Name ngrok -ErrorAction SilentlyContinue) {
        try {
            $Tun = Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 5
            $Match = @($Tun.tunnels | Where-Object { $_.proto -eq 'https' -and $_.config.addr -match "^(https?://)?(127\.0\.0\.1|localhost):$Port/?$" })
        } catch { throw 'ngrok is running, but its local API could not verify the tunnel. Not modified.' }
        if ($Match.Count -ne 1) { throw "ngrok is running without exactly one HTTPS tunnel to port $Port. Not modified." }
        $PublicUrl = $Match[0].public_url
        Write-Host ('Reusing ngrok tunnel: ' + $PublicUrl)
    } else {
        Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoLogo', '-NoProfile', '-NoExit', '-Command', "ngrok http $Port") | Out-Null
        $Deadline = (Get-Date).AddSeconds(40)
        while (-not $PublicUrl -and (Get-Date) -lt $Deadline) {
            Start-Sleep -Seconds 1
            try {
                $Tun = Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 3
                $Match = @($Tun.tunnels | Where-Object { $_.proto -eq 'https' })
                if ($Match.Count -ge 1) { $PublicUrl = $Match[0].public_url }
            } catch { }
        }
        if (-not $PublicUrl) { throw 'ngrok did not report a tunnel in 40 s. Check the ngrok window (agent version, authtoken).' }
    }

    # Public check
    $Pub = Invoke-WebRequest -Method Post -Uri ($PublicUrl + '/mcp') -ContentType 'application/json' -Headers $Headers -Body $Body -UseBasicParsing -TimeoutSec 30
    $PubCount = ([regex]::Matches($Pub.Content, '"name":"')).Count
    $Key = $null; $Headers = $null
    Write-Host ''
    Write-Host ('Public MCP endpoint: ' + $PublicUrl + '/mcp') -ForegroundColor Green
    Write-Host ("Public check with key: $PubCount tools.")
    Write-Host 'Connector: Streamable HTTP, auth = API Key.'
    Write-Host 'Keep the gateway and ngrok windows open. Stop each with Ctrl+C. Nothing was killed or modified.'
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'No existing process was stopped. Inspect any window already opened.'
    exit 1
}