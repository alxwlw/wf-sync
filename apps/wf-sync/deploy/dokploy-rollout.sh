#!/usr/bin/env bash
# Deploys or updates Wealthfolio + wf-sync as a compose app of the Dokploy on this host. Safe to re-run.
# Usage, from apps/wf-sync/deploy: dokploy-rollout.sh --check | --apply
#   --check  reads only: what --apply would change in Dokploy (compose diff, config.yaml diff, env names
#            new/changed/same/removed), whether the 1Password items are readable, and whether the tailnet name is
#            free. Writes nothing, deploys nothing.
#   --apply  writes compose, env and config.yaml to Dokploy, deploys (containers whose config changed are
#            recreated), waits for Wealthfolio on its tailnet node, https://$TS_NODE.<tailnet>.ts.net, the only way
#            in (no port on the host), and for a finished sync pass.
# The env comes from 1Password (op-init.sh creates the item), config.yaml from WF_SYNC_CONFIG_FILE: it holds no
# secrets, only ${NAME} references to that env.
# TS_AUTHKEY is a single-use, pre-approved, tag:apps auth key that expires in an hour. It is minted through the
# Tailscale API with the OAuth client from 1Password (TS_KEY_REF), only while the tailnet has no $TS_NODE node;
# otherwise the stored key is kept, so the sidecar isn't recreated. The OAuth secret itself never leaves this
# script: containerboot hands TS_AUTHKEY to `tailscale up --authkey=…`, whose argv any local user can read in
# /proc, and the env also lands in Dokploy's .env (0644) and in `docker inspect`. The sidecar needs the key only
# while its state volume holds no node (TS_AUTH_ONCE). Lost state with the old device still in the tailnet: delete
# the device in the admin console, then run --apply again.
# Secrets reach neither argv nor the screen: values stay in shell variables and go to other programs on
# stdin; the API key goes through a mode-600 curl config removed on exit.
set -euo pipefail

OP_ITEM=${WF_OP_ITEM:-op://env-devsrvr/wf-sync}
TS_KEY_REF=${TS_KEY_REF:-op://env-devsrvr/tailscale-apps/oauth-client-secret}
TS_API=https://api.tailscale.com
TS_TAG=tag:apps
CONFIG_FILE=${WF_SYNC_CONFIG_FILE:-$HOME/.config/wf-sync/config.yaml}
COMPOSE_FILE=docker-compose.dokploy.yml
DOKPLOY_URL=${DOKPLOY_URL:-http://127.0.0.1:3000}
TIME_ZONE=${WF_TZ:-Europe/Kyiv}
PROJECT=wf-sync
APP=wealthfolio
# TS_HOSTNAME of the compose's tailscale service.
TS_NODE=wealthfolio
# Added to the 1Password item as each connector is switched on; absent ones are skipped.
CONNECTOR_VARS=(
	BINANCE_API_KEY BINANCE_SECRET
	OKX_API_KEY OKX_SECRET OKX_PASSPHRASE
	KRAKEN_API_KEY KRAKEN_SECRET
	WHITEBIT_API_KEY WHITEBIT_SECRET
	BYBIT_API_KEY BYBIT_SECRET
	GATE_API_KEY GATE_SECRET
	HTX_API_KEY HTX_SECRET
	ZERION_API_KEY
	MONOBANK_TOKEN
)

die() {
	echo "rollout: $*" >&2
	exit 1
}

case ${1:-} in
--check) MODE=check ;;
--apply) MODE=apply ;;
*) die 'usage: dokploy-rollout.sh --check | --apply' ;;
esac

[ -f "$COMPOSE_FILE" ] || die "no $COMPOSE_FILE here: run from apps/wf-sync/deploy"
[ -f "$CONFIG_FILE" ] || die "no config at $CONFIG_FILE"

required_field() {
	local value
	value=$(op read "$OP_ITEM/$1" 2>/dev/null) && [ -n "$value" ] || die "cannot read $OP_ITEM/$1 (op signed in? vault readable here? op-init.sh run?)"
	printf '%s' "$value"
}

echo '1Password: reading fields, nothing is printed'
wf_password=$(required_field WF_PASSWORD)
wf_secret_key=$(required_field WF_SECRET_KEY)
dokploy_key=$(required_field DOKPLOY_API_KEY)

[[ $dokploy_key =~ ^[A-Za-z0-9_.:-]+$ ]] || die 'the Dokploy API key has characters a curl config cannot carry safely'
CURL_CFG=$(mktemp)
TS_CFG=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$CURL_CFG" "$TS_CFG" "$BODY"' EXIT
printf 'header = "x-api-key: %s"\n' "$dokploy_key" >"$CURL_CFG"
unset dokploy_key

