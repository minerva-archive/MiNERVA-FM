#!/bin/bash
# =============================================================================
# fetch-modarchive.sh — populate the radio from The Mod Archive.
#
# The Mod Archive is the only large music library that (a) publishes in native
# tracker formats and (b) records an explicit licence per module. This script
# downloads the two unencumbered sets — Public Domain and CC0 — into the
# <TLD>/<Game>/<file> layout the indexer expects:
#
#   music/ModArchive/Impulse Tracker/2100_a_tale.it
#   music/ModArchive/FastTracker II/aeolus.xm
#   music/ModArchive/ProTracker/8bit_castle.mod
#
# Only native formats are ever fetched: a module is a few tens of KB where the
# rendered audio would be megabytes, and the station decodes them in-container.
# Anything that is not a module MiNERVA can decode is skipped, not downloaded.
#
# Usage:   ./examples/fetch-modarchive.sh [OPTIONS] [DEST]
#            DEST                 where to write (default ./music)
#          -l, --licence LIST     comma-separated; default "publicdomain,cc0".
#                                 Also: by, by-sa, by-nd, by-nc, by-nc-sa,
#                                 by-nc-nd — these carry conditions, see below.
#          -p, --pages N          stop after N listing pages per licence
#          -n, --limit N          stop after N modules in total
#          -d, --delay SECS       pause between requests (default 2)
#          -t, --tld NAME         top-level folder name (default ModArchive)
#              --flat             one folder for everything, no per-format split
#              --dry-run          list what would be downloaded, fetch nothing
#
# Public Domain and CC0 are free of conditions. The `by*` licences all require
# attribution, and `nc` forbids commercial use — if you broadcast those, meeting
# their terms is on you. Every download is recorded in MANIFEST.csv next to the
# music, with the module id and the licence it was published under.
#
# The archive runs on donations; this script waits between requests. Please
# leave the delay alone, and don't re-run it in a loop.
# =============================================================================

set -uo pipefail

LICENCES="publicdomain,cc0"
MAX_PAGES=0            # 0 = all
LIMIT=0                # 0 = no limit
DELAY=2
TLD="ModArchive"
FLAT=0
DRY_RUN=0
DEST="./music"

UA="MiNERVA-FM/1.0 (radio station populate script)"
LISTING="https://modarchive.org/index.php"
DOWNLOAD="https://api.modarchive.org/downloads.php"

# --- argument parsing --------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -l|--licence|--license) LICENCES="$2"; shift 2 ;;
        -p|--pages)             MAX_PAGES="$2"; shift 2 ;;
        -n|--limit)             LIMIT="$2"; shift 2 ;;
        -d|--delay)             DELAY="$2"; shift 2 ;;
        -t|--tld)               TLD="$2"; shift 2 ;;
        --flat)                 FLAT=1; shift ;;
        --dry-run)              DRY_RUN=1; shift ;;
        -h|--help)              sed -n '2,38p' "$0"; exit 0 ;;
        -*)                     echo "Unknown option: $1" >&2; exit 1 ;;
        *)                      DEST="$1"; shift ;;
    esac
done

IFS=',' read -r -a LICENCE_LIST <<< "$LICENCES"
for l in "${LICENCE_LIST[@]}"; do
    case "$l" in
        publicdomain|cc0|by|by-sa|by-nd|by-nc|by-nc-sa|by-nc-nd) ;;
        *) echo "Unknown licence: $l" >&2; exit 1 ;;
    esac
done
[[ "$MAX_PAGES" =~ ^[0-9]+$ && "$LIMIT" =~ ^[0-9]+$ && "$DELAY" =~ ^[0-9.]+$ ]] \
    || { echo "--pages, --limit and --delay must be numbers." >&2; exit 1; }

command -v wget >/dev/null 2>&1 || { echo "ERROR: wget is required." >&2; exit 1; }

fetch(){ wget -q -O - --user-agent="$UA" --tries=3 --timeout=30 "$1"; }

# --- extension -> folder name ------------------------------------------------
# Native tracker formats only, and only ones listed in EXTS in
# minerva-indexer.sh. Rendered audio (mp3/ogg/flac/wav) is deliberately absent:
# an unrecognised extension is skipped rather than downloaded unplayable.
format_for(){
    case "$1" in
        mod|nst|wow|m15) echo "ProTracker" ;;
        xm)              echo "FastTracker II" ;;
        it)              echo "Impulse Tracker" ;;
        s3m)             echo "Scream Tracker 3" ;;
        stm)             echo "Scream Tracker 2" ;;
        mptm)            echo "OpenMPT" ;;
        med)             echo "OctaMED" ;;
        okt)             echo "Oktalyzer" ;;
        mtm)             echo "MultiTracker" ;;
        669)             echo "Composer 669" ;;
        far)             echo "Farandole" ;;
        dbm)             echo "DigiBooster Pro" ;;
        digi)            echo "DigiBooster" ;;
        psm)             echo "Epic MegaGames MASI" ;;
        ptm)             echo "PolyTracker" ;;
        mdl)             echo "DigiTrakker" ;;
        dmf)             echo "X-Tracker" ;;
        dsm)             echo "DSIK" ;;
        amf)             echo "DSMI" ;;
        gdm)             echo "General DigiMusic" ;;
        ult)             echo "UltraTracker" ;;
        umx)             echo "Unreal Package" ;;
        mo3)             echo "MO3" ;;
        j2b)             echo "Galaxy Sound System" ;;
        imf)             echo "Imago Orpheus" ;;
        dtm)             echo "Digital Tracker" ;;
        ams)             echo "Velvet Studio" ;;
        mt2)             echo "MadTracker 2" ;;
        plm)             echo "Disorder Tracker 2" ;;
        *)               echo "" ;;      # not a format we decode — skip
    esac
}

