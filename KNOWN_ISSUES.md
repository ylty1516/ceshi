# Known Issues / 已知问题

This document lists known limitations and issues with workarounds.

本文档列出了已知的限制和问题及其解决方法。

---

## Festivals and Non-Skippable Events Are Not Handled (Fundamental Limitation)
## 节日与不可跳过事件不被处理（根本性限制）

**Issue / 问题:**

When a festival starts, or when the game triggers a **non-skippable** event/cutscene, the headless host has no human to interact with it and can get **stuck**. While the host is stuck, connected players may be unable to act, effectively freezing the session.

当节日开始，或游戏触发一个**不可跳过的**事件/过场动画时，无头房主没有真人去与之交互，可能会**卡住**。房主卡住期间，已连接的玩家可能无法操作，整局游戏实际上被冻结。

**Why This Happens / 原因:**

Stardew Valley has no real dedicated-server mode — the host is a full game participant. The bundled `AutoHideHost` mod can only skip events that the game itself marks as *skippable* (`Game1.CurrentEvent.skippable`), and it auto-confirms sleep/shipping/ready-check menus. It does **not** implement any festival logic, and it cannot skip events the game marks as non-skippable.

星露谷没有真正的专用服务器模式——房主是一个完整的游戏参与者。捆绑的 `AutoHideHost` 模组只能跳过游戏本身标记为*可跳过*（`Game1.CurrentEvent.skippable`）的事件，并自动确认睡眠/出货/准备检查菜单。它**没有**实现任何节日处理逻辑，也无法跳过游戏标记为不可跳过的事件。

**Workaround / 解决方法:**

- Connect via VNC during a festival or a stuck event and interact with the host manually (advance/close the event).
- Avoid relying on fully unattended operation across festival days.

- 在节日或卡住的事件期间通过 VNC 连接，手动与房主交互（推进/关闭事件）。
- 不要指望在有节日的日子里完全无人值守地运行。

**Status / 状态:**

This is a fundamental limitation of running an unattended headless host, not a fixable bug. A robust solution requires a **human-hosted** game instead of an unattended host. See the "Project Status" section in the README for the recommended direction.

这是"无人值守无头房主"这一架构的根本性限制，而不是一个可修复的 bug。稳健的方案需要改为**真人当房主**，而不是无人值守的房主。推荐方向见 README 的"项目状态"一节。

---

## Container Restart - Native Co-op Autoload
## 容器重启 - 原生 Co-op 自动加载

**Status / 状态:**

Fixed in ServerAutoLoad v2.0.0.

已在 ServerAutoLoad v2.0.0 修复。

**What changed / 改动:**

Older builds loaded save data directly and then tried to force host mode. In Stardew Valley 1.6+, that can leave the multiplayer farmhand slot list incomplete. ServerAutoLoad v2 now opens Stardew Valley's native `Co-op -> Host` menu, waits for host save slots, and activates the selected save through the game's own `HostFileSlot.Activate()` path.

旧版会直接读取存档数据，然后尝试强行补成主机模式。在星露谷物语 1.6+ 中，这可能导致多人 farmhand 席位列表初始化不完整。ServerAutoLoad v2 现在会打开星露谷原生 `Co-op -> Host` 菜单，等待主持存档槽位出现，再通过游戏自己的 `HostFileSlot.Activate()` 路径载入选中的存档。

**If players still cannot join / 如果玩家仍然无法加入:**

Check the Web panel diagnostics. The report now includes `server-autoload-state.json` and the player join handshake stage, so you can distinguish:

打开 Web 面板诊断。报告现在会包含 `server-autoload-state.json` 和玩家加入握手阶段，用来区分：

- whether the native Host menu opened
- whether the selected save appeared in the Host list
- whether the host slot was activated
- whether the server sent farmhand slots to the client
- whether the client selected a farmhand and the server approved it

- 是否已打开原生 Host 菜单
- 选中的存档是否出现在 Host 列表
- 是否已激活 Host 存档槽位
- 服务端是否已把 farmhand 席位列表发给客户端
- 客户端是否已选择 farmhand，并被服务端批准

### Large Content Mods + Lowered MAX_PLAYERS
### 大型内容 Mod + 被压低的 MAX_PLAYERS

**Issue / 问题:**

After enabling large content mods (SVE, Ridgeside, East Scarp, etc.), clients may see "no free slots on the server" even though empty cabins are visible on the farm.

开启大型内容 Mod（SVE、里村、East Scarp 等）后，客户端可能提示“服务器没有空闲位置”，但农场上仍能看到空闲农夫小屋。

**Why This Happens / 原因:**

