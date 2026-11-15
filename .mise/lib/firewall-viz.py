#!/usr/bin/env python3
"""Build the self-contained HTML zone matrix of the UniFi zone-based firewall.

usage: python3 -I firewall-viz.py <input-dir> <out.html>

Input dir (written by .mise/tasks/unifi/firewall-viz): policies.json,
zones.json, networks.json, groups.json, state.json (tofu state), cidrs.json
(firewall_cidrs), policies.tf (unifi/firewall_policies.tf, for the keys
declared in git but not in the state, e.g. after a failed apply). The page carries no addresses: raw address lists become
firewall_cidrs slugs or "N addresses", groups show by name only, and the
finished HTML is scanned for IPv4/IPv6/MAC patterns before it is written.
"""
import datetime
import ipaddress
import json
import os
import re
import sys

ZONE_ORDER = ["internal", "iot", "work", "vpn", "external", "gateway"]
DEFAULTS = {"Allow All Traffic": "ALLOW", "Block All Traffic": "BLOCK", "Allow Return Traffic": "RETURN"}

SCANS = {
    "IPv4": re.compile(r"(?<![\w.])\d{1,3}(?:\.\d{1,3}){3}(?![\w.])"),
    "IPv6": re.compile(r"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])|(?<![\w:])::[0-9A-Fa-f:]*[0-9A-Fa-f](?![\w:])"),
    "MAC": re.compile(r"(?<![\w:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![\w:-])"),
}


def load(d, name):
    with open(os.path.join(d, name)) as f:
        return json.load(f)


def norm(cidr):
    try:
        return str(ipaddress.ip_network(cidr.strip(), strict=False))
    except ValueError:
        return cidr.strip()


