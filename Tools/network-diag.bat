@echo off
setlocal EnableDelayedExpansion
title Network Diagnostics - System Repair Tool
color 0A

set "LF=%USERPROFILE%\Desktop\network-diag-%COMPUTERNAME%.txt"
set "PDF=%USERPROFILE%\Desktop\network-diag-%COMPUTERNAME%.pdf"
set "SUMMARY=%TEMP%\netdiag_summary.txt"
set "PSSCRIPT=%TEMP%\netdiag_pdf.ps1"
if exist "%LF%" del "%LF%"
if exist "%SUMMARY%" del "%SUMMARY%"

echo ============================================================
echo   NETWORK DIAGNOSTICS - System Repair Tool
echo   %DATE% %TIME%
echo   Computer: %COMPUTERNAME%
echo   This will take a few minutes. Please wait...
echo ============================================================
echo.

echo ============================================================>> "%LF%"
echo   NETWORK DIAGNOSTICS REPORT>> "%LF%"
echo   Date: %DATE% %TIME%>> "%LF%"
echo   Computer: %COMPUTERNAME%>> "%LF%"
echo   User: %USERNAME%>> "%LF%"
echo   Domain: %USERDOMAIN%>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"

:: ---- Write summary header ----
echo DATE=%DATE% %TIME%> "%SUMMARY%"
echo COMPUTER=%COMPUTERNAME%>> "%SUMMARY%"
echo USER=%USERNAME%>> "%SUMMARY%"
echo DOMAIN=%USERDOMAIN%>> "%SUMMARY%"

:: ---- 1. DEVICE INFO ----
echo ============================================================>> "%LF%"
echo   1. DEVICE INFORMATION>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"
echo   Collecting system info...
systeminfo >> "%LF%" 2>&1
echo.>> "%LF%"

for /f "tokens=2 delims=:" %%a in ('systeminfo ^| findstr /i "OS Name"') do (
    set "OSNAME=%%a"
    set "OSNAME=!OSNAME:~1!"
)
echo OSNAME=!OSNAME!>> "%SUMMARY%"

for /f "tokens=2 delims=:" %%a in ('systeminfo ^| findstr /i "OS Version"') do (
    set "OSVER=%%a"
    set "OSVER=!OSVER:~1!"
)
echo OSVER=!OSVER!>> "%SUMMARY%"

for /f "tokens=2 delims=:" %%a in ('systeminfo ^| findstr /i "System Model"') do (
    set "MODEL=%%a"
    set "MODEL=!MODEL:~1!"
)
echo MODEL=!MODEL!>> "%SUMMARY%"

:: ---- 2. IP CONFIG ----
echo ============================================================>> "%LF%"
echo   2. IP CONFIGURATION>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"
echo   Collecting IP configuration...
ipconfig /all >> "%LF%" 2>&1
echo.>> "%LF%"

set "GATEWAY="
set "IPADDR="
set "DNSSERVERS="
set "DNS_OK=0"
set "IP_OK=0"

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "Default Gateway" ^| findstr /r "[0-9]"') do (
    set "GATEWAY=%%a"
    set "GATEWAY=!GATEWAY: =!"
)

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "IPv4 Address" ^| findstr /r "[0-9]"') do (
    set "IPADDR=%%a"
    set "IPADDR=!IPADDR: =!"
)

for /f "tokens=2 delims=:" %%a in ('ipconfig /all ^| findstr /i "DNS Servers"') do (
    set "DNSSERVERS=%%a"
    set "DNSSERVERS=!DNSSERVERS:~1!"
)

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "Subnet Mask" ^| findstr /r "[0-9]"') do (
    set "SUBNET=%%a"
    set "SUBNET=!SUBNET: =!"
)

set "SSID="
for /f "tokens=2 delims=:" %%a in ('netsh wlan show interfaces ^| findstr /i "SSID" ^| findstr /v "BSSID"') do (
    set "SSID=%%a"
    set "SSID=!SSID:~1!"
)

set "SIGNAL="
for /f "tokens=2 delims=:" %%a in ('netsh wlan show interfaces ^| findstr /i "Signal"') do (
    set "SIGNAL=%%a"
    set "SIGNAL=!SIGNAL: =!"
)

