@echo off
setlocal
pushd "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Get-TestMedia.ps1" %*
set "suiteExitCode=%errorlevel%"
popd
echo.
if not "%suiteExitCode%"=="0" echo Media setup failed. Read the message above.
pause
exit /b %suiteExitCode%
