#!/usr/bin/env bash
# mesh-spawn: 在指定机器上新建/复用 herdr space + tab，起一个接入 mesh 的 claude。
# 同一台设备 + 同一个项目根目录共用一个 space；每次 spawn 只新建一个 tab。
# 用法: spawn.sh --name <ascii-id> [--on local|<machine>] [--cwd <dir>]
#                [--project <space 名>] [--title <tab 显示名>] [--task <首条任务>]
#                [--resume <session-id>]
# 输出一行 JSON: {"route":"app|hc","machine":..,"address":..,"space":..,"tab":..,
#                 "project":..,"name":..,"title":..,"reused":..}
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' PYTHONUTF8=1 PYTHONIOENCODING=utf-8

PY=""
for cand in python python3 python3.14 "$HOME/.local/bin/python3.14.exe" "$HOME"/.local/bin/python3.*.exe; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'print(1)' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "找不到可用的 python（python/python3）" >&2; exit 2; }

on=local; cwd=""; name=""; project=""; title=""; task=""; resume=""; rhost=""; ctl_host=""
while [ $# -gt 0 ]; do
  case "$1" in
    --on) on="$2"; shift 2;;
    --cwd) cwd="$2"; shift 2;;
    --name) name="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --title) title="$2"; shift 2;;
    --task) task="$2"; shift 2;;
    --resume) resume="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$on" in ""|local|本机) on="";; esac
[[ "$name" =~ ^[a-z0-9_-]{1,32}$ ]] || { echo "--name 必须是 1-32 位 a-z0-9-_" >&2; exit 2; }
title="${title:-$name}"
die() { echo "{\"error\":$(printf '%s' "$1" | "$PY" -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}"; exit 1; }

