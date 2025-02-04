#!/bin/bash

# Navigate to the InfluxDB directory
cd 'C:\Program Files\InfluxData\influxdb\'

# Start InfluxDB with the specified configuration file
./influxd --http-bind-address=":8096"