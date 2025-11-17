#!/usr/bin/env bash
#
# LHlab wiki – NGINX + IMGProxy Image & HTML Cache Test Suite (v1.3)
# ------------------------------------------------------------------
# This script runs comprehensive tests for:
#   • Image delivery via NGINX + IMGProxy (cache warmup, content negotiation, validators, fallback)
#   • HTML/CDN caching behaviour on a cacheable article and the start page
#
# Code comments are in English (per request).
# Output shows OK/FAIL/WARN and prints the key headers for each step.
#
# HOW TO RUN
# ----------
#   chmod +x lhlab_imgproxy_test_v1_3.sh
#   ./lhlab_imgproxy_test_v1_3.sh
#
# No need to export variables in the shell — adjust them in the CONFIGURATION block below.
# Exit code is non‑zero if any critical FAIL occurs.
# ------------------------------------------------------------------
#
# CONFIGURATION (edit values on the right-hand side)
# -------------------------------------------------
# Target host (FQDN) to test via HTTPS (reverse‑proxy with NGINX in front)
HOST="lhlab.wiki"
# Path to an existing image on HOST; may include a query string (e.g. ?v=123)
IMG="/images/9/91/GlobeView_Logo_Big.png"
# Canonical base URL for HTML checks
BASE_URL="https://lhlab.wiki"
# A cacheable article page (used to verify MISS→HIT and s-maxage behaviour)
PAGE_CACHEABLE="/wiki/Docker_Backup_und_Restore_-_eine_kleine_Anleitung"
# Your start page (headers are printed for info)
PAGE_START="/wiki/Willkommen_im_LHlab"
#
# Accept headers used to steer content negotiation
AVIF='image/avif,image/webp;q=0.9,image/*;q=0.8,*/*;q=0.5'
WEBP='image/webp,image/*;q=0.8,*/*;q=0.5'
PNGONLY='image/png,*/*;q=0.5'
#
# If set to 1, negotiation tests use the image URL **without** query string (safer default)
NEGATE_QS_FOR_NEG=1
# Set to 1 only when you intentionally stop imgproxy to confirm the fallback path
EXPECT_FALLBACK=0
#
# Optional: direct tests against the local imgproxy (only if reachable)
IMGPROXY_LOCAL="http://127.0.0.1:8989"
# Full MediaWiki source URL from imgproxy's perspective (example below). Leave empty to skip.
# Example when calling via Docker DNS:  MW_BACKEND_IMAGEURL="http://mediawiki_test/images/1/14/Docker_small_logo.jpg"
MW_BACKEND_IMAGEURL="http://127.0.0.1:8093/images/9/91/GlobeView_Logo_Big.png"
# ------------------------------------------------------------------

# Do not exit on first error; we gather results and report at the end.
set -u

BASE_IMG="https://${HOST}${IMG}"
IMG_NOQ="${IMG%%\?*}"
NEG_URL="https://${HOST}${IMG_NOQ}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { printf "${GREEN}OK${NC}    %s\n" "$*"; }
fail() { printf "${RED}FAIL${NC}  %s\n" "$*"; FAILS=$((FAILS+1)); }
warn() { printf "${YELLOW}WARN${NC}  %s\n" "$*"; WARNS=$((WARNS+1)); }
info() { printf "${CYAN}INFO${NC}  %s\n" "$*"; }

FAILS=0
WARNS=0

line() { printf -- "---------------------------------------------------------------------\n"; }
curl_headers()   { curl -s -D - "$1" -o /dev/null; }
curl_headers_H() { curl -s -D - -H "$1" "$2" -o /dev/null; }
hdr() { awk -v IGNORECASE=1 -v key="$1" 'BEGIN{FS=": *"} $1 ~ "^"key"$" { sub(/\r$/,"",$2); print $2; exit }'; }
focus() { echo "$1" | egrep -i '^(HTTP/|x-cache|x-cache-status|x-imgproxy-fallback|content-type|cache-control|etag|last-modified|vary|age|expires):' || true; }

echo "== LHlab wiki – NGINX + IMGProxy Image & HTML Cache Test Suite (v1.3) =="
printf "Host: %s\nIMG:  %s\n" "$HOST" "$IMG"; line

# -----------------------
# B) IMAGE DELIVERY TESTS
# -----------------------
echo "== B) Images via NGINX + IMGProxy on ${BASE_IMG} =="

