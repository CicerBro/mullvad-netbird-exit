# Mullvad NetBird exit router

A disposable Flatcar VM that acts as a NetBird exit node. NetBird's encrypted peer transport and overlay-host traffic stay on the normal LAN/WAN path; forwarded exit traffic goes through the headless Mullvad daemon.

## What this provisions

- Flatcar configuration through Butane and Ignition.
- The latest NetBird amd64 release, fetched once on first boot.
- The latest Mullvad Debian package, extracted with Flatcar's `bsdtar` into `/opt`.
- Mullvad daemon and CLI without the GUI.
- NetBird started through `mullvad-exclude`.
- IPv4 and IPv6 forwarding.
- Mullvad local-network sharing, automatic connection, account login, and relay location.
- NetBird setup-key enrollment.
- The proven nftables bypass: `100.115.0.0/16` on `wt0` and NetBird UDP port `51820` use Mullvad's documented bypass marks. Forwarded traffic is deliberately not bypassed.

## Secrets

`.env`, `router.bu`, and `router.ign` contain credentials and are ignored by Git. Use a one-off NetBird setup key. Treat the Mullvad account number as a secret.

Edit `.env` before building:

```sh
HOSTNAME=mullvad-exit
SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@example"
NETBIRD_SETUP_KEY=...
NETBIRD_OVERLAY_CIDR=100.115.0.0/16
NETBIRD_WG_PORT=51820
MULLVAD_ACCOUNT=...
MULLVAD_COUNTRY=de
MULLVAD_CITY=ber
```

`MULLVAD_COUNTRY` and `MULLVAD_CITY` are passed to `mullvad relay set location`.

## Build

Requirements on your machine: Docker and `envsubst` (`gettext`).

```sh
cd /path/to/mullvad-netbird-exit
chmod +x build.sh
./build.sh
```

The script uses an explicit `envsubst` variable allow-list so shell variables inside the provisioned scripts are preserved. It then runs the official Butane container with strict validation and writes `router.ign`.

## Install on TrueNAS

Download the [Flatcar Stable ISO](https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_iso_image.iso) and attach it as a CD-ROM.

### VM settings

| Setting | Value |
| --- | --- |
| CPU | 1 vCPU |
| RAM during ISO install | 2 GB minimum |
| RAM after installation | 1 GB recommended, or test 512 MB |
| Disk | 10 GB VirtIO |
| Network | VirtIO NIC on the LAN |
| Boot mode | Legacy BIOS |
| Secure Boot | Off |

Flatcar's ISO requires 2 GB RAM to boot and does not support UEFI boot. After the ISO is removed, reduce the VM to 1 GB RAM. A 512 MB runtime allocation may also work for this dedicated router, but validate a reboot and normal exit-node traffic before keeping that lower limit.

### Installation

1. Boot the ISO. The ISO uses the VGA/VNC console, which is expected. Its serial console may not be usable.
2. The ISO environment does not provide a convenient Ignition URL workflow and may not include `curl`. In the VNC console, find the DHCP address, set a temporary password, and start SSH:

```sh
ip -br addr
sudo passwd core
sudo systemctl start sshd
```

3. From your machine, transfer the generated Ignition file over SSH:

```sh
cd /path/to/mullvad-netbird-exit
scp router.ign core@VM_LAN_IP:/home/core/router.ign
```

4. Back in VNC, confirm that `/dev/vda` is the empty 10 GB VM disk, then install:

```sh
lsblk
sudo flatcar-install -d /dev/vda -C stable -i /home/core/router.ign
sudo poweroff
```

5. Remove the ISO and boot the VM from the VirtIO disk. Ignition runs once on this first installed boot.
6. The temporary ISO password is not normally carried to the newly installed VM. If a password is nevertheless present and you deliberately want an empty local password, run this on the installed VM:

```sh
sudo passwd -d core
```

This permits passwordless local/VNC login. It is not needed for SSH-key login and is less secure. To disable password login instead, use `sudo passwd -l core`.
7. In NetBird, add this peer as an exit node, keep masquerading enabled, and set Auto Apply according to preference.

## Validation

After first boot, use SSH. Keep the TrueNAS VNC console available until the LAN and NetBird paths are confirmed.

```sh
systemctl status router-assets netbird-mullvad-bypass mullvad-daemon netbird router-enroll
/opt/bin/mullvad status
/opt/bin/netbird status -d
sudo nft list table inet netbird_mullvad_bypass
```

From a client after selecting the exit node:

```sh
curl https://am.i.mullvad.net/connected
```

It should report a Mullvad relay IP. Direct NetBird access to the router's overlay address should remain available.

## Operations

The first-boot asset service intentionally preserves installed binaries on later boots. This avoids silently changing the router because it rebooted. During initial provisioning it waits and retries after temporary DHCP, DNS, or network failures before allowing dependent services to start. To refresh to current upstream releases deliberately, remove the installed binaries and restart the asset service from the serial console, then restart Mullvad and NetBird. The enrollment service waits for both daemons and retries safely when a daemon is still coming up.

For host inspection, use Flatcar Toolbox rather than modifying the immutable host OS:

```sh
/usr/bin/toolbox
dnf -y install htop
htop
```

## Recovery

Enrollment is guarded by marker files in `/var/lib/mullvad-router`. If a deployment is interrupted before a marker is created, the next start retries it. To deliberately re-enroll, stop the affected service, remove its marker, and start `router-enroll.service` again. For a fresh, disposable deployment, rebuild and install a new Flatcar VM.
