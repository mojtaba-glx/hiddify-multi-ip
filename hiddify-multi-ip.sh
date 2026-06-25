#!/bin/bash
# ============================================================================
#  hiddify-multi-ip.sh   —   Smart Multi-IP Outbound Installer for Hiddify v10
# ============================================================================
#  WHAT IT DOES:
#    Each non-primary server IP gets its own outbound (sendThrough) so that
#    traffic arriving on IP X exits through IP X. Domains are irrelevant to the
#    routing logic (DNS already maps each domain to an IP); this script only
#    needs to know the server's IPs.
#
#  AUTO-DETECTS:
#    * All public IPv4 addresses on the server
#    * The primary (default) IP from the routing table
#    * Country of each IP via free GeoIP API (for nice labels)
#    * Domains from Hiddify's current.json (for display/validation)
#
#  PERSISTENT:
#    * systemd path-watcher (fires after every Hiddify Apply)
#    * 30s safety timer
#    * hash-aware restart -> services restart ONLY when config really changed
#      (no disconnects during normal use / online gaming)
#
#  USAGE:   bash hiddify-multi-ip.sh
#  ROLLBACK: bash hiddify-multi-ip.sh --remove
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
#  Self-install shim: when piped via "bash <(curl ...)" or "curl | bash",
#  stdin is the script body, which breaks inner heredocs (<<EOF / <<PY).
#  So if we detect we're being piped, save ourselves to disk first and
#  re-exec from the file (detaching stdin). This makes curl-pipe installs safe.
# ----------------------------------------------------------------------------
if [ ! -t 0 ] && [ -z "${HMI_REEXEC:-}" ]; then
  SCRIPT_PATH="/root/hiddify-multi-ip.sh"
  cat > "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  HMI_REEXEC=1 exec bash "$SCRIPT_PATH" "$@" < /dev/null
fi

HM="/opt/hiddify-manager"
MIDIR="$HM/multi-ip"
BUILD="$MIDIR/build.sh"
ENVF="$MIDIR/config.env"
LOG="$HM/log/multi-ip.log"
SVC="multi-ip-builder"
GEO_API="http://ip-api.com/json"

# ---------- helpers ----------
die(){ echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d "$HM/xray/configs" ] || die "Hiddify not found at $HM"
command -v python3 >/dev/null 2>&1 || die "python3 required (apt install python3)"

# ============================================================================
#  --remove  : full rollback
# ============================================================================
if [ "${1:-}" = "--remove" ]; then
  echo ">>> Removing multi-ip (smart cleanup - no backup dependency) ..."
  systemctl disable --now "${SVC}.path" "${SVC}.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${SVC}.path" "/etc/systemd/system/${SVC}.timer"
  systemctl daemon-reload

  # remove our generated files
  rm -f "$HM/haproxy/99_multi_ip.cfg" "$HM/xray/configs/50_multi_ip.json"
  rm -f /etc/sysctl.d/99-multiip.conf; sysctl --system >/dev/null 2>&1 || true

  XDIR="$HM/xray/configs"; HADIR="$HM/haproxy"
  echo ">>> Cleaning our injections from Xray configs ..."
  for f in "$XDIR/03_routing.json" "$XDIR/06_outbounds.json"; do
    [ -f "$f" ] || continue
    tmp=$(mktemp)
    python3 - "$f" <<'PY' > "$tmp"
import json,sys
d=json.load(open(sys.argv[1]))
# remove multi_ outbounds
if "outbounds" in d:
    d["outbounds"]=[o for o in d["outbounds"] if not str(o.get("tag","")).startswith("multi_")]
# remove multi_ routing rules + rules referencing multi_ inbound tags
rules=d.get("routing",{}).get("rules",[])
clean=[]
for r in rules:
    ot=str(r.get("outboundTag",""))
    it=r.get("inboundTag") or []
    if ot.startswith("multi_"): continue
    if isinstance(it,list) and any(str(t).endswith("_nl") or str(t).endswith("_pl") or str(t).endswith("_gb") or str(t).endswith("_uk") or str(t).endswith("_ip1") or str(t).endswith("_ip2") for t in it): continue
    clean.append(r)
