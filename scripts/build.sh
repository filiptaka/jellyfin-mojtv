#!/usr/bin/env bash
# Builds the moj.tv patch for one upstream Jellyfin release.
#
#   scripts/build.sh 12.4 out
#
# Clones jellyfin and jellyfin-web at tag v<version>, applies patches/, and writes
# out/jellyfin-patch-<version>.tar.gz (+ .sha256) containing:
#   manifest.json  version, source, built, server (patched assemblies), web (true/false)
#   server/        the assemblies of the projects that patches/jellyfin changes
#   web/           the complete patched web client
# A part whose patch is already included upstream is left out.
set -euo pipefail

version=${1:?usage: build.sh VERSION OUTDIR}
out=${2:?usage: build.sh VERSION OUTDIR}
[[ $version =~ ^[0-9]{1,3}(\.[0-9]{1,4}){1,3}$ ]] || { echo "invalid version $version" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/stage
mkdir -p "$stage/server"

# The patches are part of upstream once these files mention the new options.
server_marker=MediaBrowser.Model/Configuration/ServerConfiguration.cs
web_marker=src/apps/dashboard/routes/libraries/display.tsx
marker_text=DisplayLatestEpisodes

clone() {
    git clone -q --filter=blob:none --branch "v$version" "https://github.com/jellyfin/$1.git" "$work/$1"
}

# git am keeps the original authors and can fall back to a 3-way merge; it fails loudly on conflicts.
apply_patches() {
    git -C "$1" -c user.name=build -c user.email=build@localhost am --3way --quiet "${@:2}"
}

clone jellyfin
clone jellyfin-web
server=false
web=false

if grep -q "$marker_text" "$work/jellyfin/$server_marker"; then
    echo "jellyfin $version already includes the server patch"
else
    apply_patches "$work/jellyfin" "$root"/patches/jellyfin/*.patch
    server=true
fi

if grep -q "$marker_text" "$work/jellyfin-web/$web_marker"; then
    echo "jellyfin-web $version already includes the web patch"
else
    apply_patches "$work/jellyfin-web" "$root"/patches/jellyfin-web/*.patch
    # Translations are merged rather than patched: upstream rewrites these files often.
    node "$root/scripts/merge-strings.mjs" "$work/jellyfin-web/src/strings" "$root/patches/jellyfin-web/strings"
    web=true
fi

assemblies=()
if [ "$server" = true ]; then
    (cd "$work/jellyfin" && dotnet test tests/Jellyfin.Server.Implementations.Tests -c Release --nologo -v quiet)
    dotnet publish "$work/jellyfin/Jellyfin.Server/Jellyfin.Server.csproj" -c Release -r linux-x64 --self-contained \
        -p:DebugSymbols=false -p:DebugType=none --nologo -v quiet -o "$work/publish"

    # Ship the assemblies of every project that the server patches touch (tests excluded).
    for file in $(sed -n 's#^diff --git a/\([^ ]*\) .*#\1#p' "$root"/patches/jellyfin/*.patch | grep -v '^tests/' | sort -u); do
        dir=$(dirname "$file")
        while [ "$dir" != . ] && ! ls "$work/jellyfin/$dir"/*.csproj >/dev/null 2>&1; do dir=$(dirname "$dir"); done
        [ "$dir" != . ] || { echo "no project for $file" >&2; exit 1; }
        project=$(ls "$work/jellyfin/$dir"/*.csproj | head -n1)
        name=$(sed -n 's#.*<AssemblyName>\(.*\)</AssemblyName>.*#\1#p' "$project" | head -n1)
        assemblies+=("${name:-$(basename "$project" .csproj)}.dll")
    done
    mapfile -t assemblies < <(printf '%s\n' "${assemblies[@]}" | sort -u)
    for assembly in "${assemblies[@]}"; do
        cp "$work/publish/$assembly" "$stage/server/"
    done
fi

if [ "$web" = true ]; then
    (cd "$work/jellyfin-web" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error && npm run build:production --silent)
    cp -r "$work/jellyfin-web/dist" "$stage/web"
fi

source=$(git -C "$root" describe --always --dirty 2>/dev/null || echo unknown)
VERSION=$version SOURCE=$source WEB=$web ASSEMBLIES="${assemblies[*]:-}" node -e '
    const e = process.env;
    console.log(JSON.stringify({
        version: e.VERSION,
        source: e.SOURCE,
        built: new Date().toISOString(),
        server: e.ASSEMBLIES ? e.ASSEMBLIES.split(" ") : [],
        web: e.WEB === "true"
    }, null, 2));' > "$stage/manifest.json"

tarball=jellyfin-patch-$version.tar.gz
(cd "$stage" && tar -czf "$out/$tarball" -- *)
(cd "$out" && sha256sum "$tarball" > "$tarball.sha256")
echo "built $out/$tarball"
cat "$stage/manifest.json"
