#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null
command -v ruby >/dev/null
docker info >/dev/null
work=$(mktemp -d)
network="nexus-proxy-test-$$"
proxy="$network-proxy"
nexus="$network-nexus"
cleanup() {
  docker rm -f "$proxy" "$nexus" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

helm template nexus-jar-proxy charts/nexus-jar-proxy \
  --set-string "nexus.url=${SMOKE_NEXUS_ROOT_URL:-http://nexus:8081}" \
  --set-string "proxy.rootUrl=${SMOKE_PROXY_ROOT_URL:-http://nexus-jar-proxy}" > "$work/rendered.yaml"
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0]))
  config = docs.find { |d| d["kind"] == "ConfigMap" }
  deployment = docs.find { |d| d["kind"] == "Deployment" }
  File.write(ARGV[1], config.fetch("data").fetch("nginx.conf.template"))
  File.write(ARGV[2], deployment.fetch("spec").fetch("template").fetch("spec").fetch("containers")[0].fetch("args")[0])
' "$work/rendered.yaml" "$work/nginx.conf.template" "$work/start.sh"
# mktemp defaults to 0700; the non-root container needs read access to these dummy fixtures.
chmod 755 "$work"
chmod 644 "$work/nginx.conf.template" "$work/start.sh"

docker network create "$network" >/dev/null
target_path=$(ruby -ruri -e 'puts URI(ARGV[0]).path' "${SMOKE_NEXUS_ROOT_URL:-http://nexus:8081}")
docker run -d --name "$nexus" --network "$network" --network-alias nexus \
  -e "MOCK_ROOT_PATH=$target_path" \
  -v "$PWD/tests/mock-nexus.mjs:/mock-nexus.mjs:ro" \
  node:22-alpine node /mock-nexus.mjs >/dev/null
image=$(ruby -ryaml -e 'd = YAML.load_stream(File.read(ARGV[0])).find { |x| x["kind"] == "Deployment" }; puts d["spec"]["template"]["spec"]["containers"][0]["image"]' "$work/rendered.yaml")
docker run -d --name "$proxy" --network "$network" \
  --read-only --user 101:101 --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,uid=101,gid=101,mode=0700,size=64m \
  -p 127.0.0.1::8080 \
  -v "$work/nginx.conf.template:/config/nginx.conf.template:ro" \
  -v "$work/start.sh:/start.sh:ro" \
  -e NEXUS_USERNAME=reader -e 'NEXUS_PASSWORD=p:a$$word' \
  --entrypoint /bin/sh "$image" /start.sh >/dev/null
port=$(docker port "$proxy" 8080/tcp)
base="http://$port"
ready=false
for attempt in {1..30}; do
  if curl --fail --silent "$base/healthz" >/dev/null; then ready=true; break; fi
  sleep 1
done
if [ "$ready" != true ]; then docker logs "$proxy"; exit 1; fi
proxy_path=$(ruby -ruri -e 'puts URI(ARGV[0]).path.sub(%r{/$}, "")' "${SMOKE_PROXY_ROOT_URL:-http://nexus-jar-proxy}")
if [ -n "$proxy_path" ]; then
  test "$(curl --silent --show-error -o /dev/null -w '%{http_code}' "$base/outside-root")" = 404
fi
base="$base$proxy_path"

url="$base/repository/maven-public/driver.jar?download=1"
curl --fail --silent --show-error "$url" \
  -H 'Authorization: Basic wrong' -H 'Cookie: client=secret' -H 'X-Client-Secret: hidden' \
  -o "$work/driver.jar"
ruby -e 'abort "Binary download mismatch" unless File.binread(ARGV[0]) == ["504b030400ff0a0d804a4152"].pack("H*")' "$work/driver.jar"
for jar in jar1 jar2; do
  curl --fail --silent --show-error "$base/driver/$jar?download=1" \
    -H 'Authorization: Basic wrong' -o "$work/$jar"
  for method in POST PUT DELETE PATCH; do
    test "$(curl --silent --show-error -X "$method" -o /dev/null -w '%{http_code}' "$base/driver/$jar?download=1")" = 403
  done
done
ruby -e '
  expected = ["504b030400ff0a0d804a4152"].pack("H*")
  abort "jar1 mismatch" unless File.binread(ARGV[0]) == expected
  abort "jar2 mismatch" unless File.binread(ARGV[1]) == expected + "jar2"
' "$work/jar1" "$work/jar2"
curl --fail --silent --show-error "$base/irgendwas/nested/jar1?download=1" -o "$work/arbitrary.jar"
cmp "$work/driver.jar" "$work/arbitrary.jar"
curl --fail --silent --show-error --head "$url" > "$work/head"
rg -qi '^Content-Length: 12' "$work/head"
status=$(curl --silent --show-error -H 'Range: bytes=0-3' -o "$work/range" -w '%{http_code}' "$url")
test "$status" = 206
ruby -e 'abort "Range mismatch" unless File.binread(ARGV[0]) == ["504b0304"].pack("H*")' "$work/range"
test "$(curl --silent --show-error -H 'If-None-Match: "driver-v1"' -o /dev/null -w '%{http_code}' "$url")" = 304
for method in POST PUT DELETE PATCH; do
  test "$(curl --silent --show-error -X "$method" -o /dev/null -w '%{http_code}' "$url")" = 403
done
for code in 'missing:404' 'forbidden:403'; do
  path=${code%:*}
  expected=${code#*:}
  test "$(curl --silent --show-error -o /dev/null -w '%{http_code}' "$base/repository/maven-public/$path.jar")" = "$expected"
done
test "$(curl --silent --show-error -o /dev/null -w '%{http_code}' "$base/admin")" = 418
curl --fail --silent --show-error --location "$base/repository/maven-public/redirect.jar" -o "$work/redirect.jar"
cmp "$work/driver.jar" "$work/redirect.jar"
printf '%s\n' 'Smoke test passed: Basic Auth, arbitrary paths under root URLs, binary GET, HEAD, Range, conditional GET, errors, redirects and blocked writes.'
