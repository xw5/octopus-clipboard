# octopus-clipboard — 剪贴板历史管理器

纯 AutoHotkey v2 实现，无第三方依赖，单文件即可运行。支持**中文 / English 双语界面**。

> 使用者请阅读 [使用说明书.md](使用说明书.md)；本文档面向开发者。
> For end users, see [使用说明书.md](使用说明书.md); this document is for developers.

- [中文文档](#中文文档)
- [English Documentation](#english-documentation)

---

# 中文文档

界面采用「小清新」薄荷绿主题：米白背景、纯白卡片、深绿灰文字、无网格线的清爽列表。配色集中在脚本顶部「配色（小清新主题）」区，可按需调整为其他色系（RGB 十六进制）。窗口顶部提示栏右侧显示「当前条数/总数」（如 `3/20`），随搜索和选择实时更新。

## 安装运行

1. 安装 AutoHotkey v2：https://www.autohotkey.com/ （本机已装于 `C:\Program Files\AutoHotkey\v2`）
2. **双击 `octopus-clipboard.ahk`** 即可运行（托盘出现图标）。
3. 如需开机常驻，可在托盘菜单勾选「开机自启」。
4. `octopus-clipboard.ico` 为应用图标（章鱼抱着剪贴板），需与脚本放在同一目录；托盘与窗口图标会自动应用。图标预览见 `icon-preview.png`。
5. 可用 Ahk2Exe 编译为独立 exe：
   `Ahk2Exe.exe /in octopus-clipboard.ahk /out octopus-clipboard.exe`

> ⚠️ 不要在 Git Bash 中用 `AutoHotkey64.exe /参数` 方式启动——Git Bash 会把 `/参数`
> 误转换为文件路径导致 "Script file not found"。请直接双击脚本，或在 PowerShell/CMD 中运行。

## 版本管理与打包

版本号唯一来源：`version.txt`（三段 `x.y.z`，如 `1.0.0`）。双击 `build.bat` 即打包，exe 的**文件版本 / 产品版本**自动写为 `x.y.z.0`（Windows 资源管理器「属性 → 详细信息」可查看），文件名也带版本。

**产物两个文件：**
- `octopus-clipboard-v<版本>.exe`：带版本号的发布包（如 `octopus-clipboard-v1.0.0.exe`），用于分发/留档
- `octopus-clipboard.exe`：固定名副本，内容与上面完全相同，供日常双击和开机自启使用（自启路径不随版本变化）

```bat
build.bat              :: 默认 patch +1（1.0.0 → 1.0.1）
build.bat patch        :: 同上
build.bat minor        :: minor +1，patch 归零（1.0.3 → 1.1.0）
build.bat major        :: major +1，其余归零（1.2.3 → 2.0.0）
build.bat 2.5.0        :: 直接指定版本
build.bat keep         :: 不递增，用当前版本重打包
```

流程：读取 `version.txt` → 计算新版本 → 关闭正在运行的旧 exe → 生成带 `;@Ahk2Exe-SetVersion` 等版本指令的临时脚本 → 编译到带版本名文件 → 复制为固定名 → 写回 `version.txt` → 校验 exe 版本。

- 编译器 `Ahk2Exe.exe` 放在 `tools/`（缺失时自动找 `%TEMP%\ahk2exe` 或 PATH）。
- AHK v2 基础解释器固定为 `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`（`build.bat` 顶部 `BASE` 可改）。
- 界面不显示版本号；版本只写进 exe 属性，`version.txt` 是唯一维护点。
- 手动编译（不带版本）仍可用：`Ahk2Exe.exe /in octopus-clipboard.ahk /out octopus-clipboard.exe`。

## 快捷键

默认热键如下，全部可在「设置 → 快捷键」中修改，保存后立即生效：

| 热键 | 作用 | 范围 |
|---|---|---|
| `Ctrl+Alt+V` | 呼出历史窗口 | 全局 |
| `Enter` / 双击 | 粘贴选中项 | 历史窗口 |
| `Esc` | 隐藏历史窗口 | 历史窗口 |
| `Delete` | 删除选中条目 | ListView 聚焦 |
| `Ctrl+P` | 钉住 / 取消钉住 | ListView 聚焦 |
| `Ctrl+C` | 仅复制到剪贴板 | ListView 聚焦 |
| `Ctrl+A` | 全选列表 | ListView 聚焦 |
| `Esc` | 关闭大图预览 | 大图窗口 |
| 滚轮 | 缩放大图 | 大图窗口 |
| 右键 → 仅复制到剪贴板 / 用画图编辑 | 扩展操作 | 历史窗口 |
| 直接输入 | 顶部搜索框实时过滤历史 | 历史窗口 |

## 右侧预览区

- 选中列表项后，右侧实时显示完整内容：
  - **文本**：可编辑文本框显示全文；修改后点「保存修改」
  - **文件**：可编辑路径列表；光标定位到某行后点「删除选中路径」可从记录中移除该路径（不删除磁盘文件）
  - **图片**：缩略图（自适应预览区大小，保持比例）
- 保存修改时会提示：`新增一条记录` / `替换当前记录` / `取消`。
- 切换条目时如有未保存修改，会提示保存、放弃或返回。
- 文件列表含图片时，可用「文件列表 / 图片预览」按钮切换视图。
- **智能图片识别**：以下情况都会直接渲染图片而非显示路径——
  - 剪贴板捕获的位图（截图、网页图片）
  - 从资源管理器复制的单个图片文件（png/jpg/gif/bmp/webp 等）
  - 文本内容恰好是一个存在的图片路径（含带引号的"复制文件路径"）
- 点击缩略图 → 弹出大图预览窗口：
  - 滚轮缩放（5% ~ 800%）
  - 标题栏显示原始尺寸与当前缩放比例
  - `Esc` 关闭
- 大图预览不做编辑功能（保持轻量），需要修改图片时右键「用画图编辑」跳转系统画图。

## 支持的剪贴板类型

- **文本**：自动换行合并展示，单条上限 10 万字符
- **图片**：自动保存为 PNG（含截图、网页复制图片），粘贴时恢复为位图
- **文件**：资源管理器里「复制」的文件/文件夹，粘贴时恢复为文件列表

## 数据存储

- 历史记录：`%APPDATA%\octopus-clipboard\history.dat`
- 图片文件：`%APPDATA%\octopus-clipboard\images\`
- 默认保留 500 条，超出时从最旧开始清理未钉住条目

> 从旧名称 `AhkClip` 升级时，脚本会自动把旧数据目录 `%APPDATA%\AhkClip` 迁移到新目录，并迁移旧启动项 `AhkClip.lnk`，历史记录与设置不会丢失。旧格式备份（`AHKCLIP-BACKUP-v1`）也可正常导入。

## 右上角「···」菜单

- **设置**：打开设置窗口
- **关闭记录 / 开启记录**：切换是否捕获剪贴板
- **语言：切换到 English**：中英文界面切换（见下节）
- **清空记录**：清空全部历史（含钉住项），带**不可恢复**二次确认
- **导入记录**：从 `.ahkcb` 备份恢复，合并并自动去重
- **导出记录**：把所有历史保存为自包含 `.ahkcb` 备份文件（图片以 base64 内嵌）

托盘菜单也提供「清空全部（不可恢复）」入口，以及「语言：切换到 English」。

## 国际化（i18n）

- 所有界面文本集中在脚本顶部 `L10N` 字典：`[1]` 为中文，`[2]` 为英文。
- `Tr(key)` 取当前语言文本；`TrF(key, vals*)` 用 `{1}`、`{2}` 占位符格式化。
- 语言状态存于 `%APPDATA%\octopus-clipboard\settings.ini`：
  ```ini
  [General]
  Language=zh    ; zh=中文, en=English
  ```
- **默认跟随系统 UI 语言**：首次运行（ini 无 `Language` 项）按系统语言自动选中文/英文；一旦手动切换，选择写入 ini 并固定，之后不再跟随系统。
- 切换入口：右上「···」菜单、托盘菜单、设置窗口内的语言按钮。
- 切换时写入 ini 后 `Reload` 脚本，重建全部窗口 / 菜单；历史会先落盘，不会丢失。
- 新增文案：在 `L10N` 加一对中英条目，再用 `Tr()` / `TrF()` 引用即可。

## 设置

「···」菜单 →「设置」或托盘菜单「设置」：
- **最大记录条数**：0-999（0 = 不限制），超出时从最旧清理未钉住条目
- **开机自启动**：勾选即创建启动项快捷方式
- **语言**：点击按钮即时切换中英文界面
- **快捷键**：全局呼出、粘贴、隐藏、删除、钉住、仅复制、全选、关闭大图
  - 每项有两栏：左侧「快捷键控件」直接按键录入；右侧「选择...」按钮点击后弹出勾选窗
  - 勾选窗分两块：**修饰键**（Ctrl / Alt / Win / Shift，可多选）+ **主键**（Esc、Enter、字母、F1-F12、方向键等，单选）
  - 勾选/选择后底部自动组合成快捷键，并同时显示 AHK 键名与友好格式（如 `^p` → `Ctrl+P`）
  - 不选修饰键即为单独主键（如 `Esc`）；已有快捷键打开时会反解析成对应勾选状态
  - 设置窗口打开期间所有快捷键暂时禁用，录入时不会误触发
  - 关闭设置窗口请用「取消」按钮或标题栏 X；未绑定 `Esc`（避免与可配置的 `Esc` 快捷键冲突）
  - 保存后立即生效，无需重启
  - 「恢复默认」只恢复输入框，需再点「保存」
- 配置持久化于 `%APPDATA%\octopus-clipboard\settings.ini`

```ini
[General]
MaxItems=500
RecordEnabled=1    ; 1=记录剪贴板，0=暂停记录
Language=zh        ; zh=中文, en=English

[Hotkeys]
ShowHistory=^!v
Paste=Enter
HideMain=Esc
Delete=Delete
Pin=^p
CopyOnly=^c
SelectAll=^a
HideBig=Esc
```

## 自定义

脚本顶部「配置区」可修改默认值（会被 settings.ini 覆盖）：

```autohotkey
MAX_ITEMS     := 500      ; 最大条数
MAX_TEXT_LEN  := 100000   ; 单条文本上限
```

---

# English Documentation

Built purely with AutoHotkey v2 — no third-party dependencies, runs from a single file. Supports a **bilingual Chinese / English UI**.

> End users: see [使用说明书.md](使用说明书.md). This document is for developers.

The UI uses a fresh mint-green theme: off-white background, pure white cards, dark green-gray text, and a clean gridless list. Colors are centralized in the "配色（小清新主题）" section at the top of the script (RGB hex). The hint bar at the top-right shows "current/total" (e.g. `3/20`), updating live with search and selection.

## Install & Run

1. Install AutoHotkey v2: https://www.autohotkey.com/ (installed locally at `C:\Program Files\AutoHotkey\v2`).
2. **Double-click `octopus-clipboard.ahk`** to run (tray icon appears).
3. For auto-start, check "开机自启" in the tray menu.
4. `octopus-clipboard.ico` is the app icon; keep it next to the script. Tray/window icons apply automatically. Preview: `icon-preview.png`.
5. Compile to a standalone exe with Ahk2Exe:
   `Ahk2Exe.exe /in octopus-clipboard.ahk /out octopus-clipboard.exe`

> ⚠️ Do not launch via `AutoHotkey64.exe /param` from Git Bash — it rewrites `/param` into a file path, causing "Script file not found". Double-click the script or run from PowerShell/CMD.

## Versioning & Build

The single source of truth is `version.txt` (three-part `x.y.z`, e.g. `1.0.0`). Double-click `build.bat` to build; the exe's **File version / Product version** is written as `x.y.z.0` (visible in Explorer → Properties → Details), and the filename carries the version too.

**Two output files:**
- `octopus-clipboard-v<version>.exe`: the versioned release (e.g. `octopus-clipboard-v1.0.0.exe`), for distribution/archiving
- `octopus-clipboard.exe`: a fixed-name copy, byte-identical, for daily double-click and auto-start (autostart path stays stable across versions)

```bat
build.bat              :: patch +1 by default (1.0.0 -> 1.0.1)
build.bat patch        :: same as above
build.bat minor        :: minor +1, patch reset (1.0.3 -> 1.1.0)
build.bat major        :: major +1, others reset (1.2.3 -> 2.0.0)
build.bat 2.5.0        :: set an explicit version
build.bat keep         :: rebuild with the current version, no bump
```

Flow: read `version.txt` -> compute new version -> close any running exe -> generate a temp script with `;@Ahk2Exe-SetVersion` directives -> compile to the versioned filename -> copy to the fixed name -> write back `version.txt` -> verify the exe version.

- Compiler `Ahk2Exe.exe` lives in `tools/` (falls back to `%TEMP%\ahk2exe` or PATH).
- AHK v2 base is fixed at `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe` (edit `BASE` at the top of `build.bat`).
- The version is not shown in the UI; it lives only in the exe properties, with `version.txt` as the single maintenance point.
- Plain compile without a version still works: `Ahk2Exe.exe /in octopus-clipboard.ahk /out octopus-clipboard.exe`.

## Hotkeys

Defaults below; all editable in Settings → Hotkeys, effective immediately after Save:

| Hotkey | Action | Scope |
|---|---|---|
| `Ctrl+Alt+V` | Show history window | Global |
| `Enter` / double-click | Paste selected item | History window |
| `Esc` | Hide history window | History window |
| `Delete` | Delete selected item | ListView focused |
| `Ctrl+P` | Pin / unpin | ListView focused |
| `Ctrl+C` | Copy to clipboard only | ListView focused |
| `Ctrl+A` | Select all | ListView focused |
| `Esc` | Close image preview | Image window |
| Mouse wheel | Zoom image | Image window |
| Right-click → Copy only / Edit with Paint | Extended actions | History window |
| Typing | Live-filter history in search box | History window |

## Right Preview Pane

- Selecting a row shows its full content on the right:
  - **Text**: editable box; click "Save Changes" after editing
  - **Files**: editable path list; place the cursor on a line and click "Remove Selected Path" to drop it from the record (disk file untouched)
  - **Image**: thumbnail (auto-fit, keeps aspect ratio)
- Saving prompts: `Add a new record` / `Replace current record` / `Cancel`.
- Switching items with unsaved edits prompts to save, discard, or return.
- When a file list contains images, toggle "File List / Image Preview" to switch views.
- **Smart image detection** — renders an image instead of a path when:
  - clipboard holds a bitmap (screenshot, web image)
  - a single image file was copied from Explorer (png/jpg/gif/bmp/webp, etc.)
  - the text is exactly an existing image path (including quoted "copy file path")
- Click a thumbnail → full-size preview:
  - wheel zoom (5%–800%)
  - title bar shows native size and current zoom
  - `Esc` closes
- The preview is view-only; right-click "Edit with Paint" opens MS Paint for editing.

## Supported Clipboard Types

- **Text**: auto-joined lines, 100k chars max per item
- **Image**: saved as PNG (screenshots, web copies), restored as a bitmap on paste
- **Files**: files/folders copied in Explorer, restored as a file list

## Data Storage

- History: `%APPDATA%\octopus-clipboard\history.dat`
- Images: `%APPDATA%\octopus-clipboard\images\`
- Keeps 500 items by default; oldest unpinned items are pruned first

> Upgrading from `AhkClip`: the script migrates the old data dir `%APPDATA%\AhkClip` and startup shortcut `AhkClip.lnk`; history and settings are preserved. Old-format backups (`AHKCLIP-BACKUP-v1`) import normally.

## Top-right "···" Menu

- **Settings**: open the settings window
- **Pause / Resume Recording**: toggle clipboard capture
- **Language: Switch to 中文**: switch between Chinese and English UI (see below)
- **Clear History**: wipe all records (including pinned), with an **irreversible** confirmation
- **Import History**: restore from a `.ahkcb` backup, merge and dedupe
- **Export History**: save all history to a self-contained `.ahkcb` backup (images embedded as base64)

The tray menu also has "Clear All (Irreversible)" and the language switch.

## Internationalization (i18n)

- All UI text lives in the `L10N` map near the top of the script: `[1]` = Chinese, `[2]` = English.
- `Tr(key)` returns text in the current language; `TrF(key, vals*)` formats `{1}`, `{2}` placeholders.
- Language is stored in `%APPDATA%\octopus-clipboard\settings.ini`:
  ```ini
  [General]
  Language=zh    ; zh=Chinese, en=English
  ```
- **Defaults to the system UI language**: on first run (no `Language` entry in the ini), Chinese or English is chosen automatically from the system language. Once you switch manually, the choice is saved to the ini and stays fixed (no longer follows the system).
- Switch entries: top-right "···" menu, tray menu, and the language button in Settings.
- Switching writes the ini and `Reload`s the script to rebuild all windows/menus; history is flushed first, so nothing is lost.
- To add a string: add a zh/en pair to `L10N`, then reference it via `Tr()` / `TrF()`.

## Settings

"···" → "Settings", or tray → "Settings":
- **Max records**: 0–999 (0 = unlimited); oldest unpinned items pruned when exceeded
- **Start with Windows**: creates a startup shortcut when checked
- **Language**: click the button to switch the UI instantly
- **Hotkeys**: global show, paste, hide, delete, pin, copy-only, select-all, close preview
  - each row has two columns: left hotkey control for direct key entry; right "Select..." button opens a picker
  - picker has **Modifiers** (Ctrl / Alt / Win / Shift, multi-select) + **Base key** (Esc, Enter, letters, F1–F12, arrows, single-select)
  - selection composes the hotkey at the bottom, showing both the AHK key name and a friendly form (e.g. `^p` → `Ctrl+P`)
  - no modifier means a single base key (e.g. `Esc`); opening an existing hotkey reverse-parses it into the picker state
  - all hotkeys are temporarily disabled while Settings is open, to avoid misfires during entry
  - close Settings with "Cancel" or the title-bar X; `Esc` is intentionally unbound to avoid conflicting with a configurable `Esc` hotkey
  - changes apply immediately after Save, no restart needed
  - "Restore Defaults" only resets the fields — click "Save" to persist
- Settings persist in `%APPDATA%\octopus-clipboard\settings.ini`

```ini
[General]
MaxItems=500
RecordEnabled=1    ; 1=record clipboard, 0=paused
Language=zh        ; zh=Chinese, en=English

[Hotkeys]
ShowHistory=^!v
Paste=Enter
HideMain=Esc
Delete=Delete
Pin=^p
CopyOnly=^c
SelectAll=^a
HideBig=Esc
```

## Customization

Edit the "配置区" constants at the top of the script (overridden by settings.ini):

```autohotkey
MAX_ITEMS     := 500      ; max records
MAX_TEXT_LEN  := 100000   ; max chars per text item
```