# Exchanges the OAuth client secret for an API token in $TS_CFG (mode 600, removed on exit). The secret goes to
# curl on stdin, never in argv. Its middle part is the client ID (tskey-client-<id>-<secret>).
ts_login() {
	local secret token
	echo '1Password: reading the Tailscale OAuth client secret, nothing is printed'
	secret=$(op read "$TS_KEY_REF" 2>/dev/null) && [ -n "$secret" ] ||
		die "cannot read $TS_KEY_REF: create it first (an OAuth client with Keys → Auth Keys → Write and $TS_TAG)"
	[[ $secret =~ ^tskey-client-([A-Za-z0-9]+)-[A-Za-z0-9]+$ ]] || die "$TS_KEY_REF is not an OAuth client secret (tskey-client-…)"
	token=$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' "${BASH_REMATCH[1]}" "$secret" |
		curl -sS -m 20 --fail-with-body -d @- "$TS_API/api/v2/oauth/token" | jq -r '.access_token // empty') ||
		die 'Tailscale refused the OAuth client (wrong secret, or a revoked client)'
	unset secret
	[[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die 'no usable access token from Tailscale'
	printf 'header = "Authorization: Bearer %s"\n' "$token" >"$TS_CFG"
}

# Prints a single-use, pre-approved, non-ephemeral $TS_TAG auth key that expires in an hour.
ts_mint() {
	local key
	key=$(jq -n --arg tag "$TS_TAG" --arg d "$TS_NODE rollout" \
		'{capabilities: {devices: {create: {reusable: false, ephemeral: false, preauthorized: true, tags: [$tag]}}},
		  expirySeconds: 3600, description: $d}' |
		curl -sS -m 20 --fail-with-body -K "$TS_CFG" -H 'Content-Type: application/json' -d @- \
			"$TS_API/api/v2/tailnet/-/keys" | jq -r '.key // empty') ||
		die "Tailscale refused to mint a $TS_TAG key: the OAuth client needs Keys → Auth Keys → Write with $TS_TAG"
	[[ $key =~ ^tskey-auth-[A-Za-z0-9-]+$ ]] || die 'Tailscale returned no auth key'
	printf '%s' "$key"
}

# The server's message is printed on failure, never the request.
check_status() {
	[[ $2 == 2* ]] && {
		cat "$BODY"
		return 0
	}
	die "Dokploy $1: HTTP $2 $(jq -r '.message // empty' "$BODY" 2>/dev/null | cut -c1-200)"
}
get() {
	check_status "$1" "$(curl -K "$CURL_CFG" -sS -o "$BODY" -w '%{http_code}' "$DOKPLOY_URL/api/$1")"
}
post() {
	check_status "$1" "$(curl -K "$CURL_CFG" -sS -o "$BODY" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- "$DOKPLOY_URL/api/$1")"
}

echo 'Tailnet: looking up the node'
ts_status=$(tailscale status --json)
suffix=$(jq -r '.MagicDNSSuffix' <<<"$ts_status")
origin="https://$TS_NODE.$suffix"
# A node that already holds the name makes the sidecar register as $TS_NODE-1.
node=$(jq -r --arg n "$TS_NODE.$suffix." '[.Peer[]? | select(.DNSName == $n)] | first // empty | "\(.ID) tags=\(.Tags // [] | join(",")) online=\(.Online)"' <<<"$ts_status")
if [ -n "$node" ]; then
	echo "  $TS_NODE.$suffix exists: $node"
else
	echo "  $TS_NODE.$suffix is free: the first start of the sidecar registers it"
fi

echo 'Dokploy: finding the app'
projects=$(get project.all)
compose_id=$(jq -r --arg p "$PROJECT" --arg a "$APP" \
	'[.[] | select(.name == $p) | .environments[]?.compose[]? | select(.name == $a) | .composeId] | first // empty' <<<"$projects")
if [ -z "$compose_id" ]; then
	[ "$MODE" = apply ] || die "no $PROJECT/$APP in Dokploy; --apply would create it"
	environment_id=$(jq -r --arg p "$PROJECT" '[.[] | select(.name == $p) | .environments[]?.environmentId] | first // empty' <<<"$projects")
	if [ -z "$environment_id" ]; then
		environment_id=$(jq -n --arg n "$PROJECT" '{name: $n, description: "Wealthfolio and wf-sync"}' | post project.create | jq -r '.environment.environmentId')
	fi
	compose_id=$(jq -n --arg n "$APP" --arg p "$PROJECT" --arg e "$environment_id" \
		'{name: $n, appName: $p, description: "Wealthfolio and wf-sync", environmentId: $e, composeType: "docker-compose", sourceType: "raw"}' |
		post compose.create | jq -r '.composeId')
	echo "  created $PROJECT/$APP"
