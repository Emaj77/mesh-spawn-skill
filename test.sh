#!/usr/bin/env bash
# 定向测试：用假 herdr-app / hc 跑 spawn.sh，不启动任何 claude 或真实终端。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
REAL_HOME=$HOME
PYENV=""
for cand in python python3 python3.14 "$REAL_HOME/.local/bin/python3.14.exe" "$REAL_HOME"/.local/bin/python3.*.exe; do
  p=$(command -v "$cand" 2>/dev/null || true)
  if [ -n "$p" ] && "$p" -c 'print(1)' >/dev/null 2>&1; then PYENV="$p"; break; fi
done
[ -n "$PYENV" ] || { echo "no usable python" >&2; exit 2; }
PYNAME=$(basename "$PYENV")
export PATH="$(dirname "$PYENV"):$PATH"
work=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then work_path=$(cygpath -m "$work"); else work_path="$work"; fi
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
export XDG_STATE_HOME="$work/state"
export FAKE_STATE="$work_path/app.json"
export FAKE_HC_STATE="$work_path/hc.json"
export FAKE_CALLS="$work_path/calls.jsonl"
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
export PATH="$work/bin:$PATH"
mkdir -p "$HOME/.claude/plugins/cache/sunkit/mesh/0.0.0/shell" "$work/bin" "$XDG_STATE_HOME"
echo 'plugin:mesh@sunkit' > "$HOME/.claude/plugins/cache/sunkit/mesh/0.0.0/shell/claude-mesh.ps1"

cat > "$work/bin/herdr-app.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_STATE"]
calls = os.environ["FAKE_CALLS"]
def load():
    try:
        with open(state_path) as f: return json.load(f)
    except Exception: return {"spaces": []}
def save(d):
    with open(state_path, "w") as f: json.dump(d, f, ensure_ascii=False)
def log(*a):
    with open(calls, "a") as f: f.write(json.dumps(a, ensure_ascii=False) + "\n")
args = sys.argv[1:]
if len(args) >= 2 and args[0] == "--fake-machines":
    os.environ["FAKE_MACHINES_JSON"] = args[1]
    args = args[2:]
if not args: sys.exit(1)
cmd = args[0]
if cmd == "status":
    if os.environ.get("FAKE_APP_FAIL_AFTER_STATUS") == "1":
        marker = calls + ".status_fail_n"
        try:
            with open(marker) as f: n = int(f.read().strip() or "0")
        except Exception: n = 0
        n += 1
        with open(marker, "w") as f: f.write(str(n))
        sys.exit(0 if n == 1 else 1)
    if os.environ.get("FAKE_APP_VISIBLE") == "1":
        # 每次 spawn 的第一次 status（route 判定）返回「窗口没开」；之后的调用可见
        marker = calls + ".status_n"
        try:
            with open(marker) as f: n = int(f.read().strip() or "0")
        except Exception: n = 0
        n += 1
        with open(marker, "w") as f: f.write(str(n))
        if n > 1: sys.exit(0)
        sys.exit(1)
    sys.exit(0 if os.environ.get("FAKE_APP_OPEN") == "1" else 1)
if cmd == "ls":
    print(json.dumps(load(), ensure_ascii=False)); sys.exit(0)
if cmd == "do":
    sub = args[1]; payload = json.loads(args[2]) if len(args) > 2 else {}
    log("do", sub, payload)
    if os.environ.get("FAKE_APP_MUTATION_FAIL") == "1": sys.exit(1)
    d = load(); spaces = d.setdefault("spaces", [])
    if sub == "tab.rename":
        tid = payload.get("id"); nm = payload.get("name", "")
        hit = None
        for s in spaces:
            for t in s.get("tabs", []):
                if t.get("id") == tid: hit = t
        if not hit: print(json.dumps({"error": "no tab"})); sys.exit(1)
        hit["name"] = nm
        save(d); print(json.dumps({"ok": True})); sys.exit(0)
    if sub == "space.rename":
        sid = payload.get("id"); nm = payload.get("name", "")
        hit = next((s for s in spaces if s.get("id") == sid), None)
        if not hit: print(json.dumps({"error": "no space"})); sys.exit(1)
        hit["name"] = nm
        save(d); print(json.dumps({"ok": True})); sys.exit(0)
    if sub == "space.new":
        sid = "sp%02d" % (len(spaces) + 1); tid = "tb%02d" % (len(spaces) + 1)
        mach = payload.get("machine") or None
        term = "t%02d" % (sum(len(s["tabs"]) for s in spaces) + 1)
        if mach: term = mach + "/" + term
        spaces.append({"id": sid, "name": payload.get("name", ""), "folder": payload.get("folder", ""),
                       "machine": mach,
                       "tabs": [{"id": tid, "name": payload.get("tab", ""), "folder": payload.get("folder", ""), "terminals": [{"terminal": term}]}]})
        save(d)
        print(json.dumps({"terminal": "t%d" % len(spaces), "space": sid, "tab": tid}))
        sys.exit(0)
    if sub == "tab.new":
        sid = payload.get("space"); sp = next((s for s in spaces if s["id"] == sid), None)
        if not sp: print(json.dumps({"error": "no space"})); sys.exit(1)
        tid = "tb%02d" % (sum(len(s["tabs"]) for s in spaces) + 1)
        mach = sp.get("machine")
        term = "t%02d" % (sum(len(s["tabs"]) for s in spaces) + 1)
        if mach: term = mach + "/" + term
        sp["tabs"].append({"id": tid, "name": payload.get("name", ""), "folder": payload.get("folder", ""), "terminals": [{"terminal": term}]})
        save(d)
        print(json.dumps({"terminal": "t%d" % (sum(len(s["tabs"]) for s in spaces)), "space": sid, "tab": tid}))
        sys.exit(0)
    print(json.dumps({"error": "unknown"})); sys.exit(1)
