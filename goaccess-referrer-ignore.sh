#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================
# Build / Update / Delete "ignore-referrer" block in goaccess.conf
# ------------------------------------------------------------
# What it does
# - Downloads the Matomo referrer-spam list.
# - Converts entries into clean GoAccess rules (regex or plain mode).
# - Inserts or replaces a marked block in goaccess.conf between BEGIN/END markers.
# - --delete removes that auto-generated block without touching anything else.
#
# Requirements
# - bash, curl, GNU awk (gawk).
#
# Usage
#   ./goaccess-referrer-ignore.sh \
#     --conf /etc/goaccess/goaccess.conf \
#     --mode regex \
#     --url  https://raw.githubusercontent.com/matomo-org/referrer-spam-list/refs/heads/master/spammers.txt
#
# Options
#   --delete        Delete the auto-generated block instead of creating/updating it.
#   --no-backup     Do not create a .bak timestamped copy before writing.
#   --dry-run       Show the resulting file to stdout; do not modify anything.
#   --conf PATH     Path to goaccess.conf (default: data/goaccess/goaccess.conf).
#   --mode MODE     'regex' (recommended) or 'plain' (default: regex).
#   --url URL       Source list URL (default: Matomo referrer-spam list).
#
# Defaults
#   CONF_FILE="data/goaccess/goaccess.conf"
#   MODE="regex"
#   LIST_URL="https://raw.githubusercontent.com/matomo-org/referrer-spam-list/refs/heads/master/spammers.txt"
#   Backups enabled (unless --no-backup); Dry-run disabled.
#
# Notes
# - The block is delimited by:
#     # >>> BEGIN AUTO-GENERATED ignore-referrer (Matomo referrer spam)
#     ... rules ...
#     # <<< END AUTO-GENERATED ignore-referrer (Matomo referrer spam)
# - Regex mode generates robust host-matching patterns; plain mode uses raw needles.
# ============================================================

CONF_FILE="data/goaccess/goaccess.conf"
LIST_URL="https://raw.githubusercontent.com/matomo-org/referrer-spam-list/refs/heads/master/spammers.txt"
MODE="regex"       # regex | plain
DO_BACKUP=1
DRY_RUN=0
DO_DELETE=0

BEGIN_MARK='# >>> BEGIN AUTO-GENERATED ignore-referrer (Matomo referrer spam)'
END_MARK='# <<< END AUTO-GENERATED ignore-referrer (Matomo referrer spam)'

usage() {
  cat <<EOF
Usage:
  $0 [--conf PATH] [--mode regex|plain] [--url URL] [--no-backup] [--dry-run]
     [--delete]

Aktionen:
  (Default)  Erzeugt/aktualisiert den Auto-Block zwischen BEGIN/END.
  --delete   Löscht den Auto-Block zwischen BEGIN/END (alles andere bleibt).

Optionen:
  --conf PATH     Pfad zur goaccess.conf (Default: $CONF_FILE)
  --mode MODE     regex|plain (Default: $MODE)
  --url URL       Matomo-Referrer-Spam-Liste (Default: $LIST_URL)
  --no-backup     Kein Backup vor dem Schreiben
  --dry-run       Nur Vorschau, keine Änderungen
EOF
}

# ------------------------------------------------------------
# Args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--conf) CONF_FILE="$2"; shift 2 ;;
    -u|--url)  LIST_URL="$2"; shift 2 ;;
    -m|--mode) MODE="${2,,}"; shift 2 ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --delete) DO_DELETE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 2 ;;
  esac
done

# ------------------------------------------------------------
# Tempfiles
tmp_in="$(mktemp)"
tmp_rules="$(mktemp)"
tmp_new="$(mktemp)"
trap 'rm -f "$tmp_in" "$tmp_rules" "$tmp_new"' EXIT

# ------------------------------------------------------------
# Datei vorbereiten
mkdir -p "$(dirname "$CONF_FILE")"
if [[ ! -f "$CONF_FILE" ]]; then
  : > "$CONF_FILE"
fi

# Backup
if [[ $DO_BACKUP -eq 1 && $DO_DELETE -eq 0 ]]; then
  cp -a "$CONF_FILE" "$CONF_FILE.bak.$(date +%Y%m%d%H%M%S)"
  echo ">> Backup erstellt: $CONF_FILE.bak.*"
