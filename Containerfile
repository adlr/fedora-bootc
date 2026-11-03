# Fedora 45 GNOME (Silverblue) bootc image with personal tooling.
# Swap to quay.io/fedora/fedora-bootc:45 for a headless/server base.
ARG BASE_IMAGE=quay.io/fedora/fedora-silverblue:45
FROM ${BASE_IMAGE}

# Google Chrome repository
COPY files/google-chrome.repo /etc/yum.repos.d/google-chrome.repo

# Claude Code repository (stable channel)
COPY files/claude-code.repo /etc/yum.repos.d/claude-code.repo

# Terra repository (provides framework-system). Per Terra's docs, the release
# and key packages are bootstrapped unsigned; later installs are verified.
RUN dnf install -y --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
        terra-release terra-gpg-keys && \
    dnf clean all

# Chrome installs into /opt, which on image-based systems lives under /var
# and is not part of the image. Install it, then relocate it into /usr and
# recreate the /opt path at boot with a tmpfiles.d symlink.
RUN set -eux; \
    mkdir -p /var/opt; \
    dnf install -y \
        git gcc gcc-c++ make cmake autoconf automake libtool pkgconf-pkg-config gdb \
        gtk-v4l gnome-tweaks jetbrains-mono-fonts-all gcolor3 \
        openssh-server \
        google-chrome-stable \
        claude-code \
        framework-system; \
    if [ -d /var/opt/google ]; then src=/var/opt/google; else src=/opt/google; fi; \
    mv "$src" /usr/lib/google; \
    echo 'L+ /var/opt/google - - - - /usr/lib/google' > /usr/lib/tmpfiles.d/google-chrome.conf; \
    rm -f /etc/cron.daily/google-chrome; \
    dnf clean all; \
    rm -rf /var/cache/* /var/log/* /var/lib/dnf

# Patched packages from COPR (built by scripts/build-patched.sh). Upgrade only
# installed packages that the COPR provides, taking new versions from it alone,
# then make sure everything in patches/ ended up patched.
COPY files/gnome-patched.repo /etc/yum.repos.d/gnome-patched.repo
COPY patches/ /tmp/patches/
RUN set -eux; \
    dnf -q repoquery --refresh --repo=gnome-patched --arch=noarch,x86_64 \
        --qf '%{name}\n' | sort -u > /tmp/copr-pkgs; \
    pkgs="$(rpm -qa --qf '%{name}\n' | sort -u | grep -Fxf /tmp/copr-pkgs)"; \
    dnf upgrade -y --from-repo=gnome-patched $pkgs; \
    for f in /tmp/patches/*.patch; do \
        pkg="$(basename "${f%-*}")"; \
        rpm -qa --qf '%{SOURCERPM}\n' | grep -E "^$pkg-[^-]+-[^-]+\.src\.rpm$" \
            | grep -q '\.patched\.src\.rpm$' \
            || { echo "$pkg is not a .patched build" >&2; exit 1; }; \
    done; \
    rm -rf /tmp/patches /tmp/copr-pkgs; \
    dnf clean all; \
    rm -rf /var/cache/* /var/log/* /var/lib/dnf

# System-wide dconf defaults (users can still override them)
COPY files/dconf/ /etc/dconf/db/local.d/
RUN dconf update

# Enable SSH by default
RUN systemctl enable sshd.service

# Local users are best created at install time (see README) so credentials
# don't end up in a public image.

RUN bootc container lint
