# mesh-spawn

在某台设备的项目目录里开一个接入 Mesh 的 claude agent。同一台设备 + 同一个项目根目录共用一个 herdr space；每次 spawn 只新建一个 tab。

## 安装

本目录就是一个 Claude Code skill。复制到技能目录即可：

```bash
mkdir -p ~/.claude/skills
cp -r mesh-spawn-skill ~/.claude/skills/mesh-spawn
```

之后对话里说「在 <机器> 的 <目录> 开一个 xxx 的 agent」即可由技能驱动 `spawn.sh`。

## 依赖

- `bash`（macOS / Linux / Windows Git Bash）
- `python` 或 `python3`（仅用于 JSON 处理）
- `hc`（herdr-core CLI，**必选**）
- `herdr-app`（herdr 桌面应用 CLI，**可选**）：窗口开着走路线 A；没开走路线 B（`hc run`）
- `git`（必选）：识别项目根目录
- 本机 mesh 插件包装脚本 `~/.claude/plugins/cache/*/mesh/*/shell/claude-mesh.ps1`（读取 `--channels` 参数）

## 用法

```bash
bash ~/.claude/skills/mesh-spawn/spawn.sh \
  --name <a-z0-9-_|1-32> \
  [--on <机器名|local|本机>] \
  [--cwd <项目目录>] \
  [--project <space 名>] \
  [--title <tab 显示名>] \
  [--task <首条任务>] \
  [--resume <session-id>]
```

例如：在本机运行 agent，由另一台机器的 herdr GUI 显示标签（将 `gui-host` 替换为 `hc machine ls` 中的机器名）：

```bash
MESH_SPAWN_GUI_ON=gui-host bash ~/.claude/skills/mesh-spawn/spawn.sh \
  --on local --cwd "$PWD" --name project-review --title '审查·项目'
```

### 参数

| 参数 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `--name` | `a-z0-9-_` 1-32 位 | 必填 | agent 标识，不可与在跑的重名 |
| `--on` | `local`、`本机`、机器名 | `local` | 目标机器；名称按 `hc machine ls` 解析，是否本机按 host 与 hostname 实际比对，不按字符串猜 |
| `--cwd` | 路径 | 目标机器家目录 | 终端实际启动目录（与分组用 repo 根分离） |
| `--project` | 任意 | 项目目录名 | space 的名字；同一项目的稳定标识 |
| `--title` | 任意 | `--name` | tab 可见标题，建议「角色·任务」，可中文 |
| `--task` | 任意 | 无 | 首条任务，作为进程位置参数传入（避开信任提示吞消息） |
| `--resume` | session id | 无 | 重启已有 agent 时接回旧会话 |

**输出**：一行 JSON
`route / machine / address / space / tab / project / name / title / reused / needs_user_action / message / claude / gui_title_pending`

- `tab` 是 GUI 侧真实 tab id（Route B 被窗口认领后回填；窗口不可达时保持 spawn 前的占位 id）。
- `title` 是期望标题；只有 `gui_title_pending=false` 时才能视为已设置的可见名。
- `gui_title_pending=true`：Route B 且窗口不可达或读回未确认，需要人工看窗口（此时 tab 可能显示为编号）。

## 行为

- **项目分组 = 设备 + repo 根**：优先 `git rev-parse --show-toplevel`，无 repo 用绝对 cwd。同一 repo 的不同子目录复用同一个 space；独立 worktree、嵌套 git repo、无 git 父子目录各自成组。
- **复用只认精确相等**：优先可信 `mesh.root` 标签；缺标签则解析候选 space/终端在目标设备上的实际 git 根或绝对目录后精确比较，解析不到就不复用。
- **启动目录与分组 root 分离**：终端始终落在 `--cwd`，space 分组只看 repo 根；space 的 folder 记录为启动目录。
- **命名**：space 名取 `--project` 或 repo 根目录名；同一 space 内 tab 重名加短序号 `名`、`名·2`。
- **路线 A（窗口开着）**：`herdr-app do space.new|tab.new` 直接给可见名。
- **路线 B（窗口没开）**：`hc run --bg --keep --no-parent --no-notify`，带 `herdr.space`/`herdr.tab`/`where`/`mesh.*` 标签；能从同项目 live 终端找回 space 就复用，否则新建。
- **Route B 的 GUI 命名修复**：spawn 后窗口可达则按 terminal 完整设备地址在 GUI 的 `herdr-app ls` 里定位真实 tab，`tab.rename` 修正被 GUI 用编号覆盖的名字并读回确认；space 名保持 GUI 自命名（space 复用由 `mesh.root` 标签决定）。窗口不可达 → `gui_title_pending=true`，不会假装命名。
**跨机 GUI**：`MESH_SPAWN_GUI_ON=<机器>` 指定运行 herdr 窗口的机器，经 `hc exec --on <机器> -- herdr-app ...` 调用。终端地址按三方身份（控制机/目标机/GUI 机）规范为 GUI 视角的完整设备地址：GUI=目标机时无前缀（`t<id>`），否则为 GUI 机 `hc machine ls` 中目标机的 `name` 前缀（`<name>/t<id>`）。解析不到前缀 → `gui_title_pending=true`，不误匹配。
- **并发**：同一控制机上「查 space → 建 space/tab」用带 owner token 的锁串行化；超时 `BLOCKED` 并保留锁，不自动回收、不 `rm -rf`。
- **claude 定位**：远端必须有 sh（没有就明确 `BLOCKED`）；本地 MSYS/Git Bash 的 POSIX 路径统一经 `cygpath -w` 转成 `C:\...`；argv[0] 必须绝对路径。`MESH_SPAWN_PROGRAM` 可覆盖为任意无 LLM 程序做验证。
- **信任/bypass 提示**：只读检测，输出 `needs_user_action`，保留会话等人工处理，不发送任何按键。
- **不挂父终端**：总控会话结束不会连带杀掉它。