1. **Client mod mismatch (most common with large mods):** the host has content mods, the client does not (or has a different pack). The server can still send a farmhand list, but the client fails around `receiveAvailableFarmhands` and shows a misleading no-slot message.
2. **MAX_PLAYERS too low:** older panel recommendations lowered `MAX_PLAYERS` to 2–3 under large-mod pressure. Empty cabins beyond that limit cannot be joined.
3. **Host not truly in Co-op Host mode:** if the save was not loaded through native `Co-op -> Host`, multiplayer farmhand slots may stay empty even though cabin buildings exist.

1. **客户端 Mod 不一致（大型 Mod 最常见）：** 服务端有内容 Mod，客户端没有或版本不同。服务端仍可能发出 farmhand 列表，但客户端在 `receiveAvailableFarmhands` 附近失败，并误报无空位。
2. **MAX_PLAYERS 过低：** 旧版配置推荐在大型 Mod 压力下会把 `MAX_PLAYERS` 降到 2–3。超过人数上限的空闲小屋无法加入。
3. **未真正走 Co-op Host：** 若存档不是通过原生 `Co-op -> Host` 载入，多人 farmhand 席位可能为空，但小屋建筑仍然存在。

**What changed / 改动:**

- Config recommendations no longer crush `MAX_PLAYERS` for large mods.
- AutoHideHost reports runtime free farmhand/cabin slots in `game-state.json`.
- Join handshake diagnostics explicitly call out fake no-slot cases when runtime free cabins exist.

- 配置推荐不再因大型 Mod 把 `MAX_PLAYERS` 压到不可用。
- AutoHideHost 会把运行时空闲 farmhand/小屋席位写入 `game-state.json`。
- 加入握手诊断在运行时仍有空闲小屋时，会明确提示这是假性“无空位”。

**Required check / 必查:**

1. Panel **Configuration** → `MAX_PLAYERS=8` (or at least host+cabins).
2. Panel **Diagnostics** → `Save slot and cabin audit` and `Runtime farmhand / cabin slots`.
3. Panel **Mods** → every player installs `/player-mods` → `stardew-client-mods.zip` and launches with SMAPI.
4. Dashboard **Join handshake** after one failed join attempt.

1. 面板 **配置** → `MAX_PLAYERS=8`（至少 host+小屋数）。
2. 面板 **诊断** → `Save slot and cabin audit` 与 `Runtime farmhand / cabin slots`。
3. 面板 **模组** → 每个玩家安装 `/player-mods` → `stardew-client-mods.zip` 并用 SMAPI 启动。
4. 失败一次加入后看仪表盘 **加入握手**。

### Client Mod Mismatch Can Look Like "No Free Slot"
### 客户端 Mod 不一致可能伪装成“没有空闲位置”

If the diagnostics show that the server already sent the farmhand list but the player still sees "no free slot", disconnects after the list, or never requests a farmhand, check the player's local Mod set before editing cabins again.

如果诊断显示服务端已经发送了 farmhand 席位列表，但玩家仍然看到“没有空闲位置”、收到列表后断开，或一直没有请求 farmhand，请先检查玩家本地 Mod，而不是继续改小屋数量。

**Why This Happens / 原因：**

Stardew multiplayer does not automatically synchronize SMAPI/content mods from the host to clients. Large content mods can add locations, events, NPCs, maps and save/world assumptions. If the host/server has those mods but a client is missing them or has different versions, the client may fail during the join flow before it can choose or load a farmhand. Depending on where the failure happens, the player-facing message can be misleading and look like an empty-slot/cabin problem.

星露谷联机不会自动把 SMAPI/内容 Mod 从房主同步到玩家本地。大型内容 Mod 会增加地点、事件、NPC、地图以及世界状态假设；如果服务端有这些 Mod，而客户端缺失或版本不同，客户端可能在选择或载入 farmhand 前失败。失败位置不同，玩家端提示可能会误导成空闲席位/小屋问题。

**What changed / 改动：**

- The player download pack now includes `ylty-client-mod-lock.json`.
- The public `/player-mods` page and `/api/public/mods/manifest.json` show the same pack fingerprint.
- Join-handshake diagnostics now mention the client mod pack when a player disconnects after the farmhand list or sees a no-slot rejection while cabins exist.
- The health check now reports the client mod parity package, including whether the pack is ready/stale and its fingerprint.

- 玩家下载包现在会包含 `ylty-client-mod-lock.json`。
- 公开 `/player-mods` 页面和 `/api/public/mods/manifest.json` 会显示同一个整包指纹。
- 玩家在收到 farmhand 列表后断开，或明明有小屋却提示无空位时，加入握手诊断会直接提示检查客户端 Mod 包。
- 健康检查会显示客户端 Mod 一致性包状态，包括是否 ready/stale 和整包指纹。

**Required workflow / 正确流程：**

1. Server owner uploads or imports mods in the panel.
2. Panel rebuilds `stardew-client-mods.zip`.
3. Every player downloads the pack from `/player-mods`.
4. Every player closes Stardew Valley, extracts the pack into local `Stardew Valley/Mods`, and starts through SMAPI.
5. If the server owner changes mods later, repeat the download/install step before joining again.

