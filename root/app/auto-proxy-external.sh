#!/usr/bin/with-contenv bash
echo "**** Starting auto-proxy-external configuration script ****"

PROXY_CONFS_PATH="/config/nginx/proxy-confs"
PROXY_EXTERNAL_CONF_FILE="${PROXY_EXTERNAL_CONF_FILE:-/config/external_services.conf}"
PROXY_EXTERNAL_DEFAULT_DOMAIN="${PROXY_EXTERNAL_DEFAULT_DOMAIN:-}"

# Check if the configuration file exists
if [ ! -f "$PROXY_EXTERNAL_CONF_FILE" ]; then
    echo "**** Configuration file not found: $PROXY_EXTERNAL_CONF_FILE ****"
    exit 1
fi

# Install yq if not already installed
if ! command -v yq &> /dev/null; then
    echo "**** yq not found, installing... ****"
    apk add --no-cache yq
fi

# Get container hostname
HOSTNAME=$(cat /etc/hostname)

# Check hostname for domain
if [ -z "$PROXY_EXTERNAL_DEFAULT_DOMAIN" ]; then
    if [[ "$HOSTNAME" =~ ^[0-9]+$ ]]; then
        echo "**** Domain is not set. Please set PROXY_EXTERNAL_DEFAULT_DOMAIN or configure the container 'hostname' option. ****"
        exit 1
    fi
fi

# Read the configuration file and generate proxy-confs
yq e '.[]' "$PROXY_EXTERNAL_CONF_FILE" | while read -r config; do
    SERVICE=$(echo "$config" | yq e '.name' -)
    ADDRESS=$(echo "$config" | yq e '.address' -)

    # Check if name and address are set
    if [ -z "$SERVICE" ] || [ -z "$ADDRESS" ]; then
        echo "**** 'name' and 'address' are mandatory fields for external services ****"
        exit 1
    fi

    # Set default values for optional fields
    PROTO=$(echo "$config" | yq e '.proto // "http"' -)
    URL=$(echo "$config" | yq e '.url // empty' -)
    PORT=$(echo "$config" | yq e '.port // "80"' -)
    if [ -z "$URL" ]; then
        if [ -n "$PROXY_EXTERNAL_DEFAULT_DOMAIN" ]; then
            URL="${SERVICE}.${PROXY_EXTERNAL_DEFAULT_DOMAIN}"
        else
            URL="${SERVICE}.${HOSTNAME}"
        fi
    fi
    AUTH=$(echo "$config" | yq e '.auth // false' -)
    AUTH_BYPASS=$(echo "$config" | yq e '.auth_bypass // empty' -)
    CUSTOM_SERVER_DIRECTIVE=$(echo "$config" | yq e '.custom_server_directive // empty' -)
    CUSTOM_ROOT_LOCATION_DIRECTIVE=$(echo "$config" | yq e '.custom_root_location_directive // empty' -)
    CUSTOM_LOCATION_BLOCKS=$(echo "$config" | yq e '.custom_location_blocks // empty' -)

    # Set path for proxy config files
    PROXY_CONF="${PROXY_CONFS_PATH}/auto-proxy-${SERVICE}.subdomain.conf"

    echo "**** Generating proxy conf for external service: ${SERVICE} ****"

    # Create proxy config file
    cat <<EOF > "${PROXY_CONF}"
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${URL};

    include /config/nginx/ssl.conf;

    client_max_body_size 0;

    $(if [ -n "$CUSTOM_SERVER_DIRECTIVE" ]; then echo "$CUSTOM_SERVER_DIRECTIVE"; fi)

    $(if [ -n "$AUTH" ]; then echo "include /config/nginx/${AUTH}-server.conf;"; fi)

    location / {
        $(if [ -n "$AUTH" ]; then echo "include /config/nginx/${AUTH}-location.conf;"; fi)
        $(if [ -n "$CUSTOM_ROOT_LOCATION_DIRECTIVE" ]; then echo "$CUSTOM_ROOT_LOCATION_DIRECTIVE"; else echo "include /config/nginx/proxy.conf; include /config/nginx/resolver.conf; set \$upstream_app $address; set \$upstream_port $port; set \$upstream_proto $proto; proxy_pass \$upstream_proto://\$upstream_app:\$upstream_port;"; fi)
    }

    $(if [ -n "$AUTH_BYPASS" ]; then
        IFS=',' read -ra ADDR <<< "$AUTH_BYPASS"
        for path in "\${ADDR[@]}"; do
            echo "location \${path} {"
            echo "    include /config/nginx/proxy.conf;"
            echo "    include /config/nginx/resolver.conf;"
            echo "    set \$upstream_app ${ADDRESS};"
            echo "    set \$upstream_port ${PORT};"
            echo "    set \$upstream_proto ${PROTO};"
            echo "    proxy_pass \$upstream_proto://\$upstream_app:\$upstream_port;"
            echo "}"
done
    fi)

    $(if [ -n "$CUSTOM_LOCATION_BLOCKS" ]; then
        echo "$CUSTOM_LOCATION_BLOCKS" | yq e '.[]' - | while read -r block; do
            path=$(echo "$block" | yq e '.path' -)
            block_auth=$(echo "$block" | yq e '.auth' -)
            directive=$(echo "$block" | yq e '.custom_definition' -)
            echo "location $path {"
            $(if [ "$block_auth" = "true" ]; then echo "include /config/nginx/authelia-location.conf;"; fi)
            $(if [ -n "$directive" ]; then echo "$directive"; else echo "include /config/nginx/proxy.conf; include /config/nginx/resolver.conf; set \$upstream_app $address; set \$upstream_port $port; set \$upstream_proto $proto; proxy_pass \$upstream_proto://\$upstream_app:\$upstream_port;"; fi)
            echo "}"
        done
    fi)
}
EOF
done

# Remove config files that are not in the config file
for file in ${PROXY_CONFS_PATH}/auto-proxy-*.subdomain.conf; do
    SERVICE=$(basename "${file}" | sed 's/auto-proxy-\(.*\)\.subdomain\.conf/\1/')
    if ! yq e ".[] | select(.name == \"${SERVICE}\")" "$PROXY_EXTERNAL_CONF_FILE" > /dev/null; then
        rm -f "${file}"
        echo "**** Removed outdated config for external service ${SERVICE} ****"
    fi
done

# Maybe not necessary because files in /config/nginx/proxy-confs are already tracked by SWAG
# Restart nginx to apply changes
#if /usr/sbin/nginx -c /config/nginx/nginx.conf -t; then
#    echo "**** Changes to nginx config are valid, reloading nginx ****"
#    /usr/sbin/nginx -c /config/nginx/nginx.conf -s reload
#else
#echo "**** Changes to nginx config are not valid, skipping nginx reload. Please double check ${PROXY_EXTERNAL_CONF_FILE} for errors. ****"
#fi

echo "**** Auto-proxy-external configuration script completed ****"