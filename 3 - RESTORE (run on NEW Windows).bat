@echo off
rem PC Migration Kit - puts a backup back onto a freshly installed Windows.
rem Windows will ask for administrator rights - click Yes. Safe to run again: finished steps are skipped.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Engine\Restore.ps1\"'"
