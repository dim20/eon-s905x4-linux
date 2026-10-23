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
resolvectl mdns                 # Global: yes
resolvectl mdns eth0 yes        # the link can still report "no"
resolvectl mdns eth0            # Link 3 (eth0): yes
```

The per-link step is not cosmetic: after the global change, `eth0` still
reported `no` until it was set on the link. To make that survive a
restart, add the same setting to the network file:

```ini
# /etc/systemd/network/10-eth0.network
[Link]
MulticastDNS=yes
```

Avahi is **not installed**; this is resolved's built-in mDNS, enough for
`hostname.local` lookups between machines that implement it.

**Tested:** the global and per-link settings changed as above, and
`resolvectl status eth0` showed `+mDNS` while they were on. **Not
tested:** an actual name resolution against a second mDNS peer — there is
none on the test network.

## WiFi

**There is no `wlan0`, and on this box that is not a driver problem — the
SDIO bus never sees a card at all.**

What the software says:

- the board DTB enables `sdio@fe088000` (`status = "okay"`, 4-bit,
  `non-removable`, SDR104) with a `wifi@1` child
  (`compatible = "brcm,bcm4329-fmac"`);
- `aml_wifi` binds and drives its `power_on-gpios` (GPIOX_6) **high** —
  visible as `gpio-481 (GPIOX_6 |sdio_wifi) out hi`;
- the SDIO pins are correctly muxed (`GPIOX_0..5` → `fe088000.sdio`);
- `bcmdhd_init_wlan_mem` preallocates 8 MB.

What the hardware says:

- `/sys/bus/sdio/devices/` is **empty**; there is no `mmc1:0001` and no
  `mmc1: new ...` card line in `dmesg`;
- `mmc1` sits at the 400 kHz identification clock with power on — the
  controller tried to enumerate a card and got no answer;
- rebinding the SDIO host (forcing a rescan) changes nothing;
- **pulsing the power line** (unbind `aml_wifi`, drive GPIOX_6 low then
  high, rescan) still finds **no card**.

So the SoC side is ready and the chip does not answer on Linux — but the
module **is** present: it is soldered on the board, and it worked under
Android. This is therefore a **vendor Linux bring-up gap**, not absent
hardware.

What was checked and cleared:

- the DTB is not the difference: `sdio@fe088000` carries `card_type = <3>`,
  `non-removable`, `cap-sdio-irq`, `keep-power-in-suspend`, SDR104, and the
  Broadcom `wifi@1` child — the same properties as the vendor's Android DTB
  (`dev/vd/vendor.dts`);
- the SDIO pin groups match Android's (`sdio_d0..d3`, `clk`, `cmd`, plus the
  `GPIOX_4` clock-gate group), and they are muxed live;
- `aml_wifi` binds, drives `GPIOX_6` high, and programs the 32 kHz LPO PWM
  (`pwm_channel1_conf` / `pwm_channel2_conf` at ~32.7 kHz are requested and
  enabled);
- the defconfig has `CONFIG_MMC=y` and `CONFIG_AMLOGIC_WIFI=y`, and does
  **not** set `WIFI_POWER_INIT_OFF`, so the driver uses the Android-style
  "reset and power on" strategy.

What still looks different, and is where the effort would go:

- `/sys/bus/sdio/drivers/` is **empty** — no SDIO client driver is
  registered at all (the vendor's `bcmdhd` SDIO glue is the usual entry);
- the vendor's Android kernel and their Linux BSP are different trees; the
  Linux BSP may simply not have finished the bring-up for this module.

`/etc/systemd/network/20-wlan0.network` is present and does DHCP with
`RouteMetric=4096`, so Ethernet wins whenever both are up. If the Linux
bring-up is finished, that file applies with no change.

**Do not expect this image to bring up wireless.** The hardware is there;
the Linux driver path is not finished.

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
- mDNS off; the global + per-link recipe was applied and reverted, and
  `eth0` showed `+mDNS` while it was on; no second mDNS peer for an
  end-to-end lookup;
- no `wlan0`: the module **is present** (worked under Android) but the SDIO
  bus finds no card even after a host rebind and a power pulse; the DTB,
  pinmux, power GPIO and 32 kHz LPO PWM are all correct, so this is a
  vendor **Linux** bring-up gap, not missing hardware;
- Bluetooth unverified (no `/sys/class/bluetooth` device).
