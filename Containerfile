# Fedora 45 GNOME (Silverblue) bootc image with personal tooling.
# Swap to quay.io/fedora/fedora-bootc:45 for a headless/server base.
ARG BASE_IMAGE=quay.io/fedora/fedora-silverblue:45
FROM ${BASE_IMAGE}

# Google Chrome repository
COPY files/google-chrome.repo /etc/yum.repos.d/google-chrome.repo

# Claude Code repository (stable channel)
COPY files/claude-code.repo /etc/yum.repos.d/claude-code.repo

# Visual Studio Code repository
COPY files/vscode.repo /etc/yum.repos.d/vscode.repo

# NetBird repository
COPY files/netbird.repo /etc/yum.repos.d/netbird.repo

# Terra repository (provides framework-system). Per Terra's docs, the release
# and key packages are bootstrapped unsigned; later installs are verified.
RUN dnf install -y --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
        terra-release terra-gpg-keys && \
    dnf clean all

# Chrome installs into /opt, which on image-based systems lives under /var
# and is not part of the image. Install it, then relocate it into /usr and
# recreate the /opt path at boot with a tmpfiles.d symlink.
# Xournal++ recommends TeX Live (~215 MB) for its optional LaTeX tool; skip it.
RUN set -eux; \
    mkdir -p /var/opt; \
    dnf install -y --exclude='texlive*' \
        git gcc gcc-c++ make cmake autoconf automake libtool pkgconf-pkg-config gdb \
        gtk-v4l gnome-tweaks jetbrains-mono-fonts-all gcolor3 \
        openssh-server \
        google-chrome-stable \
        claude-code \
        emacs-nw evtest igt-gpu-tools dbus-daemon vte291-devel \
        gh ocrmypdf vlc audacity gimp \
        code \
        ripgrep tig tmux mosh glow chezmoi \
        xournalpp qpdf tesseract-osd \
        drm-utils lm_sensors ddcutil android-tools \
        copr-cli easyeffects dconf-editor \
        framework-system; \
    if [ -d /var/opt/google ]; then src=/var/opt/google; else src=/opt/google; fi; \
    mv "$src" /usr/lib/google; \
    echo 'L+ /var/opt/google - - - - /usr/lib/google' > /usr/lib/tmpfiles.d/google-chrome.conf; \
    rm -f /etc/cron.daily/google-chrome; \
    dnf clean all; \
    rm -rf /var/cache/* /var/log/* /var/lib/dnf

# NetBird's RPM ships no systemd unit; its %post generates one with
# `netbird service install`, then fails to enable/start it without a running
# systemd. So install without scripts and generate the unit ourselves:
# /run/systemd/system makes NetBird think systemd is running. It writes the
# unit and then fails to enable it, so check the file instead of the exit code.
# Remove /run/systemd/system afterwards, or later `systemctl` calls in the
# build will also think systemd is running and fail.
# The env file may hold a PIN, so restrict it as the package script does.
RUN set -eux; \
    dnf install -y --setopt=tsflags=noscripts netbird; \
    chmod 0600 /etc/sysconfig/netbird; \
    mkdir -p /run/systemd/system; \
    netbird service install || true; \
    rmdir /run/systemd/system; \
    rmdir --ignore-fail-on-non-empty /run/systemd; \
    test -f /etc/systemd/system/netbird.service; \
    mv /etc/systemd/system/netbird.service /usr/lib/systemd/system/netbird.service; \
    echo 'd /var/log/netbird 0755 root root -' > /usr/lib/tmpfiles.d/netbird.conf; \
    dnf clean all; \
    rm -rf /var/cache/* /var/log/* /var/lib/dnf

# RPM Fusion for full codec support: swap Fedora's patent-limited ffmpeg-free
# and Intel VA-API driver for RPM Fusion's full versions, and add VLC's extra
# codec plugins. libva-utils provides `vainfo` to check hardware decoding.
RUN set -eux; \
    dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"; \
    dnf swap -y ffmpeg-free ffmpeg --allowerasing; \
    dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing; \
    dnf install -y vlc-plugins-freeworld libva-utils; \
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

# Fingerprint login, unlock and sudo. fprintd is already in the base image,
# but its PAM module is only used with this authselect feature.
RUN authselect enable-feature with-fingerprint && authselect apply-changes

# Enable SSH and NetBird by default
RUN systemctl enable sshd.service netbird.service

# Local users are best created at install time (see README) so credentials
# don't end up in a public image.

RUN bootc container lint
