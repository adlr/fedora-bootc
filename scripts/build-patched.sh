#!/bin/bash
# Make sure every package with a patch in patches/ has a patched build in COPR
# for the exact version shipped in the base image, building it if needed.
#
# Run this inside the base image so `rpm` reports the versions it ships:
#   podman run --rm -v "$PWD:/src:z" -e COPR_CONFIG \
#     quay.io/fedora/fedora-silverblue:45 /src/scripts/build-patched.sh [-n]
#
# Patches are named patches/<source package>-<upstream version>.patch. If no
# patch matches the image's version exactly, the newest older one is used.
#
#   -n   dry run: prepare SRPMs and check the patches apply, but don't submit
#
# COPR_CONFIG, if set, is written to ~/.config/copr (the copr-cli API token).
set -euo pipefail

COPR_PROJECT="${COPR_PROJECT:-andrewdelosreyes/gnome-patched}"
SUFFIX="${SUFFIX:-.patched}"
PATCH_DIR="$(cd "$(dirname "$0")/../patches" && pwd)"
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

# Source package NVR installed in this image, e.g. vte291-0.84.1-1.fc45
image_nvr() {
  rpm -qa --qf '%{SOURCERPM}\n' | grep -E "^$1-[^-]+-[^-]+\.src\.rpm$" |
    sort -u | sed 's/\.src\.rpm$//'
}

# Newest patches/<pkg>-<version>.patch whose version is <= $2
pick_patch() {
  local f v
  for f in "$PATCH_DIR/$1"-*.patch; do
    [ -e "$f" ] || continue
    v="${f##*/"$1"-}"
    v="${v%.patch}"
    # Skip other packages sharing the prefix (e.g. foo-libs-1.0.patch for foo)
    [[ "$v" =~ ^[0-9][^-]*$ ]] || continue
    if [ "$(printf '%s\n%s\n' "$v" "$2" | sort -V | tail -n1)" = "$2" ]; then
      echo "$v $f"
    fi
  done | sort -V -k1,1 | tail -n1 | cut -d' ' -f2-
}

copr_has() {
  dnf -q repoquery --refresh --repofrompath="gnome-patched,$COPR_URL" \
    --repo=gnome-patched --arch=src --qf '%{name}-%{version}-%{release}\n' "$1" |
    grep -qxF "$1"
}

# Collect versions before installing tools, which could pull in updates
declare -A NVR
for f in "$PATCH_DIR"/*.patch; do
  pkg="$(basename "${f%-*}")"
  [ -n "${NVR[$pkg]:-}" ] && continue
  nvr="$(image_nvr "$pkg")"
  [ -n "$nvr" ] || die "$pkg is not installed in the base image"
  [ "$(wc -l <<<"$nvr")" = 1 ] || die "multiple versions of $pkg in image: $nvr"
  NVR[$pkg]="$nvr"
done

log "Installing build tools"
dnf install -y -q --setopt=install_weak_deps=False \
  copr-cli koji python3-specfile rpm-build cpio dnf5-plugins >/dev/null 2>&1 ||
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
for pkg in "${!NVR[@]}"; do
  nvr="${NVR[$pkg]}"
  rest="${nvr#"$pkg"-}"
  version="${rest%-*}"
  release="${rest#*-}"
  target="$nvr$SUFFIX"

  if copr_has "$target"; then
    log "$target already in COPR"
    continue
  fi

  patch="$(pick_patch "$pkg" "$version")"
  [ -n "$patch" ] || die "no patch in $PATCH_DIR for $pkg <= $version"
  log "Building $target with $(basename "$patch")"

  dir="$WORK/$pkg"
  rm -rf "$dir"
  mkdir -p "$dir/src" "$dir/out" "$dir/build"
  (cd "$dir" && koji download-build -q --arch=src "$nvr")
  (cd "$dir/src" && rpm2cpio "../$nvr.src.rpm" | cpio -idm --quiet)
  if [ "$pkg" = kernel ]; then
    # kernel.spec applies its patches by hand, not with %autopatch, so an
    # added Patch tag would be ignored. It always applies the (normally
    # empty) linux-kernel-test.patch, which is meant for local patches.
    # Build only the base kernel (no debug variants, tools or selftests)
    # and skip debuginfo and the UKI, as `--with baseonly` etc. would.
    cp "$patch" "$dir/src/linux-kernel-test.patch"
    sed -i -e "s/^%define specrelease .*/&$SUFFIX/" \
      -e '1i %define _with_baseonly 1\n%define _without_debuginfo 1\n%define _without_efiuki 1\n%define _without_doc 1' \
      "$dir/src/$pkg.spec"
    grep -q "^%define specrelease .*$SUFFIX\$" "$dir/src/$pkg.spec" ||
      die "could not set the kernel release"
  else
    cp "$patch" "$dir/src/"

    python3 - "$dir/src/$pkg.spec" "${release%%.*}" "$SUFFIX" "$(basename "$patch")" <<'EOF'
import sys
from specfile import Specfile
path, relnum, suffix, patch = sys.argv[1:]
spec = Specfile(path)
if spec.raw_release.startswith('%autorelease'):
    spec.raw_release = f'{relnum}%{{?dist}}{suffix}'
else:
    spec.raw_release += suffix
with spec.patches() as patches:
    patches.append(patch)
spec.save()
EOF
  fi

  # kernel.spec's %prep looks for itself in %_specdir
  defs=(--define "_topdir $dir" --define "_sourcedir $dir/src" --define "_specdir $dir/src"
        --define "_srcrpmdir $dir/out" --define "_builddir $dir/build")
  # Check the patch applies now rather than after a long COPR build. %prep
  # can use macros from build dependencies, so install those first.
  dnf builddep -y -q "$dir/src/$pkg.spec" >"$dir/builddep.log" 2>&1 ||
    { tail -n 30 "$dir/builddep.log" >&2; die "failed to install build deps for $pkg"; }
  rpmbuild -bp "${defs[@]}" "$dir/src/$pkg.spec" >"$dir/prep.log" 2>&1 ||
    { tail -n 30 "$dir/prep.log" >&2; die "$(basename "$patch") does not apply to $nvr"; }
  rpmbuild -bs "${defs[@]}" "$dir/src/$pkg.spec" >/dev/null

  srpm="$dir/out/$target.src.rpm"
  [ -f "$srpm" ] || die "expected $srpm, got: $(ls "$dir/out")"
  SRPMS+=("$srpm")
done

if [ "${#SRPMS[@]}" = 0 ]; then
  log "All patched packages are up to date"
  exit 0
fi

if [ "$DRY_RUN" = yes ]; then
  log "Dry run, not submitting:"
  printf '  %s\n' "${SRPMS[@]}" >&2
  exit 0
fi

[ -f ~/.config/copr ] || die "no COPR API token: set COPR_CONFIG or create ~/.config/copr"

# Waits for all builds; exits non-zero if any fail. A kernel build can take
# hours, so allow more than the default 5h.
log "Submitting to COPR $COPR_PROJECT ($CHROOT)"
copr-cli build --timeout 36000 -r "$CHROOT" "$COPR_PROJECT" "${SRPMS[@]}"
