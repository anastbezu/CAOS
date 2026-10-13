@echo off

setlocal

set "TAR=%SystemRoot%\System32\tar.exe"

set "MAIN_SCRIPT=%~dp0archive_logs.bat"
set "LAB1_MAX_COMPRESSION="

net session > nul 2>&1
if errorlevel 1 (
    echo This test must be run as Administrator: diskpart needs admin rights to create a virtual disk.
    exit /b 1
)

set "WORK_DIR=%TEMP%\lab1_test_%RANDOM%"
mkdir "%WORK_DIR%"
set "VHD_FILE=%WORK_DIR%\disk.vhd"

set "LETTER="
for %%L in (Z Y X W V U T S R Q P O N M L K) do (
    if not defined LETTER if not exist %%L:\ set "LETTER=%%L"
)
if not defined LETTER (
    echo Error: no free drive letter
    rmdir /s /q "%WORK_DIR%"
    exit /b 1
)

> "%WORK_DIR%\create_disk.txt" echo create vdisk file="%VHD_FILE%" maximum=1024 type=expandable
>> "%WORK_DIR%\create_disk.txt" echo select vdisk file="%VHD_FILE%"
>> "%WORK_DIR%\create_disk.txt" echo attach vdisk
>> "%WORK_DIR%\create_disk.txt" echo convert mbr
>> "%WORK_DIR%\create_disk.txt" echo create partition primary
>> "%WORK_DIR%\create_disk.txt" echo format fs=ntfs quick label=LAB1TEST
>> "%WORK_DIR%\create_disk.txt" echo assign letter=%LETTER%
diskpart /s "%WORK_DIR%\create_disk.txt" > "%WORK_DIR%\diskpart.log"

if not exist %LETTER%:\ (
    echo Error: could not create the virtual disk, diskpart output:
    type "%WORK_DIR%\diskpart.log"
    call :remove_disk
    exit /b 1
)
echo Virtual disk: 1 GB VHD mounted as %LETTER%:

set "DRIVE=%LETTER%:"
set "LOG_DIR=%LETTER%:\log"
set "BACKUP_DIR=%WORK_DIR%\backup"
set "OUTPUT_FILE=%WORK_DIR%\output.txt"

call :get_disk_usage
set /a FILE_MB=TOTAL_MB * 8 / 100
echo One log file: %FILE_MB% MB (8 percent of the disk)
echo.

set /a TESTS_TOTAL=0
set /a TESTS_PASSED=0

call :start_test "below threshold - nothing to do"
call :create_log_files 8
call :show_log_size
call :run_main_script "%LOG_DIR%" 70 "%BACKUP_DIR%"
call :check_exit_code 0
call :check_no_archive
call :check_files_left 8
call :finish_test

call :start_test "above 70 percent - oldest files archived"
call :create_log_files 10
call :show_log_size
call :run_main_script "%LOG_DIR%" 70 "%BACKUP_DIR%"
call :check_exit_code 0
call :check_usage_below 70
call :check_archive gz app_10.log app_09.log
call :check_files_left 8
call :finish_test

call :start_test "one big old file - only it is archived"
set /a HUGE_MB=FILE_MB * 30 / 8
call :create_file "%LOG_DIR%\huge.log" %HUGE_MB% 30
call :create_log_files 6
call :show_log_size
call :run_main_script "%LOG_DIR%" 70 "%BACKUP_DIR%"
call :check_exit_code 0
call :check_usage_below 70
call :check_archive gz huge.log
call :check_files_left 6
call :finish_test

call :start_test "other threshold: 55 percent"
call :create_log_files 8
call :show_log_size
call :run_main_script "%LOG_DIR%" 55 "%BACKUP_DIR%"
call :check_exit_code 0
call :check_usage_below 55
call :check_archive gz app_08.log app_07.log
call :check_files_left 6
call :finish_test

call :start_test "LAB1_MAX_COMPRESSION=1 - lzma compression"
call :create_log_files 10
call :show_log_size
set "LAB1_MAX_COMPRESSION=1"
call :run_main_script "%LOG_DIR%" 70 "%BACKUP_DIR%"
set "LAB1_MAX_COMPRESSION="
call :check_exit_code 0
call :check_usage_below 70
call :check_archive lzma app_10.log app_09.log
call :check_files_left 8
call :finish_test

call :remove_disk
echo Passed %TESTS_PASSED% of %TESTS_TOTAL% tests
if %TESTS_PASSED% NEQ %TESTS_TOTAL% exit /b 1
exit /b 0

:remove_disk
> "%WORK_DIR%\remove_disk.txt" echo select vdisk file="%VHD_FILE%"
>> "%WORK_DIR%\remove_disk.txt" echo detach vdisk
diskpart /s "%WORK_DIR%\remove_disk.txt" > nul
rmdir /s /q "%WORK_DIR%"
exit /b 0

:get_disk_usage
for /f %%A in ('powershell -NoProfile -Command "[math]::Floor((New-Object System.IO.DriveInfo '%DRIVE%').TotalSize / 1000000)"') do set "TOTAL_MB=%%A"
for /f %%A in ('powershell -NoProfile -Command "[math]::Floor((New-Object System.IO.DriveInfo '%DRIVE%').TotalFreeSpace / 1000000)"') do set "FREE_MB=%%A"
set /a USED_MB=TOTAL_MB - FREE_MB
exit /b 0

:create_file
set /a SIZE_BYTES=%~2 * 1000000
fsutil file createnew "%~1" %SIZE_BYTES% > nul
powershell -NoProfile -Command "(Get-Item -LiteralPath '%~1').LastWriteTime = (Get-Date).AddDays(-%~3)"
exit /b 0

