@echo off
rem CXXForge batch redirect — forwards to PowerShell runner
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0forge.ps1" %*
exit /b %ERRORLEVEL%
