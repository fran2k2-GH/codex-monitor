@echo off
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo Codex Monitor requiere PowerShell 7 - pwsh.exe.
  echo Instala PowerShell 7 o asegurate de que pwsh.exe este disponible en PATH.
  pause
  exit /b 1
)
start "" pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0codex-monitor.ps1"
