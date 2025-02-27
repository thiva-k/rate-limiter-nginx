@echo off

REM Path to JMeter result file (.jtl or .csv)
set RESULTS_FILE="%CD%\jmeter_results.csv"

REM Output directory for the HTML report
set OUTPUT_DIR="%CD%\report"

REM Check if the report folder exists and clear its contents
if exist %OUTPUT_DIR% (
    echo Clearing existing report folder: %OUTPUT_DIR%
    rmdir /s /q %OUTPUT_DIR%
)

REM Create a fresh report folder
mkdir %OUTPUT_DIR%

REM Generate the report
"%JMETER_HOME%\bin\jmeter.bat" -g %RESULTS_FILE% -o %OUTPUT_DIR%

REM Notify user
echo Report generated at %OUTPUT_DIR%
pause
