@echo off
setlocal EnableDelayedExpansion
title Network Diagnostics - System Repair Tool
color 0A

:: Final output file (the one the user sees on their desktop)
set "LF=%USERPROFILE%\Desktop\network-diag-%COMPUTERNAME%.txt"

:: Temp files used during the run:
::   DETAIL  = the detailed verbose body, assembled during diagnostics
::   SUMMARY = key=value facts collected across sections, used for diagnosis
set "DETAIL=%TEMP%\netdiag_detail_%RANDOM%.txt"
set "SUMMARY=%TEMP%\netdiag_summary_%RANDOM%.txt"

if exist "%LF%" del "%LF%"
if exist "%DETAIL%" del "%DETAIL%"
if exist "%SUMMARY%" del "%SUMMARY%"

echo ============================================================
echo   NETWORK DIAGNOSTICS - System Repair Tool
echo   %DATE% %TIME%
echo   Computer: %COMPUTERNAME%
echo   This will take a few minutes. Please wait...
echo ============================================================
echo.

:: ---- Write summary key/value header ----
echo DATE=%DATE% %TIME%> "%SUMMARY%"
echo COMPUTER=%COMPUTERNAME%>> "%SUMMARY%"
echo USER=%USERNAME%>> "%SUMMARY%"
echo DOMAIN=%USERDOMAIN%>> "%SUMMARY%"

:: ---- 1. DEVICE INFO ----
echo ============================================================>> "%DETAIL%"
echo   1. DEVICE INFORMATION>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"
echo   Collecting system info...
systeminfo >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

for /f "tokens=2 delims=:" %%a in ('systeminfo ^| findstr /i "OS Name"') do (
    set "OSNAME=%%a"
    for /f "tokens=* delims= " %%b in ("!OSNAME!") do set "OSNAME=%%b"
)
echo OSNAME=!OSNAME!>> "%SUMMARY%"

for /f "tokens=2 delims=:" %%a in ('systeminfo ^| findstr /i "OS Version"') do (
    set "OSVER=%%a"
    for /f "tokens=* delims= " %%b in ("!OSVER!") do set "OSVER=%%b"
)
echo OSVER=!OSVER!>> "%SUMMARY%"

for /f "tokens=2 delims=:" %%a in ('systeminfo ^| findstr /i "System Model"') do (
    set "MODEL=%%a"
    for /f "tokens=* delims= " %%b in ("!MODEL!") do set "MODEL=%%b"
)
echo MODEL=!MODEL!>> "%SUMMARY%"

:: ---- 2. IP CONFIG ----
echo ============================================================>> "%DETAIL%"
echo   2. IP CONFIGURATION>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"
echo   Collecting IP configuration...
ipconfig /all >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

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
    for /f "tokens=* delims= " %%b in ("!DNSSERVERS!") do set "DNSSERVERS=%%b"
)

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "Subnet Mask" ^| findstr /r "[0-9]"') do (
    set "SUBNET=%%a"
    set "SUBNET=!SUBNET: =!"
)