print(json.dumps({"error": "unknown"})); sys.exit(1)
PY
cat > "$work/bin/herdr-app" <<WRAP
#!/usr/bin/env bash
here=\$(cd "\$(dirname "\$0")" && pwd)
p="\$here/herdr-app.py"
if command -v cygpath >/dev/null 2>&1; then p=\$(cygpath -w "\$p"); fi
exec "$PYNAME" "\$p" --fake-machines "\${FAKE_MACHINES_JSON:-}" "\$@"
WRAP

cat > "$work/bin/hc.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_HC_STATE"]
calls = os.environ["FAKE_CALLS"]
def log(*a):
    with open(calls, "a") as f: f.write(json.dumps(a, ensure_ascii=False) + "\n")
args = sys.argv[1:]
if not args: sys.exit(1)
cmd = args[0]
if cmd == "machine":
    # FAKE_HOST 指定本机 hostname；machines 列远端。GUI 机视角由 FAKE_GUI_LS 注入。
    if os.environ.get("FAKE_MACHINES_JSON"):
        print(os.environ["FAKE_MACHINES_JSON"]); sys.exit(0)
    print(json.dumps({"machines": [
        {"name": "box-a", "id": "m1", "host": "box-a", "state": "connected"},
        {"name": "box-b", "id": "m2", "host": "box-b", "state": "connected"}]}))
    sys.exit(0)
if cmd == "exec":
    on = ""; i = 1
    while i < len(args):
        if args[i] == "--on": on = args[i + 1]; i += 2
        else: break
    rest = args[i:]
    log("exec", on, rest)
    text = " ".join(rest)
    if rest[:3] == ["--", "hc", "machine"]:
        print(os.environ.get("FAKE_MACHINES_JSON") or json.dumps({"machines": []}))
        sys.exit(0)
    if os.environ.get("FAKE_REMOTE_SH") == "0" and "__mesh_sh__" in text: sys.exit(1)
    if "__mesh_sh__" in text: print("__mesh_sh__"); sys.exit(0)
    if "command -v claude" in text: print("/usr/bin/claude"); sys.exit(0)
    if "MESH_SPAWN_PATH_B64" in text or "base64 -d" in text:
        import base64, re
        encoded = ""
        match = re.search(r"MESH_SPAWN_PATH_B64=([A-Za-z0-9+/=]+)", text)
        if match: encoded = match.group(1)
        else:
            match = re.search(r"b='([A-Za-z0-9+/=]+)'", text)
            if match: encoded = match.group(1)
        if not encoded: sys.exit(1)
        target = base64.b64decode(encoded).decode()
        missing = os.environ.get("FAKE_MISSING_PATH", "")
        def norm(p):
            return p.replace("\\", "/").rstrip("/")
        if missing and norm(target) == norm(missing): sys.exit(1)
        if os.environ.get("FAKE_REMOTE_MKDIR") == "0" and "mkdir" in text: sys.exit(1)
        print(target); sys.exit(0)
    if "$HOME" in text: print("/home/fake"); sys.exit(0)
    sys.exit(1)
if cmd == "ls":
    try:
        with open(state_path) as f: print(f.read())
    except Exception:
        print(json.dumps({"terminals": []}))
    sys.exit(0)
if cmd == "get":
    addr = args[1]
    try:
        with open(state_path) as f: d = json.load(f)
    except Exception: d = {"terminals": []}
    stored = (d.get("labels") or {}).get(addr) or {}
    for t in d.get("terminals", []):
        if t.get("address") == addr:
            labels = dict(t.get("labels") or {}); labels.update(stored)
            print(json.dumps({"address": addr, "state": "live", "status": {"app": "claude-code"},
                              "labels": labels, "cwd": t.get("cwd", ""),
                              "created_ms": t.get("created_ms", 0)}, ensure_ascii=False)); sys.exit(0)
    print(json.dumps({"address": addr, "state": "live", "status": {"app": "claude-code"}, "labels": stored}, ensure_ascii=False)); sys.exit(0)
