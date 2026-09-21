@echo off
title Pendrive IA - Menu
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Menu\menu.ps1"
if errorlevel 1 (
  echo.
  echo O menu fechou com erro. A mensagem acima diz o motivo.
  pause
)
