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

REM Get current timestamp
for /f "tokens=1-6 delims=/:. " %%a in ("%date% %time%") do (
    set TIMESTAMP=%%d_%%c_%%b_%%e_%%f
)

REM Set result and log file paths
set LOG_DIR=logs\%TEST_FOLDER%\%TIMESTAMP%
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