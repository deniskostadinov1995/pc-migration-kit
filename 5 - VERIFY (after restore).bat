@echo off
rem PC Migration Kit - compares this PC with the newest backup and lists what is missing.
rem Read-only. To put things back: the program's "Verify & fix" page, or Verify.ps1 -FixAll in an admin window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Engine\Verify.ps1"