def main(d, out):
    policies = load(d, "policies.json")
    zones = {z["_id"]: z for z in load(d, "zones.json")}
    nets = {n["_id"]: n for n in load(d, "networks.json")["data"]}
    groups = {g["_id"]: g for g in load(d, "groups.json")["data"]}
    state = load(d, "state.json")
    cidrs = load(d, "cidrs.json")
    slug_by_cidr = {norm(v): k for k, v in cidrs.items()}

    tofu = {}  # policy _id -> (resource, key)
    group_tofu = {}
    for r in state.get("resources", []):
        if r.get("mode") != "managed":
            continue
        for i in r.get("instances", []):
            a = i.get("attributes", {})
            if r["type"] == "unifi_firewall_policy":
                tofu[a.get("id")] = (r["name"], i.get("index_key"))
            elif r["type"] == "unifi_firewall_group":
                group_tofu[a.get("id")] = r["name"]

    def ports_text(side):
        pt = side.get("port_matching_type", "ANY")
        neg = "NOT " if side.get("match_opposite_ports") else ""
        if pt == "OBJECT" and side.get("port_group_id"):
            g = groups.get(side["port_group_id"], {})
            mem = ",".join(g.get("group_members", []))
            return f"{neg}port group {g.get('name', '?')} ({mem})"
        if pt == "SPECIFIC" and side.get("port"):
            return f"{neg}port {side['port']}"
        return ""

    def side_info(side):
        t = side.get("matching_target", "ANY")
        neg = "NOT " if side.get("match_opposite_ips") else ""
        if t == "NETWORK":
            neg = "NOT " if side.get("match_opposite_networks") else ""
            names = [nets.get(n, {}).get("name", "unknown") for n in side.get("network_ids", [])]
            main_t = neg + ", ".join(names) + (" network" if len(names) == 1 else " networks")
        elif t == "IP":
            if side.get("ip_group_id"):
                g = groups.get(side["ip_group_id"], {})
                main_t = f"{neg}group {g.get('name', '?')}"
            else:
                ips = side.get("ips") or []
                slugs = []
                for ip in ips:
                    s = slug_by_cidr.get(norm(ip))
                    slugs.append(s)
                if ips and all(slugs):
                    main_t = neg + "slugs " + ", ".join(slugs)
                else:
                    main_t = f"{neg}{len(ips)} address" + ("" if len(ips) == 1 else "es")
        elif t == "ANY":
            main_t = "any"
        else:
            main_t = t.lower()
        if side.get("match_mac"):
            main_t += " (MAC filter)"
        p = ports_text(side)
        return main_t, p, t

    rows = []
    used = set()
    for p in policies:
        zs, zd = p["source"]["zone_id"], p["destination"]["zone_id"]
        used.update([zs, zd])
        st, sp, st_t = side_info(p["source"])
        dt, dp, dt_t = side_info(p["destination"])
        cst = p.get("connection_state_type", "ALL")
        states = "all" if cst == "ALL" else (cst if cst != "CUSTOM" else "CUSTOM: " + ", ".join(p.get("connection_states", [])))
        tf = tofu.get(p["_id"])
        rows.append({
            "id": len(rows),
            "name": p.get("name", ""),
            "act": p.get("action", "?"),
            "idx": p.get("index", 0),
            "pre": bool(p.get("predefined")),
            "en": bool(p.get("enabled", True)),
            "proto": p.get("protocol", "all"),
            "ipv": p.get("ip_version", "BOTH"),
            "st": states,
            "stAll": cst == "ALL",
            "log": bool(p.get("logging")),
            "hits": p.get("hits"),
            "last": p.get("last_hit"),
            "zs": zones.get(zs, {}).get("name", "?"),
            "zd": zones.get(zd, {}).get("name", "?"),
            "src": st, "srcP": sp, "dst": dt, "dstP": dp,
            "tofu": (f"{tf[0]}[{tf[1]}]" if tf and tf[1] else tf[0]) if tf else None,
            "tkey": (tf[1] if tf else None),
            "_sk": (st_t, tuple(sorted(p["source"].get("network_ids", []))), bool(sp), bool(p["source"].get("match_opposite_ips")) or bool(p["source"].get("match_opposite_networks"))),
            "_dk": (dt_t, bool(dp), bool(p["destination"].get("match_opposite_ips"))),
        })

    # zones that occur, ordered
    znames = sorted({zones[z]["name"] for z in used if z in zones},
                    key=lambda n: (ZONE_ORDER.index(n.lower()) if n.lower() in ZONE_ORDER else 99, n.lower()))

    # the matrix shows the core zones plus any other zone that carries a custom policy
    custom_zones = {r["zs"] for r in rows if not r["pre"]} | {r["zd"] for r in rows if not r["pre"]}
    mzones = [n for n in znames if n.lower() in ZONE_ORDER or n in custom_zones]

    # pairs: evaluation order, defaults, hazards
    pairs = {}
    for r in rows:
        pairs.setdefault((r["zs"], r["zd"]), []).append(r)
    for (zs, zd), lst in pairs.items():
        lst.sort(key=lambda r: (r["pre"], r["idx"]))
        cust_idx = [r["idx"] for r in lst if not r["pre"]]
        for pos, r in enumerate(lst, 1):
            r["pos"] = pos
            r["haz"] = []
        for pos, r in enumerate(lst):
            if r["pre"] and any(ci > r["idx"] for ci in cust_idx):
                r["haz"].append("predefined policy is indexed before custom policies; UniFi evaluates custom ones first, check the order")
        for i, b in enumerate(lst):
            if b["act"] not in ("BLOCK", "REJECT") or not b["en"] or b["pre"] or not b["stAll"]:
                continue
            if b["_dk"] != ("ANY", False, False):
                continue
            for a in lst[i + 1:]:
                if a["act"] != "ALLOW" or not a["en"] or a["pre"]:
                    continue
                if b["proto"] not in ("all", a["proto"]) or b["ipv"] not in ("BOTH", a["ipv"]):
                    continue
                bs, as_ = b["_sk"], a["_sk"]
                same_src = (bs[0] == "ANY" and not bs[2]) or (bs[0] == "NETWORK" and not bs[3] and as_[0] == "NETWORK" and bs[1] == as_[1] and not as_[3])
                if same_src:
                    a["haz"].append(f"ALLOW comes after BLOCK #{b['pos']} ({b['name']}), which already matches all of its traffic")

    cells = {}
    for (zs, zd), lst in pairs.items():
        default = None
        for r in lst:
            if r["pre"] and r["name"] in DEFAULTS:
                default = DEFAULTS[r["name"]]
        cust = [r for r in lst if not r["pre"]]
        cells[f"{zs}|{zd}"] = {
            "ids": [r["id"] for r in lst],
            "default": default,
            "custom": len(cust),
            "allow": sum(1 for r in cust if r["act"] == "ALLOW"),
            "block": sum(1 for r in cust if r["act"] != "ALLOW"),
            "haz": sum(1 for r in lst if r["haz"]),
        }

    # policy keys declared in git ("<src>-<dst>/<slug>" = {) that the state lacks
    with open(os.path.join(d, "policies.tf")) as f:
        declared = re.findall(r'^\s*"([a-z]+-[a-z]+/[a-z0-9-]+)"\s*=\s*\{', f.read(), re.M)
    state_keys = {k for _, k in tofu.values()}
    zname = {z["name"].lower(): z["name"] for z in zones.values()}
    pending = []
    for k in declared:
        if k in state_keys:
            continue
        zs, zd = (zname.get(z, z) for z in k.split("/")[0].split("-"))
        pending.append({"key": k, "zs": zs, "zd": zd})
        cell = cells.setdefault(f"{zs}|{zd}", {"ids": [], "default": None, "custom": 0, "allow": 0, "block": 0, "haz": 0})
        cell["pending"] = cell.get("pending", 0) + 1

    cust_rows = [r for r in rows if not r["pre"]]
    live_ids = {p["_id"] for p in policies}
    stats = {
        "total": len(rows),
        "custom": len(cust_rows),
        "predefined": len(rows) - len(cust_rows),
        "tofu": sum(1 for r in cust_rows if r["tofu"]),
        "drift": sum(1 for r in cust_rows if not r["tofu"]),
        "orphans": sum(1 for k in tofu if k not in live_ids),
        "hazards": sum(1 for r in rows if r["haz"]),
        "pending": len(pending),
    }
    for r in rows:
        for k in ("_sk", "_dk"):
            r.pop(k)
    data = {
        "generated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "generatedMs": int(datetime.datetime.now().timestamp() * 1000),
        "zones": mzones, "allZones": znames, "cells": cells, "policies": rows, "stats": stats,
        "pending": pending,
    }
    blob = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    page = TEMPLATE.replace("/*DATA*/", blob)

    for label, rx in SCANS.items():
        m = rx.search(page)
        if m:
            s = max(0, m.start() - 40)
            print(f"refusing to write: {label} pattern in output near {page[s:m.end() + 20]!r}", file=sys.stderr)
            return 1
    with open(out, "w") as f:
        f.write(page)
    print(f"{out}: {stats}")
    return 0


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UniFi Firewall Matrix</title>
<style>
:root{
  --bg:#f6f7f9;--panel:#fff;--ink:#1c2128;--muted:#5d6672;--line:#d9dee5;--accent:#2f5fb3;
  --allow:#1d7a46;--allow-bg:#e3f4ea;--block:#b3261e;--block-bg:#fbe6e4;--ret:#8a6200;--ret-bg:#fbf0d3;--unk-bg:#eceff3;
  --warn:#b45309;--warn-bg:#fdecd2;--shadow:0 1px 2px rgba(0,0,0,.06);
}
@media (prefers-color-scheme: dark){:root{
  --bg:#12151a;--panel:#1a1f26;--ink:#e4e8ee;--muted:#9aa4b2;--line:#303844;--accent:#7aa2f0;
  --allow:#5fd08d;--allow-bg:#17331f;--block:#ff8a80;--block-bg:#3a1b1a;--ret:#e8c25a;--ret-bg:#352b10;--unk-bg:#242a33;
  --warn:#f5b25a;--warn-bg:#3b2a12;--shadow:none;
}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-variant-numeric:tabular-nums}
.wrap{max-width:1400px;margin:0 auto;padding:16px}
header{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:baseline;gap:4px 16px;margin-bottom:12px}
h1{font-size:20px;margin:0}h2{font-size:15px;margin:0 0 8px}
.muted{color:var(--muted)}
.mono,code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:8px;margin-bottom:16px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:8px 10px;box-shadow:var(--shadow)}
.tile b{display:block;font-size:22px}.tile span{color:var(--muted);font-size:12px}
.tile.bad b{color:var(--warn)}
section{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:12px;margin-bottom:16px;box-shadow:var(--shadow)}
.scroll{overflow-x:auto;max-width:100%}
table{border-collapse:collapse;width:100%}
.matrix{width:auto;min-width:100%}
.matrix th,.matrix td{border:1px solid var(--line);padding:0}
.matrix thead th{padding:6px 8px;background:var(--bg);font-weight:600;text-align:center;white-space:nowrap}
.matrix tbody th{padding:6px 8px;background:var(--bg);text-align:left;white-space:nowrap;position:sticky;left:0}
.corner{font-weight:400;color:var(--muted);font-size:11px}
.cell{display:block;width:100%;min-width:104px;height:100%;padding:6px 8px;border:0;font:inherit;color:inherit;text-align:left;cursor:pointer;background:var(--unk-bg)}
.cell:hover,.cell:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
.cell.sel{outline:3px solid var(--accent);outline-offset:-3px}
.cell.ALLOW{background:var(--allow-bg)}.cell.BLOCK{background:var(--block-bg)}.cell.RETURN{background:var(--ret-bg)}
.cell.none{cursor:default;opacity:.6}
.dflt{font-size:11px;font-weight:700;letter-spacing:.04em}
.cell.ALLOW .dflt{color:var(--allow)}.cell.BLOCK .dflt{color:var(--block)}.cell.RETURN .dflt{color:var(--ret)}
.cnt{font-size:12px}
.chips{display:flex;gap:4px;margin-top:2px;flex-wrap:wrap}
.chip{font-size:11px;padding:0 5px;border-radius:8px;border:1px solid currentColor;font-weight:600}
.chip.a{color:var(--allow)}.chip.b{color:var(--block)}.chip.w{color:var(--warn)}
.bar{display:flex;height:4px;margin-top:3px;border-radius:2px;overflow:hidden;background:var(--line)}
.bar i{display:block;height:100%}.bar .a{background:var(--allow)}.bar .b{background:var(--block)}
.legend{display:flex;flex-wrap:wrap;gap:12px;margin:8px 0 0;font-size:12px;color:var(--muted)}
.badge{display:inline-block;padding:0 6px;border-radius:3px;font-size:11px;font-weight:700;letter-spacing:.03em;white-space:nowrap}
.badge.ALLOW{background:var(--allow-bg);color:var(--allow);border:1px solid var(--allow)}
.badge.BLOCK,.badge.REJECT{background:var(--block-bg);color:var(--block);border:1px solid var(--block)}
.badge.warn{background:var(--warn-bg);color:var(--warn);border:1px solid var(--warn)}
.badge.pre{color:var(--muted);border:1px solid var(--line)}
.list th,.list td{padding:5px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
.list th{background:var(--bg);white-space:nowrap;font-weight:600;position:sticky;top:0}
.list th.sort{cursor:pointer;user-select:none}
.list tr.off td{opacity:.5}
.list tr.off td.name{text-decoration:line-through}
.list tr.haz td{box-shadow:inset 3px 0 0 var(--warn)}
.haznote{color:var(--warn);font-size:12px;margin-top:2px}
.num{text-align:right!important;white-space:nowrap}
.filters{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px}
input,select{font:inherit;color:var(--ink);background:var(--bg);border:1px solid var(--line);border-radius:4px;padding:4px 6px;max-width:100%}
#detail:empty{display:none}
button.close{float:right;font:inherit;background:none;border:1px solid var(--line);color:var(--ink);border-radius:4px;cursor:pointer;padding:0 8px}
</style>
</head>
<body>
<div class="wrap">
<header><h1>UniFi Firewall Matrix</h1><span class="muted" id="gen"></span></header>
<div class="tiles" id="tiles"></div>
<section>
  <h2>Zone matrix <span class="muted" style="font-weight:400">rows: source zone, columns: destination zone. Click a cell.</span></h2>
  <div class="scroll"><table class="matrix" id="matrix"></table></div>
  <div class="legend">
    <span><b style="color:var(--allow)">ALLOW</b> default: pair is open</span>
    <span><b style="color:var(--block)">BLOCK</b> default: pair is closed</span>
    <span><b style="color:var(--ret)">RETURN</b> default: only return traffic</span>
    <span>chips: custom allow / block / order hazards</span>
  </div>
</section>
<section id="detail"></section>
<section>
  <h2>All policies</h2>
  <div class="filters">
    <select id="fs"></select><select id="fd"></select><select id="fa"></select>
    <select id="fk"><option value="">custom + predefined</option><option value="c">custom only</option><option value="d">drift only</option><option value="h">hazards only</option></select>
    <input id="ft" type="search" placeholder="filter text" aria-label="filter text">
    <span class="muted" id="fc"></span>
  </div>
  <div class="scroll"><table class="list" id="all"></table></div>
</section>
</div>
<script type="application/json" id="data">/*DATA*/</script>
<script>
(function(){
var D=JSON.parse(document.getElementById('data').textContent);
var P=D.policies,Z=D.zones;
function h(t,a,c){var e=document.createElement(t);if(a)for(var k in a){if(k==='class')e.className=a[k];else e.setAttribute(k,a[k]);}
  (Array.isArray(c)?c:(c==null?[]:[c])).forEach(function(x){e.appendChild(typeof x==='string'||typeof x==='number'?document.createTextNode(String(x)):x);});return e;}
function rel(ms){if(!ms)return '-';var s=Math.max(0,(D.generatedMs-ms)/1000);
  if(s<90)return 'just now';var m=s/60;if(m<90)return Math.round(m)+' min ago';var hh=m/60;if(hh<36)return Math.round(hh)+' h ago';
  var d=hh/24;if(d<60)return Math.round(d)+' d ago';return Math.round(d/30)+' mo ago';}
document.getElementById('gen').textContent='generated '+D.generated;
var S=D.stats,tiles=[['total',S.total],['custom',S.custom],['predefined',S.predefined],['in tofu',S.tofu],['drift (not in tofu)',S.drift,S.drift>0],['order hazards',S.hazards,S.hazards>0]];
if(S.orphans)tiles.push(['in state, not live',S.orphans,true]);
tiles.push(['in git, not applied',S.pending,S.pending>0]);
var tl=document.getElementById('tiles');
tiles.forEach(function(t){tl.appendChild(h('div',{class:'tile'+(t[2]?' bad':'')},[h('b',null,t[1]),h('span',null,t[0])]));});

function side(r,w){var t=r[w];var p=r[w+'P'];return h('div',null,[t].concat(p?[h('div',{class:'muted'},p)]:[]));}
function actBadge(a){return h('span',{class:'badge '+a},a);}
function tofuCell(r){if(r.tofu)return h('span',{class:'mono'},r.tkey||r.tofu);
  if(r.pre)return h('span',{class:'muted'},'-');return h('span',{class:'badge warn',title:'custom policy missing from the tofu state'},'not in tofu');}
var COLS={
 pos:['#',function(r){return r.pos;},true],
 pair:['Pair',function(r){return r.zs+' → '+r.zd;}],
 act:['Action',function(r){return actBadge(r.act);}],
 name:['Name',function(r){var c=[r.name];if(r.pre)c.push(' ',h('span',{class:'badge pre'},'predefined'));
   var d=h('div',null,c);r.haz.forEach(function(x){d.appendChild(h('div',{class:'haznote'},'⚠ '+x));});return d;},false,'name'],
 tofu:['Tofu key',tofuCell],
 proto:['Proto',function(r){return r.proto;}],
 ipv:['IP',function(r){return r.ipv;}],
 st:['States',function(r){return r.st;}],
 src:['Source',function(r){return side(r,'src');}],
 dst:['Destination',function(r){return side(r,'dst');}],
 log:['Log',function(r){return r.log?'yes':'';}],
 hits:['Hits',function(r){return r.hits==null?'-':r.hits;},true],
 last:['Last hit',function(r){return rel(r.last);},true]
};
var SORTK={pos:'pos',pair:null,act:'act',name:'name',tofu:'tkey',proto:'proto',ipv:'ipv',st:'st',src:'src',dst:'dst',log:'log',hits:'hits',last:'last'};
function build(tbl,cols,rows,sortable,state){
  tbl.textContent='';
  var tr=h('tr');cols.forEach(function(c){var d=COLS[c];var th=h('th',{class:(d[2]?'num ':'')+(sortable?'sort':'')},d[0]+(sortable&&state.key===c?(state.dir>0?' ▲':' ▼'):''));
    if(sortable)th.addEventListener('click',function(){state.dir=state.key===c?-state.dir:1;state.key=c;renderAll();});tr.appendChild(th);});
  tbl.appendChild(h('thead',null,tr));
  var tb=h('tbody');
  rows.forEach(function(r){var cl=(r.en?'':'off ')+(r.haz.length?'haz':'');
    var row=h('tr',{class:cl});cols.forEach(function(c){var d=COLS[c];var v=d[1](r);
      var td=h('td',{class:(d[2]?'num ':'')+(d[3]||'')+(c==='tofu'||c==='proto'?' mono':'')},[v]);row.appendChild(td);});tb.appendChild(row);});
  tbl.appendChild(tb);
}

var sel=null;
function cellEl(zs,zd){var c=D.cells[zs+'|'+zd];
  if(!c)return h('button',{class:'cell none',disabled:'disabled'},[h('span',{class:'muted'},'no policies')]);
  var d=c.default;var b=h('button',{class:'cell '+(d||''),'data-k':zs+'|'+zd,'aria-label':zs+' to '+zd+', default '+(d||'unknown')+', '+c.custom+' custom policies'},[
    h('div',{class:'dflt'},d||'?'),h('div',{class:'cnt'},c.custom+' custom')]);
  if(c.custom){var tot=c.allow+c.block;b.appendChild(h('div',{class:'bar'},[h('i',{class:'a',style:'width:'+(100*c.allow/tot)+'%'}),h('i',{class:'b',style:'width:'+(100*c.block/tot)+'%'})]));
    var ch=h('div',{class:'chips'});if(c.allow)ch.appendChild(h('span',{class:'chip a'},'+'+c.allow+' allow'));
    if(c.block)ch.appendChild(h('span',{class:'chip b'},c.block+' block'));b.appendChild(ch);}
  if(c.haz)b.appendChild(h('div',{class:'chips'},[h('span',{class:'chip w'},'⚠ '+c.haz)]));
  if(c.pending)b.appendChild(h('div',{class:'chips'},[h('span',{class:'chip w'},c.pending+' not applied')]));
  b.addEventListener('click',function(){show(zs,zd);});return b;}
var m=document.getElementById('matrix');
var hr=h('tr',null,[h('th',null,h('span',{class:'corner'},'source ↓ / destination →'))]);Z.forEach(function(z){hr.appendChild(h('th',null,z));});
m.appendChild(h('thead',null,hr));var mb=h('tbody');
Z.forEach(function(zs){var tr=h('tr',null,[h('th',{scope:'row'},zs)]);Z.forEach(function(zd){tr.appendChild(h('td',null,cellEl(zs,zd)));});mb.appendChild(tr);});m.appendChild(mb);

function show(zs,zd){
  var c=D.cells[zs+'|'+zd];if(!c)return;var rows=c.ids.map(function(i){return P[i];});
  document.querySelectorAll('.cell.sel').forEach(function(e){e.classList.remove('sel');});
  var be=document.querySelector('.cell[data-k="'+zs+'|'+zd+'"]');if(be)be.classList.add('sel');
  var dt=document.getElementById('detail');dt.textContent='';
  var cl=h('button',{class:'close'},'close');cl.addEventListener('click',function(){dt.textContent='';document.querySelectorAll('.cell.sel').forEach(function(e){e.classList.remove('sel');});});
  dt.appendChild(h('h2',null,[cl,zs+' → '+zd,' ',h('span',{class:'muted',style:'font-weight:400'},'evaluation order: custom by index, then predefined')]));
  var wrap=h('div',{class:'scroll'});var t=h('table',{class:'list'});wrap.appendChild(t);dt.appendChild(wrap);
  build(t,['pos','act','name','tofu','proto','ipv','st','src','dst','log','hits','last'],rows,false);
  var pend=D.pending.filter(function(p){return p.zs===zs&&p.zd===zd;});
  if(pend.length)dt.appendChild(h('div',{class:'haznote'},['⚠ declared in git but not in the tofu state (failed or unapproved apply): ',
    h('span',{class:'mono'},pend.map(function(p){return p.key;}).join(', '))]));
  dt.scrollIntoView({behavior:'smooth',block:'nearest'});
}

function fill(id,label,opts){var s=document.getElementById(id);s.appendChild(h('option',{value:''},label));opts.forEach(function(o){s.appendChild(h('option',{value:o},o));});}
fill('fs','any source zone',D.allZones);fill('fd','any destination zone',D.allZones);fill('fa','any action',['ALLOW','BLOCK','REJECT']);
var state={key:'pair',dir:1};
function text(r){return [r.name,r.tkey||'',r.proto,r.ipv,r.st,r.src,r.srcP,r.dst,r.dstP,r.act,r.zs,r.zd].join(' ').toLowerCase();}
function renderAll(){
  var fs=document.getElementById('fs').value,fd=document.getElementById('fd').value,fa=document.getElementById('fa').value,fk=document.getElementById('fk').value,ft=document.getElementById('ft').value.toLowerCase().trim();
  var rows=P.filter(function(r){return (!fs||r.zs===fs)&&(!fd||r.zd===fd)&&(!fa||r.act===fa)&&
    (fk!=='c'||!r.pre)&&(fk!=='d'||(!r.pre&&!r.tofu))&&(fk!=='h'||r.haz.length)&&(!ft||text(r).indexOf(ft)>=0);});
  var k=state.key,sk=SORTK[k];
  rows=rows.slice().sort(function(a,b){var x,y;
    if(k==='pair'){x=a.zs+'\u0000'+a.zd+'\u0000'+(a.pre?1:0)+String(1e10+a.idx);y=b.zs+'\u0000'+b.zd+'\u0000'+(b.pre?1:0)+String(1e10+b.idx);}
    else{x=a[sk];y=b[sk];}
    if(x==null)x=typeof y==='number'?-1:'';if(y==null)y=typeof x==='number'?-1:'';
    return (x<y?-1:x>y?1:0)*state.dir;});
  document.getElementById('fc').textContent=rows.length+' of '+P.length;
  build(document.getElementById('all'),['pair','act','name','tofu','proto','ipv','st','src','dst','log','hits','last'],rows,true,state);
}
['fs','fd','fa','fk'].forEach(function(i){document.getElementById(i).addEventListener('change',renderAll);});
document.getElementById('ft').addEventListener('input',renderAll);
renderAll();
})();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