if cmd == "read":
    if os.environ.get("FAKE_READ_BYPASS") == "1":
        print("Bypass permissions? Accept"); sys.exit(0)
    print("Do you trust the files in this folder?" if os.environ.get("FAKE_READ_TRUST") == "1" else "ready"); sys.exit(0)
if cmd == "label":
    addr = args[1]; pairs = args[2:]
    try:
        with open(state_path) as f: d = json.load(f)
    except Exception: d = {"terminals": []}
    st = d.setdefault("labels", {})
    cur = st.setdefault(addr, {})
    for p in pairs:
        if "=" in p:
            k, v = p.split("=", 1); cur[k] = v
    json.dump(d, open(state_path, "w"), ensure_ascii=False)
    sys.exit(0)
if cmd == "keys":
    sys.exit(0)
if cmd == "run":
    log("run", args)
    labels = {}
    target = ""
    i = 1
    while i < len(args):
        if args[i] == "--on" and i + 1 < len(args):
            target = args[i + 1]; i += 2; continue
        if args[i] == "--label" and i + 1 < len(args):
            k, _, v = args[i + 1].partition("=")
            labels[k] = v; i += 2
        else:
            i += 1
    # 唯一地址：按已登记终端数递增
    try:
        with open(state_path) as f: hd = json.load(f)
    except Exception: hd = {"terminals": []}
    addr = "t%02d" % (len(hd.get("terminals", [])) + 1)
    if target: addr = target + "/" + addr
    term = {"address": addr, "state": "live", "status": {"app": "claude-code"},
            "labels": labels, "created_ms": len(hd.get("terminals", [])) + 1}
    hd.setdefault("terminals", []).append(term)
    json.dump(hd, open(state_path, "w"), ensure_ascii=False)
    # FAKE_GUI_CLAIM：模拟窗口认领该终端，编号 tab + 自命名 space（folder 目录名）
    if os.environ.get("FAKE_GUI_CLAIM") == "1":
        import json as _j, os as _os
        st_path = _os.environ["FAKE_STATE"]
        try:
            with open(st_path) as f: ad = _j.load(f)
        except Exception: ad = {"spaces": []}
        sps = ad.setdefault("spaces", [])
        sid = labels.get("herdr.space") or ""
        sp = next((s for s in sps if s.get("id") == sid), None)
        if not sp:
            # GUI 按首个终端 cwd 的目录名自命名 space
            cwd = ""
            for i, a in enumerate(args):
                if a == "--cwd" and i + 1 < len(args):
                    cwd = args[i + 1]
            base = cwd.rstrip("/").split("/")[-1] if cwd else "claimed-dir"
            sp = {"id": sid or ("spx%02d" % (len(sps)+1)), "name": base,
                  "folder": cwd, "machine": None, "tabs": []}
            sps.append(sp)
        ntid = "tb%02d" % (sum(len(s["tabs"]) for s in sps) + 1)
        sp["tabs"].append({"id": ntid, "name": str(len(sp["tabs"]) + 1), "folder": "",
                           "terminals": [{"terminal": addr}]})
        _j.dump(ad, open(st_path, "w"), ensure_ascii=False)
    print(json.dumps({"address": addr})); sys.exit(0)
print(json.dumps({"error": "unknown"})); sys.exit(1)
PY
cat > "$work/bin/hc" <<WRAP
#!/usr/bin/env bash
here=\$(cd "\$(dirname "\$0")" && pwd)
p="\$here/hc.py"
if command -v cygpath >/dev/null 2>&1; then p=\$(cygpath -w "\$p"); fi
exec "$PYNAME" "\$p" "\$@"
WRAP
printf '#!/bin/sh\nexit 0\n' > "$work/bin/claude"
chmod +x "$work/bin/herdr-app" "$work/bin/hc" "$work/bin/claude"

reset() { echo '{"spaces":[]}' > "$FAKE_STATE"; echo '{"terminals":[]}' > "$FAKE_HC_STATE"; : > "$FAKE_CALLS"; }
spawn() { rm -f "$FAKE_CALLS.status_n"; FAKE_APP_OPEN="${FAKE_APP_OPEN:-1}" bash "$here/spawn.sh" "$@"; }

echo "== 1. 连续同项目：space 复用，tab 重名加序号"
reset
p="$work/projects/proj-a"; mkdir -p "$p"
o1=$(spawn --name a1 --cwd "$p" --title "实现·任务")
o2=$(spawn --name a2 --cwd "$p" --title "实现·任务")
"$PYENV" - "$FAKE_STATE" "$o1" "$o2" <<'PY'
import json, sys
state = json.load(open(sys.argv[1])); o1 = json.loads(sys.argv[2]); o2 = json.loads(sys.argv[3])
assert len(state["spaces"]) == 1, state
assert [t["name"] for t in state["spaces"][0]["tabs"]] == ["实现·任务", "实现·任务·2"], state
assert o1["reused"] is False and o2["reused"] is True, (o1, o2)
assert o1["space"] == o2["space"] and o1["project"] == "proj-a", (o1, o2)
print("PASS")
PY

