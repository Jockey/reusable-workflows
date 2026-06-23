#!/bin/bash

# Handles deploying and deleting App Service Slots,
# as needed by Jockey.
#
# REQUIRED ENV VARS
#   APP_NAME                    - App Service Name
#   APP_RESOURCE_GROUP          - App Service Resource Group
#   SLOT_NAME                   - Slot Name to deploy to
#   CUSTOM_URL_SUFFIX           - Appended to the $SLOT_NAME for generating the custom URL
#   IMAGE_NAME                  - Docker image name. Format MUST be `*.azurecr.io/*``
#   AZURE_SERVICE_PRINCIPAL     - Azure Service Principal Data, JSON string
#   SSL_CERT_THUMBPRINT         - SSL Certificate Thumbprint. See output of
#                                 `az webapp config ssl list --resource-group $APP_RESOURCE_GROUP`
#                                 and look for the Certificate for `*.$CUSTOM_URL_SUFFIX`
#   CLOUDFLARE_API_TOKEN        - Cloudflare API token, with `DNS:Read, DNS:Edit` permissions
#   CLOUDFLARE_ZONE_ID          - Cloudflare Zone ID to manage
#
# DEPENDENCIES
#   az, curl, jq

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

die() {
    printf "\e[31mERROR:\e[0m %s\n" "$*" >&2
    exit 1
}

info() {
    printf "\e[36m▶\e[0m %s\n" "$*"
}

print_line() {
    printf "\e[36m-----\e[0m\n"
}

error() {
    printf "\e[31mERROR:\e[0m %s\n" "$*" >&2
}

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
}

azure_login() {
    info "Logging in to Azure..."
    [[ -z "${AZURE_SERVICE_PRINCIPAL:-}" ]] && die "AZURE_SERVICE_PRINCIPAL is not set."
    az login --service-principal \
        --username="$(printf "%s" "$AZURE_SERVICE_PRINCIPAL" | jq -r '.clientId')" \
        --password="$(printf "%s" "$AZURE_SERVICE_PRINCIPAL" | jq -r '.clientSecret')" \
        --tenant="$(printf "%s" "$AZURE_SERVICE_PRINCIPAL" | jq -r '.tenantId')" \
        --output none
}

# Upsert a Cloudflare DNS record. Handles create-or-update logic.
# Usage: cf_upsert_dns <zone-id> <type> <name> <content> <proxied>
cf_upsert_dns() {
    local zone_id="$1" type="$2" name="$3" content="$4" proxied="$5"

    # Fetch existing record payload to check for presence and handle potential API failure
    local get_response
    get_response=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${name}&type=${type}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")

    # Ensure the lookup itself didn't fail
    if [[ "$(echo "$get_response" | jq -r '.success // false')" != "true" ]]; then
        error "Failed to query existing DNS records for '$name'."
        error "Details: $(echo "$get_response" | jq -c '.errors // empty')"
        return 1
    fi

    local existing_id
    existing_id=$(echo "$get_response" | jq -r '.result[0].id // empty')

    local response
    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        info "DNS $type '$name' exists (ID: $existing_id). Updating..."
        response=$(curl -s -X PATCH \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${existing_id}" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"content\":\"${content}\",\"proxied\":${proxied}}")
    else
        info "DNS $type '$name' not found. Creating..."
        response=$(curl -s -X POST \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"${type}\",\"name\":\"${name}\",\"content\":\"${content}\",\"ttl\":1,\"proxied\":${proxied}}")
    fi

    # Evaluate execution status of the mutation step
    if [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]; then
        info "Success: DNS $type '$name' upserted successfully."
    else
        error "Failed to upsert DNS $type '$name'."
        error "Details: $(echo "$response" | jq -c '.errors // empty')"
        return 1
    fi
}

