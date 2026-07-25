variant: flatcar
version: 1.0.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "${SSH_PUBLIC_KEY}"

storage:
  directories:
    - path: /opt/bin
      mode: 0755
    - path: /opt/router
      mode: 0755
    - path: /opt/Mullvad VPN/resources
      mode: 0755
    - path: /var/lib/mullvad-router
      mode: 0700
    - path: /etc/nftables
      mode: 0755

  links:
    - path: /etc/localtime
      target: /usr/share/zoneinfo/${TIMEZONE}
      overwrite: true

  files:
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: ${HOSTNAME}

    - path: /etc/sysctl.d/90-mullvad-router.conf
      mode: 0644
      contents:
        inline: |
          net.ipv4.ip_forward=1
          net.ipv6.conf.all.forwarding=1

    - path: /etc/mullvad-router.env
      mode: 0600
      contents:
        inline: |
          NETBIRD_SETUP_KEY='${NETBIRD_SETUP_KEY}'
          MULLVAD_ACCOUNT='${MULLVAD_ACCOUNT}'
          MULLVAD_COUNTRY='${MULLVAD_COUNTRY}'
          MULLVAD_CITY='${MULLVAD_CITY}'

    - path: /etc/nftables/netbird-mullvad-bypass.nft
      mode: 0644
      contents:
        inline: |
          table inet netbird_mullvad_bypass {
            chain input {
              type filter hook input priority -100; policy accept;
              iifname "wt0" ip saddr ${NETBIRD_OVERLAY_CIDR} ct mark set 0x00000f41 meta mark set 0x6d6f6c65
              udp dport ${NETBIRD_WG_PORT} ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            }

            chain output {
              type route hook output priority -100; policy accept;
              ip daddr ${NETBIRD_OVERLAY_CIDR} ct mark set 0x00000f41 meta mark set 0x6d6f6c65
              udp sport ${NETBIRD_WG_PORT} ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            }
          }

    - path: /opt/router/install-assets.sh
      mode: 0755
      contents:
        inline: |
          #!/usr/bin/env bash
          set -euo pipefail

          # Latest is fetched only for an unprovisioned appliance. Existing
          # binaries are retained across boots so a reboot is deterministic.
          if [[ -x /opt/bin/netbird && -x /opt/bin/mullvad && -x /opt/bin/mullvad-daemon && -x /opt/bin/mullvad-exclude ]]; then
            exit 0
          fi

          work="$(mktemp -d /var/tmp/mullvad-router.XXXXXX)"
          trap 'rm -rf "$work"' EXIT

          release_json="$(curl --fail --location --silent --show-error https://api.github.com/repos/netbirdio/netbird/releases/latest)"
          netbird_url="$(printf '%s\n' "$release_json" | sed -n 's/.*"browser_download_url": *"\([^"]*netbird_[^"]*_linux_amd64\.tar\.gz\)".*/\1/p' | head -n 1)"
          test -n "$netbird_url"
          curl --fail --location --silent --show-error "$netbird_url" -o "$work/netbird.tar.gz"
          mkdir "$work/netbird"
          bsdtar -xf "$work/netbird.tar.gz" -C "$work/netbird"
          install -m 0755 "$work/netbird/netbird" /opt/bin/netbird

          curl --fail --location --silent --show-error https://mullvad.net/download/app/deb/latest -o "$work/mullvad.deb"
          mkdir "$work/deb" "$work/mullvad-root"
          bsdtar -xf "$work/mullvad.deb" -C "$work/deb"
          data_archive="$(find "$work/deb" -maxdepth 1 -name 'data.tar.*' -print -quit)"
          test -n "$data_archive"
          bsdtar -xf "$data_archive" -C "$work/mullvad-root"

          install -m 0755 "$work/mullvad-root/usr/bin/mullvad" /opt/bin/mullvad
          install -m 0755 "$work/mullvad-root/usr/bin/mullvad-daemon" /opt/bin/mullvad-daemon
          install -m 4755 "$work/mullvad-root/usr/bin/mullvad-exclude" /opt/bin/mullvad-exclude
          install -m 0755 "$work/mullvad-root/opt/Mullvad VPN/resources/mullvad-setup" "/opt/Mullvad VPN/resources/mullvad-setup"
          install -m 0644 "$work/mullvad-root/opt/Mullvad VPN/resources/ca.crt" "/opt/Mullvad VPN/resources/ca.crt"
          install -m 0644 "$work/mullvad-root/opt/Mullvad VPN/resources/relays.json" "/opt/Mullvad VPN/resources/relays.json"

    - path: /opt/router/enroll.sh
      mode: 0700
      contents:
        inline: |
          #!/usr/bin/env bash
          set -euo pipefail
          # shellcheck disable=SC1091
          source /etc/mullvad-router.env

          state_dir=/var/lib/mullvad-router

          wait_for_cli() {
            local command_name="$1"
            local attempt
            for attempt in $(seq 1 60); do
              if /opt/bin/"$command_name" status >/dev/null 2>&1; then
                return 0
              fi
              sleep 1
            done
            echo "Timed out waiting for $command_name" >&2
            return 1
          }

          wait_for_cli mullvad
          wait_for_cli netbird

          if [[ ! -e "$state_dir/mullvad-enrolled" ]]; then
            /opt/bin/mullvad account login "$MULLVAD_ACCOUNT"
            /opt/bin/mullvad lan set allow
            /opt/bin/mullvad relay set location "$MULLVAD_COUNTRY" "$MULLVAD_CITY"
            /opt/bin/mullvad auto-connect set on
            /opt/bin/mullvad connect
            touch "$state_dir/mullvad-enrolled"
          fi

          if [[ ! -e "$state_dir/netbird-enrolled" ]]; then
            /opt/bin/netbird up --setup-key "$NETBIRD_SETUP_KEY"
            touch "$state_dir/netbird-enrolled"
          fi