echo "== 2. 不同项目：各自一个 space"
reset
p2="$work/projects/proj-b"; p3="$work/projects/proj-c"; mkdir -p "$p2" "$p3"
spawn --name b1 --cwd "$p2" --title "实现·任务" >/dev/null
spawn --name b2 --cwd "$p3" --title "实现·任务" >/dev/null
"$PYENV" - "$FAKE_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 2, state
assert sorted(s["name"] for s in state["spaces"]) == ["proj-b", "proj-c"], state
print("PASS")
PY

echo "== 3. 同名不同路径：不合并，space 名加序号"
reset
x="$work/x/proj"; y="$work/y/proj"; mkdir -p "$x" "$y"
spawn --name x1 --cwd "$x" --title "实现·任务" >/dev/null
spawn --name y1 --cwd "$y" --title "实现·任务" >/dev/null
"$PYENV" - "$FAKE_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 2, state
names = sorted(s["name"] for s in state["spaces"])
assert names == ["proj", "proj·2"], names
assert len({s["folder"] for s in state["spaces"]}) == 2, state
print("PASS")
PY

echo "== 4. 远端 machine：按设备 + 路径复用，别名归一"
reset
spawn --name r1 --on boxa --cwd "/srv/app" --title "实现·远端" >/dev/null
spawn --name r2 --on box-a --cwd "/srv/app/" --title "实现·远端" >/dev/null
"$PYENV" - "$FAKE_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 1, state
s = state["spaces"][0]
assert s["machine"] == "box-a", s
assert len(s["tabs"]) == 2, s
assert [t["name"] for t in s["tabs"]] == ["实现·远端", "实现·远端·2"], s
print("PASS")
PY

echo "== 5. 并发：同一项目 4 个 spawn 只建 1 个 space"
reset
p5="$work/projects/proj-c"; mkdir -p "$p5"
for i in 1 2 3 4; do
  ( spawn --name "c$i" --cwd "$p5" --title "实现·并发" > "$work/out$i.json" 2> "$work/err$i.log" ) &
done
wait
"$PYENV" - "$FAKE_STATE" "$work_path" <<'PY'
import json, sys, os
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 1, state
tabs = sorted(t["name"] for t in state["spaces"][0]["tabs"])
assert tabs == sorted(["实现·并发", "实现·并发·2", "实现·并发·3", "实现·并发·4"]), tabs
for i in range(1, 5):
    err = open(os.path.join(sys.argv[2], "err%d.log" % i), encoding="utf-8", errors="replace").read()
    assert not err.strip(), (i, err)
print("PASS")
PY

echo "== 6. 中文与空格路径"
reset
p6="$work/项目 空格/proj 目录"; mkdir -p "$p6"
spawn --name z1 --cwd "$p6" --title "实现·中文" >/dev/null
spawn --name z2 --cwd "$p6" --title "实现·中文" >/dev/null
"$PYENV" - "$FAKE_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 1, state
s = state["spaces"][0]
assert "项目 空格" in s["folder"] and "proj 目录" in s["folder"], s
assert [t["name"] for t in s["tabs"]] == ["实现·中文", "实现·中文·2"], s
print("PASS")
PY

echo "== 7. 窗口没开：路由 hc，能从 live 终端找回 space"
reset
p7="$work/projects/proj-d"; mkdir -p "$p7"
FAKE_APP_OPEN=0 spawn --name d1 --cwd "$p7" --title "实现·后台" >/dev/null
"$PYENV" - "$FAKE_STATE" "$FAKE_CALLS" "$p7" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
runs = [c for c in calls if c[0] == "run"]
assert len(runs) == 1, runs
args = runs[0][1]
assert any("herdr.space=spc" in a for a in args), args
assert any("mesh.project=proj-d" in a for a in args), args
print("PASS")
PY
p7_real=$(cd "$p7" && { pwd -W 2>/dev/null || pwd -P; })
"$PYENV" - "$p7_real" "$FAKE_HC_STATE" <<'PY'
import json, sys
json.dump({"terminals": [{"address": "t55", "cwd": sys.argv[1],
                          "labels": {"herdr.space": "sp-old", "where": "proj-d / 实现·后台",
                                     "mesh.project": "proj-d"}, "created_ms": 1}]},
          open(sys.argv[2], "w"), ensure_ascii=False)
PY
o8=$(FAKE_APP_OPEN=0 spawn --name d2 --cwd "$p7" --title "实现·后台")
"$PYENV" - "$FAKE_CALLS" "$o8" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
runs = [c for c in calls if c[0] == "run"]
args = runs[-1][1]
assert any(a == "herdr.space=sp-old" for a in args), args
assert any("where=proj-d / 实现·后台·2" in a for a in args), args
out = json.loads(sys.argv[2])
assert out["route"] == "hc" and out["reused"] is True, out
assert out["space"] == "sp-old", out
print("PASS")
PY