echo "-- B1) Warmup (expect MISS -> HIT)"
B1_1="$(curl_headers "$BASE_IMG")"; B1_2="$(curl_headers "$BASE_IMG")"
focus "$B1_1"; echo; focus "$B1_2"; echo
XC1="$(echo "$B1_1" | hdr X-Cache)"; XC2="$(echo "$B1_2" | hdr X-Cache)"
if [[ "$XC1" =~ MISS|BYPASS ]] && [[ "$XC2" =~ HIT ]]; then ok "X-Cache: $XC1 -> $XC2"; else warn "Expected MISS/BYPASS -> HIT; observed '$XC1' -> '$XC2'"; fi
V1="$(echo "$B1_1" | hdr Vary)"; echo "$V1" | grep -qi '\<Accept\>' && ok "Vary includes Accept" || warn "Vary missing Accept"; line

echo "-- B2) Negotiation by Accept (AVIF/WebP/PNG-only)"
NEG_TARGET="$BASE_IMG"; if [[ "$NEGATE_QS_FOR_NEG" == "1" && "$IMG" != "$IMG_NOQ" ]]; then NEG_TARGET="$NEG_URL"; info "Negotiation uses URL without query: $NEG_TARGET"; fi
HAVIF="$(curl_headers_H "Accept: $AVIF" "$NEG_TARGET")"
HWEBP="$(curl_headers_H "Accept: $WEBP" "$NEG_TARGET")"
HPNGO="$(curl_headers_H "Accept: $PNGONLY" "$NEG_TARGET")"
echo "AVIF:";  focus "$HAVIF";  echo "WEBP:"; focus "$HWEBP"; echo "PNG:";  focus "$HPNGO"; echo
echo "$HAVIF" | hdr Content-Type | grep -qi '^image/avif' && ok "AVIF delivered" || fail "AVIF not delivered"
echo "$HWEBP" | hdr Content-Type | grep -qi '^image/webp' && ok "WebP delivered" || fail "WebP not delivered"
echo "$HPNGO" | hdr Content-Type | grep -qiE '^image/(avif|webp)$' && fail "PNGONLY still returned avif/webp" || ok "PNGONLY returned non-avif/webp"; line

echo "-- B3) Bypass with Cookie: session=1 (expect BYPASS)"
HBYP="$(curl_headers_H "Cookie: session=1" "$BASE_IMG")"; focus "$HBYP"; echo
XB="$(echo "$HBYP" | hdr X-Cache)"; echo "$XB" | grep -qi 'BYPASS' && ok "Bypass observed (X-Cache: $XB)" || warn "Bypass not observed (X-Cache: $XB)"; line

echo "-- B4) Validators via NGINX (ETag / Last-Modified)"
HVAL="$(curl_headers "$BASE_IMG")"; focus "$HVAL"; echo
ET="$(echo "$HVAL" | hdr ETag)"; LM="$(echo "$HVAL" | hdr Last-Modified)"
[[ -n "$ET" ]] && ok "ETag present" || warn "ETag missing"
[[ -n "$LM" ]] && ok "Last-Modified present" || warn "Last-Modified missing (OK if ETag exists)"; line

echo "-- B5) Fallback detection (@wiki_direct)"
HFB="$(curl_headers "$BASE_IMG")"; XF="$(echo "$HFB" | hdr X-Imgproxy-Fallback)"
if [[ -z "$XF" && "$EXPECT_FALLBACK" == "0" ]]; then ok "No fallback (imgproxy path OK)"
elif [[ -n "$XF" && "$EXPECT_FALLBACK" == "1" ]]; then ok "Fallback observed as expected"
elif [[ -n "$XF" && "$EXPECT_FALLBACK" == "0" ]]; then warn "Fallback occurred unexpectedly (X-Imgproxy-Fallback: $XF)"
else warn "Fallback not observed but EXPECT_FALLBACK=1"; fi
line

# -------------------------------------
# D) HTML/CDN CACHING – EXACT COMMANDS
# -------------------------------------
echo "== D) HTML/CDN caching on ${BASE_URL}${PAGE_CACHEABLE} and ${BASE_URL}${PAGE_START} =="
echo "-- D1) Cacheable page: expect MISS -> HIT (and s-maxage for anon)"
D1_1="$(curl -I -s "${BASE_URL}${PAGE_CACHEABLE}")"; D1_2="$(curl -I -s "${BASE_URL}${PAGE_CACHEABLE}")"
focus "$D1_1"; focus "$D1_2"; echo
DX1="$(echo "$D1_1" | hdr X-Cache)"; DX2="$(echo "$D1_2" | hdr X-Cache)"
if [[ "$DX1" =~ MISS|BYPASS ]] && [[ "$DX2" =~ HIT ]]; then ok "HTML X-Cache: $DX1 -> $DX2"; else warn "HTML MISS/HIT not observed: '$DX1' -> '$DX2'"; fi
CC1="$(echo "$D1_1" | hdr Cache-Control)"
echo "$CC1" | grep -qi 's-maxage' && ok "HTML Cache-Control has s-maxage" || warn "No s-maxage in HTML Cache-Control (may be intentional)"
line