fi
[ -n "$compose_id" ] && [ "$compose_id" != null ] || die 'no composeId from Dokploy'

echo 'Env: building'
current=$(get "compose.one?composeId=$compose_id")
stored_env=$(jq -j '.env // ""' <<<"$current")

# The value of $1 in the stored env, without the single quotes add_env wraps it in.
stored_value() {
	sed -n "s/^$1=//p" <<<"$stored_env" | tail -n 1 | sed "s/^'\(.*\)'\$/\1/"
}

# One dotenv line. Single quotes keep every character of the value literal. The status (new, changed, same) never
# prints a value.
env_block=""
add_env() {
	local state
	case $2 in
	*\'* | *$'\n'*) die "$1 contains a single quote or a newline, which the env block can't carry" ;;
	esac
	env_block+="$1='$2'"$'\n'
	if ! grep -q "^$1=" <<<"$stored_env"; then
		state=new
	# $(…) drops the newline sed ends with.
	elif [ "$(stored_value "$1")" = "$2" ]; then
		state=same
	else
		state=changed
	fi
	echo "  env $1 ($state)"
}

# A new salt on every run, so WF_AUTH_PASSWORD_HASH is `changed` every time and a rollout also recreates the
# wealthfolio container: seconds, and the sessions survive.
sync_image=$(awk '/ghcr.io\/alxwlw\/wf-sync/ { print $2; exit }' "$COMPOSE_FILE")
password_hash=$(printf '%s' "$wf_password" | docker run --rm -i --entrypoint bun "$sync_image" \
	-e 'console.log(await Bun.password.hash(await Bun.stdin.text(), { algorithm: "argon2id" }))' 2>/dev/null)
[[ $password_hash == \$argon2id\$* ]] || die 'hashing the password failed'
add_env WF_PASSWORD "$wf_password"
add_env WF_SECRET_KEY "$wf_secret_key"
add_env WF_AUTH_PASSWORD_HASH "$password_hash"
add_env WF_CORS_ALLOW_ORIGINS "$origin"
add_env TZ "$TIME_ZONE"
for name in "${CONNECTOR_VARS[@]}"; do
	value=$(op read "$OP_ITEM/$name" 2>/dev/null) || value=""
	[ -z "$value" ] || add_env "$name" "$value"
done
unset wf_password wf_secret_key password_hash value
# The sidecar's key: the stored one while the node exists (the sidecar ignores it then), a new one while it doesn't.
ts_authkey=$(stored_value TS_AUTHKEY)
if [ -n "$node" ] && [[ $ts_authkey =~ ^tskey-auth- ]]; then
	add_env TS_AUTHKEY "$ts_authkey"
else
	ts_login
	if [ "$MODE" = apply ]; then
		ts_authkey=$(ts_mint)
		add_env TS_AUTHKEY "$ts_authkey"
	else
		echo "  env TS_AUTHKEY (the OAuth client works; --apply mints a single-use $TS_TAG key)"
	fi
fi
# Names the stored env has and this run drops (TS_AUTHKEY is decided above).
while IFS= read -r name; do
	[ "$name" = TS_AUTHKEY ] || grep -q "^$name=" <<<"$env_block" || echo "  env $name (removed)"
done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' <<<"$stored_env")
unset ts_authkey stored_env

mount_id=$(jq -r '[(.mounts // [])[] | select(.type == "file" and .filePath == "config.yaml") | .mountId] | first // empty' <<<"$current")

if [ "$MODE" = check ]; then
	echo 'Compose: stored in Dokploy (-) vs this directory (+)'
	diff -u --label dokploy --label "$COMPOSE_FILE" <(jq -j '.composeFile // ""' <<<"$current") "$COMPOSE_FILE" || true
	echo
	echo 'config.yaml: stored in Dokploy (-) vs the config file (+)'
	diff -u --label dokploy --label "$CONFIG_FILE" \
		<(jq -j '[(.mounts // [])[] | select(.type == "file" and .filePath == "config.yaml") | .content] | first // ""' <<<"$current") "$CONFIG_FILE" || true
	echo
	echo 'Check done, nothing written. --apply writes the above and deploys: compose recreates the containers whose'
	echo 'config changed (the wealthfolio container, whose password hash always changes) and starts new services.'
	exit 0
