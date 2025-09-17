#!/bin/bash
set -euo pipefail

# Configuration with better defaults
UAA_URL="${UAA_URL:-https://uaa.sys.fritzyTech.com}"
CLIENT_ID="${CLIENT_ID:-admin}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
TARGET_CLIENT="${TARGET_CLIENT:-concourse_client}"
CREDHUB_URL="${CREDHUB_URL:-${UAA_URL}}"  # Often same as UAA URL
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

# Function to get UAA token with better error handling
get_uaa_token() {
    local client_id=$1
    local client_secret=$2
    
    log "Getting UAA token for client: $client_id"
    
    # Make the request and capture both output and HTTP status
    local response
    local http_code
    
    response=$(curl -s -w "%{http_code}" -X POST "$UAA_URL/oauth/token" \
        -H "Accept: application/json" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "$client_id:$client_secret" \
        -d "grant_type=client_credentials" 2>/dev/null)
    
    http_code="${response: -3}"
    response="${response%???}"
    
    if [[ "$http_code" != "200" ]]; then
        error "UAA token request failed with HTTP $http_code. Response: $response"
    fi
    
    local token
    token=$(echo "$response" | jq -r '.access_token' 2>/dev/null)
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        error "Failed to parse UAA token from response: $response"
    fi
    
    echo "$token"
}

# Function to generate secure client secret
generate_secret() {
    log "Generating new secret"
    # Generate a 32-character alphanumeric secret
    openssl rand -base64 48 | tr -d "=+/\n" | cut -c1-32
}

# Function to get current client configuration
get_client_config() {
    local token=$1
    local client_id=$2
    
    log "Retrieving current configuration for client: $client_id"
    
    local response
    local http_code
    
    response=$(curl -s -w "%{http_code}" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        "$UAA_URL/oauth/clients/$client_id" 2>/dev/null)
    
    http_code="${response: -3}"
    response="${response%???}"
    
    if [[ "$http_code" != "200" ]]; then
        error "Failed to get client config. HTTP $http_code. Response: $response"
    fi
    
    echo "$response"
}

# Function to update UAA client secret
update_uaa_client_secret() {
    local token=$1
    local client_id=$2
    local new_secret=$3
    
    log "Updating UAA client secret for: $client_id"
    
    # Get current client configuration
    local current_config
    current_config=$(get_client_config "$token" "$client_id")
    
    # Update the secret in the configuration
    local updated_config
    updated_config=$(echo "$current_config" | jq --arg secret "$new_secret" '.client_secret = $secret')
    
    # Send the update request
    local response
    local http_code
    
    response=$(curl -s -w "%{http_code}" -X PUT "$UAA_URL/oauth/clients/$client_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$updated_config" 2>/dev/null)
    
    http_code="${response: -3}"
    response="${response%???}"
    
    if [[ "$http_code" != "200" ]]; then
        error "Failed to update UAA client secret. HTTP $http_code. Response: $response"
    fi
    
    log "Successfully updated UAA client secret"
}

# Function to update CredHub secret
update_credhub_secret() {
    local credhub_path=$1
    local new_secret=$2
    
    log "Updating CredHub secret at: $credhub_path"
    
    # Get CredHub token
    local credhub_token
    credhub_token=$(get_uaa_token "$CREDHUB_CLIENT" "$CREDHUB_SECRET")
    
    # Update the secret in CredHub
    local response
    local http_code
    
    response=$(curl -s -w "%{http_code}" -X PUT "$CREDHUB_URL/v1/data" \
        -H "Authorization: Bearer $credhub_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$credhub_path\",
            \"type\": \"password\",
            \"value\": \"$new_secret\"
        }" 2>/dev/null)
    
    http_code="${response: -3}"
    response="${response%???}"
    
    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        error "Failed to update CredHub secret. HTTP $http_code. Response: $response"
    fi
    
    log "Successfully updated CredHub secret"
}

# Function to test credentials
test_credentials() {
    local client_id=$1
    local client_secret=$2
    
    log "Testing credentials for client: $client_id"
    
    local test_token
    test_token=$(get_uaa_token "$client_id" "$client_secret")
    
    if [[ -n "$test_token" ]]; then
        log "✓ Credentials test successful"
        return 0
    else
        log "✗ Credentials test failed"
        return 1
    fi
}

# Main rotation function
rotate_credentials() {
    local target_client=${1:-$TARGET_CLIENT}
    local credhub_path=${2:-$CREDHUB_PATH}
    
    log "Starting credential rotation for client: $target_client"
    log "CredHub path: $credhub_path"
    
    # Validate inputs
    [[ -z "$target_client" ]] && error "Target client not specified"
    [[ -z "$credhub_path" ]] && error "CredHub path not specified"
    
    # Generate new secret
    local new_secret
    new_secret=$(generate_secret)
    log "Generated new secret"
    
    # Get admin token for UAA operations
    log "Authenticating with UAA admin client"
    local admin_token
    admin_token=$(get_uaa_token "$CLIENT_ID" "$CLIENT_SECRET")
    
    # Update UAA client secret
    update_uaa_client_secret "$admin_token" "$target_client" "$new_secret"
    
    # Small delay to ensure UAA has processed the change
    sleep 2
    
    # Test the new UAA credentials before updating CredHub
    if test_credentials "$target_client" "$new_secret"; then
        # Update CredHub secret
        update_credhub_secret "$credhub_path" "$new_secret"
        log "Credential rotation completed successfully!"
    else
        error "New credentials failed validation. Rotation aborted."
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
    
    # Validate required environment variables
    [[ -z "$CLIENT_SECRET" ]] && error "CLIENT_SECRET environment variable is required"
    [[ -z "$CREDHUB_SECRET" ]] && error "CREDHUB_SECRET environment variable is required"
    
    # Check required tools
    command -v curl >/dev/null 2>&1 || error "curl is required but not installed"
    command -v jq >/dev/null 2>&1 || error "jq is required but not installed"
    command -v openssl >/dev/null 2>&1 || error "openssl is required but not installed"
    
    # Parse command line arguments
    local target_client="${1:-$TARGET_CLIENT}"
    local credhub_path="${2:-$CREDHUB_PATH}"
    
    # Perform rotation
    rotate_credentials "$target_client" "$credhub_path"
}

# Execute main function
main "$@"