echo "== 8. git repo 子目录：同一 repo 共用一个 space，启动目录各自保留"
reset
repo="$work/repo-x"; mkdir -p "$repo/a" "$repo/b"
( cd "$repo" && git init -q . )
spawn --name g1 --cwd "$repo/a" --title "实现·A" >/dev/null
spawn --name g2 --cwd "$repo/b" --title "实现·B" >/dev/null
"$PYENV" - "$FAKE_STATE" "$repo" "$repo/a" "$repo/b" <<'PY'
import json, sys, posixpath, os
state = json.load(open(sys.argv[1])); repo = sys.argv[2]
assert len(state["spaces"]) == 1, state
s = state["spaces"][0]
assert s["name"] == "repo-x", s
assert os.path.realpath(s["folder"]) == os.path.realpath(sys.argv[3]), s
folders = [os.path.realpath(t["folder"]) for t in s["tabs"] if t.get("folder")]
assert folders == [os.path.realpath(sys.argv[3]), os.path.realpath(sys.argv[4])], folders
print("PASS")
PY

echo "== 9. 锁：首次成功且释放干净；第二进程等待不覆盖；已有锁超时不改内容"
reset
p9="$work/projects/proj-lock"; mkdir -p "$p9"
spawn --name l1 --cwd "$p9" --title "实现·锁" >/dev/null
[ ! -d "$XDG_STATE_HOME/mesh-spawn/spawn.lock" ] || { echo "lock dir left behind" >&2; exit 1; }
spawn --name l2 --cwd "$p9" --title "实现·锁" >/dev/null
[ ! -d "$XDG_STATE_HOME/mesh-spawn/spawn.lock" ] || { echo "lock dir left behind after second" >&2; exit 1; }
mkdir -p "$XDG_STATE_HOME/mesh-spawn/spawn.lock"
sleep 30 & lpid=$!
echo "first-owner-token" > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/token"
echo "$lpid" > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid"
echo "first-owner-token" > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/owner"
"$PYENV" -c 'import time; print(int(time.time() * 1000))' > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/started_ms"
set +e
out9=$(MESH_SPAWN_LOCK_TRIES=5 spawn --name l3 --cwd "$p9" --title "实现·锁" 2>"$work/lock-err.log")
rc9=$?
set -e
kill "$lpid" 2>/dev/null || true
wait "$lpid" 2>/dev/null || true
[ "$rc9" -ne 0 ] || { echo "expected lock timeout, got success: $out9" >&2; exit 1; }
[ "$(cat "$XDG_STATE_HOME/mesh-spawn/spawn.lock/token")" = "first-owner-token" ] || { echo "owner token overwritten" >&2; exit 1; }
[ "$(cat "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid")" = "$lpid" ] || { echo "pid overwritten" >&2; exit 1; }
"$PYENV" - "$out9" "$lpid" <<'PY'
import json, sys
msg = json.loads(sys.argv[1]).get("error", "")
assert "仍在运行" in msg and sys.argv[2] in msg, msg
print("PASS")
PY
rm -f "$XDG_STATE_HOME/mesh-spawn/spawn.lock/token" "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid" "$XDG_STATE_HOME/mesh-spawn/spawn.lock/owner" "$XDG_STATE_HOME/mesh-spawn/spawn.lock/started_ms"
rmdir "$XDG_STATE_HOME/mesh-spawn/spawn.lock"
echo "PASS"

echo "== 10. 信任提示：只读检测，返回 needs_user_action，不发送按键"
reset
p10="$work/projects/proj-trust"; mkdir -p "$p10"
o10=$(FAKE_APP_OPEN=1 FAKE_READ_TRUST=1 spawn --name t1 --cwd "$p10" --title "实现·信任")
"$PYENV" - "$o10" "$FAKE_CALLS" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
assert out["needs_user_action"] is True, out
assert out["message"] == "trust prompt detected", out
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert not [c for c in calls if c[0] == "keys"], calls
print("PASS")
PY

echo "== 10b. bypass 提示：只读检测，不发送按键"
reset
o10b=$(FAKE_APP_OPEN=1 FAKE_READ_BYPASS=1 spawn --name t2 --cwd "$p10" --title "实现·bypass")
"$PYENV" - "$o10b" "$FAKE_CALLS" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
assert out["needs_user_action"] is True, out
assert out["message"] == "bypass prompt detected", out
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert not [c for c in calls if c[0] == "keys"], calls
print("PASS")
PY

