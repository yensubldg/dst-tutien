#!/usr/bin/env bash

# Mod manager for DST dedicated server.
#
# All mods (legacy and UGC) are downloaded via steamcmd and placed as full
# directories in mods/workshop-<id>/. They are then removed from
# dedicated_server_mods_setup.lua so DST never tries to re-download or
# delete them via its UGC system.
#
# Legacy mods: distributed as _legacy.bin ZIP files — extracted in place.
# UGC mods:    full content copied from steamcmd download directory.

if [[ "${DST_SKIP_MOD_SETUP}" == "true" ]] || [[ -z "${DST_SERVER_MOD_SETUP}" ]]; then
    true
else

_STEAMCMD_WORKSHOP_DIR="/var/lib/steam/Steam/steamapps/workshop/content/322330"
_STEAMCMD_ACF="/var/lib/steam/Steam/steamapps/workshop/appworkshop_322330.acf"
_LOCAL_MODS_DIR="/usr/share/game/mods"
_MOD_SETUP_FILE="${DST_MOD_SETUP_FILE:-/usr/share/game/mods/dedicated_server_mods_setup.lua}"

IFS=',' read -ra _ALL_MOD_IDS <<< "${DST_SERVER_MOD_SETUP}"

# ── Categorise mods ────────────────────────────────────────────────────────────
# INSTALLED: mods we manage (have .dst_timeupdated) → check for updates
# NEW:       not present → fresh steamcmd download needed
_MODS_NEW=()
_MODS_INSTALLED=()

for _MOD_ID in "${_ALL_MOD_IDS[@]}"; do
    _MOD_ID="${_MOD_ID// /}"
    [[ -z "${_MOD_ID}" ]] && continue

    if [[ -f "${_LOCAL_MODS_DIR}/workshop-${_MOD_ID}/.dst_timeupdated" ]]; then
        _MODS_INSTALLED+=("${_MOD_ID}")
    elif [[ ! -d "${_LOCAL_MODS_DIR}/workshop-${_MOD_ID}" ]]; then
        _MODS_NEW+=("${_MOD_ID}")
    fi
done

# ── Update check via Steam Web API ────────────────────────────────────────────
_MODS_TO_UPDATE=()

