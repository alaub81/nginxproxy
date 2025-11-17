#!/usr/bin/env bash
#########################################################################
#issue-from-list.sh
#This Script uses a running certbot docker container to issue letsencrypt
#SSL certificates for Domains listed in a txt file.
#by A. Laub
#andreas[-at-]laub-home.de
#
# Please at first define all domains in txt list file
# (default: domains.list) - space seperated:
# www.example.de test.example.de
# first domain will be the name of cert (www.example.de)
# one certificate per line will be generated:
# domains.list example:
# > www.example.de test.example.de
# > stats.example.com
# > www.example.com test.example.com
# > www.example.tld test.example.tld
#########################################################################

set -euo pipefail

# === Domainlist ===
# File with domain lists (one list per line, separate domains with spaces)
# Example:
# example.com www.example.com
# example.org www.example.org blog.example.org
# domains.list is used as the default, or the first parameter.
DOMAINS_FILE="${1:-domains.list}"

# === Konfig ===
# Email for registration with Let’s Encrypt
EMAIL="andreas@laub-home.de"
# Webroot path for validation (must match the Nginx setup)
WEBROOT="/data/letsencrypt"
# Let’s Encrypt Staging true/false
STAGING=true
# Dry run true/false
DRYRUN=true
# If you are working in Docker, set:
# CERTBOT_BIN='docker compose run --rm certbot certbot'
CERTBOT_BIN="docker compose exec -T certbot certbot"
# Optional: Nginx reload after successful run (leave blank to skip)
# uncomment the following line to enable reload
#RELOAD="docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload"

# === do the job ===
[[ -f "$DOMAINS_FILE" ]] || { echo "Datei nicht gefunden: $DOMAINS_FILE" >&2; exit 1; }

args_common=(--agree-tos
    --no-eff-email
    --webroot -w "$WEBROOT"
    --non-interactive
    --text --email "$EMAIL"
    --key-type ecdsa
    --expand)
[[ "$STAGING" = true ]] && args_common+=(--staging)
[[ "$DRYRUN"  = true ]] && args_common+=(--dry-run)

# Open file on FD 3 so that STDIN remains free
exec 3< "$DOMAINS_FILE"

while IFS= read -r raw <&3 || [[ -n "${raw:-}" ]]; do
  # Remove comments/blank lines + clean CR
  line="${raw%%#*}"; line="${line//$'\r'/}"; line="$(echo "$line" | xargs || true)"
  [[ -z "$line" ]] && continue

  # Optional: Allow commas as separators
  line="${line//,/ }"

  # Domains in Array, 1. Domain = cert-name
  read -r -a doms <<<"$line"
  certname="${doms[0]}"

  # -d Build arguments
  dargs=()
  for d in "${doms[@]}"; do dargs+=( -d "$d" ); done

  echo "==> Zertifikat: $certname  | Domains: ${doms[*]}"

  # --- Call: Close STDIN and catch errors ---
  set +e
  $CERTBOT_BIN certonly --cert-name "$certname" "${args_common[@]}" "${dargs[@]}" </dev/null
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "WARN: certbot für '$certname' schlug fehl (RC=$rc). Gehe zur nächsten Zeile weiter." >&2
    continue
  fi
done

# Close FD 3
exec 3<&-

# optional nginx reload
if [[ -n "${RELOAD:-}" ]]; then
  echo "==> Nginx reload"
  sh -c "$RELOAD"
fi

echo "Fertig."