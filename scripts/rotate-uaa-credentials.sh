#!/bin/bash
set -euo pipefail

# Configuration with defaults
UAA_URL="${UAA_URL:-https://uaa.sys.home.fritzyTech.com}"
CREDHUB_URL="${CREDHUB_URL:-https://uaa.sys.home.fritzyTech.com}"
CLIENT_ID="${CLIENT_ID:-admin}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
TARGET_CLIENT="${TARGET_CLIENT:-concourse_client}"
CREDHUB_CLIENT="${CREDHUB_CLIENT:-credhub_admin_client}"
CREDHUB_SECRET="${CREDHUB_SECRET:-}"
CREDHUB_PATH="${CREDHUB_PATH:-/concourse/main/uaa_client_secret}"

# TLS Configuration - set to true if using self-signed certificates
SKIP_TLS_VERIFY="${SKIP_TLS_VERIFY:-false}"
CURL_OPTS=""
if [ "$SKIP_TLS_VERIFY" = "true" ]; then
    CURL_OPTS="-k"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

debug() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] DEBUG: $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Function to test connectivity
test_connectivity() {
    local url=$1
    local service_name=$2
    
    debug "Testing connectivity to $service_name at $url"
    
    # Test basic connectivity
    if ! curl $CURL_OPTS -s --connect-timeout 10 --max-time 30 "$url/info" > /dev/null 2>&1; then
        # Try without /info endpoint
        if ! curl $CURL_OPTS -s --connect-timeout 10 --max-time 30 "$url" > /dev/null 2>&1; then
            error "Cannot connect to $service_name at $url. Please check network connectivity and URL."
        fi
    fi
    
    log "✓ Connectivity to $service_name confirmed"
}

# Enhanced UAA token function with debugging
get_uaa_token() {
    local client_id=$1
    local client_secret=$2
    local service_name=${3:-"UAA"}
    
    log "Authenticating with $service_name client: $client_id"
    debug "Using URL: $UAA_URL/oauth/token"
    
    # Create temporary file for response
    local temp_response=$(mktemp)
    local temp_headers=$(mktemp)
    
    # Make the request with detailed output
    local http_code
    http_code=$(curl $CURL_OPTS -s \
        --connect-timeout 10 \
        --max-time 30 \
        -w "%{http_code}" \
        -D "$temp_headers" \
        -o "$temp_response" \
        -X POST "$UAA_URL/oauth/token" \
        -H "Accept: application/json" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "$client_id:$client_secret" \
        -d "grant_type=client_credentials")
    
    debug "HTTP Status Code: $http_code"
    debug "Response Headers:"
    cat "$temp_headers" | sed 's/^/[DEBUG] /' || true
    debug "Response Body:"
    cat "$temp_response" | sed 's/^/[DEBUG] /' || true
    
    # Check for connection errors
    if [ "$http_code" = "000" ]; then
        error "$service_name token request failed with HTTP 000. This indicates a connection problem. Check:
1. Network connectivity to $UAA_URL
2. DNS resolution
3. Firewall rules
4. TLS/SSL certificate issues (try setting SKIP_TLS_VERIFY=true for testing)"
    fi
    
    # Check for authentication errors
    if [ "$http_code" != "200" ]; then
        local error_msg="Unknown error"
        if [ -f "$temp_response" ]; then
            error_msg=$(cat "$temp_response")
        fi
        error "$service_name token request failed with HTTP $http_code. Response: $error_msg"
    fi
    
    # Extract token
    local token
    if ! token=$(cat "$temp_response" | jq -r '.access_token' 2>/dev/null); then
        error "Failed to parse access token from $service_name response"
    fi
    
    if [ "$token" = "null" ] || [ -z "$token" ]; then
        error "Received null or empty access token from $service_name"
    fi
    
    # Cleanup
    rm -f "$temp_response" "$temp_headers"
    
    log "✓ Successfully authenticated with $service_name"
    echo "$token"
}

