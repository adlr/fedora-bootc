#!/bin/bash
# Install the COPR's patched packages and extensions during the image build.
#
#   install-copr.sh [SRPM...]
#
# Each argument is a source package build in the COPR, as listed by
# build-patched.sh and build-extensions.sh, e.g. vte291-0.84.1-1.fc45.patched.
# Installed packages built from the same source are upgraded to exactly that
# build. If none are installed (an extension, or a patched package the base
# image doesn't ship), the package named after the source is installed.
# Without arguments, the newest COPR build of each package in patches/ and
# extensions.txt is used, for local builds.
#
# Every package in patches/ and extensions.txt must be covered, and afterwards
# every installed package that a build provides must come from exactly that
# build. (Packages the build doesn't provide are left alone, e.g. kernel-tools,
# which the base-only kernel build doesn't produce.)
set -euo pipefail

REPO=gnome-patched
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

# Source packages that must come from the COPR
expected() {
  local f
  for f in "$ROOT"/patches/*.patch; do
    [ -e "$f" ] && basename "${f%-*}"
  done
  sed 's/#.*//' "$ROOT/extensions.txt" | awk 'NF { print $1 }'
}
mapfile -t names < <(expected | sort -u)

if [ $# = 0 ]; then
  mapfile -t srpms < <(dnf -q repoquery --refresh --repo="$REPO" --arch=src \
    --latest-limit=1 --qf '%{name}-%{version}-%{release}\n' "${names[@]}")
  set -- "${srpms[@]}"
fi

for name in "${names[@]}"; do
  for srpm in "$@"; do
    [ "${srpm%-*-*}" = "$name" ] && continue 2
  done
  die "no COPR build given for $name"
done

# Binary packages in the COPR: source rpm, name, NEVRA
bins="$(mktemp)"
dnf -q repoquery --refresh --repo="$REPO" --arch="noarch,$(uname -m)" \
  --qf '%{sourcerpm} %{name} %{name}-%{version}-%{release}.%{arch}\n' >"$bins"

upgrade=()
install=()
for srpm in "$@"; do
  src="${srpm%-*-*}"
  found=no
  while read -r name nevra; do
    if rpm -q "$name" >/dev/null; then
      upgrade+=("$nevra")
      found=yes
    elif [ "$name" = "$src" ]; then
      main="$nevra"
    fi
  done < <(awk -v s="$srpm.src.rpm" '$1 == s { print $2, $3 }' "$bins")
  if [ "$found" = no ]; then
    [ -n "${main:-}" ] || die "no package $src from $srpm in the COPR"
    install+=("$main")
  fi
  unset main
done

# Upgrade rather than install, so the kernel is replaced instead of being
# installed alongside the old one
if [ "${#upgrade[@]}" != 0 ]; then
  dnf upgrade -y --from-repo="$REPO" "${upgrade[@]}"
fi
if [ "${#install[@]}" != 0 ]; then
  dnf install -y --from-repo="$REPO" "${install[@]}"
fi

for srpm in "$@"; do
  while read -r name; do
    got="$(rpm -q --qf '%{SOURCERPM}\n' "$name" 2>/dev/null)" || continue
    [ "$got" = "$srpm.src.rpm" ] || die "$name comes from $(paste -sd ' ' <<<"$got"), not $srpm"
  done < <(awk -v s="$srpm.src.rpm" '$1 == s { print $2 }' "$bins" | sort -u)
done
rm -f "$bins"

# rpm-ostree's kernel-install hook (layout=ostree) runs depmod and dracut into
# /usr/lib/modules/<kver>/initramfs.img. Check that there's exactly one kernel
# and that it got an initramfs.
kver="$(ls /usr/lib/modules)"
[ "$(wc -l <<<"$kver")" = 1 ] || die "multiple kernels: $kver"
[ -s "/usr/lib/modules/$kver/initramfs.img" ] || die "no initramfs for $kver"
