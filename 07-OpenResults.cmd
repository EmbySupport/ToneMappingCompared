@echo off
setlocal
pushd "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Export-Results.ps1" %*
set "suiteExitCode=%errorlevel%"
if "%suiteExitCode%"=="0" start "" "%~dp0index.html"
popd
if not "%suiteExitCode%"=="0" pause
exit /b %suiteExitCode%
