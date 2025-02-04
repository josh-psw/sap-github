#!/bin/sh

CREATE_SITE_BODY=$(cat <<EOF | jq -c
{
    "query": "mutation CreateSite(\$input: CreateSiteInput!) { create_site(input: \$input) { site { name id scope_v2 { start_urls in_scope_url_prefixes out_of_scope_url_prefixes protocol_options } } } }",
    "operationName": "CreateSite",
    "variables": {
        "input": {
            "name": "$SITE_NAME",
            "scope_v2": {
                "start_urls": ["$APPLICATION_URL"],
                "protocol_options": "USE_HTTP_AND_HTTPS"
            },
            "parent_id": 0,
            "confirm_permission_to_scan": true,
            "scan_configuration_ids": ["13467384-a8c8-49f9-8d45-68e70e3e8776"],
            "application_logins": {}
        }
    }
}
EOF
)

create_scan_body() {
    local site_id="$1"

    jq -nc --arg site_id "$site_id" '{
        query: "mutation CreateScheduleItem($input: CreateScheduleItemInput!) { create_schedule_item(input: $input) { schedule_item { id } } }",
        operationName: "CreateScheduleItem",
        variables: {
            input: {
                site_id: $site_id,
                verbose_debug: null
            }
        }
    }'
}

scan_status_body() {
    local schedule_item_id="$1"

    jq -nc --arg site_id "$site_id" '{
        "query": "query GetScan($schedule_item_id: ID) {scans(limit: 1, schedule_item_id: $schedule_item_id) { status } }",
        "operationName": "GetScan",
        "variables": {
            "input": {
                "schedule_item_id": $schedule_item_id
            }
        }
    }'
}

make_request() {
    local action_name="$1"
    local body="$2"
    local json_selector="$3"

    response=$(curl -s -w "\n%{http_code}" --request POST \
        --url "$BURP_ENTERPRISE_SERVER_URL/graphql/v1" \
        --header "Authorization: $BURP_ENTERPRISE_API_KEY" \
        --header "Content-Type: application/json" \
        --data "$body")

    response_body=$(echo "$response" | sed '$d')
    response_code=$(echo "$response" | tail -n1)

    if [ "$response_code" -ne 200 ] || echo "$response_body" | grep -iq '"errors"'; then
        echo "$action_name: failed (code = $response_code)"
        echo "Response body: $response_body"
        
        return 1 
    else
        echo "$action_name request: success"
                
        if [ -n "$json_selector" ]; then
            extracted_value=$(echo "$response_body" | jq -r "$json_selector")

            if [ "$extracted_value" = "null" ]; then
                :
            else
                echo "$extracted_value"
            fi
        else
            echo "" 
        fi

        return 0 
    fi
}

poll_scan_status() {
    local schedule_item_id="$1"
    local status=""
    local scan_status_body=$(scan_status_body "$SCHEDULE_ITEM_ID")

    while true; do
        status=$(make_request "Check scan status" "$scan_status_body" ".data.scans[0].status" | tee /dev/tty | tail -n1)
        
        echo "Current scan status: $status"

        if [ "$status" = "succeeded" ] || [ "$status" = "cancelled" ] || [ "$status" = "failed" ]; then
            echo "$status"
            return 0
        fi

        sleep 60
    done
}

# Create site
echo "Creating site $SITE_NAME"
SITE_ID=$(make_request "Create site" "$CREATE_SITE_BODY" ".data.create_site.site.id" | tee /dev/tty | tail -n1)

# Start scan
echo "Starting scan"

SCAN_BODY=$(create_scan_body "$SITE_ID")
SCHEDULE_ITEM_ID=$(make_request "Start scan" "$SCAN_BODY" ".data.create_schedule_item.schedule_item.id" | tee /dev/tty | tail -n1)

# Poll for scan complete
echo "Waiting for scan to complete"
SCAN_STATUS=$(poll_scan_status $SCHEDULE_ITEM_ID)

if [ -z "$scan_status" ]; then
    echo "Something has gone wrong - scan status is empty. Exiting with -1"
    exit -1
elif [ "$scan_status" = "failed" ]; then
    echo "Scan failed. Exiting with -2"
    exit -2
elif [ "$scan_status" = "cancelled" ]; then
    echo "Scan was cancelled. Exiting with -3"
    exit -3
elif [ "$scan_status" = "succeeded" ]; then
    echo "Scan completed. View the results in the dashboard"
else
    echo "Unexpected scan status: $scan_status. Exiting with -4"
    exit -4
fi


# script can be modified to retrieve results after scan completed, show link to scan, have thresholds baased on vulnerabilities detected etc
