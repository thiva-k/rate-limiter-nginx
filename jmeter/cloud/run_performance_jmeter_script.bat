@echo off
REM Set JMeter parameters
set LB_1_HOSTNAME=34.105.131.163
set LB_2_HOSTNAME=34.30.98.150
set LB_1_PORT=8090
set LB_2_PORT=8091

set WARM_UP_USERS=100
set WARM_UP_TIME=30
set TEST_RUN_TIME=600
set RAMP_UP=10

set GROUP_1=70
set GROUP_2=25
set GROUP_3=5
set GROUP_1_REQUEST_RATE=30
set GROUP_2_REQUEST_RATE=90
set GROUP_3_REQUEST_RATE=120

set TEST_PLAN=teastore_performance.jmx
set TEST_FOLDER=performance

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
set LOG_FILE="%~dp0%LOG_DIR%\warm_up_results.csv"

echo log file: %LOG_FILE%

REM Create log directory if it doesn't exist
if not exist %LOG_DIR% (
    mkdir %LOG_DIR%
)

REM create new file called warm_up_results.csv under LOG_DIR folder without any content
echo. > %LOG_DIR%\warm_up_results.csv

REM Copy run_generate_report.bat to the log directory
copy run_generate_report.bat %LOG_DIR%

REM Save all jmeter properties to a file
echo lb_1_hostname=%LB_1_HOSTNAME% > %LOG_DIR%\jmeter.properties
echo lb_2_hostname=%LB_2_HOSTNAME% >> %LOG_DIR%\jmeter.properties
echo lb_1_port=%LB_1_PORT% >> %LOG_DIR%\jmeter.properties
echo lb_2_port=%LB_2_PORT% >> %LOG_DIR%\jmeter.properties
echo warm_up_users=%WARM_UP_USERS% >> %LOG_DIR%\jmeter.properties
echo warm_up_time=%WARM_UP_TIME% >> %LOG_DIR%\jmeter.properties
echo test_run_time=%TEST_RUN_TIME% >> %LOG_DIR%\jmeter.properties
echo ramp_up=%RAMP_UP% >> %LOG_DIR%\jmeter.properties
echo group_1=%GROUP_1% >> %LOG_DIR%\jmeter.properties
echo group_2=%GROUP_2% >> %LOG_DIR%\jmeter.properties
echo group_3=%GROUP_3% >> %LOG_DIR%\jmeter.properties
echo group_1_request_rate=%GROUP_1_REQUEST_RATE% >> %LOG_DIR%\jmeter.properties
echo group_2_request_rate=%GROUP_2_REQUEST_RATE% >> %LOG_DIR%\jmeter.properties
echo group_3_request_rate=%GROUP_3_REQUEST_RATE% >> %LOG_DIR%\jmeter.properties

REM Run JMeter test
"%JMETER_HOME%\bin\jmeter.bat" -n -t %TEST_PLAN% -l %RESULT_FILE% -j %JMETER_LOG% ^
-Jlb_1_hostname=%LB_1_HOSTNAME% ^
-Jlb_2_hostname=%LB_2_HOSTNAME% ^
-Jlb_1_port=%LB_1_PORT% ^
-Jlb_2_port=%LB_2_PORT% ^
-Jwarm_up_users=%WARM_UP_USERS% ^
-Jwarm_up_time=%WARM_UP_TIME% ^
-Jtest_run_time=%TEST_RUN_TIME% ^
-Jgroup_1=%GROUP_1% ^
-Jgroup_2=%GROUP_2% ^
-Jgroup_3=%GROUP_3% ^
-Jgroup_1_request_rate=%GROUP_1_REQUEST_RATE% ^
-Jgroup_2_request_rate=%GROUP_2_REQUEST_RATE% ^
-Jgroup_3_request_rate=%GROUP_3_REQUEST_RATE% ^
-Jramp_up=%RAMP_UP% ^
-Jlog_file=%LOG_FILE%
