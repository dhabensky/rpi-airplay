#!/bin/bash
# Boots the built rootfs under systemd-nspawn with veths named eth0/wlan0 and
# checks eth0's 169.254.100.1/16 backup address (unplug/replug, flushes, DHCP + ifdown,
# service restarts, late eth0) and the idle menu's IP. Runs in the colima VM.
set -uo pipefail

VOLUME_PATH=/var/lib/docker/volumes/rpi-airplay-dietpi-root/_data
MACHINE=rpi-airplay-ethtest
# Not ve-*: the colima VM's networkd gives those its own addresses and a DHCP server.
ETH_HOST=rpitest-eth
WLAN_HOST=rpitest-wlan
ADDR=169.254.100.1
PEER=169.254.100.2/16

command -v systemd-nspawn >/dev/null || { echo "ERROR: systemd-nspawn not installed" >&2; exit 1; }
[ -d "$VOLUME_PATH" ] || { echo "ERROR: $VOLUME_PATH not found -- run 'make image' first" >&2; exit 1; }

fail=0
pass() { echo "PASS: $*"; }
failed() { echo "FAIL: $*"; fail=1; }
in_machine() { systemd-run -M "$MACHINE" --wait --pipe -q "$@" </dev/null 2>/dev/null; }
# Polls a check function for up to $1 seconds.
wait_for() { local secs=$1; shift; for _ in $(seq 1 "$secs"); do "$@" && return 0; sleep 1; done; return 1; }
eth0_has_addr() { in_machine ip -o -4 addr show dev eth0 scope link | grep -qF "inet $ADDR/16 "; }
eth0_is_up() { in_machine ip -o link show dev eth0 | grep -Eq '[<,]UP[,>]'; }
eth0_ready() { eth0_has_addr && eth0_is_up; }
# TCP connect to sshd from the host end: the colima VM ships no ping.
reachable() { timeout 2 bash -c "exec 3<>/dev/tcp/$ADDR/22" 2>/dev/null; }

machinectl poweroff "$MACHINE" >/dev/null 2>&1 || true
sleep 1

echo "==> Booting $MACHINE (ephemeral, private network: eth0 + wlan0 veths)"
systemd-nspawn -D "$VOLUME_PATH" --ephemeral --machine="$MACHINE" --hostname="$MACHINE" \
  --network-veth-extra="$ETH_HOST:eth0" --network-veth-extra="$WLAN_HOST:wlan0" --boot \
  > /tmp/nspawn-test-eth-backup.log 2>&1 &

if wait_for 90 systemctl -M "$MACHINE" is-active -q multi-user.target 2>/dev/null; then
  pass "reached multi-user.target with eth0 cable unplugged"
else
  echo "FAIL: never reached multi-user.target -- see /tmp/nspawn-test-eth-backup.log"
  machinectl poweroff "$MACHINE" >/dev/null 2>&1 || true
  exit 1
fi

# nspawn never mounts the boot partition, so dietpi.txt's hostname is unset.
in_machine hostnamectl set-hostname "$MACHINE"
in_machine systemctl restart avahi-daemon.service

echo "eth0-backup-ip.service: $(systemctl -M "$MACHINE" is-active eth0-backup-ip.service 2>&1)"
echo "avahi-daemon.service: $(systemctl -M "$MACHINE" is-active avahi-daemon.service 2>&1)"

if wait_for 5 eth0_ready; then pass "eth0 up with $ADDR/16 (scope link) while unplugged (no carrier)"
else failed "eth0 lacks $ADDR/16 scope link while unplugged:"; in_machine ip addr show dev eth0; fi

# Runs the real uxplay-menu-render with menu-render stubbed (ephemeral copy) and prints its IP line.
printf '#!/bin/sh\nprintf "%%s\\n" "$1" > /tmp/menu-text\n' > /tmp/menu-render-stub
chmod 0755 /tmp/menu-render-stub
machinectl copy-to --force "$MACHINE" /tmp/menu-render-stub /usr/local/bin/menu-render
menu_ip() { in_machine bash -c 'rm -f /tmp/menu-text; /usr/local/bin/uxplay-menu-render; grep "^IP: " /tmp/menu-text'; }

got=$(menu_ip)
[ "$got" = "IP: (no IP yet)" ] && pass "menu shows '$got' with only the backup address" || failed "menu IP line with only the backup address: '$got'"

