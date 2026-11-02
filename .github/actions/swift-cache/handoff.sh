#!/bin/bash
# Carries the cached build paths from a tag run to the run that promotes them, keeping
# symlinks and sub-second mtimes. Usage: handoff.sh pack|unpack ARCHIVE
# CACHE_PATHS lists the paths, one per line; a leading ~/ means relative to $HOME, anything
# else relative to the working directory. An archive holds nothing but those paths.
set -euo pipefail
export COPYFILE_DISABLE=1
action="$1"
archive="$2"
workspace_paths=()
home_paths=()
while IFS= read -r path; do
    case "$path" in
        "~/"*) home_paths+=("${path#\~/}") ;;
        *) workspace_paths+=("$path") ;;
    esac
done <<< "$CACHE_PATHS"

pack() {
    local present=() path
    for path in "${workspace_paths[@]}"; do
        if [[ -e "$path" ]]; then present+=(-C "$PWD" "$path"); fi
    done
    for path in "${home_paths[@]}"; do
        if [[ -e "$HOME/$path" ]]; then present+=(-C "$HOME" "$path"); fi
    done
    mkdir -p "$(dirname "$archive")"
    /usr/bin/tar --format pax -cf - "${present[@]}" | zstd -T0 -q -o "$archive"
}

# The archive crosses from a tag run into a default-branch run, so it is checked before use.
check_member() {
    local member="$1" path
    case "/$member/" in */../*) printf 'Refusing member: %s\n' "$member" >&2; return 1 ;; esac
    for path in "${workspace_paths[@]}" "${home_paths[@]}"; do
        case "$member" in "$path" | "$path"/*) return 0 ;; esac
    done
    printf 'Refusing member: %s\n' "$member" >&2
    return 1
}

unpack() {
    local member path skip_home=() skip_workspace=()
    while IFS= read -r member; do
        check_member "$member"
    done < <(zstd -dcq "$archive" | /usr/bin/tar -tf - || printf '/unreadable archive\n')
    for path in "${home_paths[@]}"; do skip_home+=(--exclude "$path"); done
    for path in "${workspace_paths[@]}"; do skip_workspace+=(--exclude "$path"); done
    # Without -P tar also refuses .. in a name and writing through a symlink.
    zstd -dcq "$archive" | /usr/bin/tar -xpf - -C "$PWD" "${skip_home[@]}"
    zstd -dcq "$archive" | /usr/bin/tar -xpf - -C "$HOME" "${skip_workspace[@]}"
}

case "$action" in
    pack) pack ;;
    unpack) unpack ;;
    *) exit 2 ;;
esac
