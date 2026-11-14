# fedora-bootc

A personal Fedora 45 (GNOME / Silverblue) bootc image, rebuilt daily by GitHub Actions
and pushed to `ghcr.io/<owner>/fedora-bootc`.

Includes: git, gcc/g++, make, cmake, autotools, gdb, Google Chrome, gtk-v4l,
gnome-tweaks, jetbrains-mono-fonts-all, gcolor3, emacs-nw, evtest, igt-gpu-tools (`intel_gpu_top`), dbus-daemon, vte291-devel, ripgrep, tig, tmux, mosh, glow, chezmoi,
Xournal++, qpdf, tesseract-osd, drm-utils, lm_sensors, ddcutil, android-tools, copr-cli,
EasyEffects, dconf-editor, NetBird (from NetBird's repo; service enabled, run
`netbird up` to log in), gh, ocrmypdf, VLC,
Audacity, GIMP, Visual Studio Code (from Microsoft's repo), full ffmpeg codecs,
VLC's extra codec plugins and the full Intel VA-API driver for hardware video decoding
(from [RPM Fusion](https://rpmfusion.org/); check with `vainfo`), Claude Code (stable channel, from
Anthropic's dnf repo), framework-system (`framework_tool`, from the
[Terra](https://terrapkg.com/) repo). `sshd` is enabled, and fingerprint authentication is on (enroll in Settings → Users).

Tags: `latest`, `45`, `45-YYYYMMDD`.

## Prerequisite: make the image pullable

After the first workflow run, open your GitHub profile → Packages → `fedora-bootc` →
Package settings and set visibility to **Public**, or log in on the target machine
(`sudo podman login ghcr.io`) so `bootc` can pull the image.

## Install from USB (recommended): Silverblue, then switch

This uses the stock interactive installer, so you pick the disk and create your user
as usual.

1. On another Fedora machine, install Fedora Media Writer (`sudo dnf install mediawriter`),
   have it download **Fedora Silverblue 45**, and write it to a USB stick.
2. Boot the target machine from the USB stick and install. Create your user (as an
   administrator) during first-boot setup.
3. Switch to this image and reboot:

   ```sh
   sudo bootc switch ghcr.io/<owner>/fedora-bootc:latest
   sudo systemctl reboot
   ```

4. Confirm with `bootc status`, then copy your SSH key over from another machine:
   `ssh-copy-id <user>@<host>`.

The same `bootc switch` command works on any existing Fedora Atomic or bootc machine;
existing users and data are kept.

## Install from USB: custom ISO of this image

> **Warning:** this ISO installs **unattended** and erases the target's disk without
> prompting. Disconnect any drives you want to keep.

On another Fedora machine, create `config.toml` with your user:

```toml
[[customizations.user]]
name = "adlr"
password = "changeme"           # change after first login
key = "ssh-ed25519 AAAA... adlr"
groups = ["wheel"]
```

Build the ISO:

```sh
mkdir -p output
sudo podman pull ghcr.io/<owner>/fedora-bootc:latest
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type anaconda-iso --rootfs btrfs \
  ghcr.io/<owner>/fedora-bootc:latest
```

Write `output/bootiso/install.iso` to a USB stick with Fedora Media Writer
("Select .iso file"), or with `dd`:

```sh
sudo dd if=output/bootiso/install.iso of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync
```

Use `--type qcow2` or `--type raw` instead of `anaconda-iso` for a VM disk image.

## Updates

Updates are manual. The image is rebuilt daily, but installed machines don't fetch or
apply it on their own (`bootc-fetch-apply-updates.timer` is disabled in the
Silverblue base). To update:

```sh
sudo bootc upgrade        # download the latest image; applied on next boot
sudo systemctl reboot
```

`bootc status` shows the booted image and any staged update. To go back to the
previous image, run `sudo bootc rollback` and reboot.

## Patched packages (COPR)

Packages with a patch in `patches/` are rebuilt with that patch in the
[andrewdelosreyes/gnome-patched](https://copr.fedorainfracloud.org/coprs/andrewdelosreyes/gnome-patched/)
COPR, and the image replaces the stock versions with them.

Before each image build, `scripts/build-patched.sh` runs inside the base image. For
each patched package it:

1. reads the version the base image ships, e.g. `vte291-0.84.1-1.fc45`;
2. skips it if the COPR already has `vte291-0.84.1-1.fc45.patched`;
3. otherwise downloads that exact SRPM from Koji, adds `.patched` to the release and
   the patch to the spec, checks the patch applies, and submits it to COPR.

The workflow waits for the COPR builds and fails if any of them fail, so the image isn't
built. In the Containerfile, every installed package that the COPR provides is upgraded
from the COPR only, and the build fails if a package in `patches/` didn't end up as a
`.patched` build.

**Patch names:** `patches/<source package>-<upstream version>.patch`, e.g.
`patches/libinput-1.32.0.patch`. If there's no patch for the exact version, the newest
patch for an older version is tried. To patch another package, add a file here.

**The kernel** (`patches/kernel-<version>.patch`) is handled a little differently:
kernel.spec doesn't apply extra `Patch` tags, so the patch replaces the spec's
(normally empty) `linux-kernel-test.patch`, and only the base kernel is built (no debug
variants, debuginfo, tools or UKI). The build still takes hours in COPR, and it reruns
every time Fedora updates the kernel. The image gets e.g. `7.3.3-300.fc45.patched`, and
its initramfs is regenerated during the image build. COPR kernels aren't signed with
Fedora's Secure Boot key, so the target machine needs Secure Boot disabled (or the kernel
signed with your own enrolled MOK key).

**Setup:** the workflow needs your COPR API token as the `COPR_CONFIG` repository secret
(Settings → Secrets and variables → Actions). Copy the config shown at
<https://copr.fedorainfracloud.org/api/> (the same content as `~/.config/copr`). COPR
tokens expire after 180 days, so renew the secret when they do.

**Testing locally** (dry run: builds the SRPMs and checks the patches apply, but doesn't
submit anything):

```sh
podman run --rm -v "$PWD:/src:z" quay.io/fedora/fedora-silverblue:45 \
  /src/scripts/build-patched.sh -n
```

To submit from your machine, add `-e COPR_CONFIG="$(cat ~/.config/copr)"` and drop `-n`.

## Desktop defaults (dconf)

Files in `files/dconf/` are installed to `/etc/dconf/db/local.d/` as system-wide
defaults; users' own settings still take precedence. To refresh the Ptyxis defaults
from your current setup:

```sh
dconf dump /org/gnome/Ptyxis/ \
  | sed -e 's|^\[/\]$|[org/gnome/Ptyxis]|;t' -e 's|^\[\(.*\)\]$|[org/gnome/Ptyxis/\1]|' \
  > files/dconf/50-ptyxis
```

The same works for other apps: dump their path and rewrite the section headers to
absolute paths (without the leading `/`) in a new `files/dconf/` keyfile.

## Notes

- Chrome lives in `/usr/lib/google`, with `/opt/google` symlinked to it at boot through
  tmpfiles.d, so it's part of the immutable image and updates with each build.
