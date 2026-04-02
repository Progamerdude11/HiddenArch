set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
banner() { echo -e "\n${CYAN}${BOLD}>>> $1${NC}"; }
ask()    { read -rp "$(echo -e ${YELLOW}[?]${NC} $1) " "$2"; }
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"
[[ ! -f /etc/arch-release ]] && error "Arch Linux only."
clear
echo -e "${CYAN}${BOLD}"
cat << 'EOF'
 ___  ___ _____   _____  _______   __  ___ ___ _____ _   _ ___
| _ \| _ \_ _\ \ / /_  )/ /_  / | / / / __| __|_   _| | | | _ \
|  _/|   / | | \ V / / // /_ < |/ / \__ \ _|  | | | |_| |  _/
|_|  |_|_\___|  \_/ /___/_//__/|__/  |___/___| |_|  \___/|_|
         Arch Privacy + VeraCrypt 
EOF
echo -e "${NC}"
echo "This script will:"
echo "  [1]  Route ALL traffic through Tor (transparent proxy)"
echo "  [2]  iptables kill switch (no Tor = no internet)"
echo "  [3]  MAC address spoofing on every boot"
echo "  [4]  Kernel / sysctl hardening"
echo "  [5]  DNS forced through Tor"
echo "  [6]  Install privacy tools (Tor Browser, KeePassXC, OnionShare, mat2...)"
echo "  [7]  Install VeraCrypt + create outer/hidden vault"
echo "  [8]  Vault stores: GPG keys, SSH keys, Tor Browser profile, Documents"
echo "  [9]  vault-open / vault-close commands"
echo "  [10] Disable swap, unnecessary services, shell history"
echo "  [11] AppArmor + Firejail sandboxing"
echo ""
echo ""
ask "Continue? [y/N]" confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    ask "Your normal (non-root) username:" REAL_USER
fi
id "$REAL_USER" &>/dev/null || error "User '$REAL_USER' does not exist."
REAL_HOME=$(eval echo "~$REAL_USER")
echo ""
echo -e "${CYAN}${BOLD}How do you want to route your traffic by default on boot?${NC}"
echo ""
echo "  [1] Tor + kill switch  — all traffic through Tor (most private)"
echo "  [2] ProtonVPN          — install ProtonVPN, you manage routing in the app"
echo "  [3] Neither            — install both, use tor-on / protonvpn manually"
echo ""
ask "Choice [1/2/3]:" ROUTING_CHOICE
case "$ROUTING_CHOICE" in
    1)
        ROUTING_TOR=1; ROUTING_VPN=0; ROUTING_NONE=0
        log "Tor + kill switch will be active on boot"
        ;;
    2)
        ROUTING_TOR=0; ROUTING_VPN=1; ROUTING_NONE=0
        warn "ProtonVPN selected, enable the kill switch inside the ProtonVPN app yourself"
        warn "Tor is installed but NOT active on boot. Use 'tor-on' if you ever need it."
        ;;
    3)
        ROUTING_TOR=0; ROUTING_VPN=0; ROUTING_NONE=1
        warn "No auto-routing on boot — use 'tor-on' or ProtonVPN manually when needed"
        ;;
    *)
        warn "Invalid choice, defaulting to Tor + kill switch"
        ROUTING_TOR=1; ROUTING_VPN=0; ROUTING_NONE=0
        ;;
esac
banner "1. Updating system"
pacman -Syu --noconfirm
log "System updated"
banner "2. Installing packages"
PACKAGES=(
    tor torsocks nyx obfs4proxy
    iptables
    macchanger
    keepassxc gnupg gnupg2
    mat2
    onionshare
    electrum
    bleachbit
    secure-delete
    thunderbird
    firejail
    apparmor apparmor-utils
    curl wget git base-devel
    htop arch-audit
    rsync
    xclip
    fuse2 wxgtk3
)
pacman -S --noconfirm --needed "${PACKAGES[@]}"
log "Packages installed"
banner "3. Installing yay (AUR helper)"
if ! command -v yay &>/dev/null; then
    YAY_TMP=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$YAY_TMP/yay"
    chown -R "$REAL_USER:$REAL_USER" "$YAY_TMP"
    sudo -u "$REAL_USER" bash -c "cd $YAY_TMP/yay && makepkg -si --noconfirm"
    rm -rf "$YAY_TMP"
    log "yay installed"
