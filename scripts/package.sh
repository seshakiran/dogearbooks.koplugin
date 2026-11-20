#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$repo_root/dist"}
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
archive="$output_dir/dogearbooks.koplugin.zip"
# Build a fresh archive so removed source files cannot linger in an older ZIP.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT INT TERM
(
    cd "$repo_root"
    zip -qr "$staging/dogearbooks.koplugin.zip" dogearbooks.koplugin -x '*/.DS_Store' '*/._*'
)
mv "$staging/dogearbooks.koplugin.zip" "$archive"
printf 'Created %s\n' "$archive"