# --- listing scrape ----------------------------------------------------------
# Rows link the download endpoint as
#   https://api.modarchive.org/downloads.php?moduleid=<id>#<filename>
# which is all we need: the id to fetch, the filename to save as.
page_entries(){                   # page_entries LICENCE PAGE -> "<id>\t<name>"
    fetch "${LISTING}?request=view_by_license&query=$1&page=$2" \
      | grep -oE 'downloads\.php\?moduleid=[0-9]+#[^"]+' \
      | sed -E 's/.*moduleid=([0-9]+)#(.*)/\1\t\2/' \
      | sort -u -k1,1n
}

last_page(){                      # highest page number advertised for a licence
    fetch "${LISTING}?request=view_by_license&query=$1&page=1" \
      | grep -oE "query=$1&amp;page=[0-9]+" \
      | grep -oE '[0-9]+$' | sort -n | tail -1
}

# Keep only characters that are safe in a path; the archive's filenames are
# already tame, but they come off a web page, so never trust them blindly.
sanitise(){ printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed -E 's/^\.+//'; }

csv_escape(){ printf '%s' "${1//\"/\"\"}"; }

# --- go ----------------------------------------------------------------------
MANIFEST="$DEST/$TLD/MANIFEST.csv"
echo "Licences:    ${LICENCE_LIST[*]}"
echo "Destination: $DEST/$TLD"
echo "------------------------------------------"

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$DEST/$TLD"
    [ -s "$MANIFEST" ] || echo "ModuleID,Licence,Format,Folder,File_Name,Source_URL" > "$MANIFEST"
fi

got=0 skipped=0 failed=0 unplayable=0
for licence in "${LICENCE_LIST[@]}"; do
    pages=$(last_page "$licence")
    [[ "$pages" =~ ^[0-9]+$ ]] || pages=1
    [ "$MAX_PAGES" -gt 0 ] && [ "$MAX_PAGES" -lt "$pages" ] && pages="$MAX_PAGES"
    echo "== $licence: $pages page(s)"

    for ((page = 1; page <= pages; page++)); do
        echo "[$licence page $page/$pages]"
        while IFS=$'\t' read -r id name; do
            [ -n "$id" ] && [ -n "$name" ] || continue
            [ "$LIMIT" -gt 0 ] && [ "$got" -ge "$LIMIT" ] && break 3

            name=$(sanitise "$name")
            ext="${name##*.}"; ext="${ext,,}"
            folder=$(format_for "$ext")
            if [ -z "$folder" ]; then
                echo "  skip (not a decodable module): $name"
                ((unplayable++)); continue
            fi
            [ "$FLAT" -eq 1 ] && folder="All"

            out="$DEST/$TLD/$folder/$name"
            url="${DOWNLOAD}?moduleid=${id}"
            if [ -s "$out" ]; then ((skipped++)); continue; fi
            if [ "$DRY_RUN" -eq 1 ]; then echo "  would fetch: $out"; ((got++)); continue; fi

            mkdir -p "$(dirname "$out")"
            # Fetch to a temp name so an interrupted or bogus download never
            # lands in the catalogue as a real file.
            tmp="$out.part"
            if ! wget -q -O "$tmp" --user-agent="$UA" --tries=3 --timeout=30 "$url"; then
                echo "  FAIL (http): $name"; rm -f "$tmp"; ((failed++))
            elif [ ! -s "$tmp" ] || head -c 256 "$tmp" | grep -qi '<html'; then
                echo "  FAIL (not a module): $name"; rm -f "$tmp"; ((failed++))   # an error page
            else
                mv -f "$tmp" "$out"
                printf '%s,"%s","%s","%s","%s","%s"\n' "$id" \
                    "$(csv_escape "$licence")" "$(csv_escape "$ext")" \
                    "$(csv_escape "$folder")"  "$(csv_escape "$name")" \
                    "$(csv_escape "$url")" >> "$MANIFEST"
                echo "  $folder/$name"
                ((got++))
            fi
            sleep "$DELAY"
        done < <(page_entries "$licence" "$page")
        [ "$page" -lt "$pages" ] && sleep "$DELAY"
    done
done

echo "------------------------------------------"
echo "Downloaded: $got | already had: $skipped | not decodable: $unplayable | failed: $failed"
if [ "$DRY_RUN" -eq 0 ] && [ "$got" -gt 0 ]; then
    echo "Provenance: $MANIFEST"
    echo
    echo "Next: drop the stale catalogue and restart, so the station reindexes:"
    echo "  docker compose exec station rm -f /data/vgm_catalogue.csv"
    echo "  docker compose restart station"
fi
