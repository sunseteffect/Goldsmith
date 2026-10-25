@echo off
rem Runs the Goldsmith test bench (see README.md). Arguments go to run.lua.
"C:\Program Files (x86)\Lua\5.1\lua.exe" "%~dp0run.lua" %*
if "%~1"=="" pause
