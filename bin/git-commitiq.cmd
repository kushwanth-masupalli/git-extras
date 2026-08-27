@echo off
setlocal
where bash >nul 2>nul
if errorlevel 1 (
  echo commitiq: bash.exe not found on PATH - install Git for Windows ^(which bundles it^) and make sure it's on PATH. 1>&2
  exit /b 1
)
bash "%~dp0git-commitiq" %*