# Generate secure password
generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Update UAA client secret with better error handling
update_uaa_client_secret() {
    local token=$1
    local client_id=$2
    local new_secret=$3
    
    log "Updating UAA client secret for: $client_id"
    
    # Get current client configuration
    debug "Fetching current client configuration"
    local temp_client=$(mktemp)
    local http_code
    
    http_code=$(curl $CURL_OPTS -s \
        -w "%{http_code}" \
        -o "$temp_client" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        "$UAA_URL/oauth/clients/$client_id")
    
    if [ "$http_code" != "200" ]; then
        local error_msg=$(cat "$temp_client" 2>/dev/null || echo "Unknown error")
        rm -f "$temp_client"
        error "Failed to get current client info (HTTP $http_code): $error_msg"
    fi
    
    # Update client with new secret
    debug "Updating client configuration with new secret"
    local updated_client
    if ! updated_client=$(cat "$temp_client" | jq --arg secret "$new_secret" '.client_secret = $secret'); then
        rm -f "$temp_client"
        error "Failed to update client configuration JSON"
    fi
    
    # Apply the update
    local temp_update=$(mktemp)
    http_code=$(curl $CURL_OPTS -s \
        -w "%{http_code}" \
        -o "$temp_update" \
        -X PUT "$UAA_URL/oauth/clients/$client_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$updated_client")
    
    if [ "$http_code" != "200" ]; then
        local error_msg=$(cat "$temp_update" 2>/dev/null || echo "Unknown error")
        rm -f "$temp_client" "$temp_update"
        error "Failed to update UAA client secret (HTTP $http_code): $error_msg"
    fi
    
    rm -f "$temp_client" "$temp_update"
    log "✓ Successfully updated UAA client secret for: $client_id"
}

# Update CredHub secret with better error handling
update_credhub_secret() {
    local credhub_path=$1
    local new_secret=$2
    
    log "Updating CredHub secret at: $credhub_path"
    
    # Get CredHub token
    local credhub_token
    credhub_token=$(get_uaa_token "$CREDHUB_CLIENT" "$CREDHUB_SECRET" "CredHub")
    
    # Update the secret
    local temp_credhub=$(mktemp)
    local http_code
    
    http_code=$(curl $CURL_OPTS -s \
        -w "%{http_code}" \
        -o "$temp_credhub" \
        -X PUT "$CREDHUB_URL/v1/data" \
        -H "Authorization: Bearer $credhub_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$credhub_path\",
            \"type\": \"password\",
            \"value\": \"$new_secret\"
        }")
    
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        local error_msg=$(cat "$temp_credhub" 2>/dev/null || echo "Unknown error")
        rm -f "$temp_credhub"
        error "Failed to update CredHub secret (HTTP $http_code): $error_msg"
    fi
    
    rm -f "$temp_credhub"
    log "✓ Successfully updated CredHub secret at: $credhub_path"
}

# Main rotation function
rotate_credentials() {
    log "Starting credential rotation for client: $TARGET_CLIENT"
    log "CredHub path: $CREDHUB_PATH"
    
    # Test connectivity first
    test_connectivity "$UAA_URL" "UAA"
    if [ "$UAA_URL" != "$CREDHUB_URL" ]; then
        test_connectivity "$CREDHUB_URL" "CredHub"
    fi
    
    # Generate new secret
    local new_secret
    new_secret=$(generate_secret)
    log "Generated new secret"
    
    # Get admin token with enhanced debugging
    log "Authenticating with UAA admin client"
    local admin_token
    admin_token=$(get_uaa_token "$CLIENT_ID" "$CLIENT_SECRET" "UAA Admin")
    
    # Update UAA client secret
    update_uaa_client_secret "$admin_token" "$TARGET_CLIENT" "$new_secret"
    
    # Update CredHub secret
    update_credhub_secret "$CREDHUB_PATH" "$new_secret"
    
    log "Credential rotation completed successfully!"
    
    # Test the new credentials
    log "Testing new credentials..."
    local test_token
    if test_token=$(get_uaa_token "$TARGET_CLIENT" "$new_secret" "Target Client"); then
        log "✅ New credentials verified successfully"
    else
        error "❌ New credentials verification failed"
    fi
}

# Main execution
main() {
    log "UAA Credential Rotation Script"
    log "=============================="
    log "Target Client: $TARGET_CLIENT"
    log "CredHub Path: $CREDHUB_PATH"
    log "UAA URL: $UAA_URL"
    log "CredHub URL: $CREDHUB_URL"
    
    # Debug environment
    debug "TLS Verification: $([ "$SKIP_TLS_VERIFY" = "true" ] && echo "DISABLED" || echo "ENABLED")"
    debug "Curl Options: $CURL_OPTS"
    
    # Validate required environment variables
    [ -z "$CLIENT_SECRET" ] && error "CLIENT_SECRET environment variable is required"
    [ -z "$CREDHUB_SECRET" ] && error "CREDHUB_SECRET environment variable is required"
    
    # Perform rotation
    rotate_credentials
}

# Execute main function
main "$@"