# 🌐 Hiddify Multi-IP Outbound

> Make each server IP exit through its **own** IP — automatically. Built for **Hiddify Manager v10**.

If you have a server with **multiple public IPs** (e.g. DE + NL + PL), Hiddify by default sends **all outbound traffic through the primary IP only**. This script fixes that: every connection that arrives on IP `X` exits through IP `X`, automatically and persistently.

---

## ✨ Features

- 🧠 **Zero-config auto-detection** — finds all server IPs, the primary IP, and each country via GeoIP
- 🔁 **Persistent & self-healing** — survives Hiddify `Apply`, reboots, and panel updates (systemd path-watcher + 30s safety timer)
- ⚡ **Zero-disconnect during normal use** — hash-aware restart: services only restart when a config *actually* changes (no 30s disconnects in online games)
- 🔢 **N IPs supported** — not just 2; route as many extra IPs as your server has
- 🧹 **Clean rollback** — `--remove` surgically strips every injection (no fragile backup dependency)
- 🛡️ **Safe** — backs up originals, never touches Hiddify's database, fully reversible

---

## 📋 Requirements

- Hiddify Manager **v10** (HAProxy-in-front architecture)
- Multiple public IPv4 addresses on the server
- Root access
- `python3`, `curl`, `jq` (auto-installed if missing)

---

## 🚀 Install (one line)

```bash
bash <(curl -sSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/hiddify-multi-ip.sh)
```

> Replace `YOUR_USER/YOUR_REPO` after publishing. While testing locally, just run:
> ```bash
> bash hiddify-multi-ip.sh
> ```

The script will:
1. Detect all your IPs + countries (GeoIP)
2. Read your Hiddify domains from `current.json`
3. Inject Xray inbounds + `sendThrough` outbounds + routing rules
4. Inject HAProxy `dst`-based split ACLs
5. Install the self-healing systemd units
6. Apply and restart

At the end you'll see a summary like:

```
  Default exit : 91.124.209.234
  nl     exit   : 147.90.59.145  (Netherlands)
  pl     exit   : 95.135.200.40  (Poland)
```

---

## ✅ Verify

Connect to each config and visit [ipleak.net](https://ipleak.net):

| Config | Expected exit IP |
|--------|------------------|
| Domain on NL IP | 147.90.59.145 |
| Domain on PL IP | 95.135.200.40 |
| Domain on DE IP | 91.124.209.234 |

---

## 🗑️ Uninstall (rollback)

```bash
bash hiddify-multi-ip.sh --remove
```

Surgically removes every injection and restores default Hiddify behavior. Clean and safe.

---

## ⚙️ How it works

Hiddify v10 puts **HAProxy in front of Xray**, binding `:443` across all IPs. The problem: Xray can't tell which destination IP the client connected to — so all traffic exits through the primary IP.

This script solves it at two layers:

```
Client → HAProxy https-in (:443, all IPs)
          │
          ├─ acl dst <NL_IP>  → to_https_in_ssl_nl → in-tcpmode_nl
          ├─ acl dst <PL_IP>  → to_https_in_ssl_pl → in-tcpmode_pl
          └─ default          → to_https_in_ssl    → in-tcpmode
                                  │
                                  └→ Xray inbound (tagged _nl / _pl / default)
                                       │
                                       └→ routing: inboundTag=_nl → outbound multi_nl
                                                  (sendThrough = NL IP)
```

So traffic arriving on IP `X` is tagged at HAProxy, routed to a dedicated Xray inbound, and sent out via `sendThrough` bound to that same IP.

---

## 🛠️ Edit IPs later

```bash
nano /opt/hiddify-manager/multi-ip/config.env
# then re-apply:
bash /opt/hiddify-manager/multi-ip/build.sh
```

---

## ❓ FAQ

**Q: My IP shows the wrong country (e.g. "Netherlands" IP shows as UK)?**
A: That's a GeoIP database inaccuracy of your hosting provider — it does **not** affect routing. The exit IP is still correct. You can relabel via `config.env`.

**Q: Will this survive a Hiddify update?**
A: Yes. The systemd path-watcher detects when Hiddify rewrites configs and re-applies within seconds. The 30s timer is a safety net.

**Q: Does it disconnect existing connections?**
A: Only when a config *actually* changes (e.g. after you click `Apply`). Normal use (gaming, streaming) is unaffected — no 30s disconnects.

---

## 📄 License

MIT — see [LICENSE](LICENSE).

---

## 🙏 Acknowledgements

Built for the [Hiddify](https://github.com/hiddify/Hiddify-Manager) ecosystem. Hiddify is not affiliated with this project.
