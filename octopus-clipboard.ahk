#Requires AutoHotkey v2.0
#SingleInstance Force
; =====================================================================
;  octopus-clipboard —— 轻量级剪贴板历史管理器（类似 Ditto）
;  AutoHotkey v2 原生实现，无第三方依赖
;
;  功能：
;    - 全局热键呼出历史窗口（默认 Ctrl+Alt+V）
;    - 支持文本 / 图片(存PNG) / 复制的文件 三种类型
;    - 搜索过滤、钉住(置顶)、删除、清空
;    - 历史持久化，重启不丢失
;    - 托盘菜单：开机自启、清空、退出
; =====================================================================

; ----------------------- 配置区（可按需修改） -------------------------
MAX_ITEMS     := 500                ; 最大历史条数（钉住的条目不会被清理）
MAX_TEXT_LEN  := 100000             ; 单条文本最大保存字符数
DATA_DIR      := A_AppData "\octopus-clipboard"
IMG_DIR       := DATA_DIR "\images"
DATA_FILE     := DATA_DIR "\history.dat"
SETTINGS_FILE := DATA_DIR "\settings.ini"
ICON_FILE     := A_ScriptDir "\octopus-clipboard.ico"   ; 应用图标（与脚本同目录）
; 从旧名 AhkClip 迁移数据目录，保护已有历史记录/设置/图片
OLD_DATA_DIR  := A_AppData "\AhkClip"
if (DirExist(OLD_DATA_DIR) && !DirExist(DATA_DIR)) {
    try DirMove(OLD_DATA_DIR, DATA_DIR)
}
; ---------------------------------------------------------------------

; ----------------------- 配色（小清新主题） ---------------------------
; AHK v2 颜色为 RGB 十六进制（RRGGBB）
C_BG      := "F7F9F8"   ; 窗口米白背景
C_SURFACE := "FFFFFF"   ; 卡片/输入框纯白
C_IMAGEBG := "EEF2F0"   ; 图片预览区淡灰绿
C_TEXT    := "37443E"   ; 主文字 深绿灰
C_MUTED   := "8FA096"   ; 次要文字 淡灰绿
C_ACCENT  := "4FA98C"   ; 强调 薄荷绿
; ---------------------------------------------------------------------

; 设置托盘/窗口图标（须在创建 GUI 之前）
; 编译后为独立 exe：从 exe 自身读取嵌入图标；源码运行时读取同目录 ico
if A_IsCompiled
    TraySetIcon(A_ScriptFullPath)
else if FileExist(ICON_FILE)
    TraySetIcon(ICON_FILE)

; 快捷键默认值（可在设置窗口修改，自动保存到 settings.ini 的 [Hotkeys] 段）
HOTKEY_DEFAULTS := Map(
    "ShowHistory", "^!v",
    "Paste",       "Enter",
    "HideMain",    "Esc",
    "Delete",      "Delete",
    "Pin",         "^p",
    "CopyOnly",    "^c",
    "SelectAll",   "^a",
    "HideBig",     "Esc"
)
HK_KEYS    := Map()
HK_PREV    := Map()
HK_CTRL    := Map()
HK_EDIT    := Map()   ; id -> 实际键名字符串（弹窗勾选或控件录制的最终值）
HK_BTN     := Map()   ; id -> 右侧「选择...」按钮，显示友好键名
HK_LABEL   := Map(
    "ShowHistory", "显示历史窗口",
    "Paste",       "粘贴选中项",
    "HideMain",    "隐藏历史窗口",
    "Delete",      "删除选中项",
    "Pin",         "钉住 / 取消钉住",
    "CopyOnly",    "仅复制到剪贴板",
    "SelectAll",   "全选列表",
    "HideBig",     "关闭大图预览"
)
HK_CONTEXT := Map(
    "ShowHistory", "Global",
    "Paste",       "Main",
    "HideMain",    "Main",
    "Delete",      "List",
    "Pin",         "List",
    "CopyOnly",    "List",
    "SelectAll",   "List",
    "HideBig",     "Big"
)
HK_REQUIRE_MOD := Map("ShowHistory", 1, "Pin", 1, "CopyOnly", 1, "SelectAll", 1)
HK_IDS := ["Delete", "Pin", "CopyOnly", "SelectAll", "HideBig", "Paste", "HideMain", "ShowHistory"]

DirCreate(DATA_DIR)
DirCreate(IMG_DIR)

; 从设置文件恢复用户配置（覆盖默认值）
_sMax := IniRead(SETTINGS_FILE, "General", "MaxItems", 500)
if (_sMax ~= "^\d+$")
    MAX_ITEMS := Min(999, Max(0, Integer(_sMax)))

LoadHotkeySettings()

; ----------------------- 全局状态 ------------------------------------
history    := []     ; 每项: {type: "text"|"image"|"files", data:..., pinned:0/1, time:A_Now, meta:""}
rowMap     := []     ; ListView 行号 -> history 索引
lastOwnSet := 0      ; 自己设置剪贴板的时间戳（避免循环捕获）
guiReady   := false
settingsOpen := false   ; 设置窗口打开时禁用所有可配置热键，避免录入时误触
recordEnabled := true   ; 是否记录剪贴板（可在「···」菜单开关，持久化到 ini）
_rec := IniRead(SETTINGS_FILE, "General", "RecordEnabled", "1")
recordEnabled := (_rec != "0")
GdipToken  := 0

; 预览区状态
bigGui    := 0
bigPic    := 0
bigZoom   := 0       ; 0 = 自适应窗口
lastScale := 1
bigNatW   := 0
bigNatH   := 0
bigPath   := ""

LoadHistory()

; ----------------------- 剪贴板监听 ----------------------------------
OnClipboardChange(CatchClipboard)

CatchClipboard(ClipType) {
    global lastOwnSet, history, recordEnabled
    if !recordEnabled                       ; 记录已关闭：不捕获任何剪贴板变更
        return
    if (A_TickCount - lastOwnSet < 800)   ; 自己粘贴写入的剪贴板变更，忽略
        return
    ; 优先判断"复制的文件"(CF_HDROP)
    if DllCall("IsClipboardFormatAvailable", "uint", 15) {
        paths := GetClipboardFiles()
        if (paths.Length > 0)
            AddHistory("files", paths)
        return
    }
    if (ClipType = 1) {                   ; 文本
        t := A_Clipboard
        if (t = "")
            return
        if (StrLen(t) > MAX_TEXT_LEN)
            t := SubStr(t, 1, MAX_TEXT_LEN)
        AddHistory("text", t)
    } else if (ClipType = 2) {            ; 非文本（尝试按图片处理）
        if DllCall("IsClipboardFormatAvailable", "uint", 2) {   ; CF_BITMAP
            r := SaveClipboardImage()
            if r
                AddHistory("image", r.path, r.meta)
        }
    }
}

AddHistory(type, data, meta := "") {
    global history, MAX_ITEMS, guiReady
    sig := SigOf(type, data, meta)
    ; 去重：已存在则移到顶部并刷新时间
    for idx, item in history {
        if (item.type = type && SigOf(item.type, item.data, item.meta) = sig) {
            item.time := A_Now
            moved := history.RemoveAt(idx)
            history.InsertAt(1, moved)
            RefreshList()
            SaveSoon()
            return
        }
    }
    history.InsertAt(1, {type: type, data: data, pinned: 0, time: A_Now, meta: meta})
    ; 超出上限时，从最旧开始清理未钉住的条目（MAX_ITEMS=0 表示不限制）
    if (MAX_ITEMS > 0 && history.Length > MAX_ITEMS) {
        i := history.Length
        while (i > 0 && history.Length > MAX_ITEMS) {
            if !history[i].pinned
                history.RemoveAt(i)
            i--
        }
    }
    if guiReady
        RefreshList()
    SaveSoon()
}

SigOf(type, data, meta) {
    switch type {
        case "image": return meta                ; 用 "宽|高" 判重
        case "files": return StrLower(Join(data, "`n"))
        default:      return data
    }
}

; ----------------------- 主窗口 --------------------------------------
main := Gui("+Resize +MinSize640x420", "octopus-clipboard — 剪贴板历史")
main.BackColor := C_BG
main.SetFont("s10 c" C_TEXT, "Microsoft YaHei UI")
edSearch := main.AddEdit("x8 y8 w628 h26 Background" C_SURFACE, "")
btnMore  := main.AddButton("x642 y8 w50 h26", "···")
main.SetFont("s9 c" C_MUTED)
hint := main.AddText("x8 y38 w600", "")
lblCount := main.AddText("x596 y38 w96 Right c" C_MUTED, "0/0")
main.SetFont("s10 c" C_TEXT)
lv := main.AddListView("x8 y58 w340 h390 -Grid NoSortHdr Background" C_SURFACE " c" C_TEXT, ["钉", "类型", "内容", "时间"])
lv.ModifyCol(1, 26)
lv.ModifyCol(2, 40)
lv.ModifyCol(3, 250)
lv.ModifyCol(4, 76)

