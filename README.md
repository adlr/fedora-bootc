# fedora-bootc

A personal Fedora 45 (GNOME / Silverblue) bootc image, rebuilt daily by GitHub Actions
and pushed to `ghcr.io/<owner>/fedora-bootc`.

Includes: git, gcc/g++, make, cmake, autotools, gdb, Google Chrome, gtk-v4l,
gnome-tweaks, jetbrains-mono-fonts-all, gcolor3. `sshd` is enabled.

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

Installed machines pick up the daily builds through `bootc-fetch-apply-updates.timer`,
which by default applies the update and reboots. To update manually instead:

```sh
sudo systemctl disable --now bootc-fetch-apply-updates.timer
sudo bootc upgrade && sudo systemctl reboot
```

## Notes

- Chrome lives in `/usr/lib/google`, with `/opt/google` symlinked to it at boot through
  tmpfiles.d, so it's part of the immutable image and updates with each build.