## 起完之后

1. `list_agents` 按设备 + cwd 找到新会话的 mesh 名（启动约 10 秒）。
2. 回报用户：设备、space 名、tab 名、hc 地址、mesh 名；`needs_user_action` 或 `gui_title_pending` 为 true 时提示去窗口确认。

## 管理

- 派活：`send_message` 给 mesh 名；看屏幕：`hc read --lines 40 <address>`；等它停：`hc wait <address>`。
- **关单个 agent**：用 `herdr-app do tab.close '{"id":"<tab-id>","confirmed":true}'`，**不要** `space.close`（会杀掉同 space 的所有 agent）。窗口没开：`hc kill <address>` 再 `hc rm <address>`。
- **关整个 space**：先 `herdr-app ls` 找 id，`herdr-app do space.close '{"id":"<id>","confirmed":true}'`；关之前确认是用户要关的那个。

## 卸载

```bash
rm -rf ~/.claude/skills/mesh-spawn
```

不会触碰 `~/.local/state/mesh-spawn/` 下的锁状态（正常退出已自清）；也不会关掉任何已起的 agent/space。

## 已知限制

- 远程 `hc` 命令必须带 `MSYS_NO_PATHCONV=1`（脚本已设），否则 Git Bash 会把 `/Users/...` 改写成 Windows 路径。
- 远端根目录探测先试 sh，再回退 `git -C` 与 `cmd.exe`；**但定位 claude 必须有 sh**，没有就明确 BLOCKED。
- 并发锁只在同一控制机内生效；两台控制机同时对同一目标机 spawn 同一项目时仍可能各建一个 space。
- 空锁、失效 PID 或 PID 已被其他进程复用时会立即 `BLOCKED`，不会自动删除锁；需确认没有 spawn 正在运行后删除 `~/.local/state/mesh-spawn/spawn.lock`。
- Route B 的 GUI 命名修复是「事后一次」：spawn 时窗口不可达则保持 pending，之后窗口打开不会再自动改；需要人工 `tab.rename` 或重新以 Route A spawn。
- 子代理（agent 里再 `hc run` 的终端）不属于本工具管理范围。

## 测试

```bash
bash test.sh
```

24 个场景（包含跨机 GUI 地址解析失败时保持 pending）：同项目复用 + tab 序号、不同项目独立、同名不同路径独立、远端别名归一、并发防重复、中文空格路径、live 终端找回、git 子目录共 space、锁四项（首清/二次/不覆盖/超时不改内容）、信任与 bypass 提示只读、worktree 独立、嵌套 repo 独立、无 git 父子独立、Route B 旧终端无 `mesh.root` 不并入、**Route B + GUI 可达时按 terminal 定位 tab 并 rename 读回**、**Route B + GUI 不可达时明确 pending**、Route A 命名不受影响、缺失远程路径、Route A 回退、失效锁、跨机 GUI 命令路由、无 `sh` 路径传参，以及 Windows 上的本地路径转换。

## 变更日志

见 [CHANGELOG.md](./CHANGELOG.md)。

## 许可

MIT License — 见 [LICENSE](./LICENSE)。

## 来源

由个人自动化工作中的 `mesh-spawn` 技能重构为通用开源版本：移除了个人绝对路径、设备/账号名与主控标识；核心行为（设备+repo 根分组、精确根匹配、锁、信任提示只读、跨平台 claude 定位）与原版一致。