echo "== 11. 嵌套独立 worktree：不并入主 repo 的 space"
reset
repo_w="$work/repo-w"; mkdir -p "$repo_w"
( cd "$repo_w" && git init -q . && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm init )
( cd "$repo_w" && git worktree add -q "$repo_w/.claude/worktrees/task" -b task )
spawn --name w1 --cwd "$repo_w" --title "实现·主仓" >/dev/null
spawn --name w2 --cwd "$repo_w/.claude/worktrees/task" --title "实现·worktree" >/dev/null
spawn --name w3 --cwd "$repo_w" --title "实现·主仓" >/dev/null
spawn --name w4 --cwd "$repo_w/.claude/worktrees/task" --title "实现·worktree" >/dev/null
"$PYENV" - "$FAKE_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 2, state
tabs = sorted([len(s["tabs"]) for s in state["spaces"]])
assert tabs == [2, 2], tabs
folders = sorted(s["folder"] for s in state["spaces"])
assert len(set(folders)) == 2, folders
print("PASS")
PY

echo "== 12. 嵌套独立 git repo：父子项目不合并"
reset
repo_n="$work/repo-n"; mkdir -p "$repo_n/vendor/lib"
( cd "$repo_n" && git init -q . )
( cd "$repo_n/vendor/lib" && git init -q . )
spawn --name n1 --cwd "$repo_n" --title "实现·父" >/dev/null
spawn --name n2 --cwd "$repo_n/vendor/lib" --title "实现·子" >/dev/null
spawn --name n3 --cwd "$repo_n" --title "实现·父" >/dev/null
spawn --name n4 --cwd "$repo_n/vendor/lib" --title "实现·子" >/dev/null
"$PYENV" - "$FAKE_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 2, state
tabs = sorted([len(s["tabs"]) for s in state["spaces"]])
assert tabs == [2, 2], tabs
print("PASS")
PY

echo "== 13. 无 git 父子目录：不合并"
reset
ng="$work/nogit"; mkdir -p "$ng/app"
spawn --name q1 --cwd "$ng" --title "实现·父" >/dev/null
spawn --name q2 --cwd "$ng/app" --title "实现·子" >/dev/null
spawn --name q3 --cwd "$ng" --title "实现·父" >/dev/null
spawn --name q4 --cwd "$ng/app" --title "实现·子" >/dev/null
"$PYENV" - "$FAKE_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state["spaces"]) == 2, state
tabs = sorted([len(s["tabs"]) for s in state["spaces"]])
assert tabs == [2, 2], tabs
print("PASS")
PY

echo "== 14. Route B 旧终端无 mesh.root：子目录不并入父 space"
reset
ng2="$work/nogit2"; mkdir -p "$ng2/app"
ng2_real=$(cd "$ng2/app" && { pwd -W 2>/dev/null || pwd -P; })
"$PYENV" - "$ng2_real" "$FAKE_HC_STATE" <<'PY'
import json, sys
json.dump({"terminals": [{"address": "t60", "cwd": sys.argv[1],
                          "labels": {"herdr.space": "sp-legacy", "where": "old / tab"},
                          "created_ms": 1}]}, open(sys.argv[2], "w"), ensure_ascii=False)
PY
o14=$(FAKE_APP_OPEN=0 spawn --name r14 --cwd "$ng2" --title "实现·父")
"$PYENV" - "$o14" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
assert out["reused"] is False, out
assert out["space"] != "sp-legacy", out
print("PASS")
PY

if [[ "$(uname -s 2>/dev/null || true)" == MINGW* || "$(uname -s 2>/dev/null || true)" == MSYS* || "$(uname -s 2>/dev/null || true)" == CYGWIN* ]]; then
  echo "== 24. 本地 MSYS claude 路径转换为 Windows 路径"
  reset
  p24="$work/projects/proj-winpath"; mkdir -p "$p24" "$work/bin"
  printf '#!/bin/sh\nexit 0\n' > "$work/bin/claude"
  chmod +x "$work/bin/claude"
  o24=$(PATH="$work/bin:$PATH" FAKE_APP_OPEN=1 spawn --name wpath --cwd "$p24" --title "实现·路径")
  "$PYENV" - "$o24" "$FAKE_CALLS" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
created = next(c for c in calls if c[0] == "do" and c[1] == "space.new")
argv = created[2]["argv"]
assert argv[0][1:3] == ":\\" and argv[0].lower().endswith("\\claude"), argv
assert out["route"] == "app", out
print("PASS")
PY
fi

echo "ALL PASS"