set "CHANNEL="
for /f "tokens=2 delims=:" %%a in ('netsh wlan show interfaces ^| findstr /i "Channel" ^| findstr /v "Radio"') do (
    set "CHANNEL=%%a"
    set "CHANNEL=!CHANNEL: =!"
)

if defined IPADDR (echo [OK] IPv4 Address: !IPADDR!>> "%LF%") else (echo [FAIL] No IPv4 address found>> "%LF%")
if defined GATEWAY (echo [OK] Default Gateway: !GATEWAY!>> "%LF%") else (echo [FAIL] No default gateway found>> "%LF%")
echo.>> "%LF%"

echo IPADDR=!IPADDR!>> "%SUMMARY%"
echo GATEWAY=!GATEWAY!>> "%SUMMARY%"
echo SUBNET=!SUBNET!>> "%SUMMARY%"
echo DNSSERVERS=!DNSSERVERS!>> "%SUMMARY%"
echo SSID=!SSID!>> "%SUMMARY%"
echo SIGNAL=!SIGNAL!>> "%SUMMARY%"
echo CHANNEL=!CHANNEL!>> "%SUMMARY%"

:: ---- 3. GATEWAY PING ----
echo ============================================================>> "%LF%"
echo   3. GATEWAY REACHABILITY>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"
set "GW_RESULT=SKIP"
if defined GATEWAY (
    echo   Pinging gateway !GATEWAY!...
    echo Pinging gateway !GATEWAY!:>> "%LF%"
    ping -n 4 !GATEWAY! >> "%LF%" 2>&1
    if !errorlevel! equ 0 (
        set "GW_RESULT=PASS"
    ) else (
        set "GW_RESULT=FAIL"
    )
) else (
    echo [SKIP] No gateway to test>> "%LF%"
)
echo GW_RESULT=!GW_RESULT!>> "%SUMMARY%"
echo.>> "%LF%"

:: ---- 4. DNS CHECKS ----
echo ============================================================>> "%LF%"
echo   4. DNS RESOLUTION>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"

echo   Pinging google.com by name...
echo Ping google.com by name:>> "%LF%"
ping -n 4 google.com >> "%LF%" 2>&1
if !errorlevel! equ 0 (
    echo [OK] google.com resolved and reachable>> "%LF%"
    set "DNS_OK=1"
) else (
    echo [FAIL] google.com unreachable by name>> "%LF%"
    set "DNS_OK=0"
)
echo.>> "%LF%"

echo   Pinging 8.8.8.8 by IP...
echo Ping 8.8.8.8 raw IP:>> "%LF%"
ping -n 4 8.8.8.8 >> "%LF%" 2>&1
if !errorlevel! equ 0 (
    echo [OK] 8.8.8.8 reachable>> "%LF%"
    set "IP_OK=1"
) else (
    echo [FAIL] 8.8.8.8 unreachable>> "%LF%"
    set "IP_OK=0"
)
echo.>> "%LF%"

if "!DNS_OK!"=="0" if "!IP_OK!"=="1" (
    echo ***** DNS ISSUE DETECTED *****>> "%LF%"
    echo 8.8.8.8 works but google.com fails. DNS is the problem.>> "%LF%"
    echo.>> "%LF%"
)

echo   Running nslookup...
echo nslookup google.com:>> "%LF%"
nslookup google.com >> "%LF%" 2>&1
echo.>> "%LF%"
echo nslookup google.com via 8.8.8.8:>> "%LF%"
nslookup google.com 8.8.8.8 >> "%LF%" 2>&1
echo.>> "%LF%"

echo DNS_OK=!DNS_OK!>> "%SUMMARY%"
echo IP_OK=!IP_OK!>> "%SUMMARY%"

:: ---- 5. TRACEROUTE ----
echo ============================================================>> "%LF%"
echo   5. TRACEROUTE>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"
echo   Running traceroute (this takes a minute)...
echo Traceroute to google.com:>> "%LF%"
tracert -d -h 15 google.com >> "%LF%" 2>&1
echo.>> "%LF%"
echo Traceroute to 8.8.8.8:>> "%LF%"
tracert -d -h 15 8.8.8.8 >> "%LF%" 2>&1
echo.>> "%LF%"

:: ---- 6. SITE CHECKS ----
echo ============================================================>> "%LF%"
echo   6. SITE CONNECTIVITY>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"

