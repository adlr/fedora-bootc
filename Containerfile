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

# Launch Chrome with accessibility (AT-SPI) enabled from the desktop file.
RUN set -eux; \
    f=/usr/share/applications/google-chrome.desktop; \
    grep -q '^Exec=' "$f"; \
    sed -i 's|^Exec=|Exec=env ACCESSIBILITY_ENABLED=1 |' "$f"; \
    if grep '^Exec=' "$f" | grep -v '^Exec=env ACCESSIBILITY_ENABLED=1 '; then exit 1; fi

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

# neiro (laptop speaker DSP on PipeWire) from the RPM in its latest GitLab
# release. The RPM isn't signed; it's fetched over HTTPS from the project.
# GitLab rate-limits its API, hence the retries.
# Each user imports their tuning and enables it themselves (see README).
RUN set -eux; \
    url="$(curl -fsSL --retry 5 https://gitlab.com/api/v4/projects/wolf-yuan%2Fneiro/releases/permalink/latest \
        | python3 -c 'import json, sys; print(next(l["direct_asset_url"] for l in json.load(sys.stdin)["assets"]["links"] if l["name"].endswith(".x86_64.rpm")))')"; \
    dnf install -y "$url"; \
    dnf clean all; \
    rm -rf /var/cache/* /var/log/* /var/lib/dnf

# opencode CLI. It ships as a standalone binary (no dnf repo), so install the
# latest glibc x86_64 build into /usr/bin. `opencode upgrade` can't work on a
# read-only /usr; the image updates it with each build instead.
# opencode wants a writable HOME and TMPDIR for its data, log and scratch
# directories, so point both at one throwaway directory that's removed after the
# shell completions are generated: /tmp has to stay empty in the image.
RUN set -eux; \
    export HOME=/var/tmp/opencode-build TMPDIR=/var/tmp/opencode-build; \
    mkdir -p "$HOME"; \
    curl -fsSL --retry 5 -o "$HOME/opencode.tar.gz" \
        https://opencode.ai/update/api/latest/cli/opencode/opencode-linux-x64.tar.gz; \
    tar -xzf "$HOME/opencode.tar.gz" -C /usr/bin opencode; \
    chmod 0755 /usr/bin/opencode; \
    opencode --version; \
    opencode --completions bash \
        > /usr/share/bash-completion/completions/opencode; \
    opencode --completions fish \
        > /usr/share/fish/vendor_completions.d/opencode.fish; \
    rm -rf "$HOME"

# Patched packages and GNOME Shell extensions from COPR. COPR_SRPMS lists the
# exact source builds that scripts/build-patched.sh and
# scripts/build-extensions.sh made sure exist; without it, the newest builds are
# used. See scripts/install-copr.sh.
COPY files/gnome-patched.repo /etc/yum.repos.d/gnome-patched.repo
COPY scripts/install-copr.sh /tmp/copr/scripts/
COPY patches/ /tmp/copr/patches/
COPY extensions.txt /tmp/copr/
ARG COPR_SRPMS=
RUN set -eux; \
    /tmp/copr/scripts/install-copr.sh $COPR_SRPMS; \
    rm -rf /tmp/copr; \
    dnf clean all; \
    rm -rf /var/cache/* /var/log/* /var/lib/dnf

# System-wide dconf defaults (users can still override them)
COPY files/dconf/ /etc/dconf/db/local.d/
RUN dconf update

# Fingerprint login, unlock and sudo. fprintd is already in the base image,
# but its PAM module is only used with this authselect feature.
RUN authselect enable-feature with-fingerprint && authselect apply-changes
COPY files/fprintd-stop-before-sleep.conf \
    /usr/lib/systemd/system/fprintd.service.d/50-stop-before-sleep.conf

# Log what woke the system from sleep (journalctl -t log-wake-source)
COPY --chmod=0755 files/log-wake-source /usr/lib/systemd/system-sleep/log-wake-source

# Keep the touchpad from waking the system while the lid is closed
COPY files/touchpad-wake-lid.service /usr/lib/systemd/system/touchpad-wake-lid.service
RUN systemctl enable touchpad-wake-lid.service

# Enable SSH and NetBird by default
RUN systemctl enable sshd.service netbird.service

# Local users are best created at install time (see README) so credentials
# don't end up in a public image.

RUN bootc container lint