; ---- 右侧预览区 ----
pvX := 0, pvY := 0, pvW := 0, pvH := 0
previewIdx := 0, previewRow := 0, previewKind := ""
previewLoading := false, previewDirty := false, previewOriginal := ""
previewMode := false, previewImgList := [], previewHasModeBtn := false

txtEmpty   := main.AddText("Hidden Center c" C_MUTED, "未选择条目")
editPrev   := main.AddEdit("Hidden Multi VScroll Background" C_SURFACE, "")
picPreview := main.AddPicture("Hidden Background" C_IMAGEBG, "")
picHint    := main.AddText("Hidden Center c" C_MUTED, "点击图片查看大图（预览窗口内滚轮缩放）")
btnPreviewMode := main.AddButton("Hidden", "文件列表")
btnDelPath     := main.AddButton("Hidden", "删除选中路径")
btnSavePrev    := main.AddButton("Hidden", "保存修改")

; 多图网格控件池（最多 12 张）
picPool   := []
poolPaths := []
Loop 12 {
    p := main.AddPicture("Hidden Background" C_IMAGEBG, "")
    p.OnEvent("Click", PoolClick)
    picPool.Push(p)
    poolPaths.Push("")
}

edSearch.OnEvent("Change", (*) => RefreshList())
btnMore.OnEvent("Click", ShowMoreMenu)
lv.OnEvent("DoubleClick", (ctrl, row) => PasteRow(row))
lv.OnEvent("ItemSelect", (*) => PreviewSelectionChanged())
lv.OnEvent("ContextMenu", ShowContextMenu)
picPreview.OnEvent("Click", (*) => ShowBigPreview())
editPrev.OnEvent("Change", (*) => PreviewEditChanged())
btnPreviewMode.OnEvent("Click", (*) => TogglePreviewMode())
btnDelPath.OnEvent("Click", (*) => DeletePreviewPath())
btnSavePrev.OnEvent("Click", (*) => SavePreviewChange())
main.OnEvent("Close", (*) => main.Hide())
main.OnEvent("Size", GuiResize)

GuiResize(g, minmax, w, h) {
    global edSearch, btnMore, hint, lblCount, lv, pvX, pvY, pvW, pvH
    if (minmax = -1)
        return
    edSearch.Move(8, 8, w - 72, 24)
    btnMore.Move(w - 58, 8, 50, 24)
    hint.Move(8, 36, Max(100, w - 116))
    lblCount.Move(w - 104, 36, 96)
    listW := Round((w - 16 - 12) * 2 / 3)   ; 左侧列表占 2/3，右侧预览占 1/3
    lv.Move(8, 58, listW, h - 66)
    pvX := 8 + listW + 12
    pvY := 58
    pvW := w - 16 - listW - 12
    pvH := h - 66
    SetTimer(UpdatePreview, -120)
}

; 右键菜单
menuCtx := Menu()
menuCtx.Add("粘贴此项(&P)", (*) => PasteSelected())
menuCtx.Add("仅复制到剪贴板(&C)", (*) => CopySelectedOnly())
menuCtx.Add("打开位置(&O)", (*) => OpenSelected())
menuCtx.Add("用画图编辑(&E)", (*) => EditSelected())
menuCtx.Add()
menuCtx.Add("钉住 / 取消钉住(&S)", (*) => TogglePinSelected())
menuCtx.Add("删除(&D)", (*) => DeleteSelected())

ShowContextMenu(ctrl, item, isRightClick, x, y) {
    global menuCtx
    menuCtx.Show(x, y)
}

; ---- 右上角「···」菜单 ----
menuMore := Menu()

ShowMoreMenu(*) {
    global menuMore, recordEnabled, btnMore, main
    menuMore.Delete()
    menuMore.Add("设置", (*) => ShowSettings())
    menuMore.Add(recordEnabled ? "关闭记录" : "开启记录", (*) => ToggleRecord())
    menuMore.Add()
    menuMore.Add("清空记录", (*) => ClearAllRecords())
    menuMore.Add("导入记录", (*) => ImportHistory())
    menuMore.Add("导出记录", (*) => ExportHistory())
    ; 精确定位到「···」按钮正下方：控件客户区坐标 → 屏幕坐标
    CoordMode("Menu", "Screen")
    btnMore.GetPos(&bx, &by, &bw, &bh)
    pt := Buffer(8, 0)
    NumPut("Int", bx, pt, 0)
    NumPut("Int", by + bh, pt, 4)
    DllCall("user32\ClientToScreen", "ptr", main.Hwnd, "ptr", pt)
    menuMore.Show(NumGet(pt, 0, "Int"), NumGet(pt, 4, "Int"))
}

ToggleRecord() {
    global recordEnabled, SETTINGS_FILE
    recordEnabled := !recordEnabled
    IniWrite(recordEnabled ? "1" : "0", SETTINGS_FILE, "General", "RecordEnabled")
    TrayTip(recordEnabled ? "剪贴板记录已开启" : "剪贴板记录已关闭", "octopus-clipboard", "Iconi")
}

guiReady := true
GuiResize(main, 0, 700, 480)
RefreshList()

; ----------------------- 固定热键：大图预览滚轮 -------------------------
#HotIf IsObject(bigGui) && WinActive("ahk_id " bigGui.Hwnd)
WheelUp::BigZoomStep(1.25)
WheelDown::BigZoomStep(0.8)
#HotIf

; ----------------------- 可配置热键 / 托盘 -----------------------------
; 快捷键通过全局热键 + 上下文开关实现，支持设置窗口即时修改。
ApplyHotkeys()
SetTimer(UpdateHotkeyContext, 100)
UpdateHint()

A_TrayMenu.Delete()
A_TrayMenu.Add("打开剪贴板历史(&O)", (*) => ShowMain())
A_TrayMenu.Add()
A_TrayMenu.Add("清空历史(保留钉住)", (*) => ClearHistory(true))
A_TrayMenu.Add("清空全部(&A)（不可恢复）", (*) => ClearAllRecords())
A_TrayMenu.Add()
A_TrayMenu.Add("开机自启", ToggleAutostart)
A_TrayMenu.Add("设置(&S)...", (*) => ShowSettings())
A_TrayMenu.Add()
A_TrayMenu.Add("退出(&X)", (*) => ExitApp())
A_TrayMenu.Default := "打开剪贴板历史(&O)"
A_TrayMenu.Click := 1
; 迁移旧启动项名称，保持开机自启状态不丢失
_oldLnk := A_Startup "\octopus-clipboard.lnk"
_newLnk := A_Startup "\octopus-clipboard.lnk"
if (FileExist(_oldLnk) && !FileExist(_newLnk)) {
    try FileMove(_oldLnk, _newLnk)
}
if FileExist(_newLnk)
    A_TrayMenu.ToggleCheck("开机自启")

OnExit((*) => SaveHistory())

ShowMain(*) {
    global main
    RefreshList()
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    x := mx - 100
    y := my + 12
    if (x > A_ScreenWidth - 720)
        x := A_ScreenWidth - 720
    if (x < 0)
        x := 0
    if (y > A_ScreenHeight - 500)
        y := A_ScreenHeight - 500
    if (y < 0)
        y := 0
    main.Show("x" x " y" y " w700 h480")
}

; ----------------------- 列表与操作 -----------------------------------
RefreshList() {
    global lv, edSearch, history, rowMap
    rowMap := []
    lv.Delete()
    q := StrLower(Trim(edSearch.Value))
    for idx, item in history {
        preview := PreviewOf(item)
        if (q != "" && !InStr(StrLower(preview), q) && !InStr(StrLower(FullTextOf(item)), q))
            continue
        lv.Add("", item.pinned ? "★" : "", TypeName(item.type), preview, FormatTime(item.time, "MM-dd HH:mm"))
        rowMap.Push(idx)
    }
    if (rowMap.Length > 0)
        lv.Modify(1, "Select Vis")
    UpdateCountLabel()
    PreviewSelectionChanged()
}

UpdateCountLabel() {
    global lblCount, lv
    if !IsObject(lblCount)
        return
    row := lv.GetNext()
    lblCount.Value := (row > 0 ? row : 0) "/" lv.GetCount()
}

TypeName(t) {
    switch t {
        case "text":  return "文本"
        case "image": return "图片"
        case "files": return "文件"
    }
    return t
}

PreviewOf(item) {
    switch item.type {
        case "text":
            s := StrReplace(StrReplace(item.data, "`r`n", " "), "`n", " ")
            return (StrLen(s) > 150) ? SubStr(s, 1, 150) "…" : s
        case "image":
            wh := StrSplit(item.meta "|", "|")
            return "[图片 " wh[1] "x" wh[2] "]"
        case "files":
            names := ""
            imgs := 0
            for p in item.data {
                SplitPath(p, &name)
                names .= (A_Index > 1 ? "  " : "") name
                if (ImagePathFromText(p) != "")
                    imgs++
            }
            tag := (imgs > 0 && imgs = item.data.Length) ? "[图片]" : "[文件]"
            return tag " " names
    }
    return ""
}

FullTextOf(item) {
    switch item.type {
        case "files": return Join(item.data, "`n")
        case "image": return "图片"
        default:      return item.data
    }
}

