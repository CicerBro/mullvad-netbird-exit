#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_dir"

if [[ ! -f .env ]]; then
  printf '%s\n' 'Missing .env. Copy the supplied template values into it first.' >&2
  exit 1
fi

# .env is deliberately a local shell-style file so SSH keys and values with
# punctuation can be represented without a second parser.
set -a
# shellcheck disable=SC1091
source .env
set +a

required=(
  HOSTNAME SSH_PUBLIC_KEY TIMEZONE NETBIRD_SETUP_KEY NETBIRD_OVERLAY_CIDR
  NETBIRD_WG_PORT MULLVAD_ACCOUNT MULLVAD_COUNTRY MULLVAD_CITY
)
for variable in "${required[@]}"; do
  value="${!variable:-}"
  if [[ -z "$value" || "$value" == "CHANGEME" ]]; then
    printf 'Set %s in .env before building.\n' "$variable" >&2
    exit 1
  fi
done

if [[ ! "$NETBIRD_WG_PORT" =~ ^[0-9]+$ ]] || (( NETBIRD_WG_PORT < 1 || NETBIRD_WG_PORT > 65535 )); then
  printf '%s\n' 'NETBIRD_WG_PORT must be a valid UDP port.' >&2
  exit 1
fi

template_variables='$HOSTNAME $SSH_PUBLIC_KEY $TIMEZONE $NETBIRD_SETUP_KEY $NETBIRD_OVERLAY_CIDR $NETBIRD_WG_PORT $MULLVAD_ACCOUNT $MULLVAD_COUNTRY $MULLVAD_CITY'
envsubst "$template_variables" < router.bu.tpl > router.bu

docker run --rm -i quay.io/coreos/butane:release --pretty --strict < router.bu > router.ign

printf '%s\n' 'Built router.bu and router.ign.'
printf '%s\n' 'Both files contain credentials. They are ignored by Git.'
