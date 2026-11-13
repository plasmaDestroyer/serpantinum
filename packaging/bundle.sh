#!/usr/bin/env bash
set -euo pipefail

project=$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")
version=$(tr -d '[:space:]' < "$project/version.txt")
name="serpantinum-$version-x86_64-linux"
output=$(realpath -m "${1:-$project/dist/$name.tar.gz}")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/$name"
cp -a "$project/"{bin,src,config,compositors,install,packaging,version.txt,LICENSE.md} "$work/$name/"
source "$project/install/modules/bundle.sh"
bundle_daemons "$project" "$work/$name"

mkdir -p "$(dirname "$output")"
tar -czf "$work/bundle.tar.gz" -C "$work" "$name"
mv -- "$work/bundle.tar.gz" "$output"
(cd "$(dirname "$output")" && sha256sum "$(basename "$output")") > "$output.sha256"
echo "$output"
