#!/bin/sh
set -e

GARAGE_ADMIN_URL="${GARAGE_ADMIN_URL:-http://garage:3903}"
ADMIN_TOKEN="${GARAGE_ADMIN_TOKEN:-lara-admin-token}"
TIMEOUT=30
ELAPSED=0

# Helper: fetch JSON and flatten to one line for sed parsing
garage_api() {
    curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$@" | tr -d '\n '
}

# Wait for Garage admin API
echo "Waiting for Garage to start..."
until curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$GARAGE_ADMIN_URL/v1/status" > /dev/null 2>&1; do
    ELAPSED=$((ELAPSED + 1))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "ERROR: Garage did not start within ${TIMEOUT}s" >&2
        exit 1
    fi
    sleep 1
done
echo "Garage is ready."

# Skip if already initialized (bucket exists)
if curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$GARAGE_ADMIN_URL/v1/bucket?globalAlias=$GARAGE_BUCKET_NAME" > /dev/null 2>&1; then
    echo "Already initialized, skipping."
    exit 0
fi

# Get node ID
NODE_ID=$(garage_api "$GARAGE_ADMIN_URL/v1/status" \
    | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')

if [ -z "$NODE_ID" ]; then
    echo "ERROR: Could not determine Garage node ID" >&2
    exit 1
fi

# Assign layout (tags field is required by Garage v1.x)
curl -sf -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "[{\"id\":\"$NODE_ID\",\"zone\":\"dc1\",\"capacity\":1073741824,\"tags\":[\"dev\"]}]" \
    "$GARAGE_ADMIN_URL/v1/layout"

# Apply layout
LAYOUT_VERSION=$(garage_api "$GARAGE_ADMIN_URL/v1/layout" \
    | sed -n 's/.*"version":\([0-9]*\).*/\1/p')
NEXT_VERSION=$((LAYOUT_VERSION + 1))
curl -sf -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"version\":$NEXT_VERSION}" \
    "$GARAGE_ADMIN_URL/v1/layout/apply"

# Create bucket
curl -sf -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"globalAlias\":\"$GARAGE_BUCKET_NAME\"}" \
    "$GARAGE_ADMIN_URL/v1/bucket"

# Create access key (Garage generates GK-prefixed key ID and secret)
KEY_RESPONSE=$(garage_api -X POST \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"laravel\"}" \
    "$GARAGE_ADMIN_URL/v1/key")
ACCESS_KEY_ID=$(echo "$KEY_RESPONSE" | sed -n 's/.*"accessKeyId":"\([^"]*\)".*/\1/p')
SECRET_KEY=$(echo "$KEY_RESPONSE" | sed -n 's/.*"secretAccessKey":"\([^"]*\)".*/\1/p')

# Grant permissions on bucket
BUCKET_ID=$(garage_api "$GARAGE_ADMIN_URL/v1/bucket?globalAlias=$GARAGE_BUCKET_NAME" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

curl -sf -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"$ACCESS_KEY_ID\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":true}}" \
    "$GARAGE_ADMIN_URL/v1/bucket/allow"

# Write credentials to shared volume so app's entrypoint can load them
echo "AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID" > /tmp/garage/credentials
echo "AWS_SECRET_ACCESS_KEY=$SECRET_KEY" >> /tmp/garage/credentials

echo "Garage initialized: bucket=$GARAGE_BUCKET_NAME, key=$ACCESS_KEY_ID"
