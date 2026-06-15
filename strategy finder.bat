@echo off
chcp 65001 > nul
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\"' -Verb RunAs"
    exit
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strategy_finder.ps1"
pause