:: SSID capture - trim leading whitespace robustly. netsh output is " MyNetwork"
:: with a leading space; the old code did !SSID:~1! which blindly chopped the
:: first character whether or not it was a space. Use tokens=* to handle it.
set "SSID="
for /f "tokens=2 delims=:" %%a in ('netsh wlan show interfaces ^| findstr /i "SSID" ^| findstr /v "BSSID"') do (
    set "SSID=%%a"
    for /f "tokens=* delims= " %%b in ("!SSID!") do set "SSID=%%b"
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

if defined IPADDR (echo [OK] IPv4 Address: !IPADDR!>> "%DETAIL%") else (echo [FAIL] No IPv4 address found>> "%DETAIL%")
if defined GATEWAY (echo [OK] Default Gateway: !GATEWAY!>> "%DETAIL%") else (echo [FAIL] No default gateway found>> "%DETAIL%")
echo.>> "%DETAIL%"

echo IPADDR=!IPADDR!>> "%SUMMARY%"
echo GATEWAY=!GATEWAY!>> "%SUMMARY%"
echo SUBNET=!SUBNET!>> "%SUMMARY%"
echo DNSSERVERS=!DNSSERVERS!>> "%SUMMARY%"
echo SSID=!SSID!>> "%SUMMARY%"
echo SIGNAL=!SIGNAL!>> "%SUMMARY%"
echo CHANNEL=!CHANNEL!>> "%SUMMARY%"

:: ---- 3. GATEWAY PING ----
echo ============================================================>> "%DETAIL%"
echo   3. GATEWAY REACHABILITY>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"
set "GW_RESULT=SKIP"
if defined GATEWAY (
    echo   Pinging gateway !GATEWAY!...
    echo Pinging gateway !GATEWAY!:>> "%DETAIL%"
    ping -n 4 !GATEWAY! >> "%DETAIL%" 2>&1
    if !errorlevel! equ 0 (
        set "GW_RESULT=PASS"
    ) else (
        set "GW_RESULT=FAIL"
    )
) else (
    echo [SKIP] No gateway to test>> "%DETAIL%"
)
echo GW_RESULT=!GW_RESULT!>> "%SUMMARY%"
echo.>> "%DETAIL%"

:: ---- 4. DNS CHECKS ----
echo ============================================================>> "%DETAIL%"
echo   4. DNS RESOLUTION>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"

echo   Pinging google.com by name...
echo Ping google.com by name:>> "%DETAIL%"
ping -n 4 google.com >> "%DETAIL%" 2>&1
if !errorlevel! equ 0 (
    echo [OK] google.com resolved and reachable>> "%DETAIL%"
    set "DNS_OK=1"
) else (
    echo [FAIL] google.com unreachable by name>> "%DETAIL%"
    set "DNS_OK=0"
)
echo.>> "%DETAIL%"

echo   Pinging 8.8.8.8 by IP...
echo Ping 8.8.8.8 raw IP:>> "%DETAIL%"
ping -n 4 8.8.8.8 >> "%DETAIL%" 2>&1
if !errorlevel! equ 0 (
    echo [OK] 8.8.8.8 reachable>> "%DETAIL%"
    set "IP_OK=1"
) else (
    echo [FAIL] 8.8.8.8 unreachable>> "%DETAIL%"
    set "IP_OK=0"
)
echo.>> "%DETAIL%"

if "!DNS_OK!"=="0" if "!IP_OK!"=="1" (
    echo ***** DNS ISSUE DETECTED *****>> "%DETAIL%"
    echo 8.8.8.8 works but google.com fails. DNS is the problem.>> "%DETAIL%"
    echo.>> "%DETAIL%"
)

echo   Running nslookup...
echo nslookup google.com:>> "%DETAIL%"
nslookup google.com >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"
echo nslookup google.com via 8.8.8.8:>> "%DETAIL%"
nslookup google.com 8.8.8.8 >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

echo DNS_OK=!DNS_OK!>> "%SUMMARY%"
echo IP_OK=!IP_OK!>> "%SUMMARY%"

:: ---- 5. TRACEROUTE ----
echo ============================================================>> "%DETAIL%"
echo   5. TRACEROUTE>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"
echo   Running traceroute (this takes a minute)...
echo Traceroute to google.com:>> "%DETAIL%"
tracert -d -h 15 google.com >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"
echo Traceroute to 8.8.8.8:>> "%DETAIL%"
tracert -d -h 15 8.8.8.8 >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

:: ---- 6. SITE CHECKS ----
echo ============================================================>> "%DETAIL%"
echo   6. SITE CONNECTIVITY>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"

echo   Pinging common sites...
set "SITE_GOOGLE=FAIL"
set "SITE_MSFT=FAIL"
set "SITE_CF=FAIL"

echo Ping google.com:>> "%DETAIL%"
ping -n 2 google.com >> "%DETAIL%" 2>&1
if !errorlevel! equ 0 set "SITE_GOOGLE=PASS"
echo.>> "%DETAIL%"

echo Ping microsoft.com:>> "%DETAIL%"
ping -n 2 microsoft.com >> "%DETAIL%" 2>&1
if !errorlevel! equ 0 set "SITE_MSFT=PASS"
echo.>> "%DETAIL%"

echo Ping cloudflare.com:>> "%DETAIL%"
ping -n 2 cloudflare.com >> "%DETAIL%" 2>&1
if !errorlevel! equ 0 set "SITE_CF=PASS"
echo.>> "%DETAIL%"

echo SITE_GOOGLE=!SITE_GOOGLE!>> "%SUMMARY%"
echo SITE_MSFT=!SITE_MSFT!>> "%SUMMARY%"
echo SITE_CF=!SITE_CF!>> "%SUMMARY%"

echo   Testing HTTP connectivity...
echo HTTP Connectivity Tests:>> "%DETAIL%"
powershell -Command "foreach ($site in @('google.com','microsoft.com','cloudflare.com')) { try { $r = Invoke-WebRequest -Uri ('https://' + $site) -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop; '[OK] ' + $site + ' - HTTP Status: ' + $r.StatusCode } catch { if ($_.Exception.Response) { '[OK] ' + $site + ' - HTTP Status: ' + [int]$_.Exception.Response.StatusCode } else { '[FAIL] ' + $site + ' - ' + $_.Exception.Message } } }" >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

:: ---- 7. LOCAL NETWORK ----
echo ============================================================>> "%DETAIL%"
echo   7. LOCAL NETWORK>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"
echo   Collecting ARP and routing tables...
echo ARP Table:>> "%DETAIL%"
arp -a >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"
echo Routing Table:>> "%DETAIL%"
route print >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

:: ---- 8. WIRELESS ----
echo ============================================================>> "%DETAIL%"
echo   8. WIRELESS INFO>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"
echo   Collecting wireless info...
echo Wi-Fi Interface:>> "%DETAIL%"
netsh wlan show interfaces >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"
echo Available Networks:>> "%DETAIL%"
netsh wlan show networks mode=bssid >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

:: ---- 9. FIREWALL / PROXY ----
echo ============================================================>> "%DETAIL%"
echo   9. FIREWALL AND PROXY>> "%DETAIL%"
echo ============================================================>> "%DETAIL%"
echo.>> "%DETAIL%"
echo   Checking firewall and proxy...
echo Windows Firewall Status:>> "%DETAIL%"
netsh advfirewall show allprofiles state >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"
echo Proxy Settings:>> "%DETAIL%"
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable >> "%DETAIL%" 2>&1
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer >> "%DETAIL%" 2>&1
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL >> "%DETAIL%" 2>&1
echo.>> "%DETAIL%"

set "PROXY=None"
for /f "tokens=3" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2^>nul ^| findstr ProxyEnable') do (
    if "%%a"=="0x1" set "PROXY=Enabled"
)
echo PROXY=!PROXY!>> "%SUMMARY%"

