@echo off
setlocal
cd /d "%~dp0"
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0app\codex_session_manager_win10.ps1"
if errorlevel 1 (
  echo.
  echo Codex Session Manager exited with an error.
  echo Press any key to close this window.
  pause >nul
)
