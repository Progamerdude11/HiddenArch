# arch-privacy-setup

A bash script that turns a fresh Arch install into something reasonably private and hardened. Routes everything through Tor, sets up a VeraCrypt hidden vault, locks down the kernel, spoofs your MAC on boot, and a bunch of other stuff. One script, one reboot.

> **Arch Linux only. Run as root.**

---

## What it actually does

Here's the full list, roughly in order:

1. Routes all traffic through Tor (transparent proxy, not just SOCKS)
2. iptables kill switch: if Tor goes down, so does your internet
3. MAC address randomization on every boot
4. Kernel hardening via sysctl (IPv6 off, ASLR, ptrace restrictions, TCP hardening, etc.)
5. DNS locked to Tor's DNSPort, can't leak
6. Installs the usual privacy toolkit: Tor Browser, KeePassXC, OnionShare, mat2, Thunderbird, Electrum, BleachBit
7. VeraCrypt with a proper outer/hidden volume setup
8. `vault-open` / `vault-close` commands that mount the vault and symlink your sensitive dirs (`.gnupg`, `.ssh`, `Documents`, etc.) automatically
9. Swap disabled
10. AppArmor enabled, Firejail wrapping for Firefox/Chromium/Thunderbird/etc.
11. Shell history disabled system-wide
12. Disables avahi, cups, bluetooth, ModemManager

---

## Routing options

When you run the script it'll ask how you want traffic routed by default. Three choices:

**Option 1: Tor + kill switch on boot**
Everything goes through Tor automatically. If Tor isn't running, nothing gets through. Most private option, most opinionated.

**Option 2: ProtonVPN**
Installs ProtonVPN, leaves the routing to you. Tor is still installed, just not active by default. You'll need to enable the kill switch inside the ProtonVPN app yourself.

**Option 3: Neither**
Installs everything, enables nothing. Use `tor-on` or ProtonVPN manually when you need them.

---

## The vault

This is probably the most useful part of the script honestly. It creates a VeraCrypt container with an outer (decoy) volume and a hidden volume inside it.

The idea is: if you're ever forced to hand over your password, you give the outer one. It mounts to something that looks normal. The hidden volume can't be proven to exist cryptographically.

When you run `vault-open` it mounts the hidden volume and then symlinks your actual sensitive directories into place:

```
~/.gnupg        -> vault/gnupg
~/.ssh          -> vault/ssh
~/Documents     -> vault/documents
~/.tor-browser  -> vault/tor-browser-profile
~/.keepass      -> vault/keepass
~/scripts       -> vault/scripts
```

When you run `vault-close`, it removes the symlinks and dismounts. Your keys, docs, and browser profile only exist in plaintext while the vault is open.

The first time you run the script it walks you through creating both volumes interactively. You pick the size, set your outer password, set your hidden password.

---

## Installation

```bash
git clone https://github.com/yourname/arch-privacy-setup
cd arch-privacy-setup
sudo bash setup.sh
```

It'll ask a few questions upfront (your username, routing choice, vault size) and then mostly run on its own. The VeraCrypt vault creation requires some interaction because you're setting passwords.

Reboot when it's done.

---

## Commands

After install these are all available from anywhere:

```
tor-on              re-enable the Tor kill switch
tor-off             disable it (will warn you first)
tor-check           verify you're actually going through Tor
myip                check your current exit IP via Tor

vault-open          mount vault + apply symlinks
vault-close         remove symlinks + dismount
vault-copy <file>   copy a file into the vault
vault-shred <file>  copy to vault, then shred the original
vault-status        show whether vault is open and what's in it
```

Aliases for the lazy:

```
vo / vc / vs        vault open / close / status
ton / toff          tor-on / tor-off
clean-meta <file>   strip metadata with mat2
```

---

## Packages installed

From the official repos: `tor torsocks nyx obfs4proxy iptables macchanger keepassxc gnupg mat2 onionshare electrum bleachbit secure-delete thunderbird firejail apparmor apparmor-utils curl wget git base-devel htop arch-audit rsync xclip fuse2 wxgtk3`

From AUR (via yay): `veracrypt tor-browser protonvpn`

---

## Things to know / gotchas

**The kill switch blocks ALL non-Tor traffic.** That includes local network stuff if you're not careful. Private ranges (10.x, 172.16.x, 192.168.x) are allowed through, but anything else dies if Tor is down.

**IPv6 is completely disabled.** Easier than trying to route it through Tor properly. If you need it, you'll have to undo that manually.

**The vault symlinks only exist while the vault is mounted.** If you open a terminal before running `vault-open`, your `~/.gnupg` and `~/.ssh` just won't be there. That's by design. Run `vault-close` before you walk away from the machine.

**Populate your outer volume with decoy files.** The script puts a README in there reminding you. A hidden volume is much more convincing if the outer one looks actually used.

**AppArmor requires a kernel parameter.** The script tries to add it to GRUB automatically (`apparmor=1 security=apparmor`), but double-check after rebooting that it actually took.

**ProtonVPN option is a starting point.** The script installs it and that's about it. You need to log in, connect, and enable the kill switch yourself in the app. It doesn't configure anything automatically beyond installing the package.

---

## After reboot

```bash
sudo vault-open     # to get your keys and documents back
tor-check           # to confirm Tor is working
```

And when you're done with a session:

```bash
sudo vault-close
```

---

## License

MIT. Use it, modify it, don't blame me if something breaks.
