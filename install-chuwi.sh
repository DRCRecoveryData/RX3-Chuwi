#!/bin/bash
# install-chuwi.sh
# Complete installer for XDJ-RX3 firmware emulation on Chuwi MiniBook M3-8100Y
# (Ubuntu 26.04, Intel i915, 1200x1920 portrait, Goodix touchscreen).
#
# Run as your normal user (NOT root). Idempotent — safe to re-run.
#
# Usage:  bash install-chuwi.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

REPO_URL="https://github.com/mutlisensor/Rx3-flx4.git"
WORKDIR="$HOME/Rx3-flx4"
HANDOFF="$WORKDIR/rx3-handoff"
ROOTFS="$HOME/rx3-rootfs"
ROT=90                       # portrait 1200x1920 needs 90 for both presenter and bridge

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 0 — sanity
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Do not run as root."
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME unset."
command -v apt >/dev/null || die "apt not found — this targets Ubuntu."
command -v systemctl >/dev/null || die "systemd not found."

say "Chuwi MiniBook installer — $(uname -srm)"
say "User: $(id -un) (uid $(id -u)), HOME=$HOME"

# ---------------------------------------------------------------------------
# Step 1 — packages
# ---------------------------------------------------------------------------
say "Installing packages"
sudo apt update
sudo apt install -y \
    git build-essential gcc g++ make \
    gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
    fuse-overlayfs exfatprogs alsa-utils \
    python3-pil python3-cryptography \
    rsync 7zip \
    libfreetype-dev pkg-config fonts-dejavu libpng-dev \
    strace lsof coreutils evtest \
    qemu-user-binfmt

# ---------------------------------------------------------------------------
# Step 2 — QEMU ARM32
# ---------------------------------------------------------------------------
say "Verifying qemu-arm"
[ -f /proc/sys/fs/binfmt_misc/qemu-arm ] || {
    sudo systemctl restart systemd-binfmt || true
    sleep 1
}
grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-arm 2>/dev/null \
    || die "qemu-arm not enabled. Install qemu-user-binfmt."
echo "    qemu-arm enabled"

# ---------------------------------------------------------------------------
# Step 3 — /dev/fb0
# ---------------------------------------------------------------------------
say "Checking framebuffer"
[ -c /dev/fb0 ] || die "/dev/fb0 missing. Enable i915 fbdev and reboot."
echo "    /dev/fb0: $(cat /sys/class/graphics/fb0/name 2>/dev/null)"
echo "    panel:    $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"

# ---------------------------------------------------------------------------
# Step 4 — groups
# ---------------------------------------------------------------------------
say "Ensuring $USER is in video + input groups"
for g in video input; do
    if id "$USER" | grep -q "\b$g\b"; then
        echo "    already in $g"
    else
        sudo usermod -aG "$g" "$USER"
        warn "Added $USER to $g — LOG OUT AND BACK IN after install"
    fi
done

# ---------------------------------------------------------------------------
# Step 5 — clone repo
# ---------------------------------------------------------------------------
say "Cloning repo"
if [ -d "$WORKDIR/.git" ]; then
    git -C "$WORKDIR" pull --ff-only || warn "pull failed; using local copy"
else
    git clone "$REPO_URL" "$WORKDIR"
