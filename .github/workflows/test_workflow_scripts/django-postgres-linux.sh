#!/bin/bash

source ./../../../.github/workflows/test_workflow_scripts/test-iid.sh

# Start mongo before starting keploy.
docker run -p 6000:5432 --rm --name postgres -e POSTGRES_PASSWORD=my-secret-pw -d postgres:latest

# Check if there is a keploy-config file, if there is, delete it.
if [ -f "./keploy.yml" ]; then
    rm ./keploy.yml
fi
export ConnectionString="root:my-secret-pw@tcp(localhost:5432)/postgres"

send_request() {
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
    # Wait for 10 seconds for keploy to record the tcs and mocks.
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
    test_status=$(grep 'status:' "$report_file" | head -n 1 | awk '{print $2}')

    # Print the status for debugging
    echo "Test status for test-set-$i: $test_status"

    # Check if any test set did not pass
    if [ "$test_status" != "PASSED" ]; then
        all_passed=false
        echo "Test-set-$i did not pass."
        break # Exit the loop early as all tests need to pass
    fi
done

# Check the overall test status and exit accordingly
if [ "$all_passed" = true ]; then
    echo "All tests passed"
    exit 0
else
    cat "test_logs.txt"
    exit 1
fi