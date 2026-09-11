@echo off
setlocal

cd /d "%~dp0"
echo Avvio monitor qualita' Internet...
echo Premi Ctrl+C nella finestra PowerShell per terminare correttamente.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Monitor-InternetQuality.ps1"

echo.
echo Monitor terminato. Premi un tasto per chiudere questa finestra.
pause >nul