echo "== 15. Route B + GUI 可达：tab 按 terminal 定位、数字名 rename 后读回；space 名保持自命名"
reset
p15="$work/projects/proj-gui"; mkdir -p "$p15"
FAKE_GUI_CLAIM=1 FAKE_APP_VISIBLE=1 FAKE_APP_OPEN=0 spawn --name g1 --cwd "$p15" --title "实现·B" >/dev/null
FAKE_GUI_CLAIM=1 FAKE_APP_VISIBLE=1 FAKE_APP_OPEN=0 spawn --name g2 --cwd "$p15" --title "实现·B" >/dev/null
"$PYENV" - "$FAKE_STATE" "$FAKE_CALLS" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
renames = [c for c in calls if c[0] == "do" and c[1] == "tab.rename"]
assert len(renames) == 2, (renames, calls, state)
names = [c[2]["name"] for c in renames]
assert names == ["实现·B", "实现·B·2"], names
# tab.rename 读回后名字生效；space 名保持 GUI 自命名（不再 space.rename）
s = state["spaces"][0]
assert [t["name"] for t in s["tabs"]] == ["实现·B", "实现·B·2"], s["tabs"]
assert s["name"] == "proj-gui", s["name"]  # GUI 认领时按 cwd 目录名自命名
# 不应有 space.rename 调用
srenames = [c for c in calls if c[0] == "do" and c[1] == "space.rename"]
assert not srenames, srenames
print("PASS")
PY

echo "== 16. Route B + GUI 不可达：明确 pending，不假装命名"
reset
FAKE_APP_OPEN=0 spawn --name h1 --cwd "$work/projects/proj-gui" --title "实现·不可达" >/dev/null
FAKE_APP_OPEN=0 spawn --name h2 --cwd "$work/projects/proj-gui" --title "实现·不可达" > "$work/o16.json"
"$PYENV" - "$work/o16.json" <<'PY'
import json, sys
out = json.load(open(sys.argv[1]))
assert out["gui_title_pending"] is True, out
assert out["reused"] is True, out
print("PASS")
PY

echo "== 17. Route A 不受影响：space/tab 名字直接生效，pending=false"
reset
p17="$work/projects/proj-app"; mkdir -p "$p17"
o17=$(spawn --name a1 --cwd "$p17" --title "实现·A")
"$PYENV" - "$o17" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
assert out["route"] == "app", out
assert out["gui_title_pending"] is False, out
assert out["title"] == "实现·A", out
print("PASS")
PY

echo "== 18. 跨机 GUI 前缀解析：本机 spawn + 远端 GUI → 远端机看到的 machine/ 前缀地址"
reset
# 本机 hostname 由 fake uname/hostname 提供不了；直接验证 want_gui 构造单元逻辑。
# 用 MESH_SPAWN_GUI_ON=box-b + --on local：t_host=本机 hostname（真实 hostname），
# GUI=box-b（远端）；box-b 的 hc machine ls 需含「本机」条目（host=本机 hostname）。
# 这里本机 hostname 非 windows → 前缀应是本机 hc ls 里 host=hostname 的条目 name。
# fake hc machine ls 默认不含本机 → want_prefix 解析不到 → want_gui 空 → pending=true。
# 这是契约要求：解析不到就 pending，不误匹配。
p18="$work/projects/proj-xgui"; mkdir -p "$p18"
o18=$(MESH_SPAWN_GUI_ON=box-b FAKE_APP_OPEN=0 spawn --name x1 --cwd "$p18" --title "实现·跨GUI")
"$PYENV" - "$o18" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
assert out["route"] == "hc", out
# 无法确认远端 GUI 中的完整地址时，必须明确报告命名尚未确认。
assert out["gui_title_pending"] is True, out
print("PASS")
PY

echo "== 19. 不存在的远程路径：失败且不回退到无关目录"
reset
set +e
o19=$(FAKE_APP_OPEN=0 FAKE_MISSING_PATH=/missing/project spawn --name m1 --on box-a --cwd /missing/project --title "实现·缺失" 2>"$work/missing.err")
rc19=$?
set -e
[ "$rc19" -ne 0 ] || { echo "missing path unexpectedly succeeded: $o19" >&2; exit 1; }
"$PYENV" - "$o19" <<'PY'
import json, sys
msg = json.loads(sys.argv[1]).get("error", "")
assert "无法解析项目目录" in msg, msg
print("PASS")
PY

echo "== 20. Route A 创建时窗口失效：回退 Route B，不留下半成品"
reset
p20="$work/projects/proj-fallback"; mkdir -p "$p20"
o20=$(FAKE_APP_FAIL_AFTER_STATUS=1 FAKE_APP_MUTATION_FAIL=1 spawn --name f1 --cwd "$p20" --title "实现·回退")
"$PYENV" - "$o20" "$FAKE_STATE" "$FAKE_CALLS" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
state = json.load(open(sys.argv[2]))
calls = [json.loads(l) for l in open(sys.argv[3]) if l.strip()]
assert out["route"] == "hc", out
assert state["spaces"] == [], state
assert any(c[0] == "run" for c in calls), calls
print("PASS")
PY

