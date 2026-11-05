@echo off
setlocal
pushd "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Clear-Results.ps1" %*
set "suiteExitCode=%errorlevel%"
popd
if not "%suiteExitCode%"=="0" pause
exit /b %suiteExitCode%
