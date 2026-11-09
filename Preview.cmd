@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\ram-altman.ps1" -DryRun %*
set "RamAltmanExitCode=%ERRORLEVEL%"
if not defined RAM_ALTMAN_NO_PAUSE pause
exit /b %RamAltmanExitCode%
