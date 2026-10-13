@echo off
rem This execution policy applies only to the GUI process; Group Policy still takes precedence.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PrinterDeployment.ps1" -Mode Configure -ConfigPath "%~dp0printers.json"
if errorlevel 1 pause
