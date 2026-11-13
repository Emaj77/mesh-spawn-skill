# Changelog

## [Unreleased]

### Fixed
- 远程路径探测与目录创建分离，路径经 base64 传入远程命令并检查退出码；缺失路径失败，不再回退到无关目录。
- 本地 MSYS/Git Bash 的 POSIX claude 路径统一经 `cygpath -w` 转换为 Windows 路径。
- Route A 在 spawn 锁内判定；GUI 创建失败时回退 Route B，不留下半成品。
- 空锁、失效 PID 和 PID 被复用时立即 `BLOCKED`；只有 PID 与锁创建时间匹配的活进程才等待。
- 跨机 GUI 命令明确发往 `MESH_SPAWN_GUI_ON`，并在该机器上读取机器列表。

### Added
- 覆盖 bypass 提示、缺失远程路径、Route A 回退、失效锁、无 `sh` 远程路径和本地 Windows 路径转换的测试。

## [0.2.0] - 2026-11-07

### Fixed
- **Route B tab 可见名被 GUI 编号覆盖**：窗口认领 `hc run` 起的终端时，未命名 tab 显示为序号（如「1」「2」）。现在 spawn 后若 GUI 可达，按 terminal 完整设备地址在 GUI 的 `herdr-app ls` 里定位真实 tab，`tab.rename` 并读回确认。窗口不可达时输出 `gui_title_pending=true`，不再假装命名。
- 终端地址完整匹配：`machine/t<id>` 与 `t<id>` 视为不同，不再仅末段比对；地址按 GUI 所在机视角规范化（GUI=目标机时无前缀，否则带 `<目标机>/` 前缀）。
- 输出 JSON 的 `tab` 字段在 Route B + GUI 可达时回填真实 tab id，`title` 与读回的可见名一致；space 名保持 GUI 自命名（space 复用靠 `mesh.root` 标签而非名字），不再调用 `space.rename`。
- 新增 `MESH_SPAWN_GUI_ON=<机器>`：显式指定运行 herdr 窗口的机器，经 `hc exec --on <机器> -- herdr-app ...` 调远端 GUI；不扫全网，默认本机。
- 三方身份规范化：控制机（spawn 所在机）/目标机（`--on`）/GUI 机（`MESH_SPAWN_GUI_ON`）的 host/name 分别解析，终端地址构造为 GUI 视角完整设备地址；目标机为控制机时（`--on local`）也能在远端 GUI 上得到正确 `machine/` 前缀（修复此前误生成裸 `tXX` 匹配错终端的 bug）。解析不到前缀 → `gui_title_pending=true`。

### Added
- 新测试场景 15/16/17：Route B + GUI 可达 rename 读回、Route B + GUI 不可达 pending、Route A 不受影响。

## [0.1.0] - 2026-11-07

首个通用化版本。继承自个人自动化 skill，移除了个人路径/设备/账号标识。

### 行为（相对此前私有版本）
- 项目分组 = 设备 + git repo 根（`git rev-parse --show-toplevel`），无 repo 用绝对 cwd。
- 复用只认精确根匹配：可信 `mesh.root` 标签优先，否则解析候选在目标设备上的实际根；绝不路径前缀合并。独立 worktree、嵌套 repo、无 git 父子目录都不合并。
- 启动目录与分组 root 分离：终端落在 `--cwd`，space 分组看 repo 根。
- 并发：同控制机 mkdir 锁 + owner token + pid；超时 `BLOCKED`，不自动回收、不 `rm -rf`。
- claude 定位：远端必须有 sh；Windows `/c/...` 经 `cygpath -w`；`MESH_SPAWN_PROGRAM` 支持无 LLM 替身验证。
- 信任/bypass 提示只读检测，输出 `needs_user_action`，不发送按键。
- 信任设备解析：`--on` 按 `hc machine ls` 解析 name/id/host，再与本机 hostname 实际比对判断是否本机。