echo   Pinging common sites...
set "SITE_GOOGLE=FAIL"
set "SITE_MSFT=FAIL"
set "SITE_CF=FAIL"

echo Ping google.com:>> "%LF%"
ping -n 2 google.com >> "%LF%" 2>&1
if !errorlevel! equ 0 set "SITE_GOOGLE=PASS"
echo.>> "%LF%"

echo Ping microsoft.com:>> "%LF%"
ping -n 2 microsoft.com >> "%LF%" 2>&1
if !errorlevel! equ 0 set "SITE_MSFT=PASS"
echo.>> "%LF%"

echo Ping cloudflare.com:>> "%LF%"
ping -n 2 cloudflare.com >> "%LF%" 2>&1
if !errorlevel! equ 0 set "SITE_CF=PASS"
echo.>> "%LF%"

echo SITE_GOOGLE=!SITE_GOOGLE!>> "%SUMMARY%"
echo SITE_MSFT=!SITE_MSFT!>> "%SUMMARY%"
echo SITE_CF=!SITE_CF!>> "%SUMMARY%"

echo   Testing HTTP connectivity...
echo HTTP Connectivity Tests:>> "%LF%"
powershell -Command "foreach ($site in @('google.com','microsoft.com','cloudflare.com')) { try { $r = Invoke-WebRequest -Uri ('https://' + $site) -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop; '[OK] ' + $site + ' - HTTP Status: ' + $r.StatusCode } catch { if ($_.Exception.Response) { '[OK] ' + $site + ' - HTTP Status: ' + [int]$_.Exception.Response.StatusCode } else { '[FAIL] ' + $site + ' - ' + $_.Exception.Message } } }" >> "%LF%" 2>&1
echo.>> "%LF%"

:: ---- 7. LOCAL NETWORK ----
echo ============================================================>> "%LF%"
echo   7. LOCAL NETWORK>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"
echo   Collecting ARP and routing tables...
echo ARP Table:>> "%LF%"
arp -a >> "%LF%" 2>&1
echo.>> "%LF%"
echo Routing Table:>> "%LF%"
route print >> "%LF%" 2>&1
echo.>> "%LF%"

:: ---- 8. WIRELESS ----
echo ============================================================>> "%LF%"
echo   8. WIRELESS INFO>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"
echo   Collecting wireless info...
echo Wi-Fi Interface:>> "%LF%"
netsh wlan show interfaces >> "%LF%" 2>&1
echo.>> "%LF%"
echo Available Networks:>> "%LF%"
netsh wlan show networks mode=bssid >> "%LF%" 2>&1
echo.>> "%LF%"

:: ---- 9. FIREWALL / PROXY ----
echo ============================================================>> "%LF%"
echo   9. FIREWALL AND PROXY>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"
echo   Checking firewall and proxy...
echo Windows Firewall Status:>> "%LF%"
netsh advfirewall show allprofiles state >> "%LF%" 2>&1
echo.>> "%LF%"
echo Proxy Settings:>> "%LF%"
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable >> "%LF%" 2>&1
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer >> "%LF%" 2>&1
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL >> "%LF%" 2>&1
echo.>> "%LF%"

set "PROXY=None"
for /f "tokens=3" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2^>nul ^| findstr ProxyEnable') do (
    if "%%a"=="0x1" set "PROXY=Enabled"
)
echo PROXY=!PROXY!>> "%SUMMARY%"

:: ---- 10. SUMMARY in TXT ----
echo ============================================================>> "%LF%"
echo   10. DIAGNOSTIC SUMMARY>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"

if defined IPADDR (echo [OK] Device has IP: !IPADDR!>> "%LF%") else (echo [FAIL] No IP address>> "%LF%")
if defined GATEWAY (echo [OK] Gateway: !GATEWAY!>> "%LF%") else (echo [FAIL] No gateway>> "%LF%")
if "!IP_OK!"=="1" (echo [OK] Internet path works>> "%LF%") else (echo [FAIL] No internet path>> "%LF%")
if "!DNS_OK!"=="1" (echo [OK] DNS working>> "%LF%") else (echo [FAIL] DNS broken>> "%LF%")
echo.>> "%LF%"