fi
cd "$HANDOFF" || die "no rx3-handoff dir"
chmod +x "$HANDOFF"/*.sh

# ---------------------------------------------------------------------------
# Step 6 — patch patch-player.py (getPcController NULL fix)
# ---------------------------------------------------------------------------
say "Patching patch-player.py (getPcController NULL deref)"
if grep -q '31df70' patch-player.py; then
    echo "    already patched"
else
    sed -i "s|^(b/'rbp-pi').write_bytes(p)|# getPcController: return NULL instead of deref'ing a NULL singleton.\nwords(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)|" patch-player.py
    grep -q '31df70' patch-player.py || die "patch-player patch failed"
    echo "    patched"
fi

# ---------------------------------------------------------------------------
# Step 7 — patch control-shim.c (re-unlock input gate every 10s)
# ---------------------------------------------------------------------------
say "Patching control-shim.c (input gate retry)"
if grep -q 'refresh_manager' control-shim.c; then
    echo "    already patched"
else
python3 - <<'PYEOF'
from pathlib import Path
p = Path("control-shim.c"); s = p.read_text(); n = 0

old = "static void *control_thread(void *unused){\n sleep(3);"
new = ("static volatile void *g_manager = 0;\n"
"static void refresh_manager(void){\n"
" void *m=0;void *root=*(void *volatile *)0x026867c0;\n"
" if(root)m=*(void **)((char*)root+0x64);\n"
" if(m){((void (*)(void*,int))0x37c8d8)(m,3);g_manager=m;}\n"
"}\n"
"static void *gate_thread(void *unused){\n"
" sleep(5);\n"
" for(;;){refresh_manager();sleep(10);}\n"
" return 0;\n"
"}\n"
"static void *control_thread(void *unused){\n sleep(3);"
)
if old in s: s = s.replace(old, new, 1); n += 1
else: print("  MISS gate_thread insert")

old = " ((void (*)(void*,int))0x37c8d8)(manager,3);\n void (*sendkey)"
new = (" ((void (*)(void*,int))0x37c8d8)(manager,3);\n"
       " unsigned long t2;pthread_create(&t2,0,gate_thread,0);\n"
       " void (*sendkey)")
if old in s: s = s.replace(old, new, 1); n += 1
else: print("  MISS gate_thread spawn")

old = "  if(c.key<0||c.key>65535||c.operation<0||c.operation>15||c.channel<0||c.channel>2)continue;\n  sendkey(manager,c.key,c.operation,c.channel,c.value,c.analog,c.extra);"
new = ("  if(c.key<0||c.key>65535||c.operation<0||c.operation>15||c.channel<0||c.channel>2)continue;\n"
       "  refresh_manager();\n"
       "  void *m=g_manager?g_manager:manager;\n"
       "  sendkey(m,c.key,c.operation,c.channel,c.value,c.analog,c.extra);")
if old in s: s = s.replace(old, new, 1); n += 1
else: print("  MISS refresh before sendkey")

p.write_text(s); print(f"  shim patches applied: {n}/3")
PYEOF
fi

# ---------------------------------------------------------------------------
# Step 8 — patch rx3-control.py (op=0 -> op=1 for press)
# ---------------------------------------------------------------------------
say "Patching rx3-control.py (op=1 press code)"
if grep -q 'send(k,1,ch)' rx3-control.py; then
    echo "    already patched"
else
    cp rx3-control.py rx3-control.py.orig
    sed -i 's|send(k,0,ch); time.sleep(.1); send(k,2,ch)|send(k,1,ch); time.sleep(.1); send(k,2,ch)|' rx3-control.py
    sed -i "s|send(key_of(a\[1\]),0 if a\[0\]=='press' else 2|send(key_of(a[1]),1 if a[0]=='press' else 2|" rx3-control.py
    grep -q 'send(k,1,ch)' rx3-control.py || warn "rx3-control.py patch may have missed"
    echo "    patched"
fi

# ---------------------------------------------------------------------------
# Step 9 — patch usb-hotplug.sh (retry mount event delivery)
# ---------------------------------------------------------------------------
say "Patching usb-hotplug.sh (mount event retry)"
[ -f usb-hotplug.sh.orig ] || cp usb-hotplug.sh usb-hotplug.sh.orig
if grep -q 'mount event sent' usb-hotplug.sh; then
    echo "    already patched"
else
python3 - <<'PYEOF'
from pathlib import Path
p = Path("usb-hotplug.sh"); s = p.read_text()
old = '''    $H/usb-attach.sh "$DEV" $PORT 9>&- && sudo -u $RX3_USER python3 $H/rx3-control.py mount $PORT /media/$PORT/$PART 9>&-
    logger -t rx3 "$PORT attached $DEV" ;;'''
new = '''    if $H/usb-attach.sh "$DEV" $PORT 9>&-; then
        ok=0
        for i in $(seq 1 15); do
            if sudo -u "$RX3_USER" python3 $H/rx3-control.py mount $PORT /media/$PORT/$PART 9>&-; then
                ok=1; break
            fi
            sleep 1
        done
        if [ "$ok" = 1 ]; then
            logger -t rx3 "$PORT attached $DEV (mount event sent=1)"
        else
            logger -t rx3 "$PORT attached $DEV (mount event FAILED)"
        fi
    else
        logger -t rx3 "$PORT usb-attach FAILED"
    fi ;;'''
if old in s:
    s = s.replace(old, new, 1); p.write_text(s); print("  patched")
else:
    print("  MISS — edit usb-hotplug.sh manually")
PYEOF
fi

# ---------------------------------------------------------------------------
# Step 10 — patch usb-attach.sh (mknod hex->decimal for Ubuntu coreutils)
# ---------------------------------------------------------------------------
say "Patching usb-attach.sh (mknod hex to decimal)"
if grep -q '16#$(stat' usb-attach.sh; then
    echo "    already patched"
else
    sed -i 's|mknod \$R/dev/\$PART b 0x\$(stat -c %t "\$SRC") 0x\$(stat -c %T "\$SRC")|mknod $R/dev/$PART b $((16#$(stat -c %t "$SRC"))) $((16#$(stat -c %T "$SRC")))|' usb-attach.sh
    grep -q '16#$(stat' usb-attach.sh || die "usb-attach.sh mknod patch failed"
    echo "    patched"
fi

# ---------------------------------------------------------------------------
# Step 11 — firmware recovery
# ---------------------------------------------------------------------------
if [ -f "$HANDOFF/runtime-symlinks.json" ]; then
    say "Firmware already extracted — skipping"
else
    say "Recovering firmware (interactive — you supply the files)"
    warn "You need:"
    warn "  - XDJ-RX3 v1.19 firmware update from AlphaTheta"
    warn "  - Pioneer GPL source distribution for the RX3"
    warn "If recover-firmware.py hangs, Ctrl+C, get the files, then re-run this script."
    python3 recover-firmware.py || die "recover-firmware.py failed"
    python3 extract_cramfs.py 2>&1 | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py incomplete"
    [ -f "$HANDOFF/runtime-symlinks.json" ] || die "runtime-symlinks.json missing"
fi

# ---------------------------------------------------------------------------
# Step 12 — build chroot
# ---------------------------------------------------------------------------
if [ -f "$ROOTFS/etc/rx3-ctl" ] && [ -d "$ROOTFS/root/pdj" ]; then
    say "Chroot already built ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1)) — skipping"
else
    say "Building chroot (a few minutes)"
    if mount | grep -q "$ROOTFS"; then
        warn "Unmounting stale mounts"
        for m in $(mount | awk -v r="$ROOTFS" 'index($3, r) == 1 {print $3}' | sort -r); do
            sudo umount -l -- "$m" 2>/dev/null || sudo umount -f -- "$m" 2>/dev/null || true
        done
    fi
    ./build-rootfs.sh 2>&1 | tee /tmp/build-rootfs.log
    grep -q '^== done' /tmp/build-rootfs.log || die "build-rootfs.sh failed"
fi
say "Chroot size: $(du -sh "$ROOTFS" 2>/dev/null | cut -f1)"

# ---------------------------------------------------------------------------
# Step 13 — compile host helpers with correct RX3_ROOT_PATH
# ---------------------------------------------------------------------------
say "Compiling host helpers (native x86_64, RX3_ROOT_PATH=$ROOTFS)"

gcc -O2 -DRX3_ROOT_PATH="\"$ROOTFS\"" \
    $(pkg-config --cflags freetype2) \
    -o "$HOME/rx3-fb-present" fb-present.c \
    $(pkg-config --libs freetype2) \
    || die "fb-present.c compile failed"

gcc -O2 -DRX3_ROOT_PATH="\"$ROOTFS\"" \
    -o "$HOME/rx3-touch-bridge" touch-bridge.c \
    || die "touch-bridge.c compile failed"

say "Verifying embedded state path in host helpers"
for b in "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge"; do
    got=$(strings "$b" | grep -m1 'ui-state' || true)
    case "$got" in
        "$ROOTFS"*) echo "    $b ok" ;;
        *) die "$b has wrong state path: $got" ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 14 — rotation config
# ---------------------------------------------------------------------------
say "Writing rx3.conf (RX3_ROTATE=$ROT for 1200x1920 portrait panel)"
echo "RX3_ROTATE=$ROT" > "$HANDOFF/rx3.conf"

# ---------------------------------------------------------------------------
# Step 15 — upstream install.sh (systemd unit, udev rules)
# ---------------------------------------------------------------------------
say "Running upstream install.sh"
./install.sh || die "install.sh failed"

sudo systemctl daemon-reload
sudo systemctl enable rx3.service

# ---------------------------------------------------------------------------
# Step 16 — install rx3-pointer.service (auto-detect touchscreen)
# ---------------------------------------------------------------------------
say "Installing rx3-pointer.service (auto-detect, rotation $ROT)"

sudo tee /etc/systemd/system/rx3-pointer.service >/dev/null <<EOF
[Unit]
Description=RX3 touch bridge
After=rx3.service

[Service]
Type=simple
User=root
Environment=RX3_FB=/dev/fb0
Environment=RX3_ROTATE=$ROT
ExecStart=/bin/bash -c 'for i in \$(seq 1 90); do for e in /dev/input/event*; do if udevadm info -q property -n "\$e" 2>/dev/null | grep -q ID_INPUT_TOUCHSCREEN=1; then exec $HOME/rx3-touch-bridge "\$e" $ROOTFS/dev/tsc2007_2-0048; fi; done; sleep 2; done; exit 1'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Step 17 — udev rules
# ---------------------------------------------------------------------------
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-touch.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHSCREEN}=="1", SYMLINK+="input/rx3-touch"
EOF
sudo udevadm control --reload-rules 2>/dev/null || true
sudo udevadm trigger --action=add --subsystem-match=input 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable rx3-pointer.service

# ---------------------------------------------------------------------------
# Step 18 — save working config backup
# ---------------------------------------------------------------------------
BACKUP="$HOME/rx3-backup"
mkdir -p "$BACKUP"
cp "$HANDOFF/usb-attach.sh" "$HANDOFF/usb-hotplug.sh" "$BACKUP/" 2>/dev/null || true
cp "$HANDOFF/rx3-control.py" "$HANDOFF/control-shim.c" "$HANDOFF/rx3.conf" "$BACKUP/" 2>/dev/null || true
cp "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge" "$BACKUP/" 2>/dev/null || true
cp "$ROOTFS/lib/fbshim.so" "$BACKUP/fbshim-installed.so" 2>/dev/null || true
cp /etc/systemd/system/rx3.service /etc/systemd/system/rx3-pointer.service "$BACKUP/" 2>/dev/null || true
cp /etc/udev/rules.d/99-rx3-usb.rules /etc/udev/rules.d/99-rx3-touch.rules "$BACKUP/" 2>/dev/null || true
cp "$0" "$BACKUP/install-chuwi.sh" 2>/dev/null || true

cat > "$BACKUP/WORKING-CONFIG.txt" <<'EOF'
Chuwi MiniBook M3-8100Y — working RX3 configuration

PRESENTER ROTATION:  90   (rx3.conf RX3_ROTATE=90)
BRIDGE ROTATION:     90   (rx3-pointer.service RX3_ROTATE=90)
Panel:               1200x1920 portrait, i915drmfb
Touchscreen:         Goodix Capacitive (auto-detected via ID_INPUT_TOUCHSCREEN)

FIXES APPLIED (all baked into install-chuwi.sh):
  1. patch-player.py   — getPcController NULL fix (words 0x31df70 = mov r0,#0)
  2. control-shim.c    — refresh_manager/gate_thread re-unlock input gate every 10s
  3. rx3-control.py    — op=0 -> op=1 for button press
  4. usb-hotplug.sh    — retry loop for mount event delivery (15 attempts)
  5. usb-attach.sh     — mknod hex->decimal ($((16#...))) for Ubuntu coreutils

RECOVERY AFTER REBOOT:
  sudo systemctl restart rx3
  sleep 130
  sudo systemctl restart rx3-pointer

  If still broken: reboot. Both services start cleanly in the right order.

SERVICE STATE (should both be "active"):
  systemctl is-active rx3 rx3-pointer

USB WORKFLOW:
  1. ls /dev/sd*       (device letter changes between replugs: sdb1, sdc1...)
  2. Plug in stick. udev fires automatically.
  3. sudo journalctl -t rx3 -f
     Expect: usb1 attached /dev/sdX1 (mount event sent=1)
  4. On the RX3 UI: SOURCE -> USB1

TOUCH WORKFLOW:
  Tap the presenter's bottom overlay strip (SOURCE, BROWSE, LOAD 1, PLAY 1, etc.)
  Taps in the middle of the screen move the firmware's internal cursor.

KEYBOARD CONTROL:
  cd ~/Rx3-flx4/rx3-handoff
  python3 rx3-control.py source
  python3 rx3-control.py usb1
  python3 rx3-control.py rotary +1
  python3 rx3-control.py enter
  python3 rx3-control.py load 0
  python3 rx3-control.py play 0
  python3 rx3-control.py query

KNOWN LIMITATIONS:
  - Audio does not work. The firmware expects an ALSA card named
    "cs4344audiorev8" (Cirrus CS4344). No such card on a laptop.
    Play state toggles (playing=1) but no samples are written.
    Fixing this requires reverse-engineering rbp-pi with Ghidra.
  - Touch hit-boxes are approximate. The bridge's table is for 1280x800.
  - QEMU emulation is ~10x slower than native.

DO NOT:
  - Do NOT use -noborder on the presenter. The touch bridge needs the
    overlay buttons at the bottom of the screen.
  - Do NOT patch control-shim.c, touch-bridge.c, rx3-control.py, or
    fbshim.so after install. If something breaks, run the recovery above.
EOF

echo "    backup written to $BACKUP"

# ---------------------------------------------------------------------------
# Step 19 — done
# ---------------------------------------------------------------------------
cat <<EOF

============================================================
  INSTALL COMPLETE  (Chuwi MiniBook M3-8100Y)
============================================================

  Repo:          $WORKDIR
  Chroot:        $ROOTFS  ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1))
  Presenter:     $HOME/rx3-fb-present     (rotation $ROT)
  Touch bridge:  $HOME/rx3-touch-bridge   (rotation $ROT)
  Services:      rx3.service, rx3-pointer.service (both enabled)
  Backup:        $BACKUP

Next steps
----------
1. LOG OUT AND BACK IN (for video + input groups)

2. Start:
       sudo systemctl start rx3 rx3-pointer

3. Wait ~130 seconds for the firmware to boot under QEMU, then check:
       systemctl status rx3 rx3-pointer --no-pager | grep -E '●|Active:'
       pgrep -af 'qemu-arm|rx3-fb-present|rx3-touch-bridge'

4. UI should be on screen, portrait, rotation 90, no border.

5. Tap the bottom overlay strip (SOURCE / BROWSE / LOAD / PLAY) to test touch.

6. Keyboard control (works even without touch):
       cd $WORKDIR/rx3-handoff
       python3 rx3-control.py source
       python3 rx3-control.py usb1
       python3 rx3-control.py load 0
       python3 rx3-control.py play 0
       python3 rx3-control.py query

Recovery after a reboot:
       sudo systemctl restart rx3
       sleep 130
       sudo systemctl restart rx3-pointer

Known limitations:
  - No audio (firmware expects cs4344audiorev8 card).
  - Touch hit-boxes approximate for 1200x1920 portrait.
  - Performance ~10x slower than native ARM.

Full log: $HOME/rx3-install.log
EOF