d["routing"]["rules"]=clean
print(json.dumps(d,indent=2))
PY
    if [ -s "$tmp" ]; then mv "$tmp" "$f"; else rm -f "$tmp"; fi
  done

  echo ">>> Cleaning our injections from HAProxy config ..."
  if [ -f "$HADIR/haproxy.cfg" ]; then
    # strip lines between MULTI-IP-INJECT markers + the markers themselves
    sed -i '/# MULTI-IP-INJECT >>>/,/# MULTI-IP-INJECT <<</d' "$HADIR/haproxy.cfg"
  fi

  echo ">>> Restarting services ..."
  systemctl restart hiddify-haproxy 2>/dev/null || true
  sleep 1
  systemctl restart hiddify-xray 2>/dev/null || true
  echo ">>> Done. Multi-IP removed cleanly. Services restarted."
  exit 0
fi

# ============================================================================
#  STEP 1 — AUTO-DETECT IPs
# ============================================================================
echo "=== Step 1/6: detecting IPs ==="

PRIMARY_IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)"
[ -n "$PRIMARY_IP" ] || die "could not detect primary IP (no default route?)"

# all public IPv4 (exclude loopback/private via scope global + manual private filter)
mapfile -t ALL_IPS < <(ip -4 addr show scope global | grep -oP 'inet \K[0-9.]+' \
  | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)' | sort -u)

EXTRA_IPS=()
for ip in "${ALL_IPS[@]}"; do
  [ "$ip" != "$PRIMARY_IP" ] && EXTRA_IPS+=("$ip")
done

echo "  primary (default) IP : $PRIMARY_IP  <- traffic exits here by default (untouched)"
echo "  all server IPs       : ${ALL_IPS[*]}"
echo "  extra IPs to route   : ${EXTRA_IPS[*]:-<none>}"
[ "${#EXTRA_IPS[@]}" -gt 0 ] || { echo; echo ">>> Only one public IP. Nothing to do. Exiting."; exit 0; }

# ============================================================================
#  STEP 2 — GeoIP country lookup (labels only; not required for routing)
# ============================================================================
echo "=== Step 2/6: resolving countries (labels) ==="
geo_for(){ # ip -> "CC|Country"
  local ip="$1" j cc cn
  j="$(curl -s --max-time 5 "$GEO_API/$ip" 2>/dev/null || true)"
  cc="$(printf '%s' "$j" | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print((d.get("countryCode") or "x").lower()+"|"+(d.get("country") or "unknown"))
except: print("x|unknown")' 2>/dev/null)"
  [ -n "$cc" ] || cc="x|unknown"
  printf '%s' "$cc"
}

declare -a TAGS=() IPS=() COUNTRIES=()
for ip in "${EXTRA_IPS[@]}"; do
  g="$(geo_for "$ip")"
  cc="${g%%|*}"; cn="${g##*|}"
  # fallback tag if country lookup failed -> ip1, ip2...
  tag="$cc"
  [ "$tag" != "x" ] || tag="ip$(( ${#TAGS[@]} + 1 ))"
  TAGS+=("$tag"); IPS+=("$ip"); COUNTRIES+=("$cn")
  printf '  %-16s  %s  (%s)\n' "$ip" "$tag" "$cn"
done

# ============================================================================
#  STEP 3 — read domains from Hiddify (display + validate)
# ============================================================================
echo "=== Step 3/6: reading domains from Hiddify ==="
CUR="$HM/current.json"
if [ -f "$CUR" ]; then
  python3 - "$CUR" "${IPS[@]}" <<'PY'
import json,sys,socket
cur=json.load(open(sys.argv[1])); ips=sys.argv[2:]
doms=[d.get("domain") for d in (cur.get("hconfigs",{}) or {}).get("domains",[]) if d.get("domain")]
# hiddify may store domains in different spots; try a few
if not doms:
    for d in cur.get("domains",[]) or []:
        if isinstance(d,dict) and d.get("domain"): doms.append(d["domain"])