else
    log "yay already installed"
fi
banner "4. Installing AUR packages (VeraCrypt, Tor Browser, ProtonVPN)"
sudo -u "$REAL_USER" yay -S --noconfirm --needed veracrypt tor-browser protonvpn
log "AUR packages installed"
banner "5. Configuring Tor"
id -u tor &>/dev/null || useradd -r -s /usr/bin/nologin tor
cat > /etc/tor/torrc << 'EOF'
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
DNSPort 5353
SocksPort 9050
AvoidDiskWrites 1
EOF
systemctl enable --now tor
log "Tor running"
banner "6. Setting up iptables kill switch"
NET_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
[[ -z "$NET_IF" ]] && { warn "Could not detect interface, defaulting to eth0"; NET_IF="eth0"; }
log "Network interface: $NET_IF"
cat > /usr/local/bin/privacy-firewall.sh << 'EOF'
TOR_UID=$(id -u tor)
TOR_TRANS_PORT=9040
TOR_DNS_PORT=5353
NON_TOR="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
iptables -P INPUT  DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner $TOR_UID -j ACCEPT
for NET in $NON_TOR; do
    iptables -A OUTPUT -d $NET -j ACCEPT
    iptables -A INPUT  -s $NET -j ACCEPT
done
iptables -t nat -A OUTPUT ! -d 127.0.0.1/32 -p udp --dport 53 -j REDIRECT --to-ports $TOR_DNS_PORT
iptables -t nat -A OUTPUT ! -d 127.0.0.1/32 -p tcp --dport 53 -j REDIRECT --to-ports $TOR_DNS_PORT
for NET in $NON_TOR; do
    iptables -t nat -A OUTPUT -d $NET -j RETURN
done
iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports $TOR_TRANS_PORT
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A OUTPUT -p udp -j REJECT --reject-with icmp-port-unreachable
iptables -A OUTPUT -j DROP
echo "[+] Kill switch ACTIVE — all traffic through Tor."
EOF
chmod +x /usr/local/bin/privacy-firewall.sh
cat > /etc/systemd/system/privacy-firewall.service << 'EOF'
[Unit]
Description=Tor Privacy Kill Switch
Before=network-pre.target
Wants=network-pre.target
After=tor.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/privacy-firewall.sh
ExecStop=/usr/bin/iptables -F
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if [[ "$ROUTING_TOR" -eq 1 ]]; then
    systemctl enable privacy-firewall
    log "Kill switch enabled on boot (Tor mode)"
else
    log "Kill switch installed but NOT enabled on boot, use 'tor-on' to activate"
fi
cat > /usr/local/bin/tor-on << 'TORON'
echo -e "\033[0;36m[i]\033[0m Re-enabling Tor kill switch..."
systemctl start privacy-firewall
echo -e "\033[0;32m[+]\033[0m Kill switch active. All traffic routed through Tor."
TORON
cat > /usr/local/bin/tor-off << 'TOROFF'
echo -e "\033[1;33m[!]\033[0m Disabling Tor kill switch, your real IP will be exposed."
read -rp "Are you sure? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
systemctl stop privacy-firewall
iptables -F
iptables -t nat -F
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
echo -e "\033[0;32m[+]\033[0m Normal internet restored."
echo -e "\033[1;33m[!]\033[0m Run 'tor-on' to re-enable Tor routing."
TOROFF
chmod +x /usr/local/bin/tor-on /usr/local/bin/tor-off
banner "7. MAC address spoofing"
cat > /usr/local/bin/spoof-mac.sh << 'EOF'
for IFACE in $(ip link show | awk -F: '/^[0-9]+:/{print $2}' | tr -d ' ' | grep -v lo); do
    ip link set "$IFACE" down 2>/dev/null || continue
    macchanger -r "$IFACE" && echo "[+] Spoofed $IFACE" || echo "[!] Could not spoof $IFACE"
    ip link set "$IFACE" up 2>/dev/null