set "DIAGNOSIS="
if "!DNS_OK!"=="0" if "!IP_OK!"=="1" set "DIAGNOSIS=DNS failure. Internet path exists but name resolution is broken. The device can reach external IPs but cannot resolve hostnames. Recommend setting DNS to 8.8.8.8 / 8.8.4.4 or checking for a captive portal that has not been authenticated."
if "!IP_OK!"=="0" if defined GATEWAY set "DIAGNOSIS=Gateway exists but no internet connectivity. Traffic is not passing upstream. Possible causes: upstream router or ISP issue, firewall blocking traffic, or captive portal requiring authentication before traffic is allowed."
if not defined GATEWAY set "DIAGNOSIS=No default gateway assigned. The device is not receiving a proper DHCP lease. Check physical cable connection, switch port, or try ipconfig /release followed by ipconfig /renew."
if "!DNS_OK!"=="1" if "!IP_OK!"=="1" set "DIAGNOSIS=Basic connectivity is functional. DNS resolves and internet is reachable. If a specific site is not loading, it may be blocked by a firewall or content filter. Test from a hotspot to confirm."

if defined DIAGNOSIS (echo !DIAGNOSIS!>> "%LF%")
echo DIAGNOSIS=!DIAGNOSIS!>> "%SUMMARY%"

echo.>> "%LF%"
echo ============================================================>> "%LF%"
echo   END OF REPORT - %DATE% %TIME%>> "%LF%"
echo ============================================================>> "%LF%"

:: ---- GENERATE PDF VIA POWERSHELL ----
echo.
echo   Generating PDF summary report...