if [[ ${#_MODS_INSTALLED[@]} -gt 0 ]]; then
    _QUERY="itemcount=${#_MODS_INSTALLED[@]}"
    for _i in "${!_MODS_INSTALLED[@]}"; do
        _QUERY="${_QUERY}&publishedfileids[${_i}]=${_MODS_INSTALLED[$_i]}"
    done

    _RESPONSE=$(curl -sf --max-time 20 -X POST \
        "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
        -d "${_QUERY}" 2>/dev/null)

    if [[ -n "${_RESPONSE}" ]]; then
        echo "${_RESPONSE}" \
            | perl -0pe 's/\},\s*\{/}\n{/g' \
            | perl -ne '
                /\"publishedfileid\"\s*:\s*\"(\d+)\"/ and $id = $1;
                /\"time_updated\"\s*:\s*(\d+)/ and $id and do {
                    print "$id $1\n"; $id = "";
                };' \
            | while IFS=' ' read -r _id _t; do
                echo "${_t}" > "/tmp/dst_wtime_${_id}"
              done

        for _MOD_ID in "${_MODS_INSTALLED[@]}"; do
            _STORED_FILE="${_LOCAL_MODS_DIR}/workshop-${_MOD_ID}/.dst_timeupdated"
            _STORED_TIME=$(cat "${_STORED_FILE}" 2>/dev/null || echo "")
            _WORKSHOP_TIME=$(cat "/tmp/dst_wtime_${_MOD_ID}" 2>/dev/null || echo "")

            if [[ -z "${_STORED_TIME}" ]] || \
               { [[ -n "${_WORKSHOP_TIME}" ]] && [[ "${_WORKSHOP_TIME}" != "${_STORED_TIME}" ]]; }; then
                echo "> mod ${_MOD_ID} update detected (local: ${_STORED_TIME:-none}, workshop: ${_WORKSHOP_TIME:-unknown})"
                _MODS_TO_UPDATE+=("${_MOD_ID}")
            fi
        done
    else
        echo "> warning: Steam API unreachable, skipping update check for installed mods"
    fi
fi

# ── Download (new + outdated mods) ────────────────────────────────────────────
_MODS_TO_DOWNLOAD=("${_MODS_NEW[@]}" "${_MODS_TO_UPDATE[@]}")

if [[ ${#_MODS_TO_DOWNLOAD[@]} -gt 0 ]]; then
    echo "> downloading ${#_MODS_TO_DOWNLOAD[@]} mod(s) via steamcmd"

    _STEAMCMD_ARGS="+login anonymous"
    for _MOD_ID in "${_MODS_TO_DOWNLOAD[@]}"; do
        _STEAMCMD_ARGS="${_STEAMCMD_ARGS} +workshop_download_item 322330 ${_MOD_ID}"
    done
    steamcmd ${_STEAMCMD_ARGS} +quit

    for _MOD_ID in "${_MODS_TO_DOWNLOAD[@]}"; do
        _SRC="${_STEAMCMD_WORKSHOP_DIR}/${_MOD_ID}"
        _DST="${_LOCAL_MODS_DIR}/workshop-${_MOD_ID}"

        if [[ ! -d "${_SRC}" ]]; then
            echo "> warning: mod ${_MOD_ID} could not be downloaded, skipping"
            continue
        fi

        _NEW_TIME=$(grep -A10 "\"${_MOD_ID}\"" "${_STEAMCMD_ACF}" 2>/dev/null | grep -m1 '"timeupdated"' | tr -dc '0-9')
        if [[ -z "${_NEW_TIME}" ]]; then
            _NEW_TIME=$(cat "/tmp/dst_wtime_${_MOD_ID}" 2>/dev/null || echo "")
        fi

        [[ -d "${_DST}" ]] && rm -rf "${_DST}"
        mkdir -p "${_DST}"

        _LEGACY=false
        for _BIN in "${_SRC}"/*_legacy.bin; do
            if [[ -f "${_BIN}" ]]; then
                echo "> extracting legacy zip for mod ${_MOD_ID}"
                unzip -q -o "${_BIN}" -d "${_DST}/" || true
                _LEGACY=true
                break
            fi
        done

        if [[ "${_LEGACY}" == "false" ]]; then
            # UGC mod: copy full content so DST loads it as a local mod
            cp -r "${_SRC}/." "${_DST}/"
        fi

        [[ -n "${_NEW_TIME}" ]] && echo "${_NEW_TIME}" > "${_DST}/.dst_timeupdated"
        echo "> mod ${_MOD_ID} ready (timeupdated: ${_NEW_TIME:-unknown})"
    done

    chown -R steam:steam "${_LOCAL_MODS_DIR}" 2>/dev/null || true
fi

# Clean up Steam API temp files
rm -f /tmp/dst_wtime_*

# ── Remove all managed mods from dedicated_server_mods_setup.lua ──────────────
# Since all mods are fully installed in mods/workshop-<id>/, DST must not try
# to re-download them via DownloadPublishedFile or UGC (both would fail or
# delete our local copy).
if [[ -f "${_MOD_SETUP_FILE}" ]]; then
    for _MOD_ID in "${_ALL_MOD_IDS[@]}"; do
        _MOD_ID="${_MOD_ID// /}"
        if [[ -n "${_MOD_ID}" ]] && \
           [[ -d "${_LOCAL_MODS_DIR}/workshop-${_MOD_ID}" ]]; then
            sed -i "/ServerModSetup(\"${_MOD_ID}\")/d" "${_MOD_SETUP_FILE}"
        fi
    done
fi

fi

true