:: ---- Compute diagnosis now that all tests have run ----
set "DIAGNOSIS="
if "!DNS_OK!"=="0" if "!IP_OK!"=="1" set "DIAGNOSIS=DNS failure. Internet path exists but name resolution is broken. The device can reach external IPs but cannot resolve hostnames. Recommend setting DNS to 8.8.8.8 / 8.8.4.4 or checking for a captive portal that has not been authenticated."
if "!IP_OK!"=="0" if defined GATEWAY set "DIAGNOSIS=Gateway exists but no internet connectivity. Traffic is not passing upstream. Possible causes: upstream router or ISP issue, firewall blocking traffic, or captive portal requiring authentication before traffic is allowed."
if not defined GATEWAY set "DIAGNOSIS=No default gateway assigned. The device is not receiving a proper DHCP lease. Check physical cable connection, switch port, or try ipconfig /release followed by ipconfig /renew."
if "!DNS_OK!"=="1" if "!IP_OK!"=="1" set "DIAGNOSIS=Basic connectivity is functional. DNS resolves and internet is reachable. If a specific site is not loading, it may be blocked by a firewall or content filter. Test from a hotspot to confirm."
echo DIAGNOSIS=!DIAGNOSIS!>> "%SUMMARY%"

:: ============================================================
::  ASSEMBLE FINAL LOG: header + summary at top + detail body
:: ============================================================
:: Write header
echo ============================================================> "%LF%"
echo   NETWORK DIAGNOSTICS REPORT>> "%LF%"
echo   Date: %DATE% %TIME%>> "%LF%"
echo   Computer: %COMPUTERNAME%>> "%LF%"
echo   User: %USERNAME%>> "%LF%"
echo   Domain: %USERDOMAIN%>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"

