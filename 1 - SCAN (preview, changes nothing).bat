@echo off
rem PC Migration Kit - looks at this PC and writes a report. Copies nothing, changes nothing.
rem Asks for administrator rights only so it can read SSD health and Windows features.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Engine\Backup.ps1\" -ScanOnly'"
