@echo off
title KestrelTech Servis Toolkit
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0servis.ps1"
