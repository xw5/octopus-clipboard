@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM ============================================================
REM  octopus-clipboard build script
REM  Usage:
REM    build.bat              patch +1 (1.0.0 -> 1.0.1)
REM    build.bat patch       same as above
REM    build.bat minor       minor +1, patch reset (1.0.3 -> 1.1.0)
REM    build.bat major       major +1, others reset (1.2.3 -> 2.0.0)
REM    build.bat 2.5.0       set explicit version
REM    build.bat keep        rebuild with current version (no bump)
REM  Single source of truth: version.txt (x.y.z)
REM  Output: octopus-clipboard-vX.Y.Z.exe  (versioned, for distribution)
REM          octopus-clipboard.exe         (fixed name copy, for daily run / autostart)
REM  exe file/product version = x.y.z.0; version.txt updated.
REM ============================================================

set "SCRIPT=octopus-clipboard.ahk"
set "OUT=octopus-clipboard.exe"
set "ICON=octopus-clipboard.ico"
set "VERFILE=version.txt"
set "BASE=C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

REM ---- locate compiler: script dir tools\ > %TEMP%\ahk2exe > PATH ----
set "A2E=%~dp0tools\Ahk2Exe.exe"
if not exist "%A2E%" set "A2E=%TEMP%\ahk2exe\Ahk2Exe.exe"
if not exist "%A2E%" for /f "delims=" %%P in ('where Ahk2Exe.exe 2^>nul') do if not exist "%A2E%" set "A2E=%%P"
if not exist "%A2E%" (
    echo [ERROR] Ahk2Exe.exe not found. Put it in tools\ or PATH.
    exit /b 1
)

REM ---- preflight ----
for %%F in ("%SCRIPT%" "%ICON%" "%VERFILE%") do if not exist %%~F (
    echo [ERROR] Missing file: %%~F
    exit /b 1
)
if not exist "%BASE%" (
    echo [ERROR] AutoHotkey v2 not found: %BASE%
    exit /b 1
)

REM ---- read current version ----
set /p CURVER=<"%VERFILE%"
for /f "tokens=1,2,3 delims=." %%a in ("%CURVER%") do (
    set "MAJ=%%a"
    set "MIN=%%b"
    set "PAT=%%c"
)
if not defined MAJ if not defined MIN if not defined PAT (
    echo [ERROR] version.txt must be x.y.z, got: %CURVER%
    exit /b 1
)

REM ---- decide new version ----
set "ARG=%~1"
set "NEWVER="
set "MODE=bump"

if "%ARG%"=="" (
    set "MODE=bump"
    set "STEP=patch"
) else if /i "%ARG%"=="patch" (
    set "MODE=bump"
    set "STEP=patch"
) else if /i "%ARG%"=="minor" (
    set "MODE=bump"
    set "STEP=minor"
) else if /i "%ARG%"=="major" (
    set "MODE=bump"
    set "STEP=major"
) else if /i "%ARG%"=="keep" (
    set "MODE=keep"
) else (
    set "MODE=set"
    set "NEWVER=%ARG%"
)

if "%MODE%"=="keep" (
    set "NEWVER=%CURVER%"
) else if "%MODE%"=="bump" (
    if /i "%STEP%"=="patch" set /a PAT+=1
    if /i "%STEP%"=="minor" (set /a MIN+=1 & set /a PAT=0)
    if /i "%STEP%"=="major" (set /a MAJ+=1 & set /a MIN=0 & set /a PAT=0)
    set "NEWVER=%MAJ%.%MIN%.%PAT%"
)

REM ---- validate x.y.z ----
set "VOK=1"
for /f "tokens=1,2,3 delims=." %%a in ("%NEWVER%") do (
    set /a _m=%%a 2>nul
    if errorlevel 1 set "VOK=0"
    set /a _n=%%b 2>nul
    if errorlevel 1 set "VOK=0"
    set /a _p=%%c 2>nul
    if errorlevel 1 set "VOK=0"
)
if "%VOK%"=="0" (
    echo [ERROR] Version must be x.y.z ^(digits only^), got: %NEWVER%
    exit /b 1
)

set "FULLVER=%NEWVER%.0"
set "VEROUT=octopus-clipboard-v%NEWVER%.exe"
echo Version: %CURVER% -^> %NEWVER%  ^(exe %FULLVER%^)
echo Output: %VEROUT%  +  %OUT%

REM ---- close running exe to release file lock ----
taskkill /IM "%OUT%" /F >nul 2>&1
taskkill /IM "octopus-clipboard-v*.exe" /F >nul 2>&1
if errorlevel 1 echo (no running instance to close)
ping -n 2 127.0.0.1 >nul

REM ---- build temp script with version directives ----
set "BUILDSRC=%TEMP%\octopus-build-%RANDOM%.ahk"
copy /y "%SCRIPT%" "%BUILDSRC%" >nul
>>"%BUILDSRC%" echo.
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetName octopus-clipboard
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetDescription Clipboard History Manager
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetProductName octopus-clipboard
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetInternalName octopus-clipboard
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetVersion %FULLVER%
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetFileVersion %FULLVER%
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetProductVersion %FULLVER%
>>"%BUILDSRC%" echo ;@Ahk2Exe-SetOrigFilename %VEROUT%

REM ---- compile to versioned name, then copy to fixed name ----
echo Compiling...
"%A2E%" /in "%BUILDSRC%" /out "%VEROUT%" /base "%BASE%" /icon "%ICON%" /silent
set "RC=%ERRORLEVEL%"
del "%BUILDSRC%" >nul 2>&1
if not "%RC%"=="0" (
    echo [ERROR] Compile failed with code %RC%
    exit /b %RC%
)
copy /y "%VEROUT%" "%OUT%" >nul
if errorlevel 1 (
    echo [ERROR] Failed to copy to fixed name %OUT%
    exit /b 1
)

REM ---- persist new version ----
> "%VERFILE%" echo %NEWVER%

REM ---- verify exe version resource ----
echo Verifying version info...
set "BUILTVER="
for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Item '%VEROUT%' -ErrorAction SilentlyContinue).VersionInfo.FileVersion"`) do set "BUILTVER=%%v"
if "%BUILTVER%"=="%FULLVER%" (
    echo [OK] Built %VEROUT%  version %BUILTVER%
    echo [OK] Copied to %OUT%
) else (
    echo [WARN] exe version "%BUILTVER%", expected "%FULLVER%".
)

exit /b 0
