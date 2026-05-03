#!/usr/bin/env bash

# Copy pre-made config files from /etc/dst-config/<ShardName>/ into the shard
# directory. Runs before 20-configs.sh so DST_SKIP_* flags prevent gomplate
# from overwriting them afterward.
#
# Mount config files in docker-compose like:
#   - ./config/Master/modoverrides.lua:/etc/dst-config/Master/modoverrides.lua:ro
#   - ./config/Master/leveldataoverride.lua:/etc/dst-config/Master/leveldataoverride.lua:ro

_CONFIG_SRC="/etc/dst-config/${DST_SHARD_NAME}"

if [[ -f "${_CONFIG_SRC}/modoverrides.lua" ]]; then
    echo "> copying modoverrides.lua from ${_CONFIG_SRC}"
    mkdir -p "${DST_SHARD_DIR}"
    cp "${_CONFIG_SRC}/modoverrides.lua" "${DST_MOD_OVERRIDES_FILE}"
    export DST_SKIP_MOD_OVERRIDES="true"
fi

if [[ -f "${_CONFIG_SRC}/leveldataoverride.lua" ]]; then
    echo "> copying leveldataoverride.lua from ${_CONFIG_SRC}"
    mkdir -p "${DST_SHARD_DIR}"
    cp "${_CONFIG_SRC}/leveldataoverride.lua" "${DST_LEVELDATA_OVERRIDE_FILE}"
    export DST_SKIP_LEVELDATA_OVERRIDE="true"
fi

true