:: Write SUMMARY section at top
echo ============================================================>> "%LF%"
echo   DIAGNOSTIC SUMMARY>> "%LF%"
echo ============================================================>> "%LF%"
echo.>> "%LF%"

if defined SSID (
    echo   Wi-Fi SSID:       !SSID!>> "%LF%"
    if defined SIGNAL echo   Wi-Fi Signal:     !SIGNAL!>> "%LF%"
    if defined CHANNEL echo   Wi-Fi Channel:    !CHANNEL!>> "%LF%"
) else (
    echo   Wi-Fi:            Not connected to a wireless network>> "%LF%"
)
echo.>> "%LF%"

if defined IPADDR (echo   [OK]   Device has IP: !IPADDR!>> "%LF%") else (echo   [FAIL] No IP address>> "%LF%")
if defined GATEWAY (echo   [OK]   Gateway: !GATEWAY!>> "%LF%") else (echo   [FAIL] No gateway>> "%LF%")
if "!IP_OK!"=="1" (echo   [OK]   Internet path works (8.8.8.8 reachable)>> "%LF%") else (echo   [FAIL] No internet path>> "%LF%")
if "!DNS_OK!"=="1" (echo   [OK]   DNS resolution working>> "%LF%") else (echo   [FAIL] DNS broken>> "%LF%")
echo.>> "%LF%"

if defined DIAGNOSIS (
    echo   DIAGNOSIS:>> "%LF%"
    echo   !DIAGNOSIS!>> "%LF%"
    echo.>> "%LF%"
)

echo   See detailed sections below for full test output.>> "%LF%"
echo.>> "%LF%"

:: Append the detail body captured during the run
type "%DETAIL%" >> "%LF%"

:: Footer
echo.>> "%LF%"
echo ============================================================>> "%LF%"
echo   END OF REPORT - %DATE% %TIME%>> "%LF%"
echo ============================================================>> "%LF%"

:: Cleanup temp files
del "%DETAIL%" 2>nul
del "%SUMMARY%" 2>nul

:: Console summary
echo.
echo ============================================================
echo   DIAGNOSTICS COMPLETE
echo ============================================================
echo.
echo Log saved to: %LF%
echo.
if defined SSID (echo [INFO] Connected to Wi-Fi: !SSID!) else (echo [INFO] Not connected to Wi-Fi)
if defined IPADDR (echo [OK] IP: !IPADDR!) else (echo [FAIL] No IP)
if defined GATEWAY (echo [OK] Gateway: !GATEWAY!) else (echo [FAIL] No gateway)
if "!IP_OK!"=="1" (echo [OK] 8.8.8.8 reachable) else (echo [FAIL] 8.8.8.8 unreachable)
if "!DNS_OK!"=="1" (echo [OK] DNS working) else (echo [FAIL] DNS broken)
echo.

echo Opening text log...
start notepad "%LF%"

:: Auto-close: the text log is open in Notepad for the tech to review.
:: Keeping this window open just to show "DIAGNOSTICS COMPLETE" is noise -
:: exit cleanly so the tech's desktop isn't cluttered with a leftover cmd.
endlocal
exit /b
