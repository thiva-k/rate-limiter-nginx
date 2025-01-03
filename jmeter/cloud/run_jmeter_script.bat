@echo off

REM Prompt user for test type
set /p TEST_TYPE="Enter test type (performance/stress): "

REM Validate input
if /i "%TEST_TYPE%"=="performance" (
    set TEST_PLAN=teastore_performance.jmx
    set TEST_FOLDER=performance
) else if /i "%TEST_TYPE%"=="stress" (
    set TEST_PLAN=teastore_stress.jmx
    set TEST_FOLDER=stress
) else (
    echo Invalid test type. Please enter either "performance" or "stress".
    pause
    exit /b 1
)

REM Prompt user for rate limiting algorithm
echo Select rate limiting algorithm:
echo 1 - fixed_window_counter
echo 2 - sliding_window_counter
echo 3 - sliding_window_log
echo 4 - token_bucket
echo 5 - leaky_bucket
set /p ALGO_OPTION="Enter the number corresponding to the algorithm: "

REM Validate algorithm input
if "%ALGO_OPTION%"=="1" (
    set ALGO_NAME=fixed_window_counter
) else if "%ALGO_OPTION%"=="2" (
    set ALGO_NAME=sliding_window_counter
) else if "%ALGO_OPTION%"=="3" (
    set ALGO_NAME=sliding_window_log
) else if "%ALGO_OPTION%"=="4" (
    set ALGO_NAME=token_bucket
) else if "%ALGO_OPTION%"=="5" (
    set ALGO_NAME=leaky_bucket
) else (
    echo Invalid algorithm option. Please enter a number between 1 and 5.
    pause
    exit /b 1
)

REM Get current timestamp
for /f "tokens=1-6 delims=/:. " %%a in ("%date% %time%") do (
    set TIMESTAMP=%%d_%%c_%%b_%%e_%%f
)

REM Set result and log file paths
set LOG_DIR=logs\%ALGO_NAME%\%TEST_FOLDER%\%TIMESTAMP%
set RESULT_FILE=%LOG_DIR%\jmeter_results.csv
set JMETER_LOG=%LOG_DIR%\jmeter.log

REM Create log directory if it doesn't exist
if not exist %LOG_DIR% (
    mkdir %LOG_DIR%
)

REM Copy run_generate_report.bat to the log directory
copy run_generate_report.bat %LOG_DIR%

REM Run JMeter test plan
"%JMETER_HOME%\bin\jmeter.bat" -n -t %TEST_PLAN% -l %RESULT_FILE% -j %JMETER_LOG%

pause