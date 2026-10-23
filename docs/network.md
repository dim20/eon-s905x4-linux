# Network

What the box does out of the box, and the recipes for the three things
people ask for: a static address, mDNS, and WiFi. Everything below was
read from the eMMC system on **2026-10-23**.

---

## The default: DHCP on Ethernet

`systemd-networkd` is the network manager. It is enabled, and so is
`systemd-resolved`.

`/etc/systemd/network/10-eth0.network`:

```
[Match]
Name=eth0

[Network]
DHCP=yes
IgnoreCarrierLoss=5 seconds

[DHCPv4]
RouteMetric=4096

[IPv6AcceptRA]
RouteMetric=4096
# stable IPv6 interface identifier across images
Token=prefixstable,8b4d3eba-43f1-461e-b582-7a782646afd5
```

On the test network that gives:

```
eth0   UP   192.168.1.20/24
           2a02:586:.../64  fe80::ad:32ff:fe01:ab6b/64
gateway    192.168.1.1
speed      100 Mbps, full duplex
```

The Ethernet controller is the internal RMII PHY (`meson8b-dwmac`), not a
USB adapter.

### DNS

`/etc/resolv.conf` is a **static file** with `8.8.8.8` and `1.1.1.1`.
`systemd-resolved` reports `resolv.conf mode: foreign`, which means it is
not managing that file. The DHCP-provided DNS (`192.168.1.1`) is known to
resolved for the link, but the static file wins for ordinary lookups.

This is deliberate: the vendor's DHCP client did not write `resolv.conf`,
so `scripts/prepare-stick.sh` wrote a working one. If you would rather have
resolved manage it and use the DHCP server's DNS:

```sh
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved
```

That is a recipe, not the default.

### Hostname

The hostname is `eon-sc2` (`/etc/hostname`). The build now adds

```
127.0.1.1   eon-sc2
```

to `/etc/hosts`, so `hostname -f` and `getent hosts eon-sc2` work locally.
The vendor's `127.0.0.1 tvbox` line is left alone; it is harmless.

Without that line, `hostname -f` fails with `Name or service not known`,
and anything that wants the local FQDN breaks. It was missing in the
published v0.7-tty image; the next build carries the fix, and the smoke
test now checks it.

## A static address

Edit `/etc/systemd/network/10-eth0.network` and replace the `[Network]`
section:

```
[Match]
Name=eth0

[Network]
Address=192.168.1.50/24
Gateway=192.168.1.1
DNS=192.168.1.1
```

Then:

```sh
networkctl reload
networkctl reconfigure eth0
ip -br addr show eth0
```

**What was tested:** the mechanism, on `dummy0`, so the SSH session could
not drop. A `30-dummy0.network` with `Address=10.99.0.1/24` was applied
with `networkctl reload && networkctl reconfigure dummy0`; the address
appeared and `ping 10.99.0.1` worked; eth0 kept its DHCP address. The
config was then removed.

**What was not tested:** applying the exact `10-eth0.network` change live.
That drops the DHCP address, and if the static address is wrong the box
becomes unreachable. Do it with the serial console or the stick at hand.

## mDNS

mDNS is **off**: `resolvectl` shows `-mDNS` globally and on every link.
LLMNR is on.

To turn mDNS on:

```sh
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nMulticastDNS=yes\n' > /etc/systemd/resolved.conf.d/10-mdns.conf
systemctl restart systemd-resolved
resolvectl mdns          # should say yes
```

Avahi is **not installed**; this is resolved's built-in mDNS, enough for
`hostname.local` lookups between machines that implement it. It was not
tested end-to-end here because there is no second mDNS peer on the test
network.

## WiFi

**There is no `wlan0`.** The kernel has the vendor's `aml_wifi` and
`bcmdhd` (Broadcom) code built in, and the boot log shows it preallocating
memory, but no wireless interface appears. The vendor's firmware/NVRAM is
not shipped in this image.

`/etc/systemd/network/20-wlan0.network` is present and does DHCP with
`RouteMetric=4096`, so Ethernet is preferred whenever both are up. If you
supply a working vendor driver and firmware and `wlan0` appears, that file
applies without further changes.

WiFi is therefore **a user-supplied driver problem**, not a configuration
one. Do not expect the image to bring up wireless on its own.

## Bluetooth

The kernel has `bt_init`, `hci_uart` and the H4 protocol registered. There
is no `/sys/class/bluetooth` device and no Bluetooth tooling installed.
**Unverified.** Treat it as absent until someone tests a module and an
adapter.

## Security

The published password is `root` / `tvbox`, and root login over SSH is
enabled. Change it with `passwd` before the box is on a network you do not
trust. See the README's security note.

---

## Last verified

**2026-10-23**, on the eMMC system (`/dev/mmcblk0p2`):

- eth0 DHCP via systemd-networkd: `192.168.1.20/24`, gateway
  `192.168.1.1`, 100 Mbps full duplex, IPv4 and IPv6;
- `resolv.conf` static (`8.8.8.8`, `1.1.1.1`), mode `foreign`;
- `hostname -f` → `eon-sc2` after the `/etc/hosts` fix; `getent hosts
  eon-sc2` → `127.0.1.1`;
- static-address mechanism tested on `dummy0` (address applied, ping
  worked, eth0 unaffected); the exact eth0 change not applied live;
- mDNS off; recipe given; no second mDNS peer to test against;
- no `wlan0`; vendor firmware not shipped;
- Bluetooth unverified.
