#!/usr/bin/with-contenv bash

# /config/external_services.conf.sample:
# - name: "service_name"
#   url: "service.domain.com"
#   proto: "http"
#   address: "10.10.10.10"
#   port: "8080"
#   auth: "authelia"
#   custom_directive: "include /config/nginx/geoblock.conf;"
#   auth_bypass: "/path1,/path2"
#- name: "service_name"
#  url: "service.domain.com"
#  proto: "http"
#  address: "

echo "**** Starting auto-proxy-external configuration script ****"

PROXY_CONFS_PATH="/config/nginx/proxy-confs"
EXTERNAL_SERVICES_CONF_FILE="${EXTERNAL_SERVICES_CONF_FILE:-/config/external_services.conf}"
EXTERNAL_SERVICES_DEFAULT_DOMAIN="${EXTERNAL_SERVICES_DEFAULT_DOMAIN:-}"

# Check if the configuration file exists
if [ ! -f "$EXTERNAL_SERVICES_CONF_FILE" ]; then
    echo "**** Configuration file not found: $EXTERNAL_SERVICES_CONF_FILE ****"
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
if [ -z "$EXTERNAL_SERVICES_DEFAULT_DOMAIN" ]; then
    if [[ "$HOSTNAME" =~ ^[0-9]+$ ]]; then
        echo "**** Domain is not set. Please set EXTERNAL_SERVICES_DEFAULT_DOMAIN or configure the container 'hostname' option. ****"
        exit 1
    fi
fi

# Read the configuration file and generate proxy-confs
yq e '.[]' "$EXTERNAL_SERVICES_CONF_FILE" | while read -r config; do
    SERVICE=$(echo "$config" | yq e '.name' -)
    ADDRESS=$(echo "$config" | yq e '.address' -)

    # Check if name and address are set
    if [ -z "$SERVICE" ] || [ -z "$ADDRESS" ]; then
        echo "**** 'name' and 'address' are mandatory fields for external services ****"
        exit 1
    fi

    # Set default values for URL, proto, and port if not explicitly set
    URL=$(echo "$config" | yq e '.url // empty' -)
    PROTO=$(echo "$config" | yq e '.proto // "http"' -)
    PORT=$(echo "$config" | yq e '.port // "80"' -)

    if [ -z "$URL" ]; then
        if [ -n "$EXTERNAL_SERVICES_DEFAULT_DOMAIN" ]; then
            URL="${SERVICE}.${EXTERNAL_SERVICES_DEFAULT_DOMAIN}"
        else
            URL="${SERVICE}.${HOSTNAME}"
        fi
    fi

    AUTH=$(echo "$config" | yq e '.auth // empty' -)
    CUSTOM_DIRECTIVE=$(echo "$config" | yq e '.custom_directive // empty' -)
    AUTH_BYPASS=$(echo "$config" | yq e '.auth_bypass // empty' -)

    PROXY_CONF="${PROXY_CONFS_PATH}/auto-proxy-${SERVICE}.subdomain.conf"

    echo "**** Generating proxy conf for external service: ${SERVICE} ****"

    # Generate proxy-conf for services
    cat <<EOF > "${PROXY_CONF}"
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${URL};

    include /config/nginx/ssl.conf;

    client_max_body_size 0;

    $(if [ -n "$CUSTOM_DIRECTIVE" ]; then echo "$CUSTOM_DIRECTIVE"; fi)

    $(if [ -n "$AUTH" ]; then echo "include /config/nginx/${AUTH}-server.conf;"; fi)

    location / {
        $(if [ -n "$AUTH" ]; then echo "include /config/nginx/${AUTH}-location.conf;"; fi)
        proxy_pass ${PROTO}://${ADDRESS}:${PORT};
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
    }

    $(if [ -n "$AUTH_BYPASS" ]; then
        IFS=',' read -ra ADDR <<< "$AUTH_BYPASS"
        for path in "\${ADDR[@]}"; do
            echo "location \${path} {"
            echo "    proxy_pass ${PROTO}://${ADDRESS}:${PORT};"
            echo "    include /config/nginx/proxy.conf;"
            echo "    include /config/nginx/resolver.conf;"
            echo "}"
        done
    fi)
}
EOF
done

# Remove config files that are not in the config file
for file in ${PROXY_CONFS_PATH}/auto-proxy-*.subdomain.conf; do
    SERVICE=$(basename "${file}" | sed 's/auto-proxy-\(.*\)\.subdomain\.conf/\1/')
    if ! yq e ".[] | select(.name == \"${SERVICE}\")" "$EXTERNAL_SERVICES_CONF_FILE" > /dev/null; then
        rm -f "${file}"
        echo "**** Removed outdated config for external service ${SERVICE} ****"
    fi
done

# Restart nginx to apply changes
if /usr/sbin/nginx -c /config/nginx/nginx.conf -t; then
    echo "**** Changes to nginx config are valid, reloading nginx ****"
    /usr/sbin/nginx -c /config/nginx/nginx.conf -s reload
else
    echo "**** Changes to nginx config are not valid, skipping nginx reload. Please double check ${EXTERNAL_SERVICES_CONF_FILE} for errors. ****"
fi

echo "**** auto-proxy-extended configuration script completed ****"