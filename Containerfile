# Fedora 45 GNOME (Silverblue) bootc image with personal tooling.
# Swap to quay.io/fedora/fedora-bootc:45 for a headless/server base.
ARG BASE_IMAGE=quay.io/fedora/fedora-silverblue:45
FROM ${BASE_IMAGE}

# Google Chrome repository
COPY files/google-chrome.repo /etc/yum.repos.d/google-chrome.repo

# Chrome installs into /opt, which on image-based systems lives under /var
# and is not part of the image. Install it, then relocate it into /usr and
# recreate the /opt path at boot with a tmpfiles.d symlink.
RUN set -eux; \
    mkdir -p /var/opt; \
    dnf install -y \
        git gcc gcc-c++ make cmake autoconf automake libtool pkgconf-pkg-config gdb \
        gtk-v4l gnome-tweaks jetbrains-mono-fonts-all gcolor3 \
        openssh-server \
        google-chrome-stable; \
    if [ -d /var/opt/google ]; then src=/var/opt/google; else src=/opt/google; fi; \
    mv "$src" /usr/lib/google; \
    echo 'L+ /var/opt/google - - - - /usr/lib/google' > /usr/lib/tmpfiles.d/google-chrome.conf; \
    rm -f /etc/cron.daily/google-chrome; \
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