fi
unset current

echo 'Dokploy: writing compose, env and config.yaml'
jq -Rs --arg id "$compose_id" '{composeId: $id, composeFile: ., sourceType: "raw", composeType: "docker-compose"}' "$COMPOSE_FILE" |
	post compose.update >/dev/null
printf '%s' "$env_block" | jq -Rs --arg id "$compose_id" '{composeId: $id, env: .}' | post compose.saveEnvironment >/dev/null
stored=$(get "compose.one?composeId=$compose_id")
# Compare digests, so that neither value lands in a variable that outlives this check.
[ "$(jq -j '.env // ""' <<<"$stored" | sha256sum)" = "$(printf '%s' "$env_block" | sha256sum)" ] || die 'the env stored in Dokploy differs from what was sent; not deploying'
unset env_block
app_name=$(jq -r '.appName' <<<"$stored")
last_deployment=$(jq -r '(.deployments // []) | sort_by(.createdAt) | last // empty | .deploymentId' <<<"$stored")
unset stored
if [ -z "$mount_id" ]; then
	jq -Rs --arg id "$compose_id" '{type: "file", filePath: "config.yaml", mountPath: "/app/config.yaml", content: ., serviceId: $id, serviceType: "compose"}' "$CONFIG_FILE" |
		post mounts.create >/dev/null
else
	jq -Rs --arg id "$mount_id" '{mountId: $id, content: .}' "$CONFIG_FILE" | post mounts.update >/dev/null
fi

echo "Dokploy: deploying $app_name"
jq -n --arg id "$compose_id" '{composeId: $id}' | post compose.deploy >/dev/null
# compose.deploy only queues the deploy: wait for a deployment newer than the one seen above.
status=""
for _ in $(seq 1 100); do
	sleep 3
	latest=$(get "compose.one?composeId=$compose_id" | jq -r '(.deployments // []) | sort_by(.createdAt) | last // empty | "\(.deploymentId) \(.status)"')
	[ -n "$latest" ] && [ "${latest%% *}" != "$last_deployment" ] || continue
	status=${latest#* }
	[ "$status" = "done" ] || [ "$status" = "error" ] && break
done
[ "$status" = "done" ] || die "deployment status '${status:-none}': see the app's deployment log in Dokploy"

# The first start registers the node and fetches its certificate before serve answers.
echo "Wealthfolio: waiting for $origin/api/v1/auth/status"
ui_up=""
for _ in $(seq 1 100); do
	curl -fsS -m 5 -o /dev/null "$origin/api/v1/auth/status" && {
		ui_up=1
		break
	}
	sleep 3
done
[ -n "$ui_up" ] || die "no answer on $origin/api/v1/auth/status after 5 minutes; see the logs of the wealthfolio and tailscale containers of $app_name"
node=$(tailscale status --json | jq -r --arg n "$TS_NODE.$suffix." '[.Peer[]? | select(.DNSName == $n)] | first // empty | "\(.ID) tags=\(.Tags // [] | join(","))"')
echo "  node $TS_NODE.$suffix: ${node:-not in tailscale status}"

# config.yaml is a single-file bind mount and is read once at startup, and a deploy that
# leaves the service unchanged doesn't recreate the container: only a restart applies it.
sync_container=$(docker ps -qf "label=com.docker.compose.project=$app_name" -f 'label=com.docker.compose.service=wf-sync')
[ -n "$sync_container" ] || die 'the wf-sync container is not running'
restarted=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker restart "$sync_container" >/dev/null

# A restart starts a pass by itself. Don't run `check` next to it: the two share the sources'
# rate limits and it fails on 429. A first Monobank import takes minutes, hence the long wait.
echo 'wf-sync: waiting for the first pass'
result=""
for _ in $(seq 1 120); do
	result=$(docker logs --since "$restarted" "$sync_container" 2>&1 | grep -F 'Done: ' | tail -1 || true)
	[ -n "$result" ] && break
	sleep 5
done
[ -n "$result" ] || die 'no finished pass after 10 minutes; see the logs of the wf-sync container'
echo "$result"
if docker logs --since "$restarted" "$sync_container" 2>&1 | grep -F ' ERROR '; then
	die 'a connector failed (see above); the app is deployed'
fi

echo
echo "Wealthfolio: $origin  (password: $OP_ITEM/WF_PASSWORD)"
echo "Node: $TS_NODE.$suffix ${node:+($node)}"
echo "App: $app_name, volumes: ${app_name}_wealthfolio-data, ${app_name}_wf-sync-data, ${app_name}_tailscale"