# Stand-in for the WiFi uplink, to check it is left untouched.
ip link set "$WLAN_HOST" up
in_machine ip link set wlan0 up
in_machine ip addr add 192.168.77.2/24 dev wlan0
in_machine ip route add default via 192.168.77.1 dev wlan0

got=$(menu_ip)
[ "$got" = "IP: 192.168.77.2" ] && pass "menu shows the wlan0 address ($got)" || failed "menu IP line with wlan0 up: '$got'"

echo "==> Plugging the cable (host veth end up, host at $PEER)"
ip link set "$ETH_HOST" up
ip addr add "$PEER" dev "$ETH_HOST"
if wait_for 10 reachable; then pass "host reaches $ADDR over the cable"; else failed "$ADDR unreachable after plug"; fi

ssh_banner() { timeout 3 bash -c "exec 3<>/dev/tcp/$ADDR/22; head -c 7 <&3" 2>/dev/null | grep -q '^SSH-2.0'; }
if wait_for 20 ssh_banner; then pass "sshd answers on $ADDR:22"; else failed "no SSH banner on $ADDR:22"; fi

# Legacy-unicast mDNS A query for <hostname>.local sent from host address $1; prints all A answers.
mdns_a() {
  python3 - "$MACHINE.local" "$1" <<'PYEOF'
import socket, struct, sys
name, src = sys.argv[1], sys.argv[2]
q = struct.pack(">HHHHHH", 0x1234, 0, 1, 0, 0, 0)
q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
q += struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((src, 0))
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(src))
s.settimeout(2)
s.sendto(q, ("224.0.0.251", 5353))
try:
    data, _ = s.recvfrom(4096)
except socket.timeout:
    sys.exit(1)
def skip_name(i):
    while data[i]:
        if data[i] >= 0xC0: return i + 2
        i += data[i] + 1
    return i + 1
qd, an = struct.unpack(">HH", data[4:8])
i = 12
for _ in range(qd): i = skip_name(i) + 4
addrs = []
for _ in range(an):
    i = skip_name(i)
    typ, _, _, rdlen = struct.unpack(">HHIH", data[i:i + 10])
    i += 10
    if typ == 1: addrs.append(socket.inet_ntoa(data[i:i + 4]))
    i += rdlen