echo "-- D2) Start page (informational)"
D2_1="$(curl -I -s "${BASE_URL}${PAGE_START}")"; D2_2="$(curl -I -s "${BASE_URL}${PAGE_START}")"
focus "$D2_1"; focus "$D2_2"; echo
ok "Start page headers printed (no strict assertion here)"; line

echo "-- D3) Logged-in cookie (should bypass)"
D3="$(curl -I -s -H 'Cookie: LoggedIn=1' "${BASE_URL}${PAGE_CACHEABLE}")"; focus "$D3"; echo
echo "$D3" | grep -qi '^X-Cache:.*BYPASS' && ok "Bypass observed with LoggedIn cookie" || warn "No BYPASS seen for LoggedIn cookie"; line

echo "-- D4) nocache=1 param (should bypass)"
D4="$(curl -I -s "${BASE_URL}${PAGE_CACHEABLE}?nocache=1")"; focus "$D4"; echo
echo "$D4" | grep -qi '^X-Cache:.*BYPASS' && ok "Bypass observed for nocache=1" || warn "No BYPASS for nocache=1"; line

echo "-- D5) action=edit (should bypass)"
D5="$(curl -I -s "${BASE_URL}${PAGE_CACHEABLE}?action=edit")"; focus "$D5"; echo
echo "$D5" | grep -qi '^X-Cache:.*BYPASS' && ok "Bypass observed for action=edit" || warn "No BYPASS for action=edit"; line

echo "-- D6) POST request (should not be cached)"
curl -s -o /dev/null -X POST -d 'dummy=value' "${BASE_URL}${PAGE_CACHEABLE}" || true
D6="$(curl -I -s "${BASE_URL}${PAGE_CACHEABLE}")"; focus "$D6"; echo
ok "POST sent (result headers printed). Ensure cache rules for unsafe methods are in place."; line

# ----------------------------------
# C) Direct imgproxy (optional part)
# ----------------------------------
echo "== C) Optional: direct imgproxy tests =="
HEALTH="$(curl -s -o /dev/null -w "%{http_code}" "$IMGPROXY_LOCAL/health" 2>/dev/null || true)"
if [[ "$HEALTH" =~ ^(200|204)$ && -n "$MW_BACKEND_IMAGEURL" ]]; then
  echo "-- C1) imgproxy direct: AVIF/WEBP/Original"
  DI_A="$(curl_headers "${IMGPROXY_LOCAL}/insecure/plain/${MW_BACKEND_IMAGEURL}@avif")"
  DI_W="$(curl_headers "${IMGPROXY_LOCAL}/insecure/plain/${MW_BACKEND_IMAGEURL}@webp")"
  DI_O="$(curl_headers "${IMGPROXY_LOCAL}/insecure/plain/${MW_BACKEND_IMAGEURL}")"
  echo "AVIF:"; focus "$DI_A"; echo "WEBP:"; focus "$DI_W"; echo "ORIG:"; focus "$DI_O"; echo
  echo "$DI_A" | hdr Content-Type | grep -qi '^image/avif' && ok "imgproxy AVIF OK" || fail "imgproxy AVIF not OK"
  echo "$DI_W" | hdr Content-Type | grep -qi '^image/webp' && ok "imgproxy WEBP OK" || fail "imgproxy WEBP not OK"
  echo "$DI_O" | hdr Content-Type | grep -qiE '^image/(avif|webp)$' && fail "imgproxy ORIG returned avif/webp" || ok "imgproxy ORIG OK"

  echo "-- C2) imgproxy 304 via ETag"
  E_DI="$(echo "$DI_A" | hdr ETag)"
  if [[ -n "$E_DI" ]]; then
    CODE="$(curl -s -D - -H "If-None-Match: $E_DI" "${IMGPROXY_LOCAL}/insecure/plain/${MW_BACKEND_IMAGEURL}@avif" -o /dev/null | head -n1)"
    echo "$CODE"; echo "$CODE" | grep -q ' 304 ' && ok "imgproxy revalidated with 304" || warn "No 304 from imgproxy"
  else
    warn "No ETag from imgproxy; skipped 304 test"
  fi
else
  info "imgproxy not reachable or MW_BACKEND_IMAGEURL unset – skipping direct tests"
fi

line
if [[ $FAILS -eq 0 ]]; then
  printf "${GREEN}All critical tests passed.${NC} "; [[ $WARNS -gt 0 ]] && printf "(with %d warnings)\n" "$WARNS" || printf "\n"
  exit 0
else
  printf "${RED}%d critical test(s) failed${NC} (and %d warning(s)).\n" "$FAILS" "$WARNS"
  exit 1
fi
