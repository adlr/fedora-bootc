# fedora-bootc

A personal Fedora 45 (GNOME / Silverblue) bootc image, rebuilt daily by GitHub Actions
and pushed to `ghcr.io/<owner>/fedora-bootc`.

Includes: git, gcc/g++, make, cmake, autotools, gdb, Google Chrome, gtk-v4l,
gnome-tweaks, jetbrains-mono-fonts-all, gcolor3. `sshd` is enabled.

Tags: `latest`, `45`, `45-YYYYMMDD`.

## Switching an existing Fedora Atomic / bootc machine

```sh
sudo bootc switch ghcr.io/<owner>/fedora-bootc:latest
sudo systemctl reboot
```

From then on, `bootc upgrade` (or the automatic `bootc-fetch-apply-updates.timer`)
pulls the daily builds.

## Fresh install with a local user (ISO / disk image)

Create `config.toml`:

```toml
[[customizations.user]]
name = "adlr"
password = "changeme"           # optional
key = "ssh-ed25519 AAAA... adlr"
groups = ["wheel"]
```

Then build an installer ISO (or use `--type qcow2` / `raw` for a VM disk):

```sh
sudo podman pull ghcr.io/<owner>/fedora-bootc:latest
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./config.toml:/config.toml:ro -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type anaconda-iso --rootfs btrfs \
  ghcr.io/<owner>/fedora-bootc:latest
```

The Anaconda ISO also lets you create the user interactively during install.

## Notes

- After the first push, set the GHCR package's visibility to public (or log in on the
  target machine) so `bootc` can pull it.
- Chrome lives in `/usr/lib/google`, with `/opt/google` symlinked to it at boot through
  tmpfiles.d, so it's part of the immutable image and updates with each build.