print("  domains registered:", ", ".join(doms) if doms else "<none found>")
for d in doms:
    try:
        r=socket.gethostbyname(d)
        mark = "<-- routes to this server" if r in ips else ""
        print(f"    {d:30s} -> {r} {mark}")
    except Exception as e:
        print(f"    {d:30s} -> (resolve failed)")
PY
else
  echo "  (current.json not found, skipping domain display)"
fi

# ============================================================================
#  STEP 4 — write config.env + build.sh
# ============================================================================
echo "=== Step 4/6: writing config + builder ==="
mkdir -p "$MIDIR" "$HM/log"

# --- config.env: PRIMARY=... then one EXTRA line per non-primary IP ---
{
  echo "# Auto-generated by hiddify-multi-ip.sh"
  echo "# PRIMARY = default exit IP (untouched). EXTRA = tag|ip  per routed IP."
  echo "PRIMARY=$PRIMARY_IP"
  for i in "${!TAGS[@]}"; do
    echo "EXTRA=${TAGS[$i]}|${IPS[$i]}|${COUNTRIES[$i]}"
  done
} > "$ENVF"
echo "  wrote $ENVF"

# --- build.sh : generic, hash-aware, loops over EXTRA IPs ---
cat > "$BUILD" <<'BUILD_EOF'
#!/bin/bash
set -euo pipefail
HM="/opt/hiddify-manager"; XDIR="$HM/xray/configs"; HADIR="$HM/haproxy"
LOG="$HM/log/multi-ip.log"; ENVF="$HM/multi-ip/config.env"; mkdir -p "$(dirname "$LOG")"
ts(){ date -Iseconds; }

# ---- hash guard: skip entirely if source configs unchanged (zero restart) ----
_hash_file="$HM/multi-ip/.src_hash"
_src_hash(){ cat "$XDIR/05_inbounds_new.json" "$XDIR/06_outbounds.json" "$XDIR/03_routing.json" \
             "$HADIR/haproxy.cfg" "$ENVF" 2>/dev/null | sha256sum | cut -d' ' -f1; }
_now="$(_src_hash)"; _prev="$(cat "$_hash_file" 2>/dev/null || echo none)"
[ "$_now" = "$_prev" ] && exit 0

python3 - "$XDIR" "$HADIR" "$ENVF" "$LOG" <<'PY'
import json,os,sys,re,copy,datetime
XDIR,HADIR,ENVF,LOG=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
def log(m):
    with open(LOG,"a") as f: f.write(f"{datetime.datetime.now().isoformat()} {m}\n")
    print(m)

# parse EXTRA lines -> [(tag, ip), ...]
extras=[]
for ln in open(ENVF):
    if ln.startswith("EXTRA="):
        tag,ip,_=ln[6:].strip().split("|",2); extras.append((tag,ip))
assert extras, "no EXTRA IPs in config.env"

# ================= XRAY =================
inb_file=f"{XDIR}/05_inbounds_new.json"
base=json.load(open(inb_file)); src=base.get("inbounds",[])
new_inbs=[]; tag_map={}   # tag -> [inbound tags]
for tag,ip in extras:
    tlist=[]
    for ib in src:
        t=ib.get("tag","")
        if not t: continue
        c=copy.deepcopy(ib); c["tag"]=t+"_"+tag
        l=c.get("listen","")
        if l.startswith("@@"): c["listen"]=l+"_"+tag
        new_inbs.append(c); tlist.append(c["tag"])
    tag_map[tag]=(ip,tlist)
json.dump({"inbounds":new_inbs}, open(f"{XDIR}/50_multi_ip.json","w"), indent=2)
log(f"[xray] 50_multi_ip.json: {len(new_inbs)} inbounds across {len(extras)} IPs")

