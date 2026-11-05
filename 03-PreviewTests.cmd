@echo off
setlocal
pushd "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Get-TestPlan.ps1" %*
set "suiteExitCode=%errorlevel%"
popd
echo.
if not "%suiteExitCode%"=="0" echo Test-plan preview failed. Read the message above.
pause
exit /b %suiteExitCode%
