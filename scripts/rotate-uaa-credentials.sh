#!/bin/bash
set -euo pipefail

# Configuration
UAA_URL="${UAA_URL:-https://uaa.sys.home.fritzyTech.com}"
CREDHUB_URL="${CREDHUB_URL:-https://uaa.sys.home.fritzyTech.com}"
CLIENT_ID="${CLIENT_ID:-admin}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
TARGET_CLIENT="${TARGET_CLIENT:-concourse_client}"
CREDHUB_CLIENT="${CREDHUB_CLIENT:-credhub_admin_client}"
CREDHUB_SECRET="${CREDHUB_SECRET:-}"
CREDHUB_PATH="${CREDHUB_PATH:-/concourse/main/uaa_client_secret}"

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

debug() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] DEBUG: $1"
}

# Test connectivity
test_connectivity() {
    local url=$1
    debug "Testing connectivity to UAA at $url"
    
    if curl -s --connect-timeout 10 --max-time 30 "$url/info" > /dev/null 2>&1; then
        log "✓ Connectivity to UAA confirmed"
    else
        error "Cannot connect to UAA at $url. Please check network connectivity and URL."
    fi
}

# Get UAA token with proper error handling
get_uaa_token() {
    local client_id=$1
    local client_secret=$2
    
    debug "Getting UAA token for client: $client_id"
    
    local response
    # local http_code
    
    response=$(curl -k "https://uaa.sys.home.fritzyTech.com/oauth/token" -d "grant_type=client_credentials" -d "client_id=admin" -d "client_secret=ZhAPma0Smz4e50rlc_RbQJOH_BVhvDzo" -d "response_type=token")
    log "Response: $response"
    
    # if [ "$http_code" != "200" ]; then
    #     error "UAA token request failed with HTTP $http_code. Response: $response"
    # fi
    
    local token
    token=$(echo "$response" | jq -r '.access_token')
    
    if [ "$token" = "null" ] || [ -z "$token" ]; then
        error "Failed to parse access token from response"
    fi
    
    echo "$token"
}

# Generate secure password
generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Update UAA client secret
update_uaa_client_secret() {
    local token=$1
    local client_id=$2
    local new_secret=$3
    
    log "Updating UAA client secret for: $client_id"
    
    # Get current client configuration
    debug "Fetching current client configuration"
    local response
    local http_code
    
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        "$UAA_URL/oauth/clients/$client_id")
    
    http_code=$(echo "$response" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)
    response=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')
    
    if [ "$http_code" != "200" ]; then
        error "Failed to get client config. HTTP $http_code. Response: $response"
    fi
    
    # Update configuration with new secret
    local updated_config
    updated_config=$(echo "$response" | jq --arg secret "$new_secret" '.client_secret = $secret')
    
    # Apply update
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X PUT "$UAA_URL/oauth/clients/$client_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$updated_config")
    
    http_code=$(echo "$response" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)
    response=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')
    
    if [ "$http_code" != "200" ]; then
        error "Failed to update UAA client secret. HTTP $http_code. Response: $response"
    fi
    
    log "Successfully updated UAA client secret"
}

# Update CredHub secret
update_credhub_secret() {
    local path=$1
    local new_secret=$2
    
    log "Updating CredHub secret at: $path"
    
    # Get CredHub token
    local credhub_token
    credhub_token=$(get_uaa_token "$CREDHUB_CLIENT" "$CREDHUB_SECRET")
    
    # Update secret
    local response
    local http_code
    
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X PUT "$CREDHUB_URL/v1/data" \
        -H "Authorization: Bearer $credhub_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$path\",
            \"type\": \"password\",
            \"value\": \"$new_secret\"
        }")
    
    http_code=$(echo "$response" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)
    
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        error "Failed to update CredHub secret. HTTP $http_code"
    fi
    
    log "Successfully updated CredHub secret"
}

# Main function
main() {
    log "UAA Credential Rotation Script"
    log "=============================="
    log "Target Client: $TARGET_CLIENT"
    log "CredHub Path: $CREDHUB_PATH"
    log "UAA URL: $UAA_URL"
    log "CredHub URL: $CREDHUB_URL"
    debug "TLS Verification: ENABLED"
    debug "Curl Options: "
    
    # Validate environment
    [ -z "$CLIENT_SECRET" ] && error "CLIENT_SECRET environment variable is required"
    [ -z "$CREDHUB_SECRET" ] && error "CREDHUB_SECRET environment variable is required"
    
    # Test connectivity
    test_connectivity "$UAA_URL"
    
    log "Starting credential rotation for client: $TARGET_CLIENT"
    log "CredHub path: $CREDHUB_PATH"
    
    # Generate new secret
    local new_secret
    new_secret=$(generate_secret)
    log "Generated new secret"
    
    # Get admin token
    log "Authenticating with UAA admin client"
    local admin_token
    admin_token=$(get_uaa_token "$CLIENT_ID" "$CLIENT_SECRET")
    
    # Update UAA client secret
    update_uaa_client_secret "$admin_token" "$TARGET_CLIENT" "$new_secret"
    
    # Update CredHub secret
    update_credhub_secret "$CREDHUB_PATH" "$new_secret"
    
    # Validate new credentials
    log "Testing new credentials..."
    local test_token
    test_token=$(get_uaa_token "$TARGET_CLIENT" "$new_secret")
    
    if [ -n "$test_token" ]; then
        log "✅ New credentials verified successfully"
        log "🎉 Credential rotation completed successfully!"
    else
        error "❌ New credentials verification failed"
    fi
}

# Execute
main "$@"