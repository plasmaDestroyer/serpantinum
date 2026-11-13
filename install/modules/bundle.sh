#!/usr/bin/env bash

# The daemons pinned in src/assets/daemons.json (the same releases and checksums the AUR
# packages ship) go inside the Serpantinum runtime, next to the shell that expects them.
# No sudo and no "latest": every archive is checked against its pin, every binary against
# its version, and nothing reaches the destination until all of them pass.
bundle_daemons() (
    set -e
    local project="$1" destination="$2" manifest name version checksum archive actual flag work
    manifest="$project/src/assets/daemons.json"
    jq -e 'type == "object" and length > 0' "$manifest" >/dev/null || return 1

    if [ "$(uname -m)" != x86_64 ]; then
        echo "No bundled daemons for $(uname -m). Use the Nix source build." >&2
        return 1
    fi

    work=$(mktemp -d) || return 1
    trap 'rm -rf -- "$work"' EXIT
    for name in $(jq -r 'keys[]' "$manifest"); do
        version=$(jq -er --arg n "$name" '.[$n].version' "$manifest") || return 1
        checksum=$(jq -er --arg n "$name" '.[$n].sha256' "$manifest") || return 1

        if [ -x "$project/bin/$name" ]; then
            # A prebuilt bundle archive already carries the binary: reuse it, still version-checked below.
            install -Dm755 "$project/bin/$name" "$work/bin/$name" || return 1
            install -Dm644 "$project/licenses/$name/LICENSE" "$work/licenses/$name/LICENSE" || return 1
        else
            archive="$name-$version-x86_64-linux.tar.gz"
            mkdir -p "$work/$name"
            curl -fsSL --connect-timeout 15 --max-time 120 --retry 3 \
                "https://github.com/ilyamiro/$name/releases/download/v$version/$archive" -o "$work/$name/$archive" || return 1
            (cd "$work/$name" && printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c --quiet) || return 1
            tar -xzf "$work/$name/$archive" -C "$work/$name" --no-same-owner \
                "usr/bin/$name" "usr/share/licenses/$name/LICENSE" || return 1
            install -Dm755 "$work/$name/usr/bin/$name" "$work/bin/$name" || return 1
            install -Dm644 "$work/$name/usr/share/licenses/$name/LICENSE" "$work/licenses/$name/LICENSE" || return 1
        fi

        flag=--version
        [ "$name" = serpantinum-audio ] && flag=version  # audio's CLI has no --version
        actual=$("$work/bin/$name" "$flag" 2>/dev/null) || actual=""  # a binary that fails here is broken
        actual=$(awk '{print $2; exit}' <<< "$actual")
        if [ "$actual" != "$version" ]; then
            echo "Bundled $name must match version $version (got ${actual:-nothing})." >&2
            return 1
        fi
    done

    for name in $(jq -r 'keys[]' "$manifest"); do
        # explicit returns: a caller using `||` or `if` switches set -e off inside this function
        install -Dm755 "$work/bin/$name" "$destination/bin/$name" || return 1
        install -Dm644 "$work/licenses/$name/LICENSE" "$destination/licenses/$name/LICENSE" || return 1
    done
)
