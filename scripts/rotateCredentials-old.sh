#!/bin/bash
set -euo pipefail


UAA_URL="${UAA_URL:-https://uaa.sys.example.com}"
CLIENT_ID="${CLIENT_ID:-admin}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
TARGET_CLIENT="${TARGET_CLIENT:-concourse_client}"
CREDHUB_URL="${CREDHUB_URL:-https://credhub.sys.example.com}"
CREDHUB_CLIENT="${CREDHUB_CLIENT:-credhub_admin_client}"
CREDHUB_SECRET="${CREDHUB_SECRET:-}"

# Colors because why not. Colors make everything better.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

get_uaa_token() {
    local client_id=$1
    local client_secret=$2
    
    log "Getting UAA token for client: $client_id"
    
    local response
    response=$(curl -s -X POST "$UAA_URL/oauth/token" \
        -H "Accept: application/json" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "$client_id:$client_secret" \
        -d "grant_type=client_credentials") || error "Failed to get UAA token"
    
    echo "$response" | jq -r '.access_token' || error "Failed to parse UAA token"
}

generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

update_uaa_client_secret() {
    local token=$1
    local client_id=$2
    local new_secret=$3
    
    log "Updating UAA client secret for: $client_id"
    
    local current_client
    current_client=$(curl -s -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        "$UAA_URL/oauth/clients/$client_id") || error "Failed to get current client info"

    local updated_client
    updated_client=$(echo "$current_client" | jq --arg secret "$new_secret" '.client_secret = $secret')
    
    curl -s -X PUT "$UAA_URL/oauth/clients/$client_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$updated_client" > /dev/null || error "Failed to update UAA client secret"
    
    log "Successfully updated UAA client secret for: $client_id"
}

update_credhub_secret() {
    local credhub_path=$1
    local new_secret=$2
    
    log "Updating CredHub secret at: $credhub_path"
    
    local credhub_token
    credhub_token=$(get_uaa_token "$CREDHUB_CLIENT" "$CREDHUB_SECRET")
    
    
    curl -s -X PUT "$CREDHUB_URL/v1/data" \
        -H "Authorization: Bearer $credhub_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$credhub_path\",
            \"type\": \"password\",
            \"value\": \"$new_secret\"
        }" > /dev/null || error "Failed to update CredHub secret"
    
    log "Successfully updated CredHub secret at: $credhub_path"
}


rotate_credentials() {
    local target_client=${1:-$TARGET_CLIENT}
    local credhub_path=${2:-"/concourse/main/uaa_client_secret"}
    
    log "Starting credential rotation for client: $target_client"
    

    local new_secret
    new_secret=$(generate_secret)
    log "Generated new secret"
    

    local admin_token
    admin_token=$(get_uaa_token "$CLIENT_ID" "$CLIENT_SECRET")
    

    update_uaa_client_secret "$admin_token" "$target_client" "$new_secret"
    

    update_credhub_secret "$credhub_path" "$new_secret"
    
    log "Credential rotation completed successfully!"
    

    log "Testing new credentials..."
    local test_token
    test_token=$(get_uaa_token "$target_client" "$new_secret")
    
    if [ -n "$test_token" ]; then
        log "✓ New credentials verified successfully"
    else
        error "✗ New credentials verification failed"
    fi
}


main() {
    log "UAA Credential Rotation Script"
    log "=============================="
    

    [ -z "$CLIENT_SECRET" ] && error "CLIENT_SECRET environment variable is required"
    [ -z "$CREDHUB_SECRET" ] && error "CREDHUB_SECRET environment variable is required"
    

    local target_client="${1:-$TARGET_CLIENT}"
    local credhub_path="${2:-/concourse/main/uaa_client_secret}"
    
    log "Target Client: $target_client"
    log "CredHub Path: $credhub_path"
    log "UAA URL: $UAA_URL"
    log "CredHub URL: $CREDHUB_URL"
    
    rotate_credentials "$target_client" "$credhub_path"
}


main "$@"