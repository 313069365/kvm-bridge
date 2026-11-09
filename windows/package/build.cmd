@echo off
setlocal
cd /d "%~dp0"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe

if not exist "%CSC%" (
    echo [ERROR] csc.exe not found.
    echo Please install .NET Framework 4.x, which ships with Windows 10 and 11.
    pause
    exit /b 1
)

set ICONOPT=
if exist app.ico set ICONOPT=/win32icon:app.ico

REM 关键：exe 正在运行时 csc 无法覆盖它，会报 CS0016 并保留旧文件，
REM 表现就是「改了代码但行为没变」。编译前先结束旧进程。
taskkill /f /im KVMBridge.exe >nul 2>&1
if exist KVMBridge.exe del /f /q KVMBridge.exe >nul 2>&1

echo Compiling KVMBridge.exe ...
"%CSC%" /nologo /target:winexe /codepage:65001 %ICONOPT% /win32manifest:app.manifest /out:KVMBridge.exe /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll KVMBridge.cs

if errorlevel 1 (
    echo.
    echo [ERROR] KVMBridge build failed.
    echo If the error mentions CS0016 or "being used by another process",
    echo close KvmBridge in the tray and run this again.
    pause
    exit /b 1
)

if not exist KVMBridge.exe (
    echo.
    echo [ERROR] KVMBridge.exe was not produced. See the messages above.
    pause
    exit /b 1
)

echo Compiling CaptureProbe.exe ^(diagnostic tool, optional^) ...
"%CSC%" /nologo /target:exe /codepage:65001 /out:CaptureProbe.exe /r:System.dll /r:System.Windows.Forms.dll CaptureProbe.cs

if errorlevel 1 (
    echo.
    echo [WARN] CaptureProbe build failed. KVMBridge.exe is still usable.
)

echo.
echo Done.
echo   KVMBridge.exe     - run this. Tray menu, monitor switching, key/mouse relay.
echo   CaptureProbe.exe  - optional diagnostic, logs 20s of local key events.
echo.
echo KVM Bridge reads the Mac address from host.txt next to the exe (port 24801).
echo Edit host.txt with your Mac's LAN IP before using keyboard/mouse sharing.
echo You can also pass it directly: KVMBridge.exe ^<macIp^> ^<port^>
pause
