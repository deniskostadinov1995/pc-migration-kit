@echo off
rem PC Migration Kit - checks the media server + smart home, and repairs what is not running.
rem Windows will ask for administrator rights - click Yes. Parts that already work are left alone.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Engine\ServerSetup.ps1\"'"