SelectedIndex() {
    global lv, rowMap
    row := lv.GetNext()
    if (row = 0 || rowMap.Length < row)
        return 0
    return rowMap[row]
}

; ----------------------- 预览区 ----------------------------------------
HidePreviewControls() {
    global txtEmpty, editPrev, picPreview, picHint, picPool
    global btnPreviewMode, btnDelPath, btnSavePrev, previewHasModeBtn
    previewHasModeBtn := false
    txtEmpty.Opt("+Hidden")
    editPrev.Opt("+Hidden")
    picPreview.Opt("+Hidden")
    picHint.Opt("+Hidden")
    btnPreviewMode.Opt("+Hidden")
    btnDelPath.Opt("+Hidden")
    btnSavePrev.Opt("+Hidden")
    for pp in picPool
        pp.Opt("+Hidden")
}

ShowEmptyPreview(msg) {
    global txtEmpty, pvX, pvY, pvW
    txtEmpty.Value := msg
    txtEmpty.Move(pvX, pvY + 10, pvW, 20)
    txtEmpty.Opt("-Hidden")
}

UpdatePreview() {
    global history, lv, guiReady
    global pvX, pvY, pvW, pvH
    global previewIdx, previewRow, previewKind, previewLoading, previewDirty
    global previewOriginal, previewMode, previewImgList, previewHasModeBtn

    if (!guiReady || pvW < 10)
        return
    HidePreviewControls()
    idx := SelectedIndex()
    if (idx = 0) {
        previewIdx := 0
        previewRow := 0
        previewKind := ""
        previewDirty := false
        previewOriginal := ""
        previewMode := false
        previewImgList := []
        ShowEmptyPreview("未选择条目")
        return
    }
    if (previewDirty && idx = previewIdx) {
        ShowPreviewEditor()
        return
    }
    if (idx != previewIdx) {
        previewIdx := idx
        previewRow := lv.GetNext()
        previewMode := false
    }
    item := history[idx]
    previewKind := item.type
    previewDirty := false
    previewOriginal := ""
    previewImgList := []

    ; 收集选中项里的所有本地图片（覆盖：图片项 / 文件列表 / 图片路径文本）
    imgList := []
    if (item.type = "image")
        imgList.Push(item.data)
    else if (item.type = "files") {
        for p in item.data {
            ip := ImagePathFromText(p)
            if (ip != "")
                imgList.Push(ip)
        }
    } else {
        ip := ImagePathFromText(item.data)
        if (ip != "")
            imgList.Push(ip)
    }
    if (imgList.Length = 1) {
        if ShowImageInPreview(imgList[1]) {
            if (item.type = "files") {
                previewImgList := imgList
                btnPreviewMode.Text := "文件列表"
                ShowPreviewModeButton()
            }
            return
        }
        if (item.type = "image") {
            ShowEmptyPreview("[图片加载失败]")
            return
        }
    } else if (imgList.Length > 1) {
        if (item.type = "files" && previewMode) {
            ; 用户切到文件列表，下面走可编辑路径列表
        } else {
            ShowImageGrid(imgList)
            if (item.type = "files") {
                previewImgList := imgList
                btnPreviewMode.Text := "文件列表"
                ShowPreviewModeButton()
            }
            return
        }
    }
    switch item.type {
        case "text":
            previewOriginal := item.data
            LoadPreviewEditor(previewOriginal)
        case "files":
            lines := ""
            for p in item.data
                lines .= (A_Index > 1 ? "`n" : "") p
            previewOriginal := lines
            btnPreviewMode.Text := "图片预览"
            if (previewImgList.Length > 0)
                ShowPreviewModeButton()
            LoadPreviewEditor(previewOriginal)
        case "image":
            ShowEmptyPreview("[图片加载失败]")
    }
}

LoadPreviewEditor(text) {
    global editPrev, previewLoading
    previewLoading := true
    editPrev.Value := text
    previewLoading := false
    ShowPreviewEditor()
}

ShowPreviewEditor() {
    global editPrev, pvX, pvY, pvW, pvH, previewHasModeBtn
    h := pvH - (previewHasModeBtn ? 54 : 28)
    editPrev.Move(pvX, pvY, pvW, Max(40, h))
    editPrev.Opt("-Hidden")
    UpdatePreviewButtons()
}

ShowPreviewModeButton() {
    global btnPreviewMode, picHint, pvX, pvY, pvW, pvH, previewHasModeBtn
    btnPreviewMode.Move(pvX, pvY + pvH - 24, 92, 22)
    btnPreviewMode.Opt("-Hidden")
    ; 提示文本右移，避开模式按钮，避免遮挡
    picHint.Value := "点击查看大图"
    picHint.Move(pvX + 100, pvY + pvH - 20, Max(60, pvW - 100), 18)
    previewHasModeBtn := true
}

UpdatePreviewButtons() {
    global btnSavePrev, btnDelPath, previewKind, previewDirty, previewHasModeBtn
    global pvX, pvY, pvW, pvH
    if (previewKind != "text" && previewKind != "files")
        return
    by := pvY + pvH - 24
    if previewHasModeBtn
        by -= 26
    if (previewKind = "files") {
        btnDelPath.Move(pvX, by, 92, 22)
        btnDelPath.Opt("-Hidden")
        btnSavePrev.Move(pvX + 100, by, Max(60, pvW - 100), 22)
    } else {
        btnSavePrev.Move(pvX + Max(0, pvW - 100), by, 100, 22)
    }
    btnSavePrev.Text := "保存修改"
    btnSavePrev.Enabled := previewDirty
    btnSavePrev.Opt("-Hidden")
}

PreviewEditChanged() {
    global previewLoading, previewDirty, previewKind
    if (previewLoading || (previewKind != "text" && previewKind != "files"))
        return
    previewDirty := true
    UpdatePreviewButtons()
}

PreviewSelectionChanged() {
    global previewIdx, previewRow, previewDirty, lv
    idx := SelectedIndex()
    if (previewDirty && idx != previewIdx) {
        r := MsgBox("预览内容已修改但未保存。`n`n是：保存修改`n否：放弃修改`n取消：返回当前项", "未保存的修改", "YesNoCancel Icon!")
        if (r = "Cancel") {
            if (previewRow > 0)
                lv.Modify(previewRow, "Select Vis")
            return
        }
        if (r = "Yes") {
            if !SavePreviewChange()
                return
        }
        previewDirty := false
    }
    UpdateCountLabel()
    UpdatePreview()
}

TogglePreviewMode() {
    global previewMode
    previewMode := !previewMode
    UpdatePreview()
}

DeletePreviewPath() {
    global editPrev, main, previewKind
    if (previewKind != "files")
        return
    line := 1
    try line := EditGetCurrentLine(editPrev, "ahk_id " main.Hwnd)
    lines := StrSplit(StrReplace(editPrev.Value, "`r`n", "`n"), "`n")
    if (line < 1 || line > lines.Length)
        return
    lines.RemoveAt(line)
    editPrev.Value := Join(lines, "`n")
    PreviewEditChanged()
}

SavePreviewChange() {
    global history, editPrev, previewIdx, previewKind, previewDirty, previewOriginal
    if (previewIdx = 0 || previewIdx > history.Length)
        return false
    text := StrReplace(editPrev.Value, "`r`n", "`n")
    if (previewKind = "text") {
        if (text = "") {
            MsgBox "文本内容不能为空。", "无法保存", "Icon!"
            return false
        }
        data := text
        sig := text
    } else if (previewKind = "files") {
        data := []
        for line in StrSplit(text, "`n") {
            p := Trim(line)
            if (p != "")
                data.Push(p)
        }
        if (data.Length = 0) {
            MsgBox "文件列表不能为空。", "无法保存", "Icon!"
            return false
        }
        sig := Join(data, "`n")
    } else
        return false

    if (sig = previewOriginal) {
        previewDirty := false
        UpdatePreviewButtons()
        return true
    }
    r := MsgBox("请选择保存方式：`n`n是：新增一条记录`n否：替换当前记录`n取消：不保存", "保存修改", "YesNoCancel Icon!")
    if (r = "Cancel")
        return false
    previewDirty := false
    if (r = "Yes") {
        AddHistory(previewKind, data)
    } else {
        item := history[previewIdx]
        item.data := data
        item.time := A_Now
        SaveHistory(true)
        RefreshList()
    }
    return true
}