> "%PSSCRIPT%" (
echo Add-Type -AssemblyName System.Drawing
echo.
echo # Parse summary data
echo $data = @{}
echo Get-Content '%SUMMARY%' ^| ForEach-Object {
echo     if ($_ -match '^([^=]+)=(.*)$'^) {
echo         $data[$Matches[1].Trim(^)] = $Matches[2].Trim(^)
echo     }
echo }
echo.
echo function Get-Val($key, $default='N/A'^) {
echo     $v = $data[$key]
echo     if ([string]::IsNullOrWhiteSpace($v^)^) { return $default }
echo     return $v
echo }
echo.
echo # PDF page dimensions in points (8.5 x 11 inches^)
echo $pageW = 612
echo $pageH = 792
echo $marginL = 54
echo $marginR = 54
echo $marginT = 42
echo $contentW = $pageW - $marginL - $marginR
echo.
echo # Colors
echo $green = [System.Drawing.Color]::FromArgb(26, 110, 60^)
echo $red = [System.Drawing.Color]::FromArgb(192, 57, 43^)
echo $blue = [System.Drawing.Color]::FromArgb(44, 62, 80^)
echo $gray = [System.Drawing.Color]::FromArgb(127, 140, 141^)
echo $lightGray = [System.Drawing.Color]::FromArgb(244, 246, 247^)
echo $white = [System.Drawing.Color]::White
echo $black = [System.Drawing.Color]::Black
echo $passBg = [System.Drawing.Color]::FromArgb(232, 245, 233^)
echo $failBg = [System.Drawing.Color]::FromArgb(255, 235, 238^)
echo $gridColor = [System.Drawing.Color]::FromArgb(200, 200, 200^)
echo.
echo # Fonts
echo $titleFont = New-Object System.Drawing.Font('Arial', 18, [System.Drawing.FontStyle]::Bold^)
echo $subtitleFont = New-Object System.Drawing.Font('Arial', 9^)
echo $headingFont = New-Object System.Drawing.Font('Arial', 12, [System.Drawing.FontStyle]::Bold^)
echo $labelFont = New-Object System.Drawing.Font('Arial', 8.5, [System.Drawing.FontStyle]::Bold^)
echo $valueFont = New-Object System.Drawing.Font('Arial', 8.5^)
echo $statusFont = New-Object System.Drawing.Font('Arial', 9, [System.Drawing.FontStyle]::Bold^)
echo $footerFont = New-Object System.Drawing.Font('Arial', 7^)
echo $diagFont = New-Object System.Drawing.Font('Arial', 9.5, [System.Drawing.FontStyle]::Bold^)
echo.
echo # Build PDF content as raw stream
echo # We use iTextSharp-free approach: build a bitmap, then save as PDF-wrapped image
echo # Actually, let's use .NET PdfSharp-free: write raw PDF syntax
echo.
echo # We'll build it by drawing to a high-res bitmap then embedding in a minimal PDF
echo $scale = 2
echo $bmpW = $pageW * $scale
echo $bmpH = $pageH * $scale
echo $bmp = New-Object System.Drawing.Bitmap($bmpW, $bmpH^)
echo $bmp.SetResolution(144, 144^)
echo $g = [System.Drawing.Graphics]::FromImage($bmp^)
echo $g.SmoothingMode = 'HighQuality'
echo $g.TextRenderingHint = 'AntiAliasGridFit'
echo $g.Clear($white^)
echo.
echo # Scale all drawing
echo $g.ScaleTransform($scale, $scale^)
echo.
echo $y = $marginT
echo.
echo # Helper: draw text
echo function DrawText($text, $font, $color, $x, $yPos, $maxW^) {
echo     $brush = New-Object System.Drawing.SolidBrush($color^)
echo     $sf = New-Object System.Drawing.StringFormat
echo     $sf.Trimming = 'EllipsisCharacter'
echo     $rect = New-Object System.Drawing.RectangleF($x, $yPos, $maxW, 200^)
echo     $g.DrawString($text, $font, $brush, $rect, $sf^)
echo     $size = $g.MeasureString($text, $font, [int]$maxW^)
echo     $brush.Dispose(^)
echo     return $size.Height
echo }
echo.
echo # Helper: draw filled rect
echo function FillRect($color, $x, $yPos, $w, $h^) {
echo     $brush = New-Object System.Drawing.SolidBrush($color^)
echo     $g.FillRectangle($brush, $x, $yPos, $w, $h^)
echo     $brush.Dispose(^)
echo }
echo.
echo # Helper: draw rect outline
echo function DrawRect($color, $x, $yPos, $w, $h^) {
echo     $pen = New-Object System.Drawing.Pen($color, 0.5^)
echo     $g.DrawRectangle($pen, $x, $yPos, $w, $h^)
echo     $pen.Dispose(^)
echo }
echo.
echo # Helper: draw line
echo function DrawLine($color, $x1, $y1, $x2, $y2, $thickness^) {
echo     $pen = New-Object System.Drawing.Pen($color, $thickness^)
echo     $g.DrawLine($pen, $x1, $y1, $x2, $y2^)
echo     $pen.Dispose(^)
echo }
echo.
echo # ---- TITLE ----
echo $h = DrawText 'Network Diagnostics Report' $titleFont $blue $marginL $y $contentW
echo $y += $h + 2
echo $subText = "$(Get-Val 'COMPUTER'^) | $(Get-Val 'DATE'^) | $(Get-Val 'USER'^)@$(Get-Val 'DOMAIN'^)"
echo $h = DrawText $subText $subtitleFont $gray $marginL $y $contentW
echo $y += $h + 6
echo DrawLine $green $marginL $y ($pageW - $marginR^) $y 2
echo $y += 10
echo.
echo # ---- DEVICE INFO ----
echo $h = DrawText 'Device Information' $headingFont $green $marginL $y $contentW
echo $y += $h + 4
echo.
echo $rowH = 22
echo $col1W = 90; $col2W = 170; $col3W = 60; $col4W = $contentW - $col1W - $col2W - $col3W
echo $fields1 = @(
echo     @('Computer', (Get-Val 'COMPUTER'^), 'OS', (Get-Val 'OSNAME'^)^),
echo     @('Model', (Get-Val 'MODEL'^), 'User', "$(Get-Val 'USER'^)@$(Get-Val 'DOMAIN'^)"^)
echo ^)
echo foreach ($row in $fields1^) {
echo     FillRect $lightGray $marginL $y $contentW $rowH
echo     DrawRect $gridColor $marginL $y $col1W $rowH
echo     DrawRect $gridColor ($marginL+$col1W^) $y $col2W $rowH
echo     DrawRect $gridColor ($marginL+$col1W+$col2W^) $y $col3W $rowH
echo     DrawRect $gridColor ($marginL+$col1W+$col2W+$col3W^) $y $col4W $rowH
echo     DrawText $row[0] $labelFont $gray ($marginL+4^) ($y+5^) ($col1W-8^) ^| Out-Null
echo     DrawText $row[1] $valueFont $black ($marginL+$col1W+4^) ($y+5^) ($col2W-8^) ^| Out-Null
echo     DrawText $row[2] $labelFont $gray ($marginL+$col1W+$col2W+4^) ($y+5^) ($col3W-8^) ^| Out-Null
echo     DrawText $row[3] $valueFont $black ($marginL+$col1W+$col2W+$col3W+4^) ($y+5^) ($col4W-8^) ^| Out-Null
echo     $y += $rowH
echo }
echo $y += 6
echo.
echo # ---- NETWORK CONFIG ----
echo $h = DrawText 'Network Configuration' $headingFont $green $marginL $y $contentW
echo $y += $h + 4
echo.
echo $col1W = 105; $col2W = 155; $col3W = 80; $col4W = $contentW - $col1W - $col2W - $col3W
echo $fields2 = @(
echo     @('IPv4 Address', (Get-Val 'IPADDR'^), 'Subnet Mask', (Get-Val 'SUBNET'^)^),
echo     @('Default Gateway', (Get-Val 'GATEWAY'^), 'DNS Server', (Get-Val 'DNSSERVERS'^)^),
echo     @('Wi-Fi SSID', (Get-Val 'SSID'^), 'Signal', (Get-Val 'SIGNAL'^)^),
echo     @('Proxy', (Get-Val 'PROXY' 'None'^), 'Channel', (Get-Val 'CHANNEL'^)^)
echo ^)
echo foreach ($row in $fields2^) {
echo     FillRect $lightGray $marginL $y $contentW $rowH
echo     DrawRect $gridColor $marginL $y $col1W $rowH
echo     DrawRect $gridColor ($marginL+$col1W^) $y $col2W $rowH
echo     DrawRect $gridColor ($marginL+$col1W+$col2W^) $y $col3W $rowH
echo     DrawRect $gridColor ($marginL+$col1W+$col2W+$col3W^) $y $col4W $rowH
echo     DrawText $row[0] $labelFont $gray ($marginL+4^) ($y+5^) ($col1W-8^) ^| Out-Null
echo     DrawText $row[1] $valueFont $black ($marginL+$col1W+4^) ($y+5^) ($col2W-8^) ^| Out-Null
echo     DrawText $row[2] $labelFont $gray ($marginL+$col1W+$col2W+4^) ($y+5^) ($col3W-8^) ^| Out-Null
echo     DrawText $row[3] $valueFont $black ($marginL+$col1W+$col2W+$col3W+4^) ($y+5^) ($col4W-8^) ^| Out-Null
echo     $y += $rowH
echo }
echo $y += 6
echo.
echo # ---- CONNECTIVITY RESULTS ----
echo $h = DrawText 'Connectivity Test Results' $headingFont $green $marginL $y $contentW
echo $y += $h + 4
echo.
echo $tc1 = 180; $tc2 = 180; $tc3 = $contentW - $tc1 - $tc2
echo $headerH = 26
echo.
echo # Table header
echo FillRect $green $marginL $y $contentW $headerH
echo DrawText 'Test' $labelFont $white ($marginL+6^) ($y+7^) ($tc1-12^) ^| Out-Null
echo DrawText 'Target' $labelFont $white ($marginL+$tc1+6^) ($y+7^) ($tc2-12^) ^| Out-Null
echo DrawText 'Result' $labelFont $white ($marginL+$tc1+$tc2+6^) ($y+7^) ($tc3-12^) ^| Out-Null
echo $y += $headerH
echo.
echo $tests = @(
echo     @('Gateway Ping', (Get-Val 'GATEWAY'^), (Get-Val 'GW_RESULT' 'SKIP'^)^),
echo     @('DNS Resolution', 'google.com', $(if ((Get-Val 'DNS_OK'^) -eq '1'^) {'PASS'} else {'FAIL'}^)^),
echo     @('Internet Path', '8.8.8.8', $(if ((Get-Val 'IP_OK'^) -eq '1'^) {'PASS'} else {'FAIL'}^)^),
echo     @('Ping google.com', 'google.com', (Get-Val 'SITE_GOOGLE' 'FAIL'^)^),
echo     @('Ping microsoft.com', 'microsoft.com', (Get-Val 'SITE_MSFT' 'FAIL'^)^),
echo     @('Ping cloudflare.com', 'cloudflare.com', (Get-Val 'SITE_CF' 'FAIL'^)^)
echo ^)
echo.
echo foreach ($test in $tests^) {
echo     $bg = if ($test[2] -eq 'PASS'^) { $passBg } else { $failBg }
echo     $statusColor = if ($test[2] -eq 'PASS'^) { $green } else { $red }
echo     FillRect $bg $marginL $y $contentW $rowH
echo     DrawRect $gridColor $marginL $y $tc1 $rowH
echo     DrawRect $gridColor ($marginL+$tc1^) $y $tc2 $rowH
echo     DrawRect $gridColor ($marginL+$tc1+$tc2^) $y $tc3 $rowH
echo     DrawText $test[0] $valueFont $black ($marginL+6^) ($y+5^) ($tc1-12^) ^| Out-Null
echo     DrawText $test[1] $valueFont $black ($marginL+$tc1+6^) ($y+5^) ($tc2-12^) ^| Out-Null
echo     DrawText $test[2] $statusFont $statusColor ($marginL+$tc1+$tc2+6^) ($y+5^) ($tc3-12^) ^| Out-Null
echo     $y += $rowH
echo }
echo $y += 10
echo.
echo # ---- DIAGNOSIS ----
echo $h = DrawText 'Diagnosis' $headingFont $green $marginL $y $contentW
echo $y += $h + 4
echo $diagnosis = Get-Val 'DIAGNOSIS' 'Unable to determine. Review verbose log for details.'
echo $h = DrawText $diagnosis $diagFont $blue $marginL $y $contentW
echo $y += $h + 16
echo.
echo # ---- FOOTER ----
echo DrawLine $gray $marginL $y ($pageW - $marginR^) $y 0.5
echo $y += 8
echo $footerText = "Full verbose log: network-diag-$(Get-Val 'COMPUTER'^).txt on Desktop"
echo DrawText $footerText $footerFont $gray $marginL $y $contentW ^| Out-Null
echo $y += 14
echo DrawText 'System Repair & Update Tool - Network Diagnostics' $footerFont $gray $marginL $y $contentW ^| Out-Null
echo.
echo # Cleanup graphics
echo $g.Dispose(^)
echo.
echo # Save as PNG first, then wrap in PDF
echo $pngPath = [System.IO.Path]::ChangeExtension('%PDF%', '.tmp.png'^)
echo $bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png^)
echo $bmp.Dispose(^)
echo.
echo # Read PNG bytes
echo $imgBytes = [System.IO.File]::ReadAllBytes($pngPath^)
echo.
echo # Build minimal PDF with embedded image
echo $sb = New-Object System.Text.StringBuilder
echo.
echo # PDF header
echo [void]$sb.Append("%%PDF-1.4`n"^)
echo.
echo # Obj 1: Catalog
echo $obj1Pos = $sb.Length
echo [void]$sb.Append("1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"^)
echo.
echo # Obj 2: Pages
echo $obj2Pos = $sb.Length
echo [void]$sb.Append("2 0 obj`n<< /Type /Pages /Kids [3 0 R] /Count 1 >>`nendobj`n"^)
echo.
echo # Obj 3: Page
echo $obj3Pos = $sb.Length
echo [void]$sb.Append("3 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pageW $pageH] /Contents 4 0 R /Resources << /XObject << /Img 5 0 R >> >> >>`nendobj`n"^)
echo.
echo # Obj 4: Content stream (draw image full page^)
echo $stream = "q $pageW 0 0 $pageH 0 0 cm /Img Do Q"
echo $obj4Pos = $sb.Length
echo [void]$sb.Append("4 0 obj`n<< /Length $($stream.Length^) >>`nstream`n$stream`nendstream`nendobj`n"^)
echo.
echo # We need to write binary for the image, so switch to byte array approach
echo $headerPart = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString(^)^)
echo.
echo # Obj 5: Image XObject
echo $imgObjHeader = "5 0 obj`n<< /Type /XObject /Subtype /Image /Width $bmpW /Height $bmpH /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length IMGLEN >>`nstream`n"
echo.
echo # Convert PNG to raw RGB and compress with deflate
echo $srcBmp = New-Object System.Drawing.Bitmap($pngPath^)
echo $rawBytes = New-Object System.Collections.Generic.List[byte]
echo for ($row = 0; $row -lt $srcBmp.Height; $row++^) {
echo     for ($col = 0; $col -lt $srcBmp.Width; $col++^) {
echo         $px = $srcBmp.GetPixel($col, $row^)
echo         [void]$rawBytes.Add($px.R^)
echo         [void]$rawBytes.Add($px.G^)
echo         [void]$rawBytes.Add($px.B^)
echo     }
echo }
echo $srcBmp.Dispose(^)
echo.
echo # Compress
echo $ms = New-Object System.IO.MemoryStream
echo $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Compress^)
echo $rawArr = $rawBytes.ToArray(^)
echo $ds.Write($rawArr, 0, $rawArr.Length^)
echo $ds.Close(^)
echo $compressedBytes = $ms.ToArray(^)
echo $ms.Dispose(^)
echo.
echo # Fix header with actual length
echo $imgObjHeader = $imgObjHeader.Replace('IMGLEN', $compressedBytes.Length.ToString(^)^)
echo $imgObjHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($imgObjHeader^)
echo $imgObjFooterBytes = [System.Text.Encoding]::ASCII.GetBytes("`nendstream`nendobj`n"^)
echo.
echo # Calculate obj5 position
echo $obj5Pos = $headerPart.Length
echo.
echo # Build xref
echo $obj5End = $obj5Pos + $imgObjHeaderBytes.Length + $compressedBytes.Length + $imgObjFooterBytes.Length
echo $xrefPos = $obj5End
echo.
echo $xref = "xref`n0 6`n0000000000 65535 f `n"
echo $xref += "$($obj1Pos.ToString('D10'^)) 00000 n `n"
echo $xref += "$($obj2Pos.ToString('D10'^)) 00000 n `n"
echo $xref += "$($obj3Pos.ToString('D10'^)) 00000 n `n"
echo $xref += "$($obj4Pos.ToString('D10'^)) 00000 n `n"
echo $xref += "$($obj5Pos.ToString('D10'^)) 00000 n `n"
echo $xref += "trailer`n<< /Size 6 /Root 1 0 R >>`nstartxref`n$xrefPos`n%%%%EOF"
echo $xrefBytes = [System.Text.Encoding]::ASCII.GetBytes($xref^)
echo.
echo # Write complete PDF
echo $outStream = [System.IO.File]::Create('%PDF%'^)
echo $outStream.Write($headerPart, 0, $headerPart.Length^)
echo $outStream.Write($imgObjHeaderBytes, 0, $imgObjHeaderBytes.Length^)
echo $outStream.Write($compressedBytes, 0, $compressedBytes.Length^)
echo $outStream.Write($imgObjFooterBytes, 0, $imgObjFooterBytes.Length^)
echo $outStream.Write($xrefBytes, 0, $xrefBytes.Length^)
echo $outStream.Close(^)
echo.
echo # Cleanup temp PNG
echo Remove-Item $pngPath -Force -ErrorAction SilentlyContinue
echo.
echo Write-Host "PDF saved to %PDF%"
)

powershell -ExecutionPolicy Bypass -File "%PSSCRIPT%" 2>nul
if !errorlevel! neq 0 (
    echo   [NOTE] PDF generation encountered an issue.
    echo   The verbose text log is still available on your Desktop.
)

:: Cleanup temp
del "%PSSCRIPT%" 2>nul
del "%SUMMARY%" 2>nul

:: Console summary
echo.
echo ============================================================
echo   DIAGNOSTICS COMPLETE
echo ============================================================
echo.
echo Verbose log: %LF%
if exist "%PDF%" echo PDF report:  %PDF%
echo.
if defined IPADDR (echo [OK] IP: !IPADDR!) else (echo [FAIL] No IP)
if defined GATEWAY (echo [OK] Gateway: !GATEWAY!) else (echo [FAIL] No gateway)
if "!IP_OK!"=="1" (echo [OK] 8.8.8.8 reachable) else (echo [FAIL] 8.8.8.8 unreachable)
if "!DNS_OK!"=="1" (echo [OK] DNS working) else (echo [FAIL] DNS broken)
echo.

if exist "%PDF%" (
    echo Opening PDF report...
    start "" "%PDF%"
) else (
    echo Opening text log...
    start notepad "%LF%"
)

echo.
pause
