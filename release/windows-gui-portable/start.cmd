@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
if errorlevel 1 (
  echo.
  echo SFW portable failed to start. Check data\logs\daemon.stderr.log.
  pause
)