; 多图网格预览（最多显示 picPool.Length 张）
ShowImageGrid(imgList) {
    global picPool, poolPaths, picHint
    global pvX, pvY, pvW, pvH
    n := Min(imgList.Length, picPool.Length)
    cols := (n <= 2) ? n : (n <= 4 ? 2 : 3)
    rows := Ceil(n / cols)
    gap := 6
    cellW := (pvW - (cols - 1) * gap - 8) // cols
    cellH := (pvH - 30 - (rows - 1) * gap) // rows
    if (cellW < 20 || cellH < 20)
        return
    Loop picPool.Length
        poolPaths[A_Index] := ""
    i := 0
    for path in imgList {
        if (i >= picPool.Length)
            break
        i++
        r := RenderImageHBITMAP(path, cellW - 4, cellH - 4, 0)
        if !r
            continue
        pic := picPool[i]
        poolPaths[i] := path
        cx := pvX + 4 + (Mod(i - 1, cols)) * (cellW + gap) + (cellW - r.w) // 2
        cy := pvY + ((i - 1) // cols) * (cellH + gap) + (cellH - r.h) // 2
        pic.Move(cx, cy, r.w, r.h)
        pic.Value := "HBITMAP:*" r.hBmp   ; 控件接管位图并自动释放
        pic.Opt("-Hidden")
    }
    if (i < imgList.Length)
        picHint.Value := "共 " imgList.Length " 张图片（显示前 " i " 张） · 点击查看大图"
    else
        picHint.Value := "共 " imgList.Length " 张图片 · 点击查看大图"
    picHint.Move(pvX, pvY + pvH - 20, pvW, 18)
    picHint.Opt("-Hidden")
}

PoolClick(ctrl, *) {
    global picPool, poolPaths
    Loop picPool.Length {
        if (picPool[A_Index].Hwnd = ctrl.Hwnd) {
            p := poolPaths[A_Index]
            if (p != "")
                ShowBigPreview(p)
            return
        }
    }
}

; 选中项若是本地图片，渲染到预览区；成功返回 true
ShowImageInPreview(path) {
    global txtEmpty, editPrev, picPreview, picHint
    global pvX, pvY, pvW, pvH
    r := RenderImageHBITMAP(path, pvW - 4, pvH - 30, 0)
    if r {
        picPreview.Move(pvX + (pvW - r.w) // 2, pvY + (pvH - 24 - r.h) // 2, r.w, r.h)
        picPreview.Value := "HBITMAP:*" r.hBmp   ; 控件接管位图并自动释放
        picPreview.Opt("-Hidden")
        picHint.Move(pvX, pvY + pvH - 20, pvW, 18)
        picHint.Opt("-Hidden")
        return true
    }
    return false
}

; 判断文本是否为一个存在的本地图片路径，是则返回规范路径，否则返回 ""
ImagePathFromText(s) {
    s := Trim(s)
    if (s = "" || InStr(s, "`n") || StrLen(s) > 260)
        return ""
    if (SubStr(s, 1, 1) = "`"" || SubStr(s, 1, 1) = "'")
        s := SubStr(s, 2)
    if (SubStr(s, -1) = "`"" || SubStr(s, -1) = "'")
        s := SubStr(s, 1, -1)
    s := Trim(s)
    SplitPath(s, , , &ext)
    ext := StrLower(ext)
    if !InStr(",png,jpg,jpeg,gif,bmp,webp,ico,tif,tiff,", "," ext ",")
        return ""
    return FileExist(s) ? s : ""
}

FreePrevBitmap() {
    ; 位图由 Picture 控件（HBITMAP:*）接管并自动释放，无需手动删除
}

; 按目标尺寸/缩放渲染图片为 HBITMAP；zoom=0 表示按 maxW/maxH 自适应（不放大）
RenderImageHBITMAP(path, maxW, maxH, zoom) {
    GdipStartup()
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", path, "ptr*", &pBitmap := 0)
    if !pBitmap
        return ""
    w := 0, h := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmap, "uint*", &w := 0)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmap, "uint*", &h := 0)
    if (w < 1 || h < 1) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
        return ""
    }
    if (zoom > 0) {
        scale := zoom
    } else {
        scale := Min(maxW / w, maxH / h)
        if (scale > 1)
            scale := 1
    }
    tw := Max(1, Round(w * scale))
    th := Max(1, Round(h * scale))
    thumb := 0
    DllCall("gdiplus\GdipGetImageThumbnail", "ptr", pBitmap, "uint", tw, "uint", th, "ptr*", &thumb := 0, "ptr", 0, "ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    if !thumb
        return ""
    hBmp := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", thumb, "ptr*", &hBmp := 0, "uint", 0xFFFFFFFF)
    DllCall("gdiplus\GdipDisposeImage", "ptr", thumb)
    if !hBmp
        return ""
    return {hBmp: hBmp, w: tw, h: th}
}

; ----------------------- 大图预览窗口 -----------------------------------
ShowBigPreview(path := "") {
    global history, bigGui, bigPic, bigZoom, bigNatW, bigNatH, bigPath
    global C_BG, C_IMAGEBG, C_TEXT, C_MUTED
    if (path != "") {
        bigPath := path
    } else {
        idx := SelectedIndex()
        if (idx = 0)
            return
        item := history[idx]
        bigPath := ""
        if (item.type = "image")
            bigPath := item.data
        else if (item.type = "files" && item.data.Length = 1)
            bigPath := ImagePathFromText(item.data[1])
        else if (item.type = "text")
            bigPath := ImagePathFromText(item.data)
        if (bigPath = "")
            return
    }
    if !IsObject(bigGui) {
        bigGui := Gui("+Resize", "图片预览")
        bigGui.BackColor := C_BG
        bigGui.SetFont("s9 c" C_MUTED)
        bigGui.AddText("x0 y2 w600 Center", "滚轮缩放 · Esc 关闭")
        bigGui.SetFont("s10 c" C_TEXT)
        bigPic := bigGui.AddPicture("x0 y20 w600 h400 Background" C_IMAGEBG, "")
        bigGui.OnEvent("Close", (*) => bigGui.Hide())
        bigGui.OnEvent("Size", BigResize)
    }
    GdipStartup()
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", bigPath, "ptr*", &pBitmap := 0)
    if !pBitmap
        return
    DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmap, "uint*", &bigNatW := 0)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmap, "uint*", &bigNatH := 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    if (bigNatW < 1 || bigNatH < 1)
        return
    bigZoom := 0
    w := (Round(bigNatW * 0.85) > A_ScreenWidth - 80) ? A_ScreenWidth - 80 : Round(bigNatW * 0.85)
    h := (Round(bigNatH * 0.85) > A_ScreenHeight - 120) ? A_ScreenHeight - 120 : Round(bigNatH * 0.85)
    w := Max(w, 320), h := Max(h, 240)   ; 小图也保证窗口可用大小
    bigGui.Show("w" w " h" h " Center")
    BigRender()
}

BigResize(g, minmax, w, h) {
    global bigZoom
    if (minmax = -1)
        return
    bigZoom := 0
    SetTimer(BigRender, -80)
}

BigZoomStep(f) {
    global bigZoom, lastScale
    base := (bigZoom > 0) ? bigZoom : lastScale
    bigZoom := Min(8, Max(0.05, base * f))
    BigRender()
}

BigRender() {
    global bigGui, bigPic, bigZoom, bigNatW, bigNatH, bigPath, lastScale
    if (!IsObject(bigGui) || bigNatW < 1)
        return
    rc := Buffer(16)
    DllCall("GetClientRect", "ptr", bigGui.Hwnd, "ptr", rc.Ptr)
    cw := NumGet(rc, 8, "Int") - NumGet(rc, 0, "Int")    ; right - left
    ch := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")  ; bottom - top
    if (bigZoom = 0) {
        scale := Min((cw - 16) / bigNatW, (ch - 34) / bigNatH)
        if (scale > 1)
            scale := 1
    } else {
        scale := bigZoom
    }
    if (scale <= 0 || scale > 8)
        scale := 1
    lastScale := scale
    tw := Max(1, Round(bigNatW * scale))
    th := Max(1, Round(bigNatH * scale))
    r := RenderImageHBITMAP(bigPath, tw, th, scale)
    if r {
        bigPic.Move((cw - r.w) // 2, 20 + (ch - 38 - r.h) // 2, r.w, r.h)
        bigPic.Value := "HBITMAP:*" r.hBmp   ; 控件接管位图并自动释放，脚本不可再 DeleteObject
        bigGui.Title := "图片预览 " bigNatW "x" bigNatH " — " Round(scale * 100) "%（滚轮缩放，Esc 关闭）"
    }
}

EditSelected() {
    global history
    idx := SelectedIndex()
    if (idx = 0)
        return
    item := history[idx]
    p := ""
    if (item.type = "image")
        p := item.data
    else if (item.type = "files" && item.data.Length = 1)
        p := ImagePathFromText(item.data[1])
    else if (item.type = "text")
        p := ImagePathFromText(item.data)
    if (p != "")
        Run("mspaint.exe `"" p "`"")
}

PasteSelected() {
    global lv
    row := lv.GetNext()
    if row
        PasteRow(row)
}

PasteRow(row) {
    global rowMap, history, main, lastOwnSet
    if (row = 0 || rowMap.Length < row)
        return
    item := history[rowMap[row]]
    main.Hide()
    SetClipboardFromItem(item)
    lastOwnSet := A_TickCount
    SetTimer(() => Send("^v"), -150)
}

CopySelectedOnly() {
    global history, main, lastOwnSet
    idx := SelectedIndex()
    if (idx = 0)
        return
    SetClipboardFromItem(history[idx])
    lastOwnSet := A_TickCount
    main.Hide()
}

OpenSelected() {
    global history
    idx := SelectedIndex()
    if (idx = 0)
        return
    item := history[idx]
    p := ""
    if (item.type = "image")
        p := item.data
    else if (item.type = "files")
        p := item.data[1]
    else
        p := ImagePathFromText(item.data)
    if (p != "")
        Run("explorer.exe /select,`"" p "`"")
}

TogglePinSelected() {
    global history, lv, rowMap
    idx := SelectedIndex()
    if (idx = 0)
        return
    item := history[idx]
    item.pinned := item.pinned ? 0 : 1
    if item.pinned {
        moved := history.RemoveAt(idx)
        history.InsertAt(1, moved)
    }
    SaveSoon()
    RefreshList()
}

DeleteSelected() {
    global history, lv
    idx := SelectedIndex()
    if (idx = 0)
        return
    item := history.RemoveAt(idx)
    if (item.type = "image" && FileExist(item.data))
        FileDelete(item.data)
    SaveHistory(true)
    RefreshList()
}

SelectAllRows() {
    global lv
    Loop lv.GetCount()
        lv.Modify(A_Index, "Select")
}

ClearHistory(keepPinned) {
    global history
    if (keepPinned) {
        keep := []
        for item in history {
            if item.pinned
                keep.Push(item)
            else if (item.type = "image" && FileExist(item.data))
                FileDelete(item.data)
        }
        history := keep
    } else {
        for item in history {
            if (item.type = "image" && FileExist(item.data)) {
                try FileDelete(item.data)
            }
        }
        history := []
    }
    SaveHistory(true)
    RefreshList()
}

; ---- 清空全部记录（含钉住），不可恢复 ----
ClearAllRecords() {
    r := MsgBox("确定清空全部剪贴板记录吗？`n`n这将删除所有记录（包括钉住项）及其图片文件，`n删除后不可恢复！`n`n建议先「导出记录」备份。", "清空记录 — 不可恢复", "YesNo Icon! Default2")
    if (r != "Yes")
        return
    ClearHistory(false)
    TrayTip("已清空全部记录", "octopus-clipboard", "Iconi")
}

; ---- 导出记录为自包含备份文件（图片以 base64 内嵌） ----
ExportHistory() {
    global history, DATA_DIR
    defaultName := "octopus-clipboard-backup-" A_YYYY A_MM A_DD "-" A_Hour A_Min A_Sec ".ahkcb"
    path := FileSelect("S16", DATA_DIR "\" defaultName, "导出剪贴板记录", "剪贴板备份 (*.ahkcb):*.ahkcb")
    if (path = "")
        return
    if !RegExMatch(path, "\.ahkcb$")
        path .= ".ahkcb"
    f := FileOpen(path, "w", "UTF-8")
    if !IsObject(f) {
        MsgBox "无法写入文件：`n" path, "导出失败", "Icon!"
        return
    }
    f.WriteLine("OCTOPUS-CLIPBOARD-BACKUP-v1")
    f.WriteLine(history.Length)
    for item in history {
        ; 字段：type, data(base64), pinned, time, meta(base64), imgBytes(base64 仅图片)
        dataType := ""
        imgB64 := ""
        switch item.type {
            case "text":
                dataType := B64Encode(item.data)
            case "files":
                dataType := B64Encode(Join(item.data, "`n"))
            case "image":
                dataType := B64Encode(item.data)
                if FileExist(item.data)
                    imgB64 := FileToB64(item.data)
        }
        meta := item.HasOwnProp("meta") ? item.meta : ""
        f.WriteLine(item.type "`t" dataType "`t" item.pinned "`t" item.time "`t" B64Encode(meta) "`t" imgB64)
    }
    f.Close()
    TrayTip("已导出 " history.Length " 条记录`n" path, "octopus-clipboard", "Iconi")
}

; ---- 从备份文件导入记录（合并到现有，自动去重） ----
ImportHistory() {
    global history, IMG_DIR
    path := FileSelect("1", , "选择备份文件", "剪贴板备份 (*.ahkcb):*.ahkcb")
    if (path = "")
        return
    f := FileOpen(path, "r", "UTF-8")
    if !IsObject(f) {
        MsgBox "无法读取文件：`n" path, "导入失败", "Icon!"
        return
    }
    header := Trim(f.ReadLine(), "`r`n")
    if (header != "OCTOPUS-CLIPBOARD-BACKUP-v1" && header != "AHKCLIP-BACKUP-v1") {
        f.Close()
        MsgBox "不是有效的 octopus-clipboard 备份文件。", "导入失败", "Icon!"
        return
    }
    cntLine := Trim(f.ReadLine(), "`r`n")
    total := (cntLine ~= "^\d+$") ? Integer(cntLine) : 0
    imported := 0, images := 0
    loop {
        if f.AtEOF
            break
        line := Trim(f.ReadLine(), "`r`n")
        if (line = "")
            continue
        parts := StrSplit(line, "`t", , 6)
        if (parts.Length < 4)
            continue
        typ := parts[1]
        data := B64Decode(parts[2])
        pinned := (parts[3] = "1") ? 1 : 0
        tm := parts[4]
        meta := (parts.Length >= 5) ? B64Decode(parts[5]) : ""
        imgB64 := (parts.Length >= 6) ? parts[6] : ""
        switch typ {
            case "text":
                if (data != "") {
                    history.InsertAt(1, {type: "text", data: data, pinned: pinned, time: tm, meta: meta})
                    imported++
                }
            case "files":
                arr := StrSplit(data, "`n")
                if (arr.Length > 0 && arr[1] != "") {
                    history.InsertAt(1, {type: "files", data: arr, pinned: pinned, time: tm, meta: meta})
                    imported++
                }
            case "image":
                newPath := ""
                if (imgB64 != "") {
                    ; 内嵌图片：还原到 images 目录，使用新文件名避免覆盖
                    newPath := IMG_DIR "\imp_" A_YYYY A_MM A_DD A_Hour A_Min A_Sec "_" imported ".png"
                    if B64ToFile(imgB64, newPath)
                        images++
                    else
                        newPath := ""
                }
                ; 无内嵌时回退到原路径（仅同机有效）
                imgPath := (newPath != "") ? newPath : data
                if (imgPath != "") {
                    history.InsertAt(1, {type: "image", data: imgPath, pinned: pinned, time: tm, meta: meta})
                    imported++
                }
        }
    }
    f.Close()
    SaveHistory(true)
    RefreshList()
    TrayTip("已导入 " imported " 条记录（含 " images " 张图片）", "octopus-clipboard", "Iconi")
}

SetAutostart(on) {
    lnk := A_Startup "\octopus-clipboard.lnk"
    if on {
        if !FileExist(lnk)
            FileCreateShortcut(A_ScriptFullPath, lnk, A_ScriptDir)
        A_TrayMenu.Check("开机自启")
    } else {
        if FileExist(lnk)
            FileDelete(lnk)
        A_TrayMenu.Uncheck("开机自启")
    }
}

ToggleAutostart(*) {
    SetAutostart(!FileExist(A_Startup "\octopus-clipboard.lnk"))
}

; ----------------------- 设置窗口 ---------------------------------------
setGui := 0
chkAuto := 0
edMax := 0

ShowSettings() {
    global setGui, chkAuto, edMax, MAX_ITEMS, HK_KEYS, HK_CTRL, HK_EDIT, HK_LABEL, settingsOpen
    global C_BG, C_SURFACE, C_TEXT, C_MUTED, C_ACCENT

    chkValue := FileExist(A_Startup "\octopus-clipboard.lnk") ? 1 : 0
    if !IsObject(setGui) {
        setGui := Gui("+OwnDialogs", "octopus-clipboard 设置")
        setGui.BackColor := C_BG
        setGui.SetFont("s9 c" C_TEXT, "Microsoft YaHei UI")
        setGui.SetFont("s9 c" C_ACCENT)
        setGui.AddGroupBox("x12 y10 w476 h96", "常规")
        setGui.SetFont("s9 c" C_TEXT)
        setGui.AddText("x24 y32 w215", "最大记录条数（0-999，0=不限）：")
        edMax := setGui.AddEdit("x244 y28 w70 Background" C_SURFACE, MAX_ITEMS)
        chkAuto := setGui.AddCheckBox("x24 y66 w200", "开机自启动")
        setGui.AddText("x230 y68 w240 c" C_MUTED, "设置保存在 settings.ini")

        setGui.SetFont("s9 c" C_ACCENT)
        setGui.AddGroupBox("x12 y116 w476 h424", "快捷键")
        setGui.SetFont("s9 c" C_MUTED)
        setGui.AddText("x24 y132 w450 c" C_MUTED, "左侧：快捷键控件直接按键录入　右侧：点击「选择」从列表勾选（可选 Esc 等键）")
        setGui.SetFont("s9 c" C_TEXT)

        AddHotkeyRow(setGui, "ShowHistory", "x24 y158 w110", "x140 y154 w150", "x300 y154 w120", true)
        setGui.AddText("x428 y158 w56 c" C_MUTED, "全局")

        setGui.AddText("x24 y186 w440 c" C_MUTED, "历史窗口内（仅对应窗口 / 控件生效）")
        AddHotkeyRow(setGui, "Paste",     "x24 y210 w110", "x140 y206 w150", "x300 y206 w120")
        AddHotkeyRow(setGui, "HideMain",  "x24 y238 w110", "x140 y234 w150", "x300 y234 w120")
        AddHotkeyRow(setGui, "Delete",    "x24 y266 w110", "x140 y262 w150", "x300 y262 w120")
        AddHotkeyRow(setGui, "Pin",       "x24 y294 w110", "x140 y290 w150", "x300 y290 w120")
        AddHotkeyRow(setGui, "CopyOnly",  "x24 y322 w110", "x140 y318 w150", "x300 y318 w120")
        AddHotkeyRow(setGui, "SelectAll", "x24 y350 w110", "x140 y346 w150", "x300 y346 w120")

        setGui.AddText("x24 y382 w440 c" C_MUTED, "大图预览窗口内")
        AddHotkeyRow(setGui, "HideBig", "x24 y404 w110", "x140 y400 w150", "x300 y400 w120")

        setGui.AddText("x24 y440 w450 c" C_MUTED, "点击「选择」按钮可从列表勾选常用键，含 Esc 等控件无法直接录入的键。")
        setGui.AddText("x24 y462 w450 c" C_MUTED, "勾选后即刻同步到左侧控件，保存后立即生效。")

        setGui.AddButton("x12 y552 w90 h28", "恢复默认").OnEvent("Click", ResetHotkeyDefaults)
        btnSave := setGui.AddButton("x330 y552 w80 h28 Default", "保存")
        setGui.AddButton("x418 y552 w60 h28", "取消").OnEvent("Click", (*) => HideSettings())
        btnSave.OnEvent("Click", SaveSettings)
        setGui.OnEvent("Close", (*) => HideSettings())
        ; 不绑定 Escape：Esc 是可配置的快捷键，录入时会误关窗口。
        ; 关闭请用「取消」按钮或标题栏 X。
    }
    edMax.Value := MAX_ITEMS
    chkAuto.Value := chkValue
    for id, ctrl in HK_CTRL {
        ctrl.Value := HK_KEYS[id]
        HK_EDIT[id] := HK_KEYS[id]
        UpdatePickButton(id)
    }
    settingsOpen := true
    UpdateHotkeyContext()
    setGui.Show("w488 h594")
}

HideSettings() {
    global setGui, settingsOpen
    settingsOpen := false
    setGui.Hide()
    UpdateHotkeyContext()   ; 恢复热键
}

; ----------------------- 快捷键勾选弹窗 ---------------------------------
pickerGui := 0
pickerLV := 0
pickerOut := 0          ; 组合结果（AHK 键名，只读展示）
pickerPreview := 0      ; 组合结果友好格式预览
pickerChk := Map()      ; 修饰键复选框: ^ ! + #
pickerId := ""
; 修饰键：符号 -> 显示名（组合顺序遵循 NormalizeHotkey: ^ ! # +）
PICKER_MODS := [["^", "Ctrl"], ["!", "Alt"], ["#", "Win"], ["+", "Shift"]]
; 主键（纯键，不含修饰），单选
PICKER_BASE := [
    "Esc", "Enter", "Delete", "Space", "Tab", "Backspace", "Insert", "Home", "End", "PgUp", "PgDn",
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "Up", "Down", "Left", "Right"
]

OpenHotkeyPicker(id) {
    global pickerGui, pickerLV, pickerOut, pickerPreview, pickerChk, pickerId
    global PICKER_MODS, PICKER_BASE
    global HK_LABEL, HK_EDIT
    global C_BG, C_SURFACE, C_TEXT, C_MUTED, C_ACCENT
    pickerId := id
    if !IsObject(pickerGui) {
        pickerGui := Gui("+OwnDialogs", "选择快捷键")
        pickerGui.BackColor := C_BG
        pickerGui.SetFont("s9 c" C_TEXT, "Microsoft YaHei UI")

        pickerGui.AddText("x16 y14 w470", "勾选修饰键（可多选）+ 选择主键（单选），下方自动组合成快捷键。")

        ; ---- 修饰键区 ----
        pickerGui.SetFont("s9 c" C_ACCENT)
        pickerGui.AddGroupBox("x12 y42 w476 h60", "修饰键（可多选）")
        pickerGui.SetFont("s9 c" C_TEXT)
        for m in PICKER_MODS {
            sym := m[1], name := m[2]
            idx := A_Index
            px := 28 + (idx - 1) * 118
            pickerChk[sym] := pickerGui.AddCheckBox("x" px " y64 w112", name)
            pickerChk[sym].OnEvent("Click", (*) => PickerBuild())
        }

        ; ---- 主键区 ----
        pickerGui.SetFont("s9 c" C_ACCENT)
        pickerGui.AddGroupBox("x12 y110 w300 h270", "主键（单选）")
        pickerGui.SetFont("s9 c" C_TEXT)
        pickerLV := pickerGui.AddListView("x24 y132 w276 h236 -Multi -Grid NoSortHdr Background" C_SURFACE " c" C_TEXT, ["按键"])
        for k in PICKER_BASE
            pickerLV.Add("", FormatHotkey(k))
        pickerLV.OnEvent("ItemSelect", PickerListSelect)
        pickerLV.OnEvent("DoubleClick", PickerConfirm)

        ; ---- 组合结果区 ----
        pickerGui.SetFont("s9 c" C_ACCENT)
        pickerGui.AddGroupBox("x320 y110 w168 h270", "组合结果")
        pickerGui.SetFont("s9 c" C_TEXT)
        pickerGui.AddText("x332 y134 w144", "AHK 键名：")
        pickerOut := pickerGui.AddEdit("x332 y156 w144 h26 ReadOnly Background" C_SURFACE, "")
        pickerGui.AddText("x332 y196 w144", "显示为：")
        pickerPreview := pickerGui.AddText("x332 y218 w144 h40", "")

        pickerGui.SetFont("s9 c" C_MUTED)
        pickerGui.AddText("x16 y392 w270", "提示：不选修饰键即为单独主键（如 Esc）。")
        pickerGui.AddButton("x300 y388 w90 h30", "确定").OnEvent("Click", PickerConfirm)
        pickerGui.AddButton("x398 y388 w80 h30", "取消").OnEvent("Click", (*) => pickerGui.Hide())
        pickerGui.OnEvent("Close", (*) => pickerGui.Hide())
        ; 不绑定 Escape：避免误关
    }
    ; 反解析当前快捷键 -> 修饰键勾选 + 主键选中
    PickerLoadValue(HK_EDIT[id])
    pickerGui.Title := "选择快捷键 — " HK_LABEL[id]
    pickerGui.Show("w500 h428")
}

; 把已有 AHK 键名拆成修饰键勾选与主键选中
PickerLoadValue(key) {
    global pickerLV, pickerChk, pickerOut, pickerPreview, PICKER_MODS, PICKER_BASE
    mods := "", base := key
    for sym in ["^", "!", "#", "+"] {
        if InStr(key, sym)
            mods .= sym
        base := StrReplace(base, sym, "")
    }
    for m in PICKER_MODS {
        sym := m[1]
        if pickerChk.Has(sym)
            pickerChk[sym].Value := InStr(mods, sym) ? 1 : 0
    }
    ; 选中主键（若有匹配）
    pickerLV.Opt("-Multi")
    found := 0
    for i, k in PICKER_BASE {
        if (k = base) {
            pickerLV.Modify(i, "Select Vis")
            found := 1
            break
        }
    }
    if !found
        pickerLV.Modify(0, "Select")   ; 清除选中
    pickerOut.Value := key
    pickerPreview.Value := FormatHotkey(key)
}

; 修饰键 / 主键变化 -> 重新组合
PickerBuild() {
    global pickerLV, pickerChk, pickerOut, pickerPreview, PICKER_BASE
    mods := ""
    for m in ["^", "!", "#", "+"] {
        if (pickerChk.Has(m) && pickerChk[m].Value = 1)
            mods .= m
    }
    row := pickerLV.GetNext()
    base := (row > 0 && row <= PICKER_BASE.Length) ? PICKER_BASE[row] : ""
    if (base = "") {
        pickerOut.Value := ""
        pickerPreview.Value := "（请选择主键）"
        return
    }
    key := NormalizeHotkey(mods base)
    pickerOut.Value := key
    pickerPreview.Value := FormatHotkey(key)
}

PickerListSelect(ctrl, row, selected) {
    if selected
        PickerBuild()
}

PickerConfirm(*) {
    global pickerGui, pickerOut, pickerId
    key := Trim(pickerOut.Value)
    if (key = "" || !IsValidHotkey(key)) {
        MsgBox "请先勾选修饰键并选择主键，组合出有效快捷键。", "选择快捷键", "Icon!"
        return
    }
    SetHotkeyValue(pickerId, key)
    pickerGui.Hide()
}

AddHotkeyRow(g, id, labelOpts, hotkeyOpts, btnOpts, globalRow := false) {
    global HK_LABEL, HK_CTRL, HK_EDIT, HK_BTN, HK_KEYS
    g.AddText(labelOpts, HK_LABEL[id])
    hkCtrl := g.AddHotkey(hotkeyOpts, HK_KEYS[id])
    HK_CTRL[id] := hkCtrl
    HK_EDIT[id] := HK_KEYS[id]
    btn := g.AddButton(btnOpts, "选择...")
    HK_BTN[id] := btn
    btn.OnEvent("Click", (*) => OpenHotkeyPicker(id))
    ; 左侧控件录入后，回写值并刷新右侧按钮文字
    hkCtrl.OnEvent("Change", (*) => SetHotkeyValue(id, HK_CTRL[id].Value))
}

; 统一设置某项快捷键：同步控件、值、按钮文字
SetHotkeyValue(id, key) {
    global HK_CTRL, HK_EDIT
    key := NormalizeHotkey(Trim(key))
    if (key = "" || !IsValidHotkey(key))
        return
    HK_EDIT[id] := key
    try HK_CTRL[id].Value := key
    UpdatePickButton(id)
}

UpdatePickButton(id) {
    global HK_BTN, HK_EDIT
    if !HK_BTN.Has(id)
        return
    HK_BTN[id].Text := "选择 " FormatHotkey(HK_EDIT[id])
}

ResetHotkeyDefaults(*) {
    global HOTKEY_DEFAULTS, HK_IDS
    for id in HK_IDS
        SetHotkeyValue(id, HOTKEY_DEFAULTS[id])
}

SaveSettings(*) {
    global setGui, chkAuto, edMax, MAX_ITEMS, SETTINGS_FILE, HK_KEYS, HK_EDIT, HK_IDS

    v := Trim(edMax.Value)
    if !RegExMatch(v, "^\d+$") {
        MsgBox "最大记录条数必须是 0-999 的整数。", "octopus-clipboard 设置", "Icon!"
        return
    }
    newMax := Min(999, Max(0, Integer(v)))

    newKeys := Map()
    for id in HK_IDS
        newKeys[id] := NormalizeHotkey(Trim(HK_EDIT[id]))
    if !ValidateHotkeySet(newKeys, true)
        return

    MAX_ITEMS := newMax
    IniWrite(MAX_ITEMS, SETTINGS_FILE, "General", "MaxItems")
    for id in HK_IDS {
        HK_KEYS[id] := newKeys[id]
        IniWrite(HK_KEYS[id], SETTINGS_FILE, "Hotkeys", id)
    }
    ApplyHotkeys()
    UpdateHint()
    SetAutostart(chkAuto.Value = 1)
    HideSettings()
}

; ----------------------- 快捷键辅助 -----------------------------------
NormalizeHotkey(key) {
    key := Trim(key)
    mods := ""
    if InStr(key, "^")
        mods .= "^"
    if InStr(key, "!")
        mods .= "!"
    if InStr(key, "#")
        mods .= "#"
    if InStr(key, "+")
        mods .= "+"
    base := key
    for sym in ["^", "!", "#", "+"]
        base := StrReplace(base, sym, "")
    return mods base
}

IsValidHotkey(key) {
    return (key != "" && !RegExMatch(key, "^[!^+#]+$") && !InStr(key, " "))
}

LoadHotkeySettings() {
    global HK_KEYS, HOTKEY_DEFAULTS, SETTINGS_FILE, HK_IDS
    HK_KEYS := Map()
    for id in HK_IDS {
        v := NormalizeHotkey(IniRead(SETTINGS_FILE, "Hotkeys", id, HOTKEY_DEFAULTS[id]))
        HK_KEYS[id] := IsValidHotkey(v) ? v : HOTKEY_DEFAULTS[id]
    }
    if !ValidateHotkeySet(HK_KEYS, false) {
        HK_KEYS := Map()
        for id in HK_IDS
            HK_KEYS[id] := HOTKEY_DEFAULTS[id]
    }
}

ValidateHotkeySet(keys, showMsg) {
    global HK_IDS, HK_LABEL, HK_REQUIRE_MOD, HK_CONTEXT
    for id in HK_IDS {
        k := keys[id]
        if !IsValidHotkey(k) {
            if showMsg
                MsgBox "快捷键“" HK_LABEL[id] "”为空或不完整。", "快捷键无效", "Icon!"
            return false
        }
        if (HK_REQUIRE_MOD.Has(id) && !RegExMatch(k, "[!^+#]")) {
            if showMsg
                MsgBox "快捷键“" HK_LABEL[id] "”必须包含 Ctrl / Alt / Shift / Win 中的至少一个修饰键。", "快捷键无效", "Icon!"
            return false
        }
    }
    showKey := keys["ShowHistory"]
    for id in HK_IDS {
        if (id != "ShowHistory" && keys[id] = showKey) {
            if showMsg
                MsgBox "“" HK_LABEL["ShowHistory"] "（全局）”不能与“" HK_LABEL[id] "”使用相同快捷键。", "快捷键冲突", "Icon!"
            return false
        }
    }
    seen := Map()
    for id in HK_IDS {
        sig := HK_CONTEXT[id] "`n" keys[id]
        if seen.Has(sig) {
            if showMsg
                MsgBox "同一范围内存在重复快捷键，请为“" HK_LABEL[id] "”换一个组合。", "快捷键冲突", "Icon!"
            return false
        }
        seen[sig] := true
    }
    return true
}

UpdateHotkeyContext() {
    global HK_KEYS, HK_PREV, HK_CONTEXT, HK_IDS, settingsOpen
    ; 设置窗口打开期间全部禁用，避免录入快捷键时触发动作
    if settingsOpen {
        for key, dummy in HK_PREV {
            try Hotkey key, "Off"
        }
        return
    }
    for key, dummy in HK_PREV {
        enabled := false
        for id in HK_IDS {
            if (HK_KEYS[id] != key)
                continue
            if HotkeyContextActive(HK_CONTEXT[id]) {
                enabled := true
                break
            }
        }
        try Hotkey key, enabled ? "On" : "Off"
    }
}

HotkeyContextActive(context) {
    switch context {
        case "Global": return true
        case "Main":   return MainActive()
        case "List":   return MainListActive()
        case "Big":    return BigPreviewActive()
    }
    return false
}

ApplyHotkeys() {
    global HK_KEYS, HK_PREV, HK_IDS
    for key, dummy in HK_PREV {
        try Hotkey key, "Off"
    }
    HK_PREV := Map()
    for id in HK_IDS {
        key := HK_KEYS[id]
        if (HK_PREV.Has(key))
            continue
        HK_PREV[key] := true
        try Hotkey key, HK_Dispatch, "Off"
    }
    UpdateHotkeyContext()
}

HK_Dispatch(HotkeyName) {
    global HK_KEYS, HK_IDS, HK_CONTEXT
    for id in HK_IDS {
        if (HK_KEYS[id] != HotkeyName)
            continue
        if !HotkeyContextActive(HK_CONTEXT[id])
            continue
        RunHotkeyAction(id)
        return
    }
}

RunHotkeyAction(id) {
    switch id {
        case "ShowHistory": ShowMain()
        case "Paste":       PasteSelected()
        case "HideMain":    HotkeyHideMain()
        case "Delete":      DeleteSelected()
        case "Pin":         TogglePinSelected()
        case "CopyOnly":    CopySelectedOnly()
        case "SelectAll":   SelectAllRows()
        case "HideBig":     HotkeyHideBig()
    }
}

HotkeyHideMain() {
    global main
    main.Hide()
}

HotkeyHideBig() {
    global bigGui
    if IsObject(bigGui)
        bigGui.Hide()
}

MainActive() {
    global main
    return IsObject(main) && WinActive("ahk_id " main.Hwnd)
}

MainListActive() {
    global main
    return MainActive() && ControlGetFocus("ahk_id " main.Hwnd) = "SysListView321"
}

BigPreviewActive() {
    global bigGui
    return IsObject(bigGui) && WinActive("ahk_id " bigGui.Hwnd)
}

FormatHotkey(key) {
    if (key = "")
        return "未设置"
    text := ""
    if InStr(key, "^")
        text .= "Ctrl+"
    if InStr(key, "!")
        text .= "Alt+"
    if InStr(key, "+")
        text .= "Shift+"
    if InStr(key, "#")
        text .= "Win+"
    base := key
    for sym in ["^", "!", "#", "+"]
        base := StrReplace(base, sym, "")
    return text base
}

UpdateHint() {
    global hint, HK_KEYS
    if !IsObject(hint)
        return
    paste := FormatHotkey(HK_KEYS["Paste"])
    pin   := FormatHotkey(HK_KEYS["Pin"])
    del   := FormatHotkey(HK_KEYS["Delete"])
    hide  := FormatHotkey(HK_KEYS["HideMain"])
    hint.Value := paste " 粘贴 · 双击图片看大图 · 右键菜单：仅复制/打开/编辑 · " pin " 钉住 · " del " 删除 · " hide " 隐藏"
}

; ----------------------- 剪贴板读写 -----------------------------------
SetClipboardFromItem(item) {
    switch item.type {
        case "text":  A_Clipboard := item.data
        case "image": SetClipboardImageFromPNG(item.data)
        case "files": SetClipboardFiles(item.data)
    }
}

SetClipboardImageFromPNG(path) {
    GdipStartup()
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", path, "ptr*", &pBitmap := 0)
    if !pBitmap
        return false
    hBmp := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", pBitmap, "ptr*", &hBmp := 0, "uint", 0xFF000000)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    if !hBmp
        return false
    if DllCall("OpenClipboard", "ptr", A_ScriptHwnd) {
        DllCall("EmptyClipboard")
        DllCall("SetClipboardData", "uint", 2, "ptr", hBmp)   ; CF_BITMAP
        DllCall("CloseClipboard")
    }
    return true
}

SetClipboardFiles(paths) {
    s := ""
    for p in paths
        s .= p "`0"
    s .= "`0"
    size := 20 + StrPut(s, "UTF-16") * 2
    buf := Buffer(size, 0)
    NumPut("UInt", 20, buf, 0)    ; DROPFILES.pFiles
    NumPut("UInt", 1, buf, 16)    ; fWide = TRUE
    StrPut(s, buf.Ptr + 20, "UTF-16")
    if !DllCall("OpenClipboard", "ptr", A_ScriptHwnd)
        return false
    DllCall("EmptyClipboard")
    h := DllCall("GlobalAlloc", "uint", 2, "uptr", size, "ptr")   ; GMEM_MOVEABLE
    p := DllCall("GlobalLock", "ptr", h, "ptr")
    DllCall("RtlMoveMemory", "ptr", p, "ptr", buf.Ptr, "uptr", size)
    DllCall("GlobalUnlock", "ptr", h)
    DllCall("SetClipboardData", "uint", 15, "ptr", h)             ; CF_HDROP
    DllCall("CloseClipboard")
    return true
}

GetClipboardFiles() {
    if !DllCall("IsClipboardFormatAvailable", "uint", 15)
        return []
    if !DllCall("OpenClipboard", "ptr", A_ScriptHwnd)
        return []
    hDrop := DllCall("GetClipboardData", "uint", 15, "ptr")
    count := DllCall("shell32\DragQueryFileW", "ptr", hDrop, "uint", 0xFFFFFFFF, "ptr", 0, "uint", 0)
    paths := []
    Loop count {
        len := DllCall("shell32\DragQueryFileW", "ptr", hDrop, "uint", A_Index - 1, "ptr", 0, "uint", 0) + 1
        buf := Buffer(len * 2)
        DllCall("shell32\DragQueryFileW", "ptr", hDrop, "uint", A_Index - 1, "ptr", buf.Ptr, "uint", len)
        paths.Push(StrGet(buf, "UTF-16"))
    }
    DllCall("CloseClipboard")
    return paths
}

SaveClipboardImage() {
    GdipStartup()
    pBitmap := 0
    if !DllCall("OpenClipboard", "ptr", A_ScriptHwnd)
        return ""
    hBmp := DllCall("GetClipboardData", "uint", 2, "ptr")   ; CF_BITMAP
    if !hBmp {
        DllCall("CloseClipboard")
        return ""
    }
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hBmp, "ptr", 0, "ptr*", &pBitmap := 0)
    DllCall("CloseClipboard")
    if !pBitmap
        return ""
    path := IMG_DIR "\" FormatTime(A_Now, "yyyyMMdd_HHmmss") "_" A_TickCount ".png"
    clsid := ClsidFromString("{557CF406-1A04-11D3-9A73-0000F81EF32E}")   ; PNG encoder
    ok := DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBitmap, "wstr", path, "ptr", clsid.Ptr, "ptr", 0)
    w := 0, h := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmap, "uint*", &w := 0)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmap, "uint*", &h := 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
    if !ok
        return ""
    return {path: path, meta: w "|" h}
}

GdipStartup() {
    global GdipToken
    if GdipToken
        return
    si := Buffer(32, 0)   ; GdiplusStartupInput：x64 下含指针对齐需 32 字节，16 字节会越界读导致初始化随机失败
    NumPut("UInt", 1, si)   ; GdiplusVersion = 1
    DllCall("gdiplus\GdiplusStartup", "ptr*", &GdipToken := 0, "ptr", si.Ptr, "ptr", 0)
}

ClsidFromString(s) {
    buf := Buffer(16)
    DllCall("ole32\CLSIDFromString", "wstr", s, "ptr", buf.Ptr)
    return buf
}

; ----------------------- 持久化 ----------------------------------------
SaveSoon() {
    SetTimer(SaveHistory, -1500)
}

SaveHistory(force := "") {
    global history, DATA_FILE
    ; 防误覆盖：退出等场景下历史意外为空时，不清空已有存档（清空操作走 force=true）
    if (force = "" && history.Length = 0 && FileExist(DATA_FILE) && FileGetSize(DATA_FILE) > 4)
        return
    f := FileOpen(DATA_FILE, "w", "UTF-8")
    for item in history {
        data := ""
        switch item.type {
            case "text":  data := item.data
            case "image": data := item.data
            case "files": data := Join(item.data, "`n")
        }
        meta := (item.HasOwnProp("meta") ? item.meta : "")
        line := item.type "`t" B64Encode(data) "`t" item.pinned "`t" item.time "`t" meta
        f.WriteLine(line)
    }
    f.Close()
}

LoadHistory() {
    global history, DATA_FILE
    if !FileExist(DATA_FILE)
        return
    f := FileOpen(DATA_FILE, "r", "UTF-8")
    while !f.AtEOF {
        line := Trim(f.ReadLine(), "`r`n")
        if (line = "")
            continue
        parts := StrSplit(line, "`t", , 5)
        if (parts.Length < 4)
            continue
        data := B64Decode(parts[2])
        pinned := (parts[3] = "1") ? 1 : 0
        meta := (parts.Length >= 5) ? parts[5] : ""
        switch parts[1] {
            case "text":
                if (data != "")
                    history.Push({type: "text", data: data, pinned: pinned, time: parts[4], meta: meta})
            case "image":
                if FileExist(data)
                    history.Push({type: "image", data: data, pinned: pinned, time: parts[4], meta: meta})
            case "files":
                arr := StrSplit(data, "`n")
                if (arr.Length > 0 && arr[1] != "")
                    history.Push({type: "files", data: arr, pinned: pinned, time: parts[4], meta: meta})
        }
    }
    f.Close()
}

; ----------------------- 工具函数 ---------------------------------------
Join(arr, sep) {
    s := ""
    for v in arr
        s .= (A_Index > 1 ? sep : "") v
    return s
}

B64Encode(s) {
    size := StrPut(s, "UTF-8") - 1
    if (size <= 0)
        return ""
    buf := Buffer(size)
    StrPut(s, buf, "UTF-8")
    cch := size * 4 + 64
    out := Buffer(cch * 2 + 8, 0)   ; base64 每3字节→4字符，另含换行开销
    ret := DllCall("crypt32\CryptBinaryToStringW", "ptr", buf.Ptr, "uint", size, "uint", 1, "ptr", out.Ptr, "uint*", &cch := cch, "int")
    if (!ret)
        return ""
    return StrReplace(StrGet(out, "UTF-16"), "`r`n")
}

B64Decode(s) {
    s := StrReplace(StrReplace(s, "`r"), "`n")
    if (s = "")
        return ""
    dsz := StrLen(s) * 4 + 4
    buf := Buffer(dsz + 8, 0)
    ret := DllCall("crypt32\CryptStringToBinaryW", "wstr", s, "uint", 0, "uint", 1, "ptr", buf.Ptr, "uint*", &dsz := dsz, "ptr", 0, "ptr", 0, "int")
    if (!ret)
        return ""
    return StrGet(buf, dsz, "UTF-8")
}

; 二进制文件 <-> base64（图片内嵌用，不经 UTF-8 转换）
FileToB64(path) {
    f := FileOpen(path, "r")
    if !IsObject(f)
        return ""
    size := f.Length
    buf := Buffer(size)
    f.RawRead(buf, size)
    f.Close()
    if (size <= 0)
        return ""
    cch := 0
    DllCall("crypt32\CryptBinaryToStringW", "ptr", buf.Ptr, "uint", size, "uint", 1, "ptr", 0, "uint*", &cch)
    if (cch <= 0)
        return ""
    out := Buffer(cch * 2 + 8, 0)
    if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf.Ptr, "uint", size, "uint", 1, "ptr", out.Ptr, "uint*", &cch)
        return ""
    return StrGet(out, "UTF-16")
}

B64ToFile(b64, path) {
    b64 := StrReplace(StrReplace(b64, "`r"), "`n")
    if (b64 = "")
        return false
    size := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "wstr", b64, "uint", 0, "uint", 1, "ptr", 0, "uint*", &size, "ptr", 0, "ptr", 0)
        return false
    buf := Buffer(size)
    if !DllCall("crypt32\CryptStringToBinaryW", "wstr", b64, "uint", 0, "uint", 1, "ptr", buf.Ptr, "uint*", &size, "ptr", 0, "ptr", 0)
        return false
    f := FileOpen(path, "w")
    if !IsObject(f)
        return false
    f.RawWrite(buf, size)
    f.Close()
    return true
}
