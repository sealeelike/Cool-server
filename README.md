# Cool-server

A small collection of server hardening and utility scripts for Debian/Ubuntu VPS.

---

## Files

### `ssh-hardening.sh`

An all-in-one SSH hardening script for Debian/Ubuntu.  
Run it once and it will walk you through every step interactively:

- Prompts you to paste your SSH public key and validates it before writing it.
- Enables public-key authentication and restarts SSH.
- Pauses and asks you to verify that key-based login works **before** touching anything else.
- Disables password authentication entirely (`PasswordAuthentication no`, etc.).
- Installs and configures **fail2ban** — bans IPs after 5 failed attempts (30 min), and bans repeat offenders for 7 days (`recidive` jail).

> **Inspiration:** `ssh-public-key.md` (see below).

#### Quick deploy

```bash
bash <(curl -sSL https://raw.githubusercontent.com/sealeelike/Cool-server/main/ssh-hardening.sh)
```

> **Note:** Because the script reads interactive prompts, run this command directly in your terminal — **do not pipe it through a shell without a TTY** (e.g. `curl ... | bash` will not work correctly with the interactive prompts).

Alternatively, download and run locally:

```bash
curl -sSLO https://raw.githubusercontent.com/sealeelike/Cool-server/main/ssh-hardening.sh
chmod +x ssh-hardening.sh
./ssh-hardening.sh
```

Requirements: Debian or Ubuntu, `sudo`/`root`, `openssh-server` already running.

---

### `ssh-public-key.md`

The inspiration behind `ssh-hardening.sh`.  
A simple AI-assisted conversation record outlining the manual step-by-step SOP for hardening a fresh Debian VPS — not intended as standalone documentation, just a reference note.

---

### `tmux-menu.sh`

An interactive menu-driven tmux session manager.  
Run it and you get a numbered menu to:

1. **Create** a new session (auto-named or custom name).
2. **Enter** one of the 5 most recently used sessions.
3. **List** all active sessions.
4. **Clean up** sessions by number, range (`1-3`), comma list (`1,3,5`), or `all`.

#### Quick deploy

```bash
bash <(curl -sSL https://raw.githubusercontent.com/sealeelike/Cool-server/main/tmux-menu.sh)
```

Or download and run locally:

```bash
curl -sSLO https://raw.githubusercontent.com/sealeelike/Cool-server/main/tmux-menu.sh
chmod +x tmux-menu.sh
./tmux-menu.sh
```

Requirements: `tmux` must be installed (`apt-get install -y tmux`).