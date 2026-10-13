#!/usr/bin/env bash

source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/caching.sh"
quickshell -p "$MAIN_QML" ipc --any-display call main forceReload
