@echo off

setlocal

set "TAR=%SystemRoot%\System32\tar.exe"

set "LOG_DIR=%~1"
set "THRESHOLD=%~2"
set "BACKUP_DIR=%~3"

if "%LOG_DIR%"=="" (
    echo Usage: %~nx0 ^<log_dir^> [threshold_percent=70] [backup_dir]
    exit /b 1
)

if not exist "%LOG_DIR%\" (
    echo Error: folder "%LOG_DIR%" not found
    exit /b 1
)

if "%THRESHOLD%"=="" set "THRESHOLD=70"

echo %THRESHOLD%| findstr /r /x "[1-9][0-9]*" > nul
if errorlevel 1 (
    echo Error: threshold must be a whole number from 1 to 99, got "%THRESHOLD%"
    exit /b 1
)
if %THRESHOLD% GTR 99 (
    echo Error: threshold must be a whole number from 1 to 99, got "%THRESHOLD%"
    exit /b 1
)

for %%D in ("%LOG_DIR%\.") do set "LOG_DIR=%%~fD"

if "%BACKUP_DIR%"=="" (
    for %%D in ("%LOG_DIR%") do set "BACKUP_DIR=%%~dpDbackup"
)

for %%D in ("%LOG_DIR%") do set "DRIVE=%%~dD"

call :get_disk_usage
set /a LIMIT_MB=TOTAL_MB * THRESHOLD / 100
set /a USAGE_BEFORE=USED_MB * 100 / TOTAL_MB

echo Folder:      %LOG_DIR%
echo Disk usage:  %USED_MB% MB of %TOTAL_MB% MB (%USAGE_BEFORE%%%), threshold %THRESHOLD%%%

if %USED_MB% LEQ %LIMIT_MB% (
    echo Below threshold, nothing to do.
    exit /b 0
)

set /a NEED_MB=USED_MB - LIMIT_MB
echo Threshold exceeded, need to free at least %NEED_MB% MB.

set "LIST_FILE=%TEMP%\archive_logs_%RANDOM%.txt"
type nul > "%LIST_FILE%"
set /a FREED_MB=0
set /a FILE_COUNT=0

for /f "delims=" %%F in ('dir /b /a-d /o:d /t:w "%LOG_DIR%" 2^>nul') do (
    call :consider_file "%LOG_DIR%\%%F" "%%F"
)

if %FILE_COUNT% EQU 0 (
    echo There are no files to archive in this folder.
    del "%LIST_FILE%"
    exit /b 2
)

echo Archiving %FILE_COUNT% oldest file(s), %FREED_MB% MB:
for /f "usebackq delims=" %%F in ("%LIST_FILE%") do echo   %%F

if "%LAB1_MAX_COMPRESSION%"=="1" (
    set "COMPRESS_OPTION=--lzma"
    set "ARCHIVE_EXTENSION=tar.lzma"
) else (
    set "COMPRESS_OPTION=--gzip"
    set "ARCHIVE_EXTENSION=tar.gz"
)

if not exist "%BACKUP_DIR%\" mkdir "%BACKUP_DIR%"
if not exist "%BACKUP_DIR%\" (
    echo Error: cannot create folder "%BACKUP_DIR%"
    del "%LIST_FILE%"
    exit /b 1
)

for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "STAMP=%%T"
set "ARCHIVE_PATH=%BACKUP_DIR%\logs_%STAMP%.%ARCHIVE_EXTENSION%"

"%TAR%" -c %COMPRESS_OPTION% -f "%ARCHIVE_PATH%" -C "%LOG_DIR%" -T "%LIST_FILE%"
if errorlevel 1 (
    echo Error: tar could not create the archive, no files were deleted
    if exist "%ARCHIVE_PATH%" del "%ARCHIVE_PATH%"
    del "%LIST_FILE%"
    exit /b 1
)
echo Archive:     %ARCHIVE_PATH%

for /f "usebackq delims=" %%F in ("%LIST_FILE%") do del /f /q "%LOG_DIR%\%%F"
del "%LIST_FILE%"
echo Deleted:     %FILE_COUNT% file(s)

call :get_disk_usage
set /a USAGE_AFTER=USED_MB * 100 / TOTAL_MB
echo Disk usage:  %USAGE_BEFORE%%% -^> %USAGE_AFTER%%%

if %USED_MB% GTR %LIMIT_MB% (
    echo Warning: still above %THRESHOLD%%%, the rest of the space is used outside %LOG_DIR%
    exit /b 2
)
exit /b 0

:get_disk_usage
for /f %%A in ('powershell -NoProfile -Command "[math]::Floor((New-Object System.IO.DriveInfo '%DRIVE%').TotalSize / 1000000)"') do set "TOTAL_MB=%%A"
for /f %%A in ('powershell -NoProfile -Command "[math]::Floor((New-Object System.IO.DriveInfo '%DRIVE%').TotalFreeSpace / 1000000)"') do set "FREE_MB=%%A"
set /a USED_MB=TOTAL_MB - FREE_MB
exit /b 0

:consider_file
if %FREED_MB% GEQ %NEED_MB% exit /b 0

set "SIZE_BYTES=%~z1"
set "SIZE_MB=%SIZE_BYTES:~0,-6%"
if "%SIZE_MB%"=="" set "SIZE_MB=0"

set /a FREED_MB=FREED_MB + SIZE_MB
set /a FILE_COUNT=FILE_COUNT + 1
>> "%LIST_FILE%" echo %~2
exit /b 0
