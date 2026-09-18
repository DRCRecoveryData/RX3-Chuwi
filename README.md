# XDJ-RX3 Firmware Emulation on Chuwi MiniBook M3-8100Y

Running the Pioneer XDJ-RX3 v1.19 ARM32 firmware on a Chuwi MiniBook
M3-8100Y (Intel Core m3-8100Y, Ubuntu 26.04, 1200×1920 portrait touchscreen)
via QEMU user-mode emulation. Renders the RX3 UI to the panel, accepts
touch and keyboard input, and browses USB media.

This is a port of the Rx3-flx4 project (originally for Raspberry Pi 5 with
DDJ-FLX4) to AMD64 Linux. The firmware runs under `qemu-arm` via
`binfmt_misc`, which the kernel invokes transparently for ARM32 binaries.

---

## Tested on

| Component     | Value                                              |
|---------------|----------------------------------------------------|
| Device        | Chuwi MiniBook M3-8100Y                            |
| OS            | Ubuntu 26.04 LTS (Resolute), x86_64                |
| Kernel        | 7.0.0-30-generic                                   |
| Display       | i915drmfb, 1200×1920 portrait                      |
| Touchscreen   | Goodix Capacitive (auto-detected via udev)         |
| QEMU          | 10.2.1 (`qemu-user-binfmt`)                        |
| Cross-gcc     | 15.2.0 (`gcc-arm-linux-gnueabi`)                   |
| Presenter rot | 90                                                 |
| Bridge rot    | 90                                                 |

---

## What works

| Feature | Status |
|---------|--------|
| RX3 UI on panel, correct orientation | ✅ |
| Keyboard control (`rx3-control.py`) | ✅ |
| Touch (bottom overlay buttons) | ✅ |
| USB browsing via SOURCE → USB1 | ✅ |
| Autostart via systemd | ✅ |
| Audio | ❌ firmware gate (see below) |

---

## Quick install

```bash
chmod +x ~/install-chuwi.sh
~/install-chuwi.sh 2>&1 | tee ~/rx3-install.log