done
EOF
chmod +x /usr/local/bin/spoof-mac.sh
cat > /etc/systemd/system/spoof-mac.service << 'EOF'
[Unit]
Description=Randomize MAC addresses
Before=network-pre.target NetworkManager.service
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/spoof-mac.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable spoof-mac
log "MAC spoofing on boot enabled"
if command -v nmcli &>/dev/null; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/mac-randomize.conf << 'EOF'
[device]
wifi.scan-rand-mac-address=yes
[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF
    log "NetworkManager MAC randomization enabled"
fi
banner "8. Kernel / sysctl hardening"
cat > /etc/sysctl.d/99-privacy.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6        = 1
net.ipv6.conf.default.disable_ipv6   = 1
net.ipv6.conf.lo.disable_ipv6        = 1
net.ipv4.tcp_syncookies               = 1
net.ipv4.conf.all.accept_source_route    = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects    = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects      = 0
net.ipv6.conf.all.accept_redirects    = 0
net.ipv4.conf.all.rp_filter           = 1
net.ipv4.conf.default.rp_filter       = 1
net.ipv4.ip_forward                   = 0
net.ipv6.conf.all.forwarding          = 0
net.ipv4.tcp_timestamps               = 0
net.ipv4.tcp_rfc1337                  = 1
net.ipv4.icmp_echo_ignore_broadcasts  = 1
kernel.dmesg_restrict                 = 1
kernel.kptr_restrict                  = 2
kernel.sysrq                          = 0
kernel.yama.ptrace_scope              = 2
kernel.randomize_va_space             = 2
kernel.perf_event_paranoid            = 3
vm.mmap_min_addr                      = 65536
EOF
sysctl --system
log "Kernel hardened"
banner "9. DNS → Tor only"
if systemctl is-enabled systemd-resolved &>/dev/null 2>&1; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/tor-dns.conf << 'EOF'
[Resolve]
DNS=127.0.0.1:5353
DNSStubListener=no
DNSSEC=no
EOF
    systemctl restart systemd-resolved
else
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf
fi
log "DNS locked to Tor (127.0.0.1:5353)"
banner "10. Disabling swap"
swapoff -a
sed -i '/\bswap\b/s/^/
log "Swap disabled"
banner "11. AppArmor + Firejail"
systemctl enable --now apparmor
if [[ -f /etc/default/grub ]]; then
    if ! grep -q "apparmor=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 apparmor=1 security=apparmor lsm=landlock,lockdown,yama,integrity,apparmor,bpf"/' /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg
        log "AppArmor added to GRUB cmdline"
    fi
fi
for app in firefox chromium thunderbird vlc evince; do
    if command -v "$app" &>/dev/null; then
        ln -sf /usr/bin/firejail /usr/local/bin/"$app" 2>/dev/null && log "Sandboxed: $app"
    fi
done
log "AppArmor + Firejail done"
banner "12. Disabling unnecessary services"
for svc in avahi-daemon cups bluetooth ModemManager; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
        systemctl disable --now "$svc" 2>/dev/null && log "Disabled: $svc" || warn "Not found: $svc"
    fi
done
banner "13. Shell privacy"
cat > /etc/profile.d/no-history.sh << 'EOF'
unset HISTFILE
export HISTSIZE=0
export HISTFILESIZE=0
EOF
grep -q "umask 077" /etc/profile || echo "umask 077" >> /etc/profile
log "Shell history disabled, umask 077"
banner "14. VeraCrypt Hidden Vault Setup"
VAULT_DIR="$REAL_HOME/.vault"
VAULT_CONTAINER="$VAULT_DIR/container"
VAULT_MOUNT="$REAL_HOME/vault"
TOOLS_DIR="/usr/local/bin"
mkdir -p "$VAULT_DIR"
mkdir -p "$VAULT_MOUNT"
chown -R "$REAL_USER:$REAL_USER" "$VAULT_DIR" "$VAULT_MOUNT"
echo ""
echo -e "${CYAN}VeraCrypt Hidden Vault${NC}"
echo "-----------------------------------------------"
echo "You will create one encrypted container with:"
echo ""
echo "  Outer volume  → decoy password → safe-looking files"
echo "  Hidden volume → real password  → your actual private data"
echo ""
echo "If forced to reveal your password, give the OUTER one."
echo "There is NO cryptographic way to prove a hidden volume exists."
echo ""
warn "Choose your container size now."
echo "  Recommended: at least 2GB for GPG keys, SSH keys, documents, Tor Browser profile"
echo ""
ask "Container size (e.g. 2G, 5G, 10G):" VAULT_SIZE
echo ""
echo -e "${YELLOW}Step 1/3: Creating the outer (decoy) volume...${NC}"
echo "  → You will be asked for the OUTER (decoy) password."
echo "  → Put fake/unimportant files here later."
echo ""
sudo -u "$REAL_USER" veracrypt \
    --text \
    --create "$VAULT_CONTAINER" \
    --size "$VAULT_SIZE" \
    --volume-type=normal \
    --encryption=AES \
    --hash=SHA-512 \
    --filesystem=Ext4 \
    --random-source=/dev/urandom
echo ""
echo -e "${YELLOW}Step 2/3: Creating the hidden volume inside the outer...${NC}"
echo "  → You will be asked for BOTH the outer password (to protect it)"
echo "  → AND your new hidden volume password (your real secret password)."
echo ""
sudo -u "$REAL_USER" veracrypt \
    --text \
    --create "$VAULT_CONTAINER" \
    --volume-type=hidden \
    --encryption=AES \
    --hash=SHA-512 \
    --filesystem=Ext4 \
    --random-source=/dev/urandom
echo ""
echo -e "${YELLOW}Step 3/3: Mounting hidden volume to set up folders...${NC}"
echo "  → Enter your HIDDEN (real) password to mount it now."
echo ""
sudo -u "$REAL_USER" veracrypt \
    --text \
    --mount "$VAULT_CONTAINER" "$VAULT_MOUNT" \
    --protect-hidden=no
log "Creating folder structure inside hidden vault..."
mkdir -p \
    "$VAULT_MOUNT/gnupg" \
    "$VAULT_MOUNT/ssh" \
    "$VAULT_MOUNT/documents" \
    "$VAULT_MOUNT/tor-browser-profile" \
    "$VAULT_MOUNT/keepass" \
    "$VAULT_MOUNT/onionshare" \
    "$VAULT_MOUNT/scripts" \
    "$VAULT_MOUNT/decoy-files"
cat > "$VAULT_MOUNT/decoy-files/README.txt" << 'EOF'
This folder is a reminder: populate your OUTER volume with believable
decoy files (old documents, photos, etc.) so it looks used.
Mount with your outer password and add files there.
EOF
chown -R "$REAL_USER:$REAL_USER" "$VAULT_MOUNT"
sudo -u "$REAL_USER" veracrypt --text --dismount "$VAULT_MOUNT"
log "Hidden vault created and unmounted"
banner "15. Installing vault commands"
cat > "$TOOLS_DIR/vault-open" << VAULTOPEN
VAULT_CONTAINER="$VAULT_CONTAINER"
VAULT_MOUNT="$VAULT_MOUNT"
REAL_USER="$REAL_USER"
REAL_HOME="$REAL_HOME"
[[ "\$EUID" -ne 0 ]] && SUDO_CMD="" || SUDO_CMD="sudo -u \$REAL_USER"
echo -e "\033[0;36m[vault]\033[0m Mounting hidden vault..."
echo "  → Enter your HIDDEN (real) password:"
echo ""
veracrypt --text --mount "\$VAULT_CONTAINER" "\$VAULT_MOUNT" --protect-hidden=no
if ! mountpoint -q "\$VAULT_MOUNT"; then
    echo -e "\033[0;31m[!]\033[0m Mount failed. Did you enter the right password?"
    exit 1
fi
echo -e "\033[0;32m[+]\033[0m Vault mounted at \$VAULT_MOUNT"
echo ""
echo -e "\033[0;36m[vault]\033[0m Applying symlinks..."
link_to_vault() {
    local src="\$1"    
    local dst="\$2"    
    if [[ ! -d "\$VAULT_MOUNT/\$src" ]]; then
        mkdir -p "\$VAULT_MOUNT/\$src"
    fi
    if [[ -e "\$dst" && ! -L "\$dst" ]]; then
        cp -a "\$dst" "\$VAULT_MOUNT/\$src.bak" 2>/dev/null || true
        rsync -a "\$dst/" "\$VAULT_MOUNT/\$src/" 2>/dev/null || true
        rm -rf "\$dst"
    elif [[ -L "\$dst" ]]; then
        rm -f "\$dst"
    fi
    ln -sf "\$VAULT_MOUNT/\$src" "\$dst"
    echo "  linked: \$dst → vault/\$src"
}
link_to_vault "gnupg"              "\$REAL_HOME/.gnupg"
link_to_vault "ssh"                "\$REAL_HOME/.ssh"
link_to_vault "tor-browser-profile" "\$REAL_HOME/.tor-browser"
link_to_vault "keepass"            "\$REAL_HOME/.keepass"
link_to_vault "onionshare"         "\$REAL_HOME/.config/onionshare"
link_to_vault "documents"          "\$REAL_HOME/Documents"
link_to_vault "scripts"            "\$REAL_HOME/scripts"
chown -R "\$REAL_USER:\$REAL_USER" "\$VAULT_MOUNT"
echo ""
echo -e "\033[0;32m[+]\033[0m Vault open. Your private data is accessible."
echo ""
echo "  Documents  → ~/Documents"
echo "  GPG keys   → ~/.gnupg"
echo "  SSH keys   → ~/.ssh"
echo "  Scripts    → ~/scripts"
echo "  KeePass    → ~/.keepass"
echo ""
echo -e "  Run \033[1mvault-close\033[0m when done."
VAULTOPEN
cat > "$TOOLS_DIR/vault-close" << VAULTCLOSE
VAULT_MOUNT="$VAULT_MOUNT"
REAL_HOME="$REAL_HOME"
REAL_USER="$REAL_USER"
echo -e "\033[0;36m[vault]\033[0m Removing symlinks..."
LINKS=(
    "\$REAL_HOME/.gnupg"
    "\$REAL_HOME/.ssh"
    "\$REAL_HOME/.tor-browser"
    "\$REAL_HOME/.keepass"
    "\$REAL_HOME/.config/onionshare"
    "\$REAL_HOME/Documents"
    "\$REAL_HOME/scripts"
)
for LINK in "\${LINKS[@]}"; do
    if [[ -L "\$LINK" ]]; then
        rm -f "\$LINK"
        echo "  removed: \$LINK"
    fi
done
echo ""
echo -e "\033[0;36m[vault]\033[0m Syncing and dismounting..."
sync
veracrypt --text --dismount "\$VAULT_MOUNT"
if mountpoint -q "\$VAULT_MOUNT" 2>/dev/null; then
    echo -e "\033[0;31m[!]\033[0m Vault still mounted. Close any open files and retry."
    exit 1
fi
echo -e "\033[0;32m[+]\033[0m Vault closed. All private data locked."
VAULTCLOSE
cat > "$TOOLS_DIR/vault-copy" << VAULTCOPY
VAULT_MOUNT="$VAULT_MOUNT"
if ! mountpoint -q "\$VAULT_MOUNT" 2>/dev/null; then
    echo -e "\033[0;31m[!]\033[0m Vault is not mounted. Run vault-open first."
    exit 1
fi
SRC="\${1:-}"
DEST_SUBFOLDER="\${2:-documents}"
[[ -z "\$SRC" ]] && { echo "Usage: vault-copy <file_or_folder> [vault_subfolder]"; exit 1; }
[[ ! -e "\$SRC" ]] && { echo -e "\033[0;31m[!]\033[0m Source not found: \$SRC"; exit 1; }
DEST="\$VAULT_MOUNT/\$DEST_SUBFOLDER"
mkdir -p "\$DEST"
rsync -a --progress "\$SRC" "\$DEST/"
echo ""
echo -e "\033[0;32m[+]\033[0m Copied '\$SRC' → vault/\$DEST_SUBFOLDER/"
echo ""
warn() { echo -e "\033[1;33m[!]\033[0m \$1"; }
warn "Original file still exists at \$SRC"
warn "Shred it if you want no trace: shred -u \"\$SRC\""
VAULTCOPY
cat > "$TOOLS_DIR/vault-shred" << VAULTSHRED
VAULT_MOUNT="$VAULT_MOUNT"
if ! mountpoint -q "\$VAULT_MOUNT" 2>/dev/null; then
    echo -e "\033[0;31m[!]\033[0m Vault is not open. Run vault-open first."
    exit 1
fi
SRC="\${1:-}"
DEST_SUBFOLDER="\${2:-documents}"
[[ -z "\$SRC" ]] && { echo "Usage: vault-shred <file> [vault_subfolder]"; exit 1; }
[[ ! -f "\$SRC" ]] && { echo -e "\033[0;31m[!]\033[0m File not found: \$SRC"; exit 1; }
DEST="\$VAULT_MOUNT/\$DEST_SUBFOLDER"
mkdir -p "\$DEST"
echo -e "\033[0;36m[vault]\033[0m Copying to vault..."
cp -a "\$SRC" "\$DEST/"
echo -e "\033[0;36m[vault]\033[0m Shredding original..."
shred -vuz "\$SRC"
echo ""
echo -e "\033[0;32m[+]\033[0m '\$(basename \$SRC)' is now ONLY in vault/\$DEST_SUBFOLDER/"
VAULTSHRED
cat > "$TOOLS_DIR/vault-status" << VAULTSTATUS
VAULT_MOUNT="$VAULT_MOUNT"
VAULT_CONTAINER="$VAULT_CONTAINER"
echo -e "\033[0;36m=== Vault Status ===\033[0m"
echo ""
if mountpoint -q "\$VAULT_MOUNT" 2>/dev/null; then
    echo -e "  State:     \033[0;32mOPEN\033[0m (mounted at \$VAULT_MOUNT)"
    echo ""
    echo "  Contents:"
    for DIR in "\$VAULT_MOUNT"/*/; do
        COUNT=\$(find "\$DIR" -type f 2>/dev/null | wc -l)
        echo "    \$(basename \$DIR)/  (\$COUNT files)"
    done
    echo ""
    DF=\$(df -h "\$VAULT_MOUNT" | tail -1)
    echo "  Disk:  \$DF"
else
    echo -e "  State:     \033[0;31mCLOSED\033[0m"
    echo "  Container: \$VAULT_CONTAINER"
    SIZE=\$(du -sh "\$VAULT_CONTAINER" 2>/dev/null | cut -f1)
    echo "  Size:      \$SIZE"
fi
echo ""
VAULTSTATUS
chmod +x \
    "$TOOLS_DIR/vault-open" \
    "$TOOLS_DIR/vault-close" \
    "$TOOLS_DIR/vault-copy" \
    "$TOOLS_DIR/vault-shred" \
    "$TOOLS_DIR/vault-status"
log "Vault commands installed: vault-open, vault-close, vault-copy, vault-shred, vault-status"
banner "16. Setting up shell aliases"
BASHRC="$REAL_HOME/.bashrc"
ZSHRC="$REAL_HOME/.zshrc"
ALIASES=$(cat << 'EOF'
alias vo='sudo vault-open'
alias vc='sudo vault-close'
alias vs='vault-status'
alias vcp='sudo vault-copy'
alias vsh='sudo vault-shred'
alias tor-check='torsocks curl -s https://check.torproject.org/api/ip'
alias ton='sudo tor-on'
alias toff='sudo tor-off'
alias clean-meta='mat2'
alias myip='torsocks curl -s https://api.ipify.org && echo'
EOF
)
echo "$ALIASES" >> "$BASHRC"
[[ -f "$ZSHRC" ]] && echo "$ALIASES" >> "$ZSHRC"
chown "$REAL_USER:$REAL_USER" "$BASHRC"
log "Shell aliases added"
clear
echo -e "${GREEN}${BOLD}"
cat << 'EOF'
  ___   ___  _  _ ___ 
 |   \ / _ \| \| | __|
 | |) | (_) |  ` | _| 
 |___/ \___/|_|\_|___|
EOF
echo -e "${NC}"
echo -e "${GREEN}Setup complete!${NC}
"
echo "  ✓ MAC spoofing on boot"
echo "  ✓ Kernel hardening"
echo "  ✓ IPv6 disabled"
echo "  ✓ Swap disabled"
echo "  ✓ AppArmor + Firejail"
echo "  ✓ Shell history disabled"
echo "  ✓ VeraCrypt hidden vault created"
echo "  ✓ ProtonVPN installed"
echo "  ✓ Tor + Tor Browser installed"
echo "  ✓ tor-on / tor-off commands available"
echo ""
if [[ "$ROUTING_TOR" -eq 1 ]]; then
    echo -e "  ${GREEN}✓ Routing: Tor kill switch ON at boot${NC}"
    echo -e "  ${YELLOW}  Run 'tor-off' to temporarily disable${NC}"
elif [[ "$ROUTING_VPN" -eq 1 ]]; then
    echo -e "  ${GREEN}✓ Routing: ProtonVPN (manage in app)${NC}"
    echo -e "  ${YELLOW}  Enable kill switch inside the ProtonVPN app${NC}"
    echo -e "  ${YELLOW}  Run 'tor-on' to switch to Tor routing${NC}"
else
    echo -e "  ${YELLOW}✓ Routing: None auto-enabled — use 'tor-on' or ProtonVPN manually${NC}"
fi
echo ""
echo -e "${CYAN}${BOLD}Network commands:${NC}"
echo ""
echo "  tor-on                  Enable Tor kill switch (all traffic through Tor)"
echo "  tor-off                 Disable kill switch (normal internet)"
echo "  protonvpn               Launch ProtonVPN"
echo "  tor-check               Verify Tor is working"
echo "  myip                    Check your current exit IP"
echo ""
echo -e "${CYAN}${BOLD}Vault commands:${NC}"
echo ""
echo "  vault-open              Mount hidden vault + apply symlinks"
echo "  vault-close             Unmount vault + remove symlinks"
echo "  vault-copy <file>       Copy a file into the vault"
echo "  vault-shred <file>      Copy to vault + shred the original"
echo "  vault-status            Show vault state and contents"
echo ""
echo -e "${CYAN}${BOLD}Aliases:${NC}"
echo ""
echo "  vo / vc / vs            open / close / status"
echo "  ton / toff              tor-on / tor-off"
echo "  clean-meta <file>       Strip metadata (mat2)"
echo ""
warn "REBOOT to apply all changes: sudo reboot"
echo ""
warn "After reboot, run: vault-open   (to access your private data)"
warn "Remember to run:   vault-close  (before walking away from your machine)"
echo ""