echo "== 21. 空锁和失效 PID：立即 BLOCKED，不改锁内容"
reset
p21="$work/projects/proj-stale"; mkdir -p "$p21"
mkdir -p "$XDG_STATE_HOME/mesh-spawn/spawn.lock"
echo 1 > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/started_ms"
set +e
o21=$(spawn --name s1 --cwd "$p21" --title "实现·空锁" 2>"$work/empty-lock.err")
rc21=$?
set -e
[ "$rc21" -ne 0 ] || { echo "empty lock unexpectedly succeeded" >&2; exit 1; }
[ ! -f "$XDG_STATE_HOME/mesh-spawn/spawn.lock/owner" ] || { echo "empty lock was modified" >&2; exit 1; }
echo 999999 > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid"
echo preserved-token > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/token"
echo preserved-owner > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/owner"
echo 1 > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/started_ms"
set +e
o21b=$(spawn --name s2 --cwd "$p21" --title "实现·失效锁" 2>"$work/dead-lock.err")
rc21b=$?
set -e
[ "$rc21b" -ne 0 ] || { echo "dead lock unexpectedly succeeded" >&2; exit 1; }
[ "$(cat "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid")" = "999999" ] || { echo "dead pid overwritten" >&2; exit 1; }
[ "$(cat "$XDG_STATE_HOME/mesh-spawn/spawn.lock/token")" = "preserved-token" ] || { echo "token overwritten" >&2; exit 1; }
sleep 30 & reused_pid=$!
echo "$reused_pid" > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid"
echo 1 > "$XDG_STATE_HOME/mesh-spawn/spawn.lock/started_ms"
set +e
o21c=$(MESH_SPAWN_LOCK_TRIES=2 spawn --name s3 --cwd "$p21" --title "实现·复用PID" 2>"$work/reused-lock.err")
rc21c=$?
set -e
kill "$reused_pid" 2>/dev/null || true
wait "$reused_pid" 2>/dev/null || true
[ "$rc21c" -ne 0 ] || { echo "reused pid unexpectedly succeeded" >&2; exit 1; }
[ "$(cat "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid")" = "$reused_pid" ] || { echo "reused pid overwritten" >&2; exit 1; }
"$PYENV" - "$o21" "$o21b" <<'PY'
import json, sys
a, b = [json.loads(x).get("error", "") for x in sys.argv[1:]]
assert "没有有效持有者" in a, a
assert "已失效" in b and "999999" in b, b
print("PASS")
PY
"$PYENV" - "$o21c" "$reused_pid" <<'PY'
import json, sys
msg = json.loads(sys.argv[1]).get("error", "")
assert "已失效" in msg and sys.argv[2] in msg, msg
print("PASS")
PY
rm -f "$XDG_STATE_HOME/mesh-spawn/spawn.lock/token" "$XDG_STATE_HOME/mesh-spawn/spawn.lock/pid" "$XDG_STATE_HOME/mesh-spawn/spawn.lock/owner" "$XDG_STATE_HOME/mesh-spawn/spawn.lock/started_ms"
rmdir "$XDG_STATE_HOME/mesh-spawn/spawn.lock"

echo "== 22. 跨机 GUI：远程窗口命令发往指定机器，并携带机器列表参数"
reset
p22="$work/projects/proj-remote-gui"; mkdir -p "$p22"
export FAKE_MACHINES_JSON
FAKE_MACHINES_JSON='{"machines":[{"name":"box-b","host":"gui-host"}]}'
o22=$(MESH_SPAWN_GUI_ON=box-b FAKE_APP_OPEN=0 spawn --name gremote --cwd "$p22" --title "实现·远端GUI")
"$PYENV" - "$o22" "$FAKE_CALLS" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
execs = [c for c in calls if c[0] == "exec" and c[1] == "box-b" and any("herdr-app" in x for x in c[2])]
assert out["route"] == "hc", out
assert execs, calls
assert any(c[0] == "exec" and c[1] == "box-b" and c[2][:3] == ["--", "hc", "machine"] for c in calls), calls
print("PASS")
PY
unset FAKE_MACHINES_JSON

echo "== 23. 无 sh 的远程机器：路径经 base64 传入 cmd，不读取本地环境变量"
reset
p23="$work/projects/no sh & path"; mkdir -p "$p23"
o23=$(FAKE_REMOTE_SH=0 FAKE_APP_OPEN=1 MESH_SPAWN_PROGRAM="/tmp/fake-claude" MESH_SPAWN_PATH="/wrong/local" spawn --name nosh --on box-a --cwd "$p23" --title "实现·无sh")
"$PYENV" - "$o23" "$FAKE_CALLS" "$p23" <<'PY'
import json, os, sys
out = json.loads(sys.argv[1])
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert out["route"] == "app" and out["machine"] == "box-a", out
cmds = [c for c in calls if c[0] == "exec" and "MESH_SPAWN_PATH_B64" in " ".join(c[2])]
assert cmds, calls
assert all("MESH_SPAWN_PATH=" not in " ".join(c[2]) for c in cmds), cmds
assert not [c for c in calls if c[0] == "exec" and "__mesh_sh__" not in " ".join(c[2]) and "sh -c" in " ".join(c[2])], calls
print("PASS")
PY

echo "ALL PASS"
