---
name: mesh-spawn
description: 在某台设备的项目目录里开一个 herdr tab，起一个自动接入 mesh 的 claude agent；同设备同项目共用一个 herdr space。用户说「在 <机器>/本机 开一个 xxx 的 agent」「新建一个工作区跑 claude」「拉一个 agent 进 mesh」「关掉/收掉 某个 agent」时使用。
---

# mesh-spawn

脚本：`bash ~/.claude/skills/mesh-spawn/spawn.sh`（在 Bash 工具里跑，Git Bash）。

## 从自然语言取参数

| 参数 | 取法 |
|---|---|
| `--on` | 本机 → `local`；其他 → `hc machine ls` 里的机器名（或其 id/host 的等价写法）。是否本机按 host 与 hostname 实际比对，不按字符串猜 |
| `--cwd` | 用户说的项目目录；没说就用该机器的家目录。Windows 路径用单引号 |
| `--project` | space 名，同一项目的稳定名字；不说就取 repo 根（或目录）名 |
| `--name` | 1-32 位 `a-z0-9-_`，从用途起，如 `erp-fix`。不能和 `hc ls` 里在跑的重名 |
| `--title` | tab 显示名，建议 `角色·任务`，如 `实现·某任务`；可中文 |
| `--task` | 首条任务。末尾加「完成或卡住时用 mesh send_message 回报给 <总控 mesh 名>」 |
| `--resume` | 接回某个旧对话（重启已有 agent 时用）。session id 从该机器 `~/.claude/sessions/<claude pid>.json` 的 `sessionId` 取；同目录有多个会话时不要用 `--continue` |

重启已有 agent：先记下 session id，再在 claude 里敲 `/exit`。必须用 `hc keys <t> / e x i t` 加 `enter`，`hc send` 会给文字套上 `<hc>` 标签，变成普通消息。最后用 `--resume` 重新起。

缺设备或目录时问一次，其余按默认直接起。

## 脚本做了什么

- 项目分组用「设备 + repo 根」：`git rev-parse --show-toplevel` 优先，无 repo 用绝对 cwd。同一 repo 的不同子目录复用同一个 space；同名但不同路径不会合并，独立 worktree、嵌套 git repo、无 git 父子目录都不合并。
- 复用只认精确相等：优先可信 `mesh.root` 标签；缺标签则解析候选 space/终端在目标设备上的实际 git 根或绝对目录后精确比较，解析不到就不复用。
- Route B（窗口没开时起 hc run）之后窗口若可达：按 terminal 完整设备地址在 GUI 的 `herdr-app ls` 里定位真实 tab，`tab.rename` 修正被 GUI 用编号覆盖的名字并读回确认；space 名保持 GUI 自命名（space 复用由 `mesh.root` 标签决定，不靠名字）。窗口不可达时输出 `gui_title_pending=true`，不假装命名。
- GUI 设备：默认本机 `herdr-app`；窗口在另一台机时设 `MESH_SPAWN_GUI_ON=<机器>`，脚本经 `hc exec --on <机器> -- herdr-app ...` 调远端 GUI。终端地址按三方身份（控制机/目标机/GUI 机）规范为 GUI 视角的完整设备地址：目标机 host 由 `--on` 归一的 rhost 或本机 hostname 决定，前缀为 GUI 机 `hc machine ls` 中 host 匹配目标机的条目 `name`；GUI=目标机时无前缀。解析不到前缀时不误匹配，`gui_title_pending=true`。
- 启动目录与分组 root 分离：终端始终落在 `--cwd` 指定的目录，space 分组只看 repo 根，独立 worktree 各自成组。
- space 名取 `--project` 或 repo 根目录名；tab 名取 `--title`。同一 space 里 tab 重名会加短序号：`实现·任务`、`实现·任务·2`。
- herdr-app 窗口开着：`herdr-app do space.new|tab.new`，立即出现在窗口里。
- 窗口没开：`hc run --bg --keep --no-parent`，带 `herdr.space`/`herdr.tab` 标签；能从同项目的 live 终端（`mesh.root` 标签或 cwd 归属）找回 space 就复用，否则新建。
- 同一控制机上并发 spawn 用锁串行化「查 space → 建 space/tab」。锁只清理本 owner 的 token/pid 文件和空目录；已有锁超时直接报错退出，不自动回收。
- argv 为 `claude "<task>" --channels <mesh 频道>`，频道参数运行时从本机 mesh 插件读取。
- 不挂父终端，总控会话结束不会连带杀掉它。
- 检测到首次进入目录的信任提示或 bypass 提示时，只读识别并返回 `needs_user_action`，保留会话等人工处理，不发送任何按键。
- 输出一行 JSON：`route / machine / address / space / tab / project / name / title / reused / needs_user_action / message / claude / gui_title_pending`。`tab` 是 GUI 侧真实 tab id（Route B 认领后回填），`title` 是期望标题，`gui_title_pending=true` 时不代表可见名已设置；space 名可能仍是 GUI 自命名；`gui_title_pending=true` 表示窗口不可达或读回未确认，需要人工看窗口。

## 起完之后

1. `list_agents` 按设备 + cwd 找到新会话的 mesh 名（启动约 10 秒）。
2. 把 `<mesh 名> = <address>@<设备>` 记进 work_state 的 `mesh 总控` 列表 identities。
3. 回报用户：设备、space 名、tab 名、hc 地址、mesh 名；`needs_user_action` 为 true 时提示去窗口确认。

## 管理

- 派活：`send_message` 给 mesh 名；看屏幕：`hc read --lines 40 <address>`；等它停：`hc wait <address>`。
- 关闭单个 agent：先 `herdr-app ls` 核对 terminal 与 tab，只关闭目标标签页：`herdr-app do tab.close '{"id":"<tab-id>","confirmed":true}'`。若标签页有多个终端，只结束目标 terminal，保留其他终端。窗口没开时仅对目标执行 `hc kill <address>`、`hc rm <address>`。禁止因关闭一个 agent 而关闭整个共享 space；只有用户明确要求关闭整个 workspace 且已核对其中全部会话时才使用 `space.close`。

## 已知限制

- Mac 上 claude 提示 `Channels are not currently available`（账号侧开关）：能用 mesh 工具发消息，但收不到推送；给它派活改用 `hc send <address> "<任务>"`。
- 远程 `hc` 命令必须带 `MSYS_NO_PATHCONV=1`（脚本已设），否则 Git Bash 会把 `/Users/...` 改写成 Windows 路径。
- 远端不假设有 sh：根目录探测先试 sh，再回退 `git -C` 与 `cmd.exe`；但定位 claude 必须有 sh，没有就明确 BLOCKED。
- Windows 上 `command -v claude` 返回的 `/c/...` 会经 `cygpath -w` 转成 `C:\...` 再启动；输出 JSON 的 `claude` 字段是实际 argv[0]。
- 并发锁只在同一控制机内生效；两台控制机同时对同一目标机 spawn 同一项目时仍可能各建一个 space。
- Route B 的 GUI 命名修复是「事后一次」：spawn 时窗口不可达则保持 pending，之后窗口打开不会再自动改；需要人工 `tab.rename` 或重新以 Route A spawn。
- 锁持有者异常退出且未清理时，后续 spawn 会一直等到超时并报错；需人工确认后删除 `~/.local/state/mesh-spawn/spawn.lock`。