# outbounds (idempotent)
ob=json.load(open(f"{XDIR}/06_outbounds.json"))
obs=[o for o in ob.get("outbounds",[]) if not str(o.get("tag","")).startswith("multi_")]
for tag,ip in extras:
    obs.append({"tag":f"multi_{tag}","protocol":"freedom","settings":{},"sendThrough":ip})
ob["outbounds"]=obs; json.dump(ob,open(f"{XDIR}/06_outbounds.json","w"),indent=2)
log(f"[xray] outbounds: "+" ".join(f"multi_{t}({i})" for t,i in extras))

# routing (idempotent prepend)
rt=json.load(open(f"{XDIR}/03_routing.json"))
rules=[r for r in rt.get("routing",{}).get("rules",[]) if not str(r.get("outboundTag","")).startswith("multi_")]
nr=[]
for tag,(ip,tl) in tag_map.items():
    if tl: nr.append({"type":"field","inboundTag":tl,"outboundTag":f"multi_{tag}"})
rt["routing"]["rules"]=nr+rules
json.dump(rt,open(f"{XDIR}/03_routing.json","w"),indent=2)
log(f"[xray] routing rules prepended")

# ================= HAPROXY =================
cfg=f"{HADIR}/haproxy.cfg"
lines=open(cfg).read().split("\n")
def section(name):
    s=None
    for i,l in enumerate(lines):
        ws=l.split()
        if len(ws)>=2 and ws[0] in ("frontend","backend","listen") and ws[1]==name and not l[0] in " \t#":
            s=i; break
    if s is None: return None
    e=len(lines)
    for j in range(s+1,len(lines)):
        l2=lines[j]
        if re.match(r'^(frontend|backend|listen|global|defaults|cache)\b',l2) and not l2[0] in " \t#":
            e=j; break
    return (s,e)
def block(seg): s,e=seg; return lines[s:e]
def all_backends(prefix):
    r={}
    for l in lines:
        ws=l.split()
        if len(ws)>=2 and ws[0]=="backend" and ws[1].startswith(prefix) and not l[0] in " \t#":
            seg=section(ws[1])
            if seg: r[ws[1]]=seg
    return r

tcp=section("in-tcpmode"); bks=all_backends("v10-")
parts=["# ==== MULTI-IP EXTRA (auto-generated) ====","# do not edit manually"]
if tcp:
    bl=block(tcp)
    for tag,ip in extras:
        out=[]
        for l in bl:
            if l.startswith("frontend in-tcpmode"):
                out.append(l.replace("in-tcpmode","in-tcpmode_"+tag)); continue
            if re.match(r'\s*bind\s+:80', l): continue
            if "abns@https_in_ssl" in l:
                out.append(l.replace("abns@https_in_ssl","abns@https_in_ssl_"+tag)); continue
            m=re.match(r'(\s*use_backend\s+)(v10-\S+)(.*)',l)
            if m and m.group(2).startswith("v10-"):
                out.append(m.group(1)+m.group(2)+"_"+tag+m.group(3)); continue
            out.append(l)
        parts.append("\n".join(out))
for name,seg in bks.items():
    bl=block(seg)
    for tag,ip in extras:
        out=[]
        for l in bl:
            if l.startswith("backend "+name):
                out.append(l.replace(name,name+"_"+tag)); continue
            if "server" in l and "abns@" in l:
                out.append(l.replace("abns@"+name,"abns@"+name+"_"+tag)); continue
            out.append(l)
        parts.append("\n".join(out))
for tag,ip in extras:
    parts += [f"backend to_https_in_ssl_{tag}",
              f"    server h abns@https_in_ssl_{tag} send-proxy-v2 tfo"]
open(f"{HADIR}/99_multi_ip.cfg","w").write("\n\n".join(parts)+"\n")
log(f"[haproxy] 99_multi_ip.cfg: {len(extras)} IP(s)")