1. 服主在面板上传或导入 Mod。
2. 面板重建 `stardew-client-mods.zip`。
3. 每个玩家从 `/player-mods` 下载整包。
4. 每个玩家关闭游戏，把整包解压到本地 `Stardew Valley/Mods`，再通过 SMAPI 启动。
5. 服主之后改过 Mod，就必须重新下载/安装后再进服。

### Other Causes of "No Free Slot"
### “没有空闲位置”的其它真实原因

Client Mod mismatch is common, but it is not the only cause. The health page now includes `Save slot and cabin audit` so the panel can prove or rule out these blockers:

- the game process is loading a different save than the one shown to the server owner
- `runtime.env`, process `SAVE_NAME`, `.selected_save`, and ServerAutoLoad `SaveFileName` disagree
- `SAVE_NAME` was exported with literal quote characters, so the game searches for `'999'` instead of `999`
- `playerLimit` is below 8 or `enableFarmhandCreation` is disabled in `startup_preferences`
- the save has fewer Cabin buildings than expected
- the save already contains enough farmhand records to fill the available cabin/playerLimit capacity
- ServerAutoLoad did not find the selected save in the native Co-op Host list, or the selected slot is not hostable

客户端 Mod 不一致很常见，但不是唯一原因。健康检查现在包含 `Save slot and cabin audit`，面板会直接证明或排除这些阻塞点：

- 游戏进程实际加载的不是服主以为的那个存档
- `runtime.env`、进程里的 `SAVE_NAME`、`.selected_save` 和 ServerAutoLoad 的 `SaveFileName` 互相不一致
- `SAVE_NAME` 被带上了字面量引号，导致游戏寻找的是 `'999'` 而不是 `999`
- `startup_preferences` 里的 `playerLimit` 低于 8，或 `enableFarmhandCreation` 被关闭
- 存档里可识别的小屋数量少于预期
- 存档里已有 farmhand 记录已经占满小屋/玩家上限容量
- ServerAutoLoad 没有在原生 Co-op Host 列表里找到目标存档，或目标槽位本身不可主持

---

## Audio Warnings in Logs
## 日志中的音频警告

**Issue / 问题:**

You may see these warnings in the logs:
日志中可能会看到这些警告：

```
OpenAL device could not be initialized
Steam achievements won't work because Steam isn't loaded
```

**Why This Happens / 原因:**

The server runs in a headless environment without audio hardware or Steam client.
服务器在无音频硬件或 Steam 客户端的 headless 环境中运行。

**Impact / 影响:**

None - these are harmless warnings and do not affect server functionality.
无影响 - 这些是无害的警告，不影响服务器功能。

**Workaround / 解决方法:**

No action needed. These warnings can be safely ignored.
无需操作。可以安全地忽略这些警告。

---

## VNC Connection Required for First Setup
## 首次设置需要 VNC 连接

**Issue / 问题:**

The first time you start the server, you must use VNC to create or load a save file.
首次启动服务器时，必须使用 VNC 创建或加载存档文件。

**Why This Happens / 原因:**

Stardew Valley's multiplayer server requires an active save file. The game must be launched and a Co-op save created through the in-game interface.
星露谷物语的联机服务器需要一个活动的存档文件。必须启动游戏并通过游戏内界面创建 Co-op 存档。

**Impact / 影响:**

One-time setup only. After the initial save is created, it will auto-load on subsequent starts (though multiplayer may require manual reload after restarts - see issue above).
仅需一次设置。创建初始存档后，ServerAutoLoad v2 会在后续启动时通过原生 `Co-op -> Host` 流程自动加载目标存档。

**Workaround / 解决方法:**

Follow the setup instructions in the README:
按照 README 中的设置说明：

1. Connect via VNC (port 5900, password from .env file)
   通过 VNC 连接（端口 5900，密码来自 .env 文件）

2. Click "CO-OP" → "Start new co-op farm" or "Load" existing save
   点击 "CO-OP" → "开始新的联机农场" 或 "加载" 现有存档

3. After setup, you can disable VNC if desired to save ~50MB RAM
   设置完成后，如需节省约 50MB 内存，可禁用 VNC

---

## Reporting New Issues / 报告新问题

If you encounter an issue not listed here, please report it:
如果遇到此处未列出的问题，请报告：

- GitHub Issues: https://github.com/AmigaMeow/puppy-stardew-server/issues
- Docker Hub: https://hub.docker.com/r/truemanlive/puppy-stardew-server

Please include:
请包含：

- Container logs: `docker logs puppy-stardew`
- Game version from logs
- Steps to reproduce

---

**Last Updated:** 2025-10-29
**Version:** v1.0.23
