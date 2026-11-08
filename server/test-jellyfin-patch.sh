#!/usr/bin/env bash
# Tests server/jellyfin-patch against a fake installation: stub jellyfin, dpkg-query,
# systemctl and a curl that serves "GitHub releases" from a local folder.
#
#   server/test-jellyfin-patch.sh out/jellyfin-patch-12.4.tar.gz
set -uo pipefail

tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
version=$(basename "$tarball" .tar.gz); version=${version#jellyfin-patch-}
script=$(cd "$(dirname "$0")" && pwd)/jellyfin-patch
t=$(cd "$(mktemp -d)" && pwd)   # pwd gives a colon-free path in Git Bash too (needed in PATH)
trap 'rm -rf "$t"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }

# Fake installation: a stock jellyfin that prints how it was started, its assemblies and web client.
mkdir -p "$t/bin" "$t/stock/bin" "$t/stock/web" "$t/releases/v$version" "$t/stubs"
for dll in $( (tar -xzOf "$tarball" manifest.json 2>/dev/null || tar -xzOf "$tarball" ./manifest.json) | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["server"]))') Other.dll; do
    echo "stock $dll" > "$t/stock/bin/$dll"
done
printf '#!/bin/bash\necho "started $0 $*"\n' > "$t/stock/bin/jellyfin"
chmod +x "$t/stock/bin/jellyfin"
echo "stock web" > "$t/stock/web/index.html"
cp "$tarball" "$tarball.sha256" "$t/releases/v$version/"

cat > "$t/stubs/dpkg-query" <<EOF
#!/bin/bash
echo -n "\$(cat "$t/installed-\${@: -1}")+ubu2404"
EOF
cat > "$t/stubs/systemctl" <<EOF
#!/bin/bash
case "\$*" in *ActiveState*) cat "$t/state" ;; *MainPID*) echo 0 ;; esac
EOF
cat > "$t/stubs/curl" <<EOF
#!/bin/bash
url=\${@: -1}; out=
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
file="$t/releases/\${url#https://github.com/*/*/releases/download/}"
[ -f "\$file" ] || exit 22
if [ -n "\$out" ]; then cp "\$file" "\$out"; else cat "\$file"; fi
EOF
chmod +x "$t/stubs/"*
echo inactive > "$t/state"

export PATH="$t/stubs:$PATH" JELLYFIN_PATCH_STATE="$t/state-dir" JELLYFIN_PATCH_STOCK_BIN="$t/stock/bin" \
    JELLYFIN_PATCH_STOCK_WEB="$t/stock/web" JELLYFIN_PATCH_STOCK_EXE="$t/stock/bin/jellyfin" JELLYFIN_PATCH_LOG="$t/log"
run_tree=$t/state-dir/run
installed() { echo -n "$1" > "$t/installed-jellyfin-server"; echo -n "${2:-$1}" > "$t/installed-jellyfin-web"; }

echo "== installed $version, build published"
installed "$version"
"$script" prepare > /dev/null
check "run tree prepared for $version" '[ "$(cat "$run_tree/VERSION")" = "$version" ]'
check "patched assemblies swapped in" '! grep -q stock "$run_tree"/bin/*.dll 2>/dev/null || [ "$(grep -l stock "$run_tree"/bin/*.dll)" = "$run_tree/bin/Other.dll" ]'
check "other files linked from stock" 'grep -q "stock Other.dll" "$run_tree/bin/Other.dll"'
check "stock files untouched" '[ "$(grep -l stock "$t"/stock/bin/*.dll | wc -l)" -ge 2 ]'
check "patched web client used" 'grep -q "<html" "$run_tree/web/index.html"'
started=$("$script" run --webdir=/usr/share/jellyfin/web --ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg)
check "starts the patched binary" '[[ $started == "started $run_tree/bin/jellyfin "* ]]'
check "points --webdir at the patched web" '[[ $started == *"--webdir=$run_tree/web --ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg" ]]'

echo "== same version again: only the checksum is fetched"
mv "$t/releases/v$version/$(basename "$tarball")" "$t/hidden.tar.gz"
"$script" prepare > /dev/null
check "still patched without downloading the tarball" '[ "$(cat "$run_tree/VERSION")" = "$version" ]'
mv "$t/hidden.tar.gz" "$t/releases/v$version/$(basename "$tarball")"

echo "== Jellyfin running: prepare leaves the run tree alone"
echo active > "$t/state"; installed 99.9
"$script" prepare > /dev/null
check "run tree unchanged while running" '[ "$(cat "$run_tree/VERSION")" = "$version" ]'
check "stale run tree not used for another installed version" '[[ $("$script" run --webdir=x) == "started $t/stock/bin/jellyfin --webdir=x" ]]'
echo inactive > "$t/state"

echo "== installed 99.9, no build published"
"$script" prepare > /dev/null
check "no run tree" '[ ! -e "$run_tree" ]'
check "starts stock with the original arguments" '[[ $("$script" run --webdir=/usr/share/jellyfin/web) == "started $t/stock/bin/jellyfin --webdir=/usr/share/jellyfin/web" ]]'

echo "== web package of another version"
installed "$version" 99.9
"$script" prepare > /dev/null
check "server patched, stock web" '[ "$(cat "$run_tree/VERSION")" = "$version" ] && grep -q "stock web" "$run_tree/web/index.html"'

echo "== disabled"
installed "$version"
"$script" disable > /dev/null && "$script" prepare > /dev/null
check "disabled: stock" '[ ! -e "$run_tree" ]'
"$script" enable > /dev/null && "$script" prepare > /dev/null
check "enabled again: patched" '[ "$(cat "$run_tree/VERSION")" = "$version" ]'

echo "== corrupted download"
"$script" disable > /dev/null; "$script" prepare > /dev/null
rm -rf "$t/state-dir/builds"
echo "0000  x" > "$t/releases/v$version/$(basename "$tarball").sha256"
"$script" enable > /dev/null; "$script" prepare > /dev/null
check "checksum mismatch: stock" '[ ! -e "$run_tree" ]'

echo
[ $failures = 0 ] && echo "all checks passed" || { echo "$failures check(s) failed"; cat "$t/log"; exit 1; }
