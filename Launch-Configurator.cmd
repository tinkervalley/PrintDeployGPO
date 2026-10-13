@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -File "%~dp0PrinterDeployment.ps1" -Mode Configure
if errorlevel 1 pause
