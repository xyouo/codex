#!/usr/bin/env bash
#
# Build a flat, self-use APT repository from one release asset directory.
# Release assets are deliberately not copied into git.

set -Eeuo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "usage: $0 <release-dir> <site-dir> <repository-url>" >&2
    exit 64
fi

release_dir="$1"
site_dir="$2"
repository_url="${3%/}/"

[[ -d "$release_dir" ]] || {
    echo "error: release asset directory does not exist: $release_dir" >&2
    exit 66
}
[[ -f "$release_dir/SHA256SUMS" ]] || {
    echo "error: release assets have no SHA256SUMS" >&2
    exit 66
}
[[ "$repository_url" =~ ^https://[^[:space:]]+/$ ]] || {
    echo "error: repository URL must be an HTTPS URL ending in /: $repository_url" >&2
    exit 65
}

for tool in dpkg-scanpackages gzip xz sha256sum; do
    command -v "$tool" >/dev/null || {
        echo "error: $tool is not installed" >&2
        exit 69
    }
done

(
    cd "$release_dir"
    sha256sum --check --strict SHA256SUMS
)

architectures=(iphoneos-arm64 iphoneos-arm64e)
shopt -s nullglob
debs=()
for architecture in "${architectures[@]}"; do
    debs+=("$release_dir"/*_"$architecture".deb)
done
shopt -u nullglob
((${#debs[@]} == 2)) || {
    echo "error: expected exactly two release packages, found ${#debs[@]}" >&2
    exit 65
}

mkdir -p "$site_dir/pool"
find "$site_dir/pool" -maxdepth 1 -type f -name '*.deb' -delete
for package in "${debs[@]}"; do
    install -m 0644 "$package" "$site_dir/pool/"
done

(
    cd "$site_dir"
    dpkg-scanpackages --multiversion pool /dev/null >Packages
    gzip -9nc Packages >Packages.gz
    xz -9ec Packages >Packages.xz
)

mapfile -t indexed_architectures < <(
    awk '$1 == "Architecture:" { print $2 }' "$site_dir/Packages" | sort -u
)
for architecture in "${architectures[@]}"; do
    printf '%s\n' "${indexed_architectures[@]}" | grep -Fxq "$architecture" || {
        echo "error: Packages index is missing $architecture" >&2
        exit 65
    }
done

printf 'deb [trusted=yes] %s ./\n' "$repository_url" >"$site_dir/source.list"

{
    printf 'Origin: xyouo\n'
    printf 'Label: xyouo Codex\n'
    printf 'Suite: stable\n'
    printf 'Codename: ios\n'
    printf 'Architectures: %s\n' "${architectures[*]}"
    printf 'Components: main\n'
    printf 'Description: Self-use Codex packages for jailbroken iOS\n'
    printf 'Date: '
    LC_ALL=C date -Ru
    printf 'Acquire-By-Hash: no\n'
    printf 'SHA256:\n'
    for index in Packages Packages.gz Packages.xz; do
        printf ' %s %s %s\n' \
            "$(sha256sum "$site_dir/$index" | awk '{print $1}')" \
            "$(stat -c %s "$site_dir/$index")" \
            "$index"
    done
} >"$site_dir/Release"

echo "built APT repository at $site_dir"
echo "source: $(cat "$site_dir/source.list")"
