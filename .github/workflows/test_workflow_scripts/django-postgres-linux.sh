#!/bin/bash

source ./../../../.github/workflows/test_workflow_scripts/test-iid.sh

# Checkout to the specified branch
git fetch origin
git checkout native-linux

# Start the postgres database
docker-compose up -d

# Install dependencies
pip3 install -r requirements.txt

# Setup environment
export PYTHON_PATH=./venv/lib/python3.10/site-packages/django

# Database migrations
python3 manage.py makemigrations
python3 manage.py migrate

# Configuration and cleanup
sudo ./../../../keployv2 config --generate
sudo rm -rf keploy/  # Clean old test data
config_file="./keploy.yml"
sed -i 's/global: {}/global: {"header": {"Allow":[],}}/' "$config_file"
sleep 5  # Allow time for configuration changes

# Check if there is a keploy-config file, if there is, delete it.
if [ -f "./keploy.yml" ]; then
    rm ./keploy.yml
fi

send_request() {
    echo "hello from inside"
    sleep 10
    app_started=false
    while [ "$app_started" = false ]; do
        if curl -X GET http://localhost:8000/user; then
            app_started=true
        fi
        sleep 3
    done
    echo "App started"
    curl -X POST http://localhost:8000/user \
        -H "Content-Type: application/json" \
        -d '{
            "name": "Jane Smith",
            "email": "jane.smith@example.com",
            "password": "smith567",
            "website": "www.janesmith.com"
        }'
    curl --location 'http://127.0.0.1:8000/user/'
    sleep 10
    pid=$(pgrep keploy)
    echo "$pid Keploy PID"
    echo "Killing keploy"
    sudo kill $pid
}

for i in {1..2}; do
    app_name="django_postgres_${i}"
    send_request &
    sudo -E env PATH="$PATH" ./../../keployv2 record -c "./django_postgres" --generateGithubActions=false &> "${app_name}.txt"
    if grep "ERROR" "${app_name}.txt"; then
        echo "Error found in pipeline..."
        cat "${app_name}.txt"
        exit 1
    fi
    if grep "WARNING: DATA RACE" "${app_name}.txt"; then
        echo "Race condition detected in recording, stopping pipeline..."
        cat "${app_name}.txt"
        exit 1
    fi
    sleep 5
    wait
    echo "Recorded test case and mocks for iteration ${i}"
done

# Start the django_postgres app in test mode.
sudo -E env PATH="$PATH" ./../../keployv2 test -c "./django_postgres" --delay 7 --generateGithubActions=false &> test_logs.txt

if grep "ERROR" "test_logs.txt"; then
    echo "Error found in pipeline..."
    cat "test_logs.txt"
    exit 1
fi

if grep "WARNING: DATA RACE" "test_logs.txt"; then
    echo "Race condition detected in test, stopping pipeline..."
    cat "test_logs.txt"
    exit 1
fi

all_passed=true

# Get the test results from the testReport file.
for i in {0..1}
do
    # Define the report file for each test set
    report_file="./keploy/reports/test-run-0/test-set-$i-report.yaml"

    # Extract the test status
    test_status=$(grep 's
