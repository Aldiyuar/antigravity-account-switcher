@echo off
chcp 65001 >nul
fltmc >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-AG.ps1" -Profile "acc1"
if errorlevel 1 pause