# mesh 频道参数：运行时从本机插件包装脚本读取，不写死。
chan=$(grep -ho 'plugin:[A-Za-z0-9@._-]*' ~/.claude/plugins/cache/sunkit/mesh/*/shell/claude-mesh.ps1 2>/dev/null | head -1)
[ -n "$chan" ] || die "找不到 mesh 频道参数（claude-mesh.ps1）"

# --on 归一：先按 hc machine ls 解析真实机器名，再判断是否实际本机（host 与本机 hostname 一致）。
# 只有 local/本机 或解析出的机器确实是本机时才走本地；显式 windows 在 Mac 上保持远程身份。
key_local() { printf '%s' "$1" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z'; }
if [ -n "$on" ]; then
  case "$on" in
    local|本机) on="";;
    *)
      machines=$(hc machine ls 2>/dev/null || true)
      resolved="$on"; rhost=""
      if [ -n "$machines" ]; then
        res=$(printf '%s' "$machines" | "$PY" -c '
import json, re, sys
want = sys.argv[1]
def key(s): return re.sub(r"[^a-z0-9]", "", (s or "").lower())
w = key(want)
try: d = json.load(sys.stdin)
except Exception: d = {}
for field in ("name", "id", "host"):
    for m in d.get("machines") or []:
        if key(m.get(field)) == w and m.get("name"):
            print(m["name"]); print(m.get("host") or ""); raise SystemExit
print(want); print("")' "$on" | tr -d '\r')
        resolved=$(printf '%s' "$res" | sed -n '1p')
        rhost=$(printf '%s' "$res" | sed -n '2p')
      fi
      on="$resolved"
      lhost=$(hostname 2>/dev/null | tr -d '\r' | cut -d. -f1 || true)
      if [ -n "$rhost" ] && [ -n "$lhost" ] && [ "$(key_local "$rhost")" = "$(key_local "$lhost")" ]; then
        on=""
      fi
      ;;
  esac
fi

# 控制机身份：本机 hostname（用于 GUI 机 hc machine ls 里反查本机的 name）。
ctl_host=$(hostname 2>/dev/null | tr -d '\r' | cut -d. -f1 || true)

# Windows 盘符路径统一成正斜杠，便于 Git Bash 的 cd 处理。
case "$cwd" in
  [A-Za-z]:*) cwd=${cwd//\\//};;
esac

# 项目根目录：优先 git show-toplevel 识别 repo 根；无 repo 回退绝对 cwd。
# 远端不假设有 sh：先实际探测一次，再 git -C / cmd.exe 兜底。
remote_sh=0
if [ -n "$on" ]; then
  if hc exec --on "$on" -- sh -c 'echo __mesh_sh__' 2>/dev/null | tr -d '\r\n' | grep -qx '__mesh_sh__'; then
    remote_sh=1
  fi
fi

resolve_abs() {
  local base="$1" out
  if [ -n "$on" ]; then
    if [ "$remote_sh" = "1" ]; then
      out=$(hc exec --on "$on" -- sh -c 'if [ -d "$1" ]; then cd "$1"; else mkdir -p "$1" && cd "$1"; fi && { pwd -W 2>/dev/null || pwd -P; }' _ "$base" 2>/dev/null | tr -d '\r\n' | tail -1)
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
    out=$(hc exec --on "$on" -- cmd.exe /c "cd /d \"$base\" & cd" 2>/dev/null | tr -d '\r\n' | tail -1)
    if [ -n "$out" ]; then echo "$out"; return 0; fi
    return 1
  else
    [ -d "$base" ] || mkdir -p "$base"
    (cd "$base" && { pwd -W 2>/dev/null || pwd -P; })
  fi
}

# 只探测不创建：候选 space/终端的实际分组根。取不到返回空，绝不用前缀猜。
probe_root() {
  local base="$1" on="$2" out
  if [ -n "$on" ]; then
    if [ "$remote_sh" = "1" ]; then
      out=$(hc exec --on "$on" -- sh -c 'if [ -d "$1" ]; then cd "$1" && { git rev-parse --show-toplevel 2>/dev/null || pwd -W 2>/dev/null || pwd -P; }; fi' _ "$base" 2>/dev/null | tr -d '\r\n' | tail -1)
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
    out=$(hc exec --on "$on" -- git -C "$base" rev-parse --show-toplevel 2>/dev/null | tr -d '\r\n' | tail -1)
    if [ -n "$out" ]; then echo "$out"; return 0; fi
    out=$(hc exec --on "$on" -- cmd.exe /c "cd /d \"$base\" & cd" 2>/dev/null | tr -d '\r\n' | tail -1)
    if [ -n "$out" ]; then echo "$out"; return 0; fi
    return 1
  else
    [ -d "$base" ] || return 1
    if command -v git >/dev/null 2>&1; then
      out=$(cd "$base" && git rev-parse --show-toplevel 2>/dev/null || true)
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
    (cd "$base" && { pwd -W 2>/dev/null || pwd -P; })
  fi
}

resolve_root() {
  local base="$1" out
  if [ -n "$on" ]; then
    if [ "$remote_sh" = "1" ]; then
      out=$(hc exec --on "$on" -- sh -c 'if [ -d "$1" ]; then cd "$1"; else mkdir -p "$1" && cd "$1"; fi && { git rev-parse --show-toplevel 2>/dev/null || pwd -W 2>/dev/null || pwd -P; }' _ "$base" 2>/dev/null | tr -d '\r\n' | tail -1)
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
    out=$(hc exec --on "$on" -- git -C "$base" rev-parse --show-toplevel 2>/dev/null | tr -d '\r\n' | tail -1)
    if [ -n "$out" ]; then echo "$out"; return 0; fi
    resolve_abs "$base"
  else
    [ -d "$base" ] || mkdir -p "$base"
    if command -v git >/dev/null 2>&1; then
      out=$(cd "$base" && git rev-parse --show-toplevel 2>/dev/null || true)
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
    (cd "$base" && { pwd -W 2>/dev/null || pwd -P; })
  fi
}

# 启动目录与分组 root 分离：launch_cwd 是终端实际落脚处，root 只用于 space 分组。
if [ -z "$cwd" ]; then
  if [ -n "$on" ]; then
    cwd=$(hc exec --on "$on" -- sh -c 'printf %s "$HOME"' 2>/dev/null | tr -d '\r' | tail -1)
    [ -n "$cwd" ] || cwd=$(hc exec --on "$on" -- cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r' | tail -1)
  else
    cwd="$HOME"
  fi
fi
[ -n "$cwd" ] || die "无法确定工作目录"
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) if [ -z "$on" ] && [[ "$cwd" =~ ^[A-Za-z]:[\\/] ]]; then die "Windows 路径只能用于 Windows 本机或 --on <机器>: $cwd"; fi;;
esac

root=$(resolve_root "$cwd")
[ -n "$root" ] || die "无法解析项目目录：$cwd"
[ "$root" = "/" ] || [[ "$root" =~ ^[A-Za-z]:/$ ]] || root=${root%/}
launch_cwd=$(resolve_abs "$cwd" 2>/dev/null || true)
[ -n "$launch_cwd" ] || launch_cwd="$root"

# 稳定项目名：显式 --project 优先，否则取项目目录名。
if [ -z "$project" ]; then
  project=$(basename "$root")
  [ -n "$project" ] || project=root
fi
project=$(printf '%s' "$project" | tr -d '\r\n')

# 并发防重复：同一控制机上把「查 space → 建 space/tab」串行化。
rnd() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/mesh-spawn"
mkdir -p "$state_dir"
lock="$state_dir/spawn.lock"
owner_token=""
release_lock() {
  if [ -n "$owner_token" ] && [ -d "$lock" ]; then
    local tok; tok=$(cat "$lock/token" 2>/dev/null || true)
    if [ "$tok" = "$owner_token" ]; then
      rm -f "$lock/token" "$lock/pid" 2>/dev/null || true
      rmdir "$lock" 2>/dev/null || true
    fi
  fi
  trap - EXIT
}
acquire_lock() {
  local i=0 lp
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -f "$lock/pid" ]; then
      lp=$(cat "$lock/pid" 2>/dev/null || true)
      if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then
        # 进程仍在运行，等待
        i=$((i + 1))
        [ "$i" -ge "${MESH_SPAWN_LOCK_TRIES:-600}" ] && die "BLOCKED: 等待 spawn 锁超时（${lock}），其他实例仍在运行"
        sleep 0.1
        continue
      fi
    fi
    # 无 stale 回收：超时即失败
    i=$((i + 1))
    [ "$i" -ge "${MESH_SPAWN_LOCK_TRIES:-600}" ] && die "BLOCKED: 等待 spawn 锁超时（${lock}）"
    sleep 0.1
  done
  # mkdir 成功后才写自己的 token 和 pid
  owner_token=$(rnd)
  echo "$owner_token" > "$lock/token"
  echo $$ > "$lock/pid"
  trap release_lock EXIT
}

# claude 定位：远端必须有 sh（没有就明确 BLOCKED，不用 fallback 假装覆盖）；
# Windows Git Bash 的 /c/... 路径要经 cygpath 转成 Windows 绝对路径。
claude_real=""
if [ -n "$on" ]; then
  if [ "$remote_sh" != "1" ]; then
    [ -n "${MESH_SPAWN_PROGRAM:-}" ] || die "BLOCKED: $on 上没有可用的 sh，无法定位 claude"
  else
    claude_real=$(hc exec --on "$on" -- sh -c 'p=$(command -v claude) || exit 3; [ -n "$p" ] || exit 3; if command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; else printf "%s" "$p"; fi' 2>/dev/null | tr -d '\r' | tail -1) || true
    [ -n "${MESH_SPAWN_PROGRAM:-}" ] || [ -n "$claude_real" ] || die "BLOCKED: $on 上找不到 claude"
  fi
else
  if [ -x "$HOME/.local/bin/claude.exe" ]; then
    claude_real=$(cygpath -w "$HOME/.local/bin/claude.exe")
  else
    claude_real=$(command -v claude 2>/dev/null || true)
  fi
  [ -n "${MESH_SPAWN_PROGRAM:-}" ] || [ -n "$claude_real" ] || die "找不到 claude"
fi
if [ -n "${MESH_SPAWN_PROGRAM:-}" ]; then claude="$MESH_SPAWN_PROGRAM"; else claude="$claude_real"; fi
case "$claude" in /*|[A-Za-z]:[\\/]*) ;; *) die "claude 启动路径不是绝对路径: $claude";; esac
hcon=(); [ -n "$on" ] && hcon=(--on "$on")

# argv：首条任务作为位置参数（避开信任框吞消息），--channels 是可变参数必须放最后。
if [ -n "${MESH_SPAWN_PROGRAM:-}" ]; then
  argv=("$claude")
else
  argv=("$claude"); [ -n "$resume" ] && argv+=(--resume "$resume"); [ -n "$task" ] && argv+=("$task"); argv+=(--channels "$chan")
fi
argv_json=$("$PY" -c 'import json,sys;print(json.dumps(sys.argv[1:],ensure_ascii=False))' "${argv[@]}")

route=""; addr=""; space=""; tab=""; gui_title_pending=false
# route A 的 tab.new/space.new 直接给可见名，不存在覆盖问题；route B 在后段视 GUI 可达性重设。
final_project="$project"; final_tab="$title"; reused=false

if herdr-app status >/dev/null 2>&1; then
  # 路线 A：窗口开着，按「设备 + 项目根目录」找 space；找到就 tab.new，否则 space.new。
  acquire_lock
  ls_json=$(herdr-app ls 2>/dev/null) || { release_lock; die "herdr-app ls 失败"; }
  # 候选 space 的分组根：优先可信 mesh.root 标签，缺失则解析其 folder 的实际 git 根/绝对目录。
  cand_tsv=$(printf '%s' "$ls_json" | "$PY" -c '
import json, re, sys
on = sys.argv[1]
def mkey(s): return re.sub(r"[^a-z0-9]", "", (s or "").lower())
target = mkey(on)
try: data = json.load(sys.stdin)
except Exception: raise SystemExit
for s in data.get("spaces") or []:
    if mkey(s.get("machine")) != target: continue
    terms = []
    for t in s.get("tabs") or []:
        for tm in t.get("terminals") or []:
            a = tm.get("terminal") or ""
            if a: terms.append(a)
    print("\x1f".join([s.get("id") or "", s.get("folder") or "", ",".join(terms)]))' "$on")
  roots_rows=()
  while IFS=$'\x1f' read -r sid sfolder terms; do
    [ -n "$sid" ] || continue
    droot=""
    for a in $(printf '%s' "$terms" | tr ',' ' '); do
      lr=$(hc get "$a" 2>/dev/null | "$PY" -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
print((d.get("labels") or {}).get("mesh.root") or "")' 2>/dev/null | tr -d '\r' || true)
      [ -n "$lr" ] && { droot="$lr"; break; }
    done
    if [ -z "$droot" ] && [ -n "$sfolder" ]; then
      droot=$(probe_root "$sfolder" "$on" 2>/dev/null || true)
    fi
    [ -n "$droot" ] && roots_rows+=("$sid"$'\t'"$droot")
  done <<< "$cand_tsv"
  roots_json='{}'
  if [ "${#roots_rows[@]}" -gt 0 ]; then
    roots_json=$(printf '%s\n' ${roots_rows[@]+"${roots_rows[@]}"} | "$PY" -c 'import json,sys
out = {}
for line in sys.stdin:
    r = line.rstrip("\n").split("\t", 1)
    if len(r) == 2 and r[1]: out[r[0]] = r[1]
print(json.dumps(out, ensure_ascii=False))')
  fi
  plan=$(printf '%s' "$ls_json" | "$PY" -c '
import json, posixpath, re, sys
on, root, project, title, roots_json = sys.argv[1:6]
def mkey(s): return re.sub(r"[^a-z0-9]", "", (s or "").lower())
def pkey(p):
    p = (p or "").strip().replace("\\", "/")
    m = re.match(r"^([A-Za-z]):", p)
    if m: p = "/" + p[0].lower() + p[1:].replace(":", "", 1)
    p = posixpath.normpath(p)
    if p.startswith("//"): p = p[1:]
    if re.match(r"^/[A-Za-z]/", p): p = p.lower()
    return p
def uniq(base, used):
    name = base; i = 2
    while name in used:
        name = base + "·" + str(i); i += 1
    return name
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("bad ls json: " + str(e)); raise SystemExit(1)
roots = json.loads(roots_json)
spaces = data.get("spaces") or []
target = mkey(on)
want = pkey(root)
def group_root(s):
    return roots.get(s.get("id") or "") or ""
matches = [s for s in spaces if mkey(s.get("machine")) == target and group_root(s) and pkey(group_root(s)) == want]
match = max(matches, key=lambda s: len(s.get("tabs") or [])) if matches else None
names = [s.get("name") or "" for s in spaces]
if match:
    used = [t.get("name") or "" for t in (match.get("tabs") or [])]
    out = {"found": True, "space": match.get("id") or "", "project": match.get("name") or project, "tab": uniq(title, used)}
else:
    out = {"found": False, "space": "", "project": uniq(project, names), "tab": title}
print(json.dumps(out, ensure_ascii=False))' "$on" "$root" "$project" "$title" "$roots_json") || { release_lock; die "解析 herdr-app ls 失败: $plan"; }
  found=$(printf '%s' "$plan" | "$PY" -c 'import json,sys;print("1" if json.load(sys.stdin).get("found") else "0")' | tr -d '\r')
  final_project=$(printf '%s' "$plan" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("project",""))' | tr -d '\r')
  final_tab=$(printf '%s' "$plan" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("tab",""))' | tr -d '\r')
  if [ "$found" = "1" ]; then
    space=$(printf '%s' "$plan" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("space",""))' | tr -d '\r')
    req=$("$PY" -c 'import json,sys;print(json.dumps({"space":sys.argv[1],"name":sys.argv[2],"folder":sys.argv[3],"argv":json.loads(sys.argv[4])},ensure_ascii=False))' "$space" "$final_tab" "$launch_cwd" "$argv_json")
    out=$(herdr-app do tab.new "$req" 2>&1) || { release_lock; die "tab.new 失败: $out"; }
    reused=true
  else
    req=$("$PY" -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"tab":sys.argv[2],"argv":json.loads(sys.argv[3]),"machine":sys.argv[4],"folder":sys.argv[5]},ensure_ascii=False))' "$final_project" "$final_tab" "$argv_json" "$on" "$launch_cwd")
    out=$(herdr-app do space.new "$req" 2>&1) || { release_lock; die "space.new 失败: $out"; }
  fi
  route=app
  read -r addr new_space tab < <(printf '%s' "$out" | "$PY" -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("terminal",""),d.get("space",""),d.get("tab",""))' | tr -d '\r') || true
  [ -n "$space" ] || space="$new_space"
  release_lock
  [ -n "$addr" ] || die "herdr-app 没返回 terminal: $out"
  [ -n "$on" ] && [[ "$addr" != */* ]] && addr="$on/$addr"
  hc label "$addr" "mesh=1" "mesh.name=$name" "mesh.project=$final_project" "mesh.root=$root" "where=$final_project / $final_tab" >/dev/null 2>&1 || true
