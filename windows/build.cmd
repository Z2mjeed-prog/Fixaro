@echo off
rem Builds Fixaro for Windows with the C# compiler that comes with Windows, installs it, and starts it.
rem Nothing to download: run this file (double-click it, or run "windows\build.cmd" from the Fixaro folder).
rem "build.cmd ci" only builds build\Fixaro.exe (no install, no pause): used by GitHub and the installer.
setlocal
cd /d "%~dp0"
set "CI="
if /i "%~1"=="ci" set "CI=1"

set "CSC="
for %%F in (FrameworkArm64 Framework64 Framework) do (
  if not defined CSC if exist "%WINDIR%\Microsoft.NET\%%F\v4.0.30319\csc.exe" set "CSC=%WINDIR%\Microsoft.NET\%%F\v4.0.30319\csc.exe"
)
if not defined CSC (
  echo Couldn't find the C# compiler that comes with Windows ^(.NET Framework 4^).
  echo Turn on ".NET Framework 4.8 Advanced Services" in "Turn Windows features on or off", then try again.
  if not defined CI pause
  exit /b 1
)

echo Building Fixaro...
if not exist build mkdir build
set "VERSION=0"
if exist ..\VERSION set /p VERSION=<..\VERSION
for /f "tokens=* delims= " %%V in ("%VERSION%") do set "VERSION=%%V"
> build\Version.cs echo namespace Fixaro { static class AppVersion { public const string Value = "%VERSION%"; } }
"%CSC%" /nologo /codepage:65001 /target:winexe /optimize+ /platform:anycpu /out:build\Fixaro.exe ^
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll Fixaro.cs build\Version.cs > build\build.log 2>&1
if errorlevel 1 (
  type build\build.log
  echo.
  echo The build failed. Please share the lines above in a GitHub issue.
  if not defined CI pause
  exit /b 1
)
if defined CI (
  echo Built build\Fixaro.exe, version %VERSION%
  exit /b 0
)

set "DEST=%LOCALAPPDATA%\Programs\Fixaro"
echo Installing to %DEST% ...
taskkill /im Fixaro.exe /f >nul 2>&1
timeout /t 1 /nobreak >nul
if not exist "%DEST%" mkdir "%DEST%"
copy /y build\Fixaro.exe "%DEST%\Fixaro.exe" >nul

rem A Start menu shortcut, so you can find and start Fixaro like any other app
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Programs')+'\Fixaro.lnk'); $s.TargetPath='%DEST%\Fixaro.exe'; $s.Save()" >nul 2>&1

start "" "%DEST%\Fixaro.exe"
echo.
echo Done. Fixaro is running: look for the F icon near the clock (it may be under the ^^ arrow).
echo Select text in any app and press Ctrl+Alt+R to rewrite it, or Ctrl+Alt+S to choose how.
echo.
pause
