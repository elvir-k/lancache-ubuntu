# lancache-ubuntu

Set up a [LanCache](https://lancache.net) server on Ubuntu in one command, made for **gaming centers and internet cafés**.

When 20 PCs need the same 30 GB Call of Duty or CS2 update, a normal network downloads it 20 times. With LanCache, the first PC downloads it from the internet and every other PC gets it from the local server at LAN speed.

- Saves internet bandwidth: popular games and updates are downloaded once
- Faster installs and updates: cached games install at local network speed (1 Gbps or more)
- Works with Steam, Epic Games, Battle.net, Riot (League of Legends, Valorant), EA App, Ubisoft Connect, Xbox/Windows Update, PlayStation and [more](https://github.com/uklans/cache-domains)
- Nothing to install on the gaming PCs: they only need to use the server for DNS

## How it works

```
 Gaming PC ──DNS──> LanCache server ──> "steam download? use me"
 Gaming PC ──download──> LanCache server ──(first time only)──> Internet
```

The script runs the official [lancachenet](https://github.com/lancachenet) Docker containers:

- **lancache-dns** answers DNS. Game download servers point to the cache, and everything else is forwarded to normal DNS.
- **monolithic** is the cache. It stores downloads on disk and serves them to every other PC.

## Requirements

- Ubuntu Server 22.04 or 24.04 (20.04 should also work)
- A **static IP** on the gaming center LAN
- A large disk for the cache. 1 TB is a good start, 2 TB or more if you have many different games. An SSD or NVMe gives the best speed when many PCs download at once.
- Ports 53, 80 and 443 free on the server (do not run a web server on the same machine)
- Wired gigabit (or faster) connection to the switch

## Install

```bash
git clone https://github.com/elvir-k/lancache-ubuntu.git
cd lancache-ubuntu
chmod +x install.sh scripts/*.sh
sudo ./install.sh
```

The installer will:

1. Detect the server's IP, free disk space and timezone, and suggest settings
2. Check that ports 53, 80 and 443 are free (and move systemd-resolved off port 53 if needed)
3. Install Docker and Docker Compose if missing
4. Write the settings to `.env`
5. Open the firewall ports if UFW is active
6. Start LanCache and check that DNS is working

For a non-interactive install:

```bash
sudo ./install.sh -y --ip 192.168.1.10 --cache-dir /srv/lancache --size 2t
```

| Option | Meaning | Default |
| --- | --- | --- |
| `--ip` | LAN IP of this server | detected |
| `--cache-dir` | Where cached games are stored | `/srv/lancache` |
| `--size` | Maximum cache size (`500g`, `2t`) | 90% of free space |
| `--dns` | Upstream DNS, separated by `;` | `1.1.1.1; 1.0.0.1` |
| `-y` | Use defaults, don't ask | |

## Point the gaming PCs to the cache

This is the most important step. Open your router's **DHCP settings** and set the **DNS server** to the LanCache server's IP. Don't add a second DNS server like 8.8.8.8, or some PCs will bypass the cache.

Then restart the PCs, or run on each one:

```
ipconfig /release
ipconfig /renew
ipconfig /flushdns
```

To check that a PC is using the cache, run this on it:

```
nslookup lancache.steamcontent.com
```

It should answer with the LanCache server's IP.

## Check that it's working

```bash
sudo ./scripts/status.sh        # today
sudo ./scripts/status.sh 7      # last 7 days
sudo ./scripts/status.sh 0      # all logs
```

This shows the containers, disk usage and how much traffic came from the cache versus the internet, per service:

```
== Traffic (last 1 day(s))
  Service            From cache  From internet Hit rate
  steam              412.35 GB       38.10 GB      92%
  epicgames           64.02 GB       12.44 GB      84%
  TOTAL              476.37 GB       50.54 GB      90%

  Internet bandwidth saved: 476.37 GB
```

*(Example output. Your numbers depend on your traffic.)*

The first download of a game is a **miss** and runs at internet speed. Every later download of it is a **hit** and runs at LAN speed.

You can also watch downloads live:

```bash
sudo tail -f /srv/lancache/logs/access.log
```

## Tips for gaming centers

- **Pre-load the cache.** Download your most popular games on one PC overnight. When customers arrive, every other PC installs them from the cache. For Steam, [SteamPrefill](https://github.com/tpill90/steam-lancache-prefill) can do this automatically from the server.
- **Size the disk for your library.** Add up the size of the games you keep installed, then add room for updates.
- **Disk-restore software** (Deep Freeze, UWF, Shadow Defender) works well with LanCache. Restored PCs re-download updates from the cache instead of the internet.
- **Update monthly:** `sudo ./scripts/update.sh` updates the containers and the list of cached domains. Cached games are kept.

## Limitations

- Only downloads that use plain HTTP can be cached. Steam, Epic, Battle.net, Riot and most others do. HTTPS-only downloads still work but go straight to the internet.
- The PCs must use the LanCache server as their only DNS. Browsers with "DNS over HTTPS" turned on still browse normally, but downloads made through them are not cached.

## Configuration

All settings are in `.env` (see `.env.example` for an explanation of each). After changing it:

```bash
sudo docker compose up -d
```

## Uninstall

First set your router's DHCP DNS back to normal, then:

```bash
sudo ./scripts/uninstall.sh
```

It asks before deleting the cached games and restores the systemd-resolved setting if the installer changed it.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `Port 80 is already in use` | Another web server runs on this machine. Stop it (`sudo systemctl disable --now apache2` or `nginx`) or use a separate server. |
| PCs don't use the cache | Run `nslookup lancache.steamcontent.com` on a PC. If it doesn't return the server IP, the PC is using another DNS server. Check the router's DHCP settings. |
| DNS check fails after install | Wait a minute, then check `sudo docker logs lancache-dns`. |
| Downloads are slow on the first try | Normal: the first download is a miss and comes from the internet. |
| Cache disk is full | LanCache removes the least-used games automatically. Lower `CACHE_DISK_SIZE` in `.env` if the disk itself fills up. |

## Credits

Built on the [lancachenet](https://github.com/lancachenet) Docker images and the [uklans/cache-domains](https://github.com/uklans/cache-domains) list.

## License

MIT