print(" ".join(addrs))
PYEOF
}
mdns_eth_ok() { [ "$(mdns_a "${PEER%/*}")" = "$ADDR" ]; }
if wait_for 15 mdns_eth_ok; then pass "mDNS: $MACHINE.local resolves to $ADDR over eth0"
else failed "mDNS: $MACHINE.local did not resolve to $ADDR over eth0 (got '$(mdns_a "${PEER%/*}")')"; fi

# A WiFi-only client must never be handed the link-local backup address.
ip addr add 192.168.77.1/24 dev "$WLAN_HOST"
mdns_wlan_answered() { [ -n "$(mdns_a 192.168.77.1)" ]; }
wait_for 15 mdns_wlan_answered
got=$(mdns_a 192.168.77.1)
[ "$got" = "192.168.77.2" ] && pass "mDNS over wlan0 answers only the wlan0 address ($got)" \
  || failed "mDNS over wlan0 answered '$got' (want only 192.168.77.2)"

echo "==> Unplug / replug"
ip link set "$ETH_HOST" down; sleep 2
if eth0_ready; then pass "address kept while unplugged"; else failed "address lost on unplug"; fi
ip link set "$ETH_HOST" up
if wait_for 10 reachable; then pass "reachable after replug"; else failed "unreachable after replug"; fi

echo "==> ip addr flush dev eth0"
in_machine ip addr flush dev eth0
if wait_for 5 eth0_ready && wait_for 5 reachable; then pass "address restored after flush"; else failed "address not restored after flush"; fi

echo "==> ip link set eth0 down"
in_machine ip link set eth0 down
if wait_for 5 eth0_ready && wait_for 5 reachable; then pass "link and address restored after link down"; else failed "not restored after link down"; fi

echo "==> Killing any one of the service's processes restarts it"
nrestarts() { systemctl -M "$MACHINE" show -p NRestarts --value eth0-backup-ip.service; }
unit_pids() { in_machine cat /sys/fs/cgroup/system.slice/eth0-backup-ip.service/cgroup.procs | sort -n; }
nprocs=$(unit_pids | wc -l)
# Picks the n-th PID each round; normally main process first, but victims are labelled by cmdline regardless.
for n in $(seq 1 "$nprocs"); do
  before=$(nrestarts)
  victim=$(unit_pids | sed -n "${n}p")
  what=$(in_machine cat /proc/"$victim"/cmdline | tr '\0' ' ')
  in_machine kill -9 "$victim"
  restarted() { [ "$(nrestarts)" -gt "$before" ] && systemctl -M "$MACHINE" is-active -q eth0-backup-ip.service; }
  if wait_for 10 restarted; then pass "killing process $n/$nprocs ($what) restarted the service"
  else failed "killing process $n/$nprocs ($what) left it running without a restart: $(unit_pids | tr '\n' ' ')"; fi
  in_machine ip addr flush dev eth0
  if wait_for 5 eth0_ready; then pass "address restored after flush (post-kill $n/$nprocs)"; else failed "not restored after flush (post-kill $n/$nprocs)"; fi
done

echo "==> WiFi stand-in untouched, no DHCP server on the Pi"
wlan_addrs=$(in_machine ip -o -4 addr show dev wlan0 | awk '{print $4}' | tr '\n' ' ')
[ "$wlan_addrs" = "192.168.77.2/24 " ] && pass "wlan0 addresses unchanged ($wlan_addrs)" || failed "wlan0 addresses changed: '$wlan_addrs'"
defroutes=$(in_machine ip -4 route show default)
[ "$(echo $defroutes)" = "default via 192.168.77.1 dev wlan0" ] && pass "only default route is via wlan0" || failed "default routes: '$defroutes'"
dhcp_listeners=$(in_machine ss -Hlun 'sport = :67')
[ -z "$dhcp_listeners" ] && pass "nothing listening on UDP 67" || failed "UDP 67 listener: $dhcp_listeners"

echo "==> DHCP on eth0 (dnsmasq on the host end as a home router), then ifdown"
# Own interfaces file: firstboot under nspawn rewrites eth0 as eth0@ifN in the real one.
IFS_FILE=/tmp/eth0-dhcp.interfaces
ip addr add 192.168.88.1/24 dev "$ETH_HOST"
dnsmasq --conf-file=/dev/null --keep-in-foreground --port=0 --bind-interfaces \
  --interface="$ETH_HOST" --dhcp-range=192.168.88.100,192.168.88.150,1h --leasefile-ro &
dnsmasq_pid=$!
in_machine bash -c "printf 'iface eth0 inet dhcp\n' > $IFS_FILE"
in_machine timeout 30 ifup -i "$IFS_FILE" eth0
eth0_v4=$(in_machine ip -o -4 addr show dev eth0 | awk '{print $4}' | tr '\n' ' ')
if grep -q '192\.168\.88\.' <<<"$eth0_v4" && grep -qF "$ADDR/16" <<<"$eth0_v4"; then
  pass "DHCP lease and backup address coexist on eth0 ($eth0_v4)"
else failed "eth0 after DHCP: '$eth0_v4'"; fi
in_machine bash -c "ip monitor address > /tmp/addr-events & sleep 0.5; ifdown -i $IFS_FILE --force eth0; sleep 1; kill \$!"
if in_machine grep -q "Deleted.*inet $ADDR/16" /tmp/addr-events; then pass "lease release flushed $ADDR (cycle really exercised)"
else failed "ifdown never removed $ADDR -- cycle not exercised"; fi
if wait_for 5 eth0_ready && wait_for 5 reachable; then pass "restored after ifup/ifdown cycle"; else failed "not restored after ifup/ifdown cycle"; fi
kill "$dnsmasq_pid" 2>/dev/null
ip addr del 192.168.88.1/24 dev "$ETH_HOST"

echo "==> eth0 appearing after boot (replaced by a fresh dummy eth0)"
in_machine ip link del eth0
in_machine ip link add eth0 type dummy
if wait_for 5 eth0_ready; then pass "late-appearing eth0 configured"; else failed "late-appearing eth0 not configured"; fi

echo
echo "=== eth0-backup-ip journal ==="
journalctl -M "$MACHINE" -u eth0-backup-ip --no-pager 2>&1 | tail -10

machinectl poweroff "$MACHINE" >/dev/null 2>&1 || true
echo "Powered off $MACHINE"
exit "$fail"
