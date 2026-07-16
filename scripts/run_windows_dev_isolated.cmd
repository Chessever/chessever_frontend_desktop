@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_windows_dev_isolated.ps1" %*
exit /b %ERRORLEVEL%
