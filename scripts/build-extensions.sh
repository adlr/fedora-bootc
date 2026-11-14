#!/bin/bash
# Make sure the COPR has a package for the latest release of each GNOME Shell
# extension in extensions.txt, building it if needed.
#
# Run this inside the base image, which has gnome-extensions for packing:
#   podman run --rm -v "$PWD:/src:z" -e COPR_CONFIG \
#     quay.io/fedora/fedora-silverblue:45 /src/scripts/build-extensions.sh [-n]
#
# An extension's latest release is its highest vN tag, and N becomes the
# package version. The extension is built here from that tag, and its zip is
# the source of a noarch RPM that unpacks it into
# /usr/share/gnome-shell/extensions/<uuid>.
#
#   -n   dry run: build the zips and SRPMs, but don't submit
#
# COPR_CONFIG, if set, is written to ~/.config/copr (the copr-cli API token).
set -euo pipefail

COPR_PROJECT="${COPR_PROJECT:-andrewdelosreyes/gnome-patched}"
LIST="$(cd "$(dirname "$0")/.." && pwd)/extensions.txt"
WORK="${WORK:-$(mktemp -d)}"

DRY_RUN=no
if [ "${1:-}" = "-n" ]; then
  DRY_RUN=yes
fi

FEDORA="$(rpm -E %fedora)"
CHROOT="fedora-$FEDORA-$(uname -m)"
COPR_URL="https://download.copr.fedorainfracloud.org/results/$COPR_PROJECT/$CHROOT/"

log() { echo "==> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Highest vN tag in repository $1, e.g. v45
latest_tag() {
  git ls-remote --tags --refs "$1" 'v*' |
    sed -n 's|.*refs/tags/\(v[0-9]\+\)$|\1|p' | sort -V | tail -n1
}

# Whether the COPR has a build of package $1 at version $2
copr_has() {
  dnf -q repoquery --refresh --repofrompath="gnome-patched,$COPR_URL" \
    --repo=gnome-patched --arch=src --qf '%{version}\n' "$1" |
    grep -qxF "$2"
}

log "Installing build tools"
dnf install -y -q --setopt=install_weak_deps=False \
  copr-cli git make zip unzip gettext rpm-build python3 >/dev/null 2>&1 ||
  die "failed to install build tools"

# In bootc images /root points into /var and may not exist in a container
if [ ! -d ~ ]; then
  export HOME="$WORK/home"
  mkdir -p "$HOME"
fi

if [ -n "${COPR_CONFIG:-}" ]; then
  mkdir -p ~/.config
  printf '%s\n' "$COPR_CONFIG" > ~/.config/copr
fi

SRPMS=()
# Read on fd 3 so the commands in the loop can't consume the list
while read -r -u 3 pkg license url zip cmd; do
  [ -n "$pkg" ] && [ "${pkg:0:1}" != "#" ] || continue
  [ -n "$cmd" ] || die "incomplete line for $pkg in $LIST"

  tag="$(latest_tag "$url")"
  [ -n "$tag" ] || die "no vN tags in $url"
  version="${tag#v}"

  if copr_has "$pkg" "$version"; then
    log "$pkg-$version already in COPR"
    continue
  fi
  log "Building $pkg-$version from $url $tag"

  dir="$WORK/$pkg"
  rm -rf "$dir"
  mkdir -p "$dir/rpm" "$dir/out"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$url" "$dir/src"
  (cd "$dir/src" && eval "$cmd") >"$dir/build.log" 2>&1 ||
    { tail -n 30 "$dir/build.log" >&2; die "'$cmd' failed for $pkg"; }
  [ -f "$dir/src/$zip" ] || die "$cmd did not produce $zip for $pkg"
  cp "$dir/src/$zip" "$dir/rpm/"

  # Name, description and uuid from the extension's own metadata
  python3 -I - "$dir/rpm/${zip##*/}" "$dir/rpm/$pkg.spec" \
    "$pkg" "$version" "$license" "${url%.git}" <<'EOF'
import json, sys, time, zipfile
zpath, spec, pkg, version, license, url = sys.argv[1:]
with zipfile.ZipFile(zpath) as z:
    meta = json.loads(z.read('metadata.json'))
esc = lambda s: s.replace('%', '%%')
source = zpath.rsplit('/', 1)[-1]
date = time.strftime('%a %b %d %Y', time.gmtime())
packager = 'Andrew de los Reyes <adlr@rosaiclabs.com>'
with open(spec, 'w') as f:
    f.write(f'''\
%global uuid {meta['uuid']}

Name:           {pkg}
Version:        {version}
Release:        1%{{?dist}}
Summary:        GNOME Shell extension: {esc(meta['name'])}
License:        {license}
URL:            {url}
Source0:        {source}
BuildArch:      noarch
BuildRequires:  unzip
Requires:       gnome-shell

%description
{esc(meta.get('description', meta['name']))}

Built from {url} at tag v{version}.

%prep

%build

%install
dest=%{{buildroot}}%{{_datadir}}/gnome-shell/extensions/%{{uuid}}
mkdir -p "$dest"
unzip -q %{{SOURCE0}} -d "$dest"
chmod -R u=rwX,go=rX "$dest"

%files
%{{_datadir}}/gnome-shell/extensions/%{{uuid}}

%changelog
* {date} {packager} - {version}-1
- Built from tag v{version}
''')
EOF

  rpmbuild -bs --define "_sourcedir $dir/rpm" --define "_srcrpmdir $dir/out" \
    "$dir/rpm/$pkg.spec" >/dev/null
  srpm=("$dir/out/$pkg-$version"-*.src.rpm)
  [ -f "${srpm[0]}" ] || die "expected an SRPM for $pkg-$version, got: $(ls "$dir/out")"
  SRPMS+=("${srpm[0]}")
done 3<"$LIST"

if [ "${#SRPMS[@]}" = 0 ]; then
  log "All extensions are up to date"
  exit 0
fi

if [ "$DRY_RUN" = yes ]; then
  log "Dry run, not submitting:"
  printf '  %s\n' "${SRPMS[@]}" >&2
  exit 0
fi

[ -f ~/.config/copr ] || die "no COPR API token: set COPR_CONFIG or create ~/.config/copr"

# Waits for all builds; exits non-zero if any fail
log "Submitting to COPR $COPR_PROJECT ($CHROOT)"
copr-cli build -r "$CHROOT" "$COPR_PROJECT" "${SRPMS[@]}"
