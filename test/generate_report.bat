@echo off

REM Set the JMeter Home Directory
set JMETER_HOME=D:\Semester 7\CS4203 - Research and Development Project\Artifacts\apache-jmeter-5.6.3

REM Path to JMeter result file (.jtl or .csv)
set RESULTS_FILE="D:\Semester 7\CS4203 - Research and Development Project\Artifacts\rate-limiter-nginx\test\logs\jmeter_results.csv"

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
