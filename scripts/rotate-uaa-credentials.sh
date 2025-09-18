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

# Logging
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
        return 0
    else
        error "Cannot connect to UAA at $url. Please check network connectivity and URL."
    fi
}

# Get UAA token with proper error handling
get_uaa_token() {
    local client_id=$1
    local client_secret=$2
    
    debug "Getting UAA token for client: $client_id using URL: $UAA_URL/oauth/token"
    
    local response
    local http_code
    
    # Make the token request
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X POST "$UAA_URL/oauth/token" \
        -H "Accept: application/json" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "$client_id:$client_secret" \
        -d "grant_type=client_credentials" 2>/dev/null)
    
    # Extract HTTP status code
    http_code=$(echo "$response" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)
    response=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')
    
    debug "HTTP Response Code: $http_code"
    debug "Response Body: $response"
    
    if [ "$http_code" != "200" ]; then
        error "UAA token request failed with HTTP $http_code. Response: $response"
    fi
    
    # Extract access token
    local token
    token=$(echo "$response" | jq -r '.access_token' 2>/dev/null)
    
    if [ "$token" = "null" ] || [ -z "$token" ]; then
        error "Failed to parse access token from response: $response"
    fi
    
    echo "$token"
}

# Generate secure password
generate_secret() {
    log "Generated new secret"
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Get current UAA client configuration
get_client_config() {
    local token=$1
    local client_id=$2
    
    debug "Fetching current client configuration for: $client_id"
    
    local response
    local http_code
    
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        "$UAA_URL/oauth/clients/$client_id" 2>/dev/null)
    
    http_code=$(echo "$response" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)
    response=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')
    
    if [ "$http_code" != "200" ]; then
        error "Failed to get client config. HTTP $http_code. Response: $response"
    fi
    
    echo "$response"
}

# Update UAA client secret
update_uaa_client_secret() {
    local token=$1
    local client_id=$2
    local new_secret=$3
    
    log "Updating UAA client secret for: $client_id"
    
    # Get current client configuration
    local current_config
    current_config=$(get_client_config "$token" "$client_id")
    
    # Update secret in the configuration
    local updated_config
    updated_config=$(echo "$current_config" | jq --arg secret "$new_secret" '.client_secret = $secret')
    
    # Send update request
    local response
    local http_code
    
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X PUT "$UAA_URL/oauth/clients/$client_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$updated_config" 2>/dev/null)
    
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
    
    # Update secret in CredHub
    local response
    local http_code
    
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X PUT "$CREDHUB_URL/v1/data" \
        -H "Authorization: Bearer $credhub_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$path\",
            \"type\": \"password\",
            \"value\": \"$new_secret\"
        }" 2>/dev/null)
    
    http_code=$(echo "$response" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)
    response=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')
    
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        error "Failed to update CredHub secret. HTTP $http_code. Response: $response"
    fi
    
    log "Successfully updated CredHub secret"
}

# Validate rotated credentials
validate_credentials() {
    local client_id=$1
    local client_secret=$2
    
    log "Validating rotated credentials..."
    
    local test_token
    test_token=$(get_uaa_token "$client_id" "$client_secret")
    
    if [ -n "$test_token" ] && [ "$test_token" != "null" ]; then
        log "✅ Credential validation successful"
        return 0
    else
        error "❌ Credential validation failed"
    fi
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
    
    # Get admin token
    log "Authenticating with UAA admin client"
    local admin_token
    admin_token=$(get_uaa_token "$CLIENT_ID" "$CLIENT_SECRET")
    
    # Update UAA client secret
    update_uaa_client_secret "$admin_token" "$TARGET_CLIENT" "$new_secret"
    
    # Small delay for UAA to process the change
    sleep 2
    
    # Update CredHub secret
    update_credhub_secret "$CREDHUB_PATH" "$new_secret"
    
    # Validate the new credentials
    validate_credentials "$TARGET_CLIENT" "$new_secret"
    
    log "🎉 Credential rotation completed successfully!"
}

# Execute
main "$@"