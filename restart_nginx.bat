@echo off

REM Rebuild the Docker images for load_balancer1 and load_balancer2
docker-compose build load_balancer1 load_balancer2

REM Restart the Docker containers for load_balancer1 and load_balancer2
docker-compose up -d --force-recreate load_balancer1 load_balancer2

REM Notify user
echo Nginx load balancers have been rebuilt and restarted.
pause