else
  # 路线 B：窗口没开，先从 live 终端找回同项目的 space，再 hc run 起新 tab。
  acquire_lock
  hc_ls=$(hc ls 2>/dev/null || true)
  cand_file="$state_dir/candidates.$$"
  match_file="$state_dir/matches.$$"
  : > "$cand_file"; : > "$match_file"
  if [ -n "$hc_ls" ]; then
    while IFS= read -r a; do
      a=${a%$'\r'}
      [ -n "$a" ] || continue
      gj=$(hc get "$a" 2>/dev/null || true)
      [ -n "$gj" ] || continue
      row=$(printf '%s' "$gj" | "$PY" -c '
import json, sys
addr = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
labels = d.get("labels") or {}
sp = labels.get("herdr.space") or ""
if not sp: raise SystemExit
w = labels.get("where") or ""
pj = labels.get("mesh.project") or ""
root = labels.get("mesh.root") or ""
cwd = d.get("cwd") or ""
print("\t".join([addr, sp, w, pj, str(d.get("created_ms") or 0), root, cwd]))' "$a" 2>/dev/null || true)
      [ -n "$row" ] || continue
      troot=$(printf '%s' "$row" | cut -f6)
      tcwd=$(printf '%s' "$row" | cut -f7)
      if [ -z "$troot" ] && [ -n "$tcwd" ]; then
        tmach=""; case "$a" in */*) tmach=${a%%/*};; *) tmach="$on";; esac
        troot=$(probe_root "$tcwd" "$tmach" 2>/dev/null || true)
        row=$(printf '%s' "$row" | "$PY" -c 'import sys
r = sys.stdin.read().rstrip("\n").split("\t")
r[5] = sys.argv[1]
print("\t".join(r))' "$troot")
      fi
      printf '%s\n' "$row" >> "$cand_file"
    done < <(printf '%s' "$hc_ls" | "$PY" -c '
import json, re, sys
on = sys.argv[1]
def mkey(s): return re.sub(r"[^a-z0-9]", "", (s or "").lower())
try: data = json.load(sys.stdin)
except Exception: raise SystemExit
target = mkey(on)
for t in data.get("terminals") or []:
    addr = t.get("address") or ""
    machine = addr.split("/", 1)[0] if "/" in addr else ""
    if mkey(machine) != target: continue
    print(addr)' "$on")
  fi
  if [ -s "$cand_file" ]; then
    "$PY" -c '
import posixpath, re, sys
root, launch = sys.argv[1:3]
def pkey(p):
    p = (p or "").strip().replace("\\", "/")
    m = re.match(r"^([A-Za-z]):", p)
    if m: p = "/" + p[0].lower() + p[1:].replace(":", "", 1)
    p = posixpath.normpath(p)
    if p.startswith("//"): p = p[1:]
    if re.match(r"^/[A-Za-z]/", p): p = p.lower()
    return p
want = pkey(root)
for line in sys.stdin:
    r = line.rstrip("\n").split("\t")
    if len(r) < 7: continue
    troot = r[5]
    if not troot: continue
    if pkey(troot) != want: continue
    sys.stdout.write(line)
' "$root" "$launch_cwd" < "$cand_file" > "$match_file"
  fi
  if [ -s "$match_file" ]; then
    space=$("$PY" -c '
import collections, sys
rows = [line.rstrip("\n").split("\t") for line in sys.stdin if line.strip()]
cnt = collections.Counter(r[1] for r in rows if len(r) >= 7)
best = sorted(rows, key=lambda r: (cnt[r[1]], int(float(r[4] or 0))), reverse=True)[0]
print(best[1])' < "$match_file" | tr -d '\r')
    final_project=$("$PY" -c '
import collections, sys
space = sys.argv[1]
rows = [line.rstrip("\n").split("\t") for line in sys.stdin if line.strip()]
names = [r[3] for r in rows if len(r) >= 7 and r[1] == space and r[3]]
if names: print(collections.Counter(names).most_common(1)[0][0])
' "$space" < "$match_file" | tr -d '\r')
    final_tab=$("$PY" -c '
import sys
space, base = sys.argv[1:3]
used = []
for line in sys.stdin:
    r = line.rstrip("\n").split("\t")
    if len(r) >= 7 and r[1] == space and r[2]:
        w = r[2]
        if " / " in w: used.append(w.rsplit(" / ", 1)[1])
name = base; i = 2
while name in used:
    name = base + "·" + str(i); i += 1
print(name)' "$space" "$title" < "$match_file" | tr -d '\r')
    final_project="${final_project:-$project}"
    [ -z "$space" ] || reused=true
  else
    final_project="$project"; final_tab="$title"
  fi
  rm -f "$cand_file" "$match_file"
  [ -n "$space" ] || space="spc$(rnd)"
  tab="tb$(rnd)"
  cwdarg=(); [ -n "$launch_cwd" ] && cwdarg=(--cwd "$launch_cwd")
  out=$(hc run --json --bg --keep --no-parent --no-notify ${hcon[@]+"${hcon[@]}"} --name "$name" ${cwdarg[@]+"${cwdarg[@]}"} \
        --label "herdr.space=$space" --label "herdr.tab=$tab" \
        --label "where=$final_project / $final_tab" --label mesh=1 --label "mesh.name=$name" --label "mesh.project=$final_project" --label "mesh.root=$root" \
        -- "${argv[@]}" 2>&1) || { release_lock; die "hc run 失败: $out"; }
  route=hc
  addr=$(printf '%s' "$out" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("address",""))' | tr -d '\r')
  [ -n "$addr" ] || { release_lock; die "hc run 没返回 address: $out"; }
  release_lock

  # GUI 认领 hc 终端时会用默认编号覆盖 tab 名：窗口可达则按 terminal 完整设备地址定位真实 tab，
  # tab.rename 修正后读回确认；space 名保持 GUI 自命名，不改（space 复用由 mesh.root 标签决定）。
  # 窗口不可达则 pending。
  gui_title_pending=true
  # 显式 GUI 设备：MESH_SPAWN_GUI_ON=<机器> 时在该机器上探测窗口；否则用本机 herdr-app。
  gui_on="${MESH_SPAWN_GUI_ON:-}"
  # want 按 GUI 所在机视角规范成完整设备地址：
  #   - GUI 在目标机（gui_on 为空且本机是目标机，或 gui_on == on）：地址无前缀（本机视角）
  #   - GUI 在其他机：地址带 <目标机>/ 前缀
  # $addr 可能带 machine/ 前缀（hc run --on 远端时）；先取短 id。
  addr_short="$addr"; case "$addr_short" in */*) addr_short=${addr_short##*/};; esac
  # 三方身份：控制机=spawn.sh 所在机（ctl_host=hostname）；目标机=$on（空=控制机）；
  # GUI 机=$gui_on（空/local/本机=控制机）。构造 GUI 视角的完整终端地址：
  #   GUI == 目标机 → "t<id>"
  #   GUI != 目标机 → "<GUI 机 hc machine ls 里目标机的 name>/t<id>"
  # 目标机 host：$on 非空时用 --on 归一得到的 rhost，归一失败回退 $on；$on 空用 ctl_host。
  # GUI 机 host：$gui_on 空用 ctl_host；否则在控制机 hc machine ls 里解析其 host。
  ctl_host="${ctl_host:-$(hostname 2>/dev/null | tr -d '\r' | cut -d. -f1 || true)}"
  if [ -n "$on" ]; then t_host="${rhost:-$on}"; else t_host="$ctl_host"; fi
  gui_remote=0; g_host="$ctl_host"
  if [ -n "$gui_on" ] && [ "$gui_on" != "local" ] && [ "$gui_on" != "本机" ]; then
    gui_remote=1
    g_host=$(hc machine ls 2>/dev/null | "$PY" -c 'import json, re, sys
want = sys.argv[1]
def key(s): return re.sub(r"[^a-z0-9]", "", (s or "").lower())
w = key(want)
try: d = json.load(sys.stdin)
except Exception: d = {}
for field in ("name", "id", "host"):
    for m in d.get("machines") or []:
        if key(m.get(field)) == w:
            print(m.get("host") or ""); raise SystemExit' "$gui_on" | tr -d '\r' | head -1)
  fi
  want_gui=""
  if [ -n "$g_host" ] && [ -n "$t_host" ] && [ "$(key_local "$g_host")" = "$(key_local "$t_host")" ]; then
    want_gui="$addr_short"          # GUI 与目标机同机：无前缀
  else
    # 取 GUI 机视角里目标机的 name 作前缀（GUI=控制机用本机 hc ls，否则 hc exec --on gui）
    gml=""
    if [ "$gui_remote" = "1" ]; then gml=$(hc exec --on "$gui_on" -- hc machine ls 2>/dev/null || true)
    else gml=$(hc machine ls 2>/dev/null || true); fi
    tp=$(printf '%s' "$gml" | "$PY" -c 'import json, re, sys
thost = sys.argv[1]
def key(s): return re.sub(r"[^a-z0-9]", "", (s or "").lower())
w = key(thost)
try: d = json.load(sys.stdin)
except Exception: d = {}
for m in d.get("machines") or []:
    if key(m.get("host")) == w and m.get("name"):
        print(m["name"]); raise SystemExit' "$t_host" | tr -d '\r' | head -1)
    if [ -n "$tp" ]; then want_gui="$tp/$addr_short"; fi
    # 解析不到前缀：同机场景（on 与 gui_on 都空）回退无前缀；跨机场景留空 → pending
    if [ -z "$want_gui" ] && [ -z "$on" ] && [ "$gui_remote" = "0" ]; then want_gui="$addr_short"; fi
  fi
  if [ -n "$gui_on" ] && [ "$gui_on" != "local" ] && [ "$gui_on" != "本机" ]; then
    gui_reachable() { hc exec --on "$gui_on" -- herdr-app status >/dev/null 2>&1; }
    gui_ls() { hc exec --on "$gui_on" -- herdr-app ls 2>/dev/null; }
    gui_rename() { hc exec --on "$gui_on" -- herdr-app do tab.rename "$1" >/dev/null 2>&1; }
  else
    gui_reachable() { herdr-app status >/dev/null 2>&1; }
    gui_ls() { herdr-app ls 2>/dev/null; }
    gui_rename() { herdr-app do tab.rename "$1" >/dev/null 2>&1; }
  fi
  if gui_reachable; then
    i=0
    while [ "$i" -lt 10 ]; do
      i=$((i + 1))
      found_t=$(gui_ls | "$PY" -c 'import json,sys
want = sys.argv[1]
try: data = json.load(sys.stdin)
except Exception: raise SystemExit
for s in data.get("spaces") or []:
    for t in s.get("tabs") or []:
        for tm in t.get("terminals") or []:
            a = tm.get("terminal") or ""
            # 完整设备地址匹配：want 带 machine/ 前缀时要求完整相等；
            # want 无前缀（本机终端）则 a 也必须无前缀才相等，禁止仅末段比对。
            if a == want:
                print("\t".join([s.get("id") or "", t.get("id") or "", (t.get("name") or "").replace("\t", " ")]))
                raise SystemExit' "$want_gui" 2>/dev/null | tr -d '\r' | head -1 || true)
      [ -n "$found_t" ] && break
      sleep 0.5
    done
    if [ -n "$found_t" ]; then
      r_space=$(printf '%s' "$found_t" | cut -f1)
      r_tab=$(printf '%s' "$found_t" | cut -f2)
      r_name=$(printf '%s' "$found_t" | cut -f3-)
      if [ "$r_name" != "$final_tab" ]; then
        rn_req=$("$PY" -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"name":sys.argv[2]},ensure_ascii=False))' "$r_tab" "$final_tab")
        gui_rename "$rn_req" || true
      fi
      # 读回确认可见名
      got=$(gui_ls | "$PY" -c 'import json,sys
want = sys.argv[1]
try: data = json.load(sys.stdin)
except Exception: raise SystemExit
for s in data.get("spaces") or []:
    for t in s.get("tabs") or []:
        for tm in t.get("terminals") or []:
            a = tm.get("terminal") or ""
            if a == want:
                print(t.get("name") or "")
                raise SystemExit' "$want_gui" 2>/dev/null | tr -d '\r' | head -1 || true)
      if [ "$got" = "$final_tab" ]; then
        gui_title_pending=false
        title="$got"
      fi
      space="$r_space"
      tab="$r_tab"
    fi
  fi
fi

# 首次进入的目录可能弹出信任提示：只读检测，输出 needs_user_action，不发送任何按键。
needs_user_action=false; nea_message=""
if [ -z "${MESH_SPAWN_PROGRAM:-}" ]; then
  for _ in 1 2 3 4 5; do
    scr=$(hc read --lines 0 "$addr" 2>/dev/null || true)
    if printf '%s' "$scr" | grep -qiE 'trust (this|the files)|Do you trust|Yes, proceed|Yes, I trust'; then
      needs_user_action=true; nea_message="trust prompt detected"; break
    fi
    if printf '%s' "$scr" | grep -qiE 'auto mode|bypass permissions' && printf '%s' "$scr" | grep -qiE 'accept'; then
      needs_user_action=true; nea_message="bypass prompt detected"; break
    fi
    st=$(hc get "$addr" 2>/dev/null | "$PY" -c 'import json,sys;d=json.load(sys.stdin);s=d.get("status") or {};print(d.get("state",""),s.get("app",""))' 2>/dev/null | tr -d '\r' || true)
    [[ "$st" == "live claude-code" ]] && break
    sleep 1.5
  done
fi
[ "$needs_user_action" = true ] && echo "需要人工处理：${nea_message}（会话 ${addr} 保留）" >&2

"$PY" -c 'import json,sys
print(json.dumps({"route":sys.argv[1],"machine":sys.argv[2] or "local","address":sys.argv[3],"space":sys.argv[4],"tab":sys.argv[5],"project":sys.argv[6],"name":sys.argv[7],"title":sys.argv[8],"reused":sys.argv[9]=="1","needs_user_action":sys.argv[10]=="1","message":sys.argv[11],"claude":sys.argv[12],"gui_title_pending":sys.argv[13]=="1"},ensure_ascii=False))' \
  "$route" "$on" "$addr" "$space" "$tab" "$final_project" "$name" "$final_tab" "$([ "$reused" = true ] && echo 1 || echo 0)" "$([ "$needs_user_action" = true ] && echo 1 || echo 0)" "$nea_message" "$claude_real" "$([ "${gui_title_pending:-false}" = true ] && echo 1 || echo 0)"
