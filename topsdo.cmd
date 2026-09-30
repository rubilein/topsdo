@echo off
rem topsdo launcher for cmd.exe: prefers PowerShell 7 (pwsh), falls back to Windows PowerShell 5.1
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0topsdo.ps1" %*
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0topsdo.ps1" %*
)