systemd:
  units:
    - name: router-assets.service
      enabled: true
      contents: |
        [Unit]
        Description=Install latest NetBird and Mullvad assets on first boot
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        # Do not let a transient DHCP/DNS delay fail the whole boot graph.
        # Dependencies only continue after this command has completed once.
        ExecStart=/bin/bash -c 'until /opt/router/install-assets.sh; do sleep 15; done'
        Restart=on-failure
        RestartSec=15
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target

    - name: netbird-mullvad-bypass.service
      enabled: true
      contents: |
        [Unit]
        Description=Install the NetBird traffic bypass for Mullvad
        After=router-assets.service
        Requires=router-assets.service
        Before=mullvad-daemon.service netbird.service

        [Service]
        Type=oneshot
        ExecStartPre=-/usr/bin/nft delete table inet netbird_mullvad_bypass
        ExecStart=/usr/bin/nft -f /etc/nftables/netbird-mullvad-bypass.nft
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target

    - name: mullvad-daemon.service
      enabled: true
      contents: |
        [Unit]
        Description=Mullvad VPN daemon
        After=network-online.target router-assets.service netbird-mullvad-bypass.service
        Wants=network-online.target
        Requires=router-assets.service netbird-mullvad-bypass.service
        RequiresMountsFor=/opt/Mullvad\x20VPN/resources/

        [Service]
        Restart=always
        RestartSec=1
        ExecStart=/opt/bin/mullvad-daemon -vv --disable-stdout-timestamps
        Environment="MULLVAD_RESOURCE_DIR=/opt/Mullvad VPN/resources/"
        RestartKillSignal=SIGUSR1

        [Install]
        WantedBy=multi-user.target

    - name: netbird.service
      enabled: true
      contents: |
        [Unit]
        Description=NetBird
        After=network-online.target router-assets.service netbird-mullvad-bypass.service mullvad-daemon.service
        Wants=network-online.target
        Requires=router-assets.service netbird-mullvad-bypass.service mullvad-daemon.service

        [Service]
        Type=simple
        ExecStart=/opt/bin/mullvad-exclude /opt/bin/netbird service run
        Restart=always
        RestartSec=5
        StateDirectory=netbird
        RuntimeDirectory=netbird
        LogsDirectory=netbird

        [Install]
        WantedBy=multi-user.target

    - name: router-enroll.service
      enabled: true
      contents: |
        [Unit]
        Description=Enroll this router with Mullvad and NetBird
        After=mullvad-daemon.service netbird.service
        Requires=mullvad-daemon.service netbird.service

        [Service]
        Type=oneshot
        ExecStart=/opt/router/enroll.sh
        Restart=on-failure
        RestartSec=5
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