:create_log_files
for /l %%I in (1,1,%~1) do call :create_numbered_file %%I
exit /b 0

:create_numbered_file
if %~1 LSS 10 (
    set "FILE_NAME=app_0%~1.log"
) else (
    set "FILE_NAME=app_%~1.log"
)
call :create_file "%LOG_DIR%\%FILE_NAME%" %FILE_MB% %~1
exit /b 0

:count_files
set "COUNT=0"
for /f %%C in ('dir /b /a-d "%~1" 2^>nul ^| find /c /v ""') do set "COUNT=%%C"
exit /b 0

:fail
echo     failed: %~1
set "TEST_FAILED=1"
exit /b 0

:start_test
set /a TESTS_TOTAL=TESTS_TOTAL + 1
echo Test %TESTS_TOTAL%: %~1
if exist "%LOG_DIR%" rmdir /s /q "%LOG_DIR%"
if exist "%BACKUP_DIR%" rmdir /s /q "%BACKUP_DIR%"
mkdir "%LOG_DIR%"
mkdir "%BACKUP_DIR%"
type nul > "%OUTPUT_FILE%"
set "TEST_FAILED=0"
exit /b 0

:show_log_size
for /f %%A in ('powershell -NoProfile -Command "[math]::Floor((Get-ChildItem -LiteralPath '%LOG_DIR%' -File | Measure-Object -Property Length -Sum).Sum / 1000000)"') do set "LOG_MB=%%A"
call :count_files "%LOG_DIR%"
call :get_disk_usage
set /a DISK_PERCENT=USED_MB * 100 / TOTAL_MB
echo     prepared: %COUNT% files, %LOG_MB% MB, disk usage %DISK_PERCENT% percent
if %LOG_MB% LSS 537 call :fail "log folder is smaller than 0.5 GB"
exit /b 0

:run_main_script
>> "%OUTPUT_FILE%" echo ^> archive_logs.bat %*
call "%MAIN_SCRIPT%" %* >> "%OUTPUT_FILE%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"
exit /b 0

:check_exit_code
if not "%EXIT_CODE%"=="%~1" call :fail "exit code %EXIT_CODE%, expected %~1"
exit /b 0

:check_usage_below
call :get_disk_usage
set /a LIMIT_MB=TOTAL_MB * %~1 / 100
if %USED_MB% GTR %LIMIT_MB% call :fail "disk usage %USED_MB% MB is above %~1 percent (%LIMIT_MB% MB)"
exit /b 0

:check_no_archive
call :count_files "%BACKUP_DIR%"
if not "%COUNT%"=="0" call :fail "an archive was created but should not have been"
exit /b 0

:check_files_left
call :count_files "%LOG_DIR%"
if not "%COUNT%"=="%~1" call :fail "%COUNT% files left in the log folder, expected %~1"
exit /b 0

:check_archive
set "ARCHIVE_TYPE=%~1"
shift

call :count_files "%BACKUP_DIR%"
if not "%COUNT%"=="1" (
    call :fail "there must be exactly one archive in the backup folder"
    exit /b 0
)
for /f "delims=" %%A in ('dir /b /a-d "%BACKUP_DIR%"') do set "ARCHIVE_PATH=%BACKUP_DIR%\%%A"

if "%ARCHIVE_TYPE%"=="lzma" (
    set "EXPECTED_ENDING=.tar.lzma"
    set "EXPECTED_FIRST_BYTE=93"
) else (
    set "EXPECTED_ENDING=.tar.gz"
    set "EXPECTED_FIRST_BYTE=31"
)
echo %ARCHIVE_PATH%| findstr /l /e /c:"%EXPECTED_ENDING%" > nul
if errorlevel 1 call :fail "archive name must end with %EXPECTED_ENDING%"
for /f %%B in ('powershell -NoProfile -Command "[System.IO.File]::ReadAllBytes('%ARCHIVE_PATH%')[0]"') do set "FIRST_BYTE=%%B"
if not "%FIRST_BYTE%"=="%EXPECTED_FIRST_BYTE%" call :fail "archive is not compressed with %ARCHIVE_TYPE%"

type nul > "%WORK_DIR%\expected_raw.txt"
:check_archive_next_name
if "%~1"=="" goto check_archive_compare
>> "%WORK_DIR%\expected_raw.txt" echo %~1
if exist "%LOG_DIR%\%~1" call :fail "%~1 was archived but not deleted"
shift
goto check_archive_next_name

:check_archive_compare
"%TAR%" -t -f "%ARCHIVE_PATH%" > "%WORK_DIR%\actual_raw.txt"
sort "%WORK_DIR%\expected_raw.txt" /o "%WORK_DIR%\expected.txt"
sort "%WORK_DIR%\actual_raw.txt" /o "%WORK_DIR%\actual.txt"
fc "%WORK_DIR%\expected.txt" "%WORK_DIR%\actual.txt" > nul
if errorlevel 1 (
    call :fail "wrong files in the archive"
    echo       expected:
    type "%WORK_DIR%\expected.txt"
    echo       in archive:
    type "%WORK_DIR%\actual.txt"
)
exit /b 0

:finish_test
if "%TEST_FAILED%"=="0" (
    echo     OK
    set /a TESTS_PASSED=TESTS_PASSED + 1
) else (
    echo     FAILED, archive_logs.bat output:
    for /f "usebackq delims=" %%L in ("%OUTPUT_FILE%") do echo     ^| %%L
)
echo.
exit /b 0
