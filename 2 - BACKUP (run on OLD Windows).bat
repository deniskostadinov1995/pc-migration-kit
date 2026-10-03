@echo off
rem PC Migration Kit - backs up apps, settings, automations and files of this Windows.
rem Windows will ask for administrator rights - click Yes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Engine\Backup.ps1\"'"