# inject dst ACLs into https-in (idempotent)
hs=section("https-in")
if hs:
    s,e=hs; head=lines[:s]; body=lines[s:e]; tail=lines[e:]
    body=[l for l in body if "# MULTI-IP-INJECT" not in l]
    inj=["    # MULTI-IP-INJECT >>>"]
    for tag,ip in extras:
        inj.append(f"    acl mi_dst_{tag} dst {ip}")
    for tag,ip in extras:
        inj.append(f"    use_backend to_https_in_ssl_{tag} if mi_dst_{tag}")
    inj.append("    # MULTI-IP-INJECT <<<")
    di=next((i for i,l in enumerate(body) if l.strip().startswith("default_backend")),len(body))
    body=body[:di]+inj+body[di:]; lines=head+body+tail
    open(cfg,"w").write("\n".join(lines))
    log("[haproxy] dst ACLs injected into https-in")
log("[done] build complete")
PY

# ---- restart + record hash (reached ONLY when something changed) ----
systemctl restart hiddify-haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null || true
sleep 1
systemctl restart hiddify-xray 2>/dev/null || true
echo "$(_src_hash)" > "$_hash_file"
echo "$(ts) config changed -> restarted haproxy+xray" >> "$LOG"
BUILD_EOF
chmod +x "$BUILD"
echo "  wrote $BUILD"

# ============================================================================
#  STEP 5 — backup originals + kernel + systemd
# ============================================================================
echo "=== Step 5/6: backup + kernel + systemd ==="
BK="$MIDIR/backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
cp -a "$HM/haproxy/haproxy.cfg" "$BK/" 2>/dev/null || true
cp -a "$HM/xray/configs/03_routing.json" "$BK/" 2>/dev/null || true
cp -a "$HM/xray/configs/05_inbounds_new.json" "$BK/" 2>/dev/null || true
cp -a "$HM/xray/configs/06_outbounds.json" "$BK/" 2>/dev/null || true
echo "  backup -> $BK"

cat > /etc/sysctl.d/99-multiip.conf <<EOF
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
sysctl --system >/dev/null 2>&1 || true

cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=Hiddify Multi-IP Builder
After=network-online.target
[Service]
Type=oneshot
ExecStart=$BUILD
EOF
cat > "/etc/systemd/system/${SVC}.path" <<EOF
[Unit]
Description=Watch Hiddify config dirs
[Path]
PathChanged=$HM/haproxy
PathChanged=$HM/xray/configs
Unit=${SVC}.service
[Install]
WantedBy=paths.target
EOF
cat > "/etc/systemd/system/${SVC}.timer" <<EOF
[Unit]
Description=Periodic re-apply Multi-IP
[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now "${SVC}.path" >/dev/null 2>&1 || true
systemctl enable --now "${SVC}.timer" >/dev/null 2>&1 || true

# convenient uninstall wrapper (so users can remove without re-running curl)
cat > "/root/hiddify-multi-ip-remove.sh" <<'UNINSTALL_EOF'
#!/bin/bash
exec bash /root/hiddify-multi-ip.sh --remove "$@"
UNINSTALL_EOF
chmod +x "/root/hiddify-multi-ip-remove.sh"
echo "  systemd units installed"

# ============================================================================
#  STEP 6 — first run
# ============================================================================
echo "=== Step 6/6: applying ==="
"$BUILD"

echo
echo "============================================================"
echo "  DONE. Multi-IP outbound is active."
echo
echo "  Default exit : $PRIMARY_IP"
for i in "${!TAGS[@]}"; do
  printf "  %-6s exit   : %s  (%s)\n" "${TAGS[$i]}" "${IPS[$i]}" "${COUNTRIES[$i]}"
done
echo
echo "  Verify services:   systemctl is-active hiddify-xray hiddify-haproxy"
echo "  Watch build log:   tail -f $LOG"
echo "  Edit IPs later:    nano $ENVF  (then run $BUILD)"
SELF="${BASH_SOURCE[0]:-$0}"
echo "  ROLLBACK:          bash \"$SELF\" --remove"
echo "============================================================"