fi

# ------------------------------------------------------------
# DELETE-PFAD
if [[ $DO_DELETE -eq 1 ]]; then
  if ! grep -qF "$BEGIN_MARK" "$CONF_FILE"; then
    echo ">> Kein Auto-Block gefunden (BEGIN-Marker fehlt). Nichts zu löschen."
    exit 0
  fi

  # Optionales Backup auch beim Löschen sinnvoll:
  if [[ $DO_BACKUP -eq 1 ]]; then
    cp -a "$CONF_FILE" "$CONF_FILE.bak.$(date +%Y%m%d%H%M%S)"
    echo ">> Backup erstellt: $CONF_FILE.bak.*"
  fi

  echo ">> Lösche Auto-Block…"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inside=1; deleted=1; next }
    inside && $0 == e { inside=0; next }
    !inside { print }
    END {
      if (!deleted) {
        # Falls BEGIN nie gesehen -> nichts zu tun
      }
    }
  ' "$CONF_FILE" > "$tmp_new"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo ">> DRY-RUN: Änderungen werden NICHT geschrieben. Vorschau:"
    echo "--------------------------------------------------------"
    cat "$tmp_new"
    echo "--------------------------------------------------------"
    exit 0
  fi

  mv "$tmp_new" "$CONF_FILE"
  echo ">> Fertig. Auto-Block entfernt aus: $CONF_FILE"
  exit 0
fi

# ------------------------------------------------------------
# UPDATE/ERZEUGEN-PFAD
ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ">> Lade Liste: $LIST_URL"
curl -fsSL "$LIST_URL" -o "$tmp_in"

case "$MODE" in
  regex)
    awk -v d="ignore-referrer" -v src="$LIST_URL" -v gen="$ts" '
      BEGIN {
        print "# Quelle: " src
        print "# Generiert: " gen
      }
      /^[[:space:]]*($|#)/ { next }
      {
        g=$0
        gsub(/\r/,"",g)
        g=tolower(g)
        gsub(/[[:space:]]+/,"",g)
        e=g
        gsub(/\./,"\\.",e)
        print d " ^https?://([^/]+\\.)?" e "(/|$)"
      }
    ' "$tmp_in" | sort -u > "$tmp_rules"
    ;;
  plain)
    awk -v d="ignore-referrer" -v src="$LIST_URL" -v gen="$ts" '
      BEGIN {
        print "# Quelle: " src
        print "# Generiert: " gen
        print "# HINWEIS: Plain-Needles können false positives verursachen."
      }
      /^[[:space:]]*($|#)/ { next }
      {
        g=$0
        gsub(/\r/,"",g)
        g=tolower(g)
        gsub(/[[:space:]]+/,"",g)
        print d " " g
      }
    ' "$tmp_in" | sort -u > "$tmp_rules"
    ;;
  *)
    echo "Ungültiger MODE: $MODE (erwartet: regex|plain)" >&2
    exit 2
    ;;
esac

rules_cnt="$(grep -c '^ignore-referrer ' "$tmp_rules" || true)"
echo ">> $rules_cnt Regeln erzeugt."
echo ">> Auto-Block aktualisieren…"

awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v fn="$tmp_rules" '
  BEGIN {
    repl = b "\n"
    while ((getline l < fn) > 0) repl = repl l "\n"
    close(fn)
    repl = repl e "\n"
    inside = 0
    updated = 0
  }
  $0 == b {
    inside = 1
    if (!updated) { print repl; updated = 1 }
    next
  }
  $0 == e && inside { inside = 0; next }
  !inside { print }
  END {
    if (!updated) print repl
  }
' "$CONF_FILE" > "$tmp_new"

if [[ $DRY_RUN -eq 1 ]]; then
  echo ">> DRY-RUN: Änderungen werden NICHT geschrieben. Vorschau:"
  echo "--------------------------------------------------------"
  cat "$tmp_new"
  echo "--------------------------------------------------------"
  exit 0
fi

mv "$tmp_new" "$CONF_FILE"
echo ">> Fertig. Datei aktualisiert: $CONF_FILE"
echo "Prüfen:"
echo "  grep -n -E '^(# >>>|ignore-referrer|# <<<)' '$CONF_FILE' | head -60"
