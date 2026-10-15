set -eu
umask 077
stage='checking prerequisites'
trap 'status=$?; if [ "$status" -ne 0 ]; then printf "proxy startup failed: stage=%s exit=%s\n" "$stage" "$status" >&2; fi; exit "$status"' EXIT
printf '%s\n' 'proxy startup: checking prerequisites' >&2
for tool in base64 tr envsubst nginx grep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'proxy startup: required command missing: %s\n' "$tool" >&2
    exit 1
  fi
done
if [ -z "${NEXUS_USERNAME:-}" ]; then
  printf '%s\n' 'proxy startup: Missing Nexus username' >&2
  exit 1
fi
if [ -z "${NEXUS_PASSWORD:-}" ]; then
  printf '%s\n' 'proxy startup: Missing Nexus password' >&2
  exit 1
fi
case "$NEXUS_USERNAME" in
  *:*) printf '%s\n' 'Nexus username must not contain a colon' >&2; exit 1 ;;
esac
NEXUS_AUTH=$(printf '%s:%s' "$NEXUS_USERNAME" "$NEXUS_PASSWORD" | base64 | tr -d '\n')
export NEXUS_AUTH
stage='rendering configuration'
printf '%s\n' 'proxy startup: rendering configuration' >&2
# Substitute only the credential, preserving NGINX variables such as $proxy_host.
envsubst '${NEXUS_AUTH}' < /config/nginx.conf.template > /tmp/nginx.conf
unset NEXUS_AUTH NEXUS_USERNAME NEXUS_PASSWORD
stage='checking CA bundle'
ca_file=${NEXUS_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}
printf 'proxy startup: checking CA bundle: %s\n' "$ca_file" >&2
if [ ! -r "$ca_file" ] || [ ! -s "$ca_file" ]; then
  printf 'proxy startup: CA bundle is missing, unreadable or empty: %s\n' "$ca_file" >&2
  exit 1
fi
if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$ca_file"; then
  printf 'proxy startup: CA bundle does not contain a PEM certificate: %s\n' "$ca_file" >&2
  exit 1
fi
stage='validating nginx configuration'
printf '%s\n' 'proxy startup: validating nginx configuration' >&2
nginx -t -e stderr -c /tmp/nginx.conf
stage='starting nginx'
printf '%s\n' 'proxy startup: starting nginx' >&2
exec nginx -e stderr -c /tmp/nginx.conf -g 'daemon off;'
