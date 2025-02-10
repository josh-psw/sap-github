#!/bin/sh

CREATE_SITE_BODY=$(cat <<EOB | jq -c
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
            "scan_configuration_ids": ["8461d22c-c06a-4255-a6ef-bb5e56f0779a"],
            "application_logins": {}
        }
    }
}
EOB
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

    jq -nc --arg schedule_item_id "$schedule_item_id" '{
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
        echo "$body"
        echo "$response_body"
      
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
    local scan_status_body="$1"
    local status=""

    while true; do
        status=$(make_request "Check scan status" "$scan_status_body" ".data.scans[0].status" | tail -n1)

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
SITE_ID=$(make_request "Create site" "$CREATE_SITE_BODY" ".data.create_site.site.id" | tail -n1)

# Start scan
echo "Starting scan"

SCAN_BODY=$(create_scan_body "$SITE_ID")
SCHEDULE_ITEM_ID=$(make_request "Start scan" "$SCAN_BODY" ".data.create_schedule_item.schedule_item.id" | tail -n1)

# Poll for scan complete
echo "Waiting for scan to complete"
SCAN_STATUS_BODY=$(scan_status_body "$SCHEDULE_ITEM_ID")
SCAN_ID=$(make_request "Scan ID" ".data.scans[0].id")

SCAN_URL="$BURP_ENTERPRISE_SERVER_URL/scans/$SCAN_ID"
echo "Scan started - view at $SCAN_URL"

SCAN_STATUS=$(poll_scan_status $SCAN_STATUS_BODY | tail -n1)

if [ -z "$SCAN_STATUS" ]; then
    echo "Something has gone wrong - scan status is empty. Exiting with -1"
    exit -1
elif [ "$SCAN_STATUS" = "failed" ]; then
    echo "Scan failed. Exiting with -2"
    exit -2
elif [ "$SCAN_STATUS" = "cancelled" ]; then
    echo "Scan was cancelled. Exiting with -3"
    exit -3
elif [ "$SCAN_STATUS" = "succeeded" ]; then
    echo "Scan completed. View the results at $SCAN_URL"
else
    echo "Unexpected scan status: $SCAN_STATUS. Exiting with -4"
    exit -4
fi
