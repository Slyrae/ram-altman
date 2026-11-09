@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\disable.ps1" %*
set "RamAltmanExitCode=%ERRORLEVEL%"
if not defined RAM_ALTMAN_NO_PAUSE pause
exit /b %RamAltmanExitCode%
