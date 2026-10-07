set -eu
umask 077
: "${NEXUS_USERNAME:?Missing Nexus username}"
: "${NEXUS_PASSWORD:?Missing Nexus password}"
case "$NEXUS_USERNAME" in
  *:*) printf '%s\n' 'Nexus username must not contain a colon' >&2; exit 1 ;;
esac
NEXUS_AUTH=$(printf '%s:%s' "$NEXUS_USERNAME" "$NEXUS_PASSWORD" | base64 | tr -d '\n')
export NEXUS_AUTH
# Substitute only the credential, preserving NGINX variables such as $proxy_host.
envsubst '${NEXUS_AUTH}' < /config/nginx.conf.template > /tmp/nginx.conf
unset NEXUS_AUTH NEXUS_USERNAME NEXUS_PASSWORD
exec nginx -c /tmp/nginx.conf -g 'daemon off;'