# Delete a Cloudflare DNS record by name+type if it exists.
# Usage: cf_delete_dns <zone-id> <name> [type]
cf_delete_dns() {
    local zone_id="$1" name="$2" type="${3:-}"

    local query="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${name}"
    [[ -n "$type" ]] && query+="&type=${type}"

    local record_id
    record_id=$(curl -s -X GET "$query" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    # Capture response and suppress HTTP transport errors from showing directly
    response=$(curl -s -X DELETE \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")

    # Validate JSON structure and extract the success boolean
    success=$(echo "$response" | jq -r '.success // false')

    if [[ "$success" == "true" ]]; then
        info "Success: DNS record '$name' deleted."
    else
        # Extract errors array or default to raw response if parsing fails
        errors=$(echo "$response" | jq -c '.errors // empty')
        error "Failed to delete DNS record '$name'."
        error "Details: ${errors:-$response}"
    fi
}

# Purges the Cache for an entire hostname
# Usage: cf_cache_purge <zone-id> <hostname>
cf_cache_purge() {
    local zone_id="$1" host_name="$2"

    info "Purging CF Cache for '$host_name' ..."
    response=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/zones/$zone_id/purge_cache" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"hosts\": [\"$host_name\"]}")

    # Evaluate execution status of the mutation step
    if [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]; then
        info "Success: Purged CF Cache"
    else
        error "Failed to Purge Cache"
        error "Details: $(echo "$response" | jq -c '.errors // empty')"
        return 1
    fi
}

# ── sub-commands ──────────────────────────────────────────────────────────────

cmd_deploy() {
    # Derived — computed once, used throughout
    local use_custom_dns=false
    local custom_hostname=""
    if [[ -n "$CUSTOM_URL_SUFFIX" && -n "$CLOUDFLARE_ZONE_ID" ]]; then
        use_custom_dns=true
        custom_hostname="${SLOT_NAME}${CUSTOM_URL_SUFFIX}"
    fi

    require_cmd az curl jq azure_login
    azure_login

    # ── Create slot (syncs config from parent app) ──────────────────────────────
    info "Upserting App Service: '$APP_NAME' | Slot: '$SLOT_NAME'"
    az webapp deployment slot create \
        --resource-group "$APP_RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --slot "$SLOT_NAME" \
        --configuration-source "$APP_NAME" \
        --output none #Default is "json"

    info "Deploying image '$IMAGE_NAME'"
    # Configures the image source to be "Azure Container",
    # and tells the App Service Slot to use "Admin Credentials"
    # which gets sorted out by Azure, it doesn't use the Service Principal or anything.
    az webapp config set \
        --resource-group "$APP_RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --slot "$SLOT_NAME" \
        --linux-fx-version "DOCKER|$IMAGE_NAME" \
        --generic-configurations '{"acrUseManagedIdentityCreds": false, "acrUserManagedIdentityID": ""}' \
        --output none

    # Enable continuous deployment so any future pushes get handled "gracefully"
    az webapp deployment container config \
        --resource-group "$APP_RESOURCE_GROUP" \
        --name "$APP_NAME" \
        --slot "$SLOT_NAME" \
        --enable-cd true \
        --output none

    print_line

    if $use_custom_dns; then
        [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && die "CLOUDFLARE_API_TOKEN is not set."

        # Check if the hostname is already bound to this specific slot
        info "Checking if custom domain '$custom_hostname' is already configured..."
        local dns_already_configured
        dns_already_configured=$(az webapp config hostname list \
            --webapp-name "$APP_NAME" \
            --resource-group "$APP_RESOURCE_GROUP" \
            --slot "$SLOT_NAME" \
            --query "[?name=='${custom_hostname}'].name | [0]" \
            -o tsv)

        if [[ "$dns_already_configured" == "$custom_hostname" ]]; then
            info "Custom domain '$custom_hostname' is already bound to slot."
            info "Skipping SSL/DNS configuration."

            sleep 5 # Wait 5s to let the deploy spin up
            cf_cache_purge "$CLOUDFLARE_ZONE_ID" "$custom_hostname"
        else
            info "Custom domain not configured. Will set up DNS and SSL..."
            local azure_target="${APP_NAME}-${SLOT_NAME}.azurewebsites.net"

            # ── TXT verification record (unproxied) ──────────────────────────────────
            local verify_id
            verify_id=$(az webapp show \
                --name "$APP_NAME" \
                --resource-group "$APP_RESOURCE_GROUP" \
                --query "customDomainVerificationId" \
                -o tsv)

            info "Upserting domain verification TXT record for 'asuid.${custom_hostname}'..."
            cf_upsert_dns "$CLOUDFLARE_ZONE_ID" TXT "asuid.${custom_hostname}" "$verify_id" false

            # ── CNAME unproxied — required for Azure SSL certificate issuance ─────────
            info "Upserting unproxied CNAME for '$custom_hostname'\n\t→ '$azure_target'..."
            cf_upsert_dns "$CLOUDFLARE_ZONE_ID" CNAME "$custom_hostname" "$azure_target" false

            info "Sleeping for 10s to let DNS propagate..."
            sleep 10

            # ── Bind hostname + issue managed SSL ────────────────────────────────────
            info "Configuring custom domain: '$custom_hostname'..."
            az webapp config hostname add \
                --webapp-name "$APP_NAME" \
                --resource-group "$APP_RESOURCE_GROUP" \
                --slot "$SLOT_NAME" \
                --hostname "$custom_hostname" \
                --output none

            info "Binding SSL certificate (SNI)..."
            az webapp config ssl bind \
                --name "$APP_NAME" \
                --resource-group "$APP_RESOURCE_GROUP" \
                --slot "$SLOT_NAME" \
                --certificate-thumbprint "$SSL_CERT_THUMBPRINT" \
                --ssl-type SNI \
                --output none

            # ── Re-enable Cloudflare proxy now that SSL is bound ─────────────────────
            info "Enabling Cloudflare proxy on '$custom_hostname'..."
            cf_upsert_dns "$CLOUDFLARE_ZONE_ID" CNAME "$custom_hostname" "$azure_target" true
        fi
    fi

    print_line

    # ── Output deployment URL ──────────────────────────────────────────────────
    local deployment_url
    if $use_custom_dns; then
        deployment_url="https://${custom_hostname}"
    else
        deployment_url="https://${APP_NAME}-${SLOT_NAME}.azurewebsites.net"
    fi

    info "Deployment complete."
    printf "deployment_url=%s\n" "${deployment_url}"

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        # Expose the value to the Github Action runner so it can be picked up
        # by caller workflows
        printf "deployment_url=%s\n" "${deployment_url}" >>"$GITHUB_OUTPUT"
    fi
}

cmd_cleanup() {
    local use_custom_dns=false
    local custom_hostname=""
    if [[ -n "$CUSTOM_URL_SUFFIX" && -n "$CLOUDFLARE_ZONE_ID" ]]; then
        use_custom_dns=true
        custom_hostname="${SLOT_NAME}${CUSTOM_URL_SUFFIX}"
    fi

    require_cmd az curl jq
    azure_login

    # ── Delete the App Service slot ────────────────────────────────────────────
    info "Deleting App Service slot '$SLOT_NAME'..."
    az webapp deployment slot delete \
        --name "$APP_NAME" \
        --resource-group "$APP_RESOURCE_GROUP" \
        --slot "$SLOT_NAME"

    # ── Remove Cloudflare DNS records ─────────────────────────────────────────
    if $use_custom_dns; then
        [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && die "CLOUDFLARE_API_TOKEN is not set."

        cf_delete_dns "$CLOUDFLARE_ZONE_ID" "$custom_hostname" CNAME
        cf_delete_dns "$CLOUDFLARE_ZONE_ID" "asuid.${custom_hostname}" TXT
    fi

    info "Cleanup complete."
}

# ── entrypoint ────────────────────────────────────────────────────────────────

subcommand="${1:-}"
shift || true

case "$subcommand" in
deploy) cmd_deploy "$@" ;;
cleanup) cmd_cleanup "$@" ;;
*)
    printf "Usage:\n"
    printf "  %s deploy\n" "$0"
    printf "  %s cleanup\n" "$0"
    exit 1
    ;;
esac
