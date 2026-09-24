# cue

macOS 剪贴板历史管理器，参考 [snip](https://github.com/clanzhang/snip) 实现的精简版。

支持复制内容自动入库、增删改查、置顶、搜索、过滤、导入导出、后台监控等。

## 隐私说明

- 剪贴板文本内容仅保存在本地 `~/Library/Application Support/cue/history/`
- 图片/文件只记录元数据，图片可选落盘（≤25MB）
- 绝不联网、绝不上传任何数据
- `cue clear` 一键清空，或删除上述 `history/` 目录

## 安装

```bash
# 从源码编译
swift build -c release
cp .build/release/cue /usr/local/bin/
```

> 无需任何授权权限即可使用 `list / show / add / edit / pin / delete / clear / export / import / stats / record`。
> 仅 `cue paste` 模拟 Cmd+V 粘贴需要「辅助功能」权限（系统设置 > 隐私与安全性 > 辅助功能）。

## 命令列表

```bash
cue                         # 显示最近 20 条
cue list                    # 列出全部
cue list --search 关键词     # 搜索（预览 + 全文）
cue list --limit N          # 限制条数
cue list --app Safari       # 按来源 App/包名过滤
cue list --type text        # 按类型过滤（text / image / file）
cue list --pinned           # 只看置顶
cue list --json             # JSON Lines 输出

cue show <id>               # 查看完整内容并复制到剪贴板（--no-copy 只看不复制）
cue show <imgId>            # 图片条目可拷回剪贴板
cue add "文本"               # 写入剪贴板并入库
cue edit <id> "新文本"       # 修改内容，同步写入剪贴板
cue pin <id>                # 置顶
cue unpin <id>              # 取消置顶
cue delete <id>             # 删除一条
cue clear                   # 清空全部（默认需确认，--yes/-y 跳过）
cue export [<path>]         # 导出全部（含全文）为 JSON，默认存桌面
cue import <file>           # 导入 JSON（同 id 自动跳过；--replace 覆盖）
cue paste <id>              # 复制内容并模拟 Cmd+V 粘贴（需辅助功能权限）
cue stats                   # 统计：类型/来源 Top/近 7/30 天
cue prune --ttl 30          # 清理 30 天前的旧记录（置顶豁免）

cue ignore <App>            # 该来源不入库（--clear 清空，无参查看）
cue sensitive <词>           # 含此词的文本不入库（--clear 清空，无参查看）

cue record                  # 监控模式：复制自动入库（--interval/--max/--ttl/--json）
cue record --daemon         # 后台常驻记录（日志: ~/Library/Logs/cue/clipd.log）
cue stop                    # 停止后台记录
cue status                  # 查看后台记录状态
cue autostart on/off        # 开机自启（LaunchAgent）
cue ui                      # 交互式 TUI（↑↓选择/输入即搜索/回车复制/v粘贴/p置顶/d删除/u撤销）
```

可直接把 `cue` 命令简写为 `cue <子命令>`，也可以写完整 `cue clip <子命令>`。

## 使用示例

```bash
# 开始后台记录（Ctrl+C 停止）
cue record

# 查看最近记录
cue

# 搜索含 "python" 的记录
cue list --search python

# 复制第 3 条并自动粘贴
cue paste <id>

# 导出备份
cue export ~/Desktop/backup.json
```

## 说明

- 历史默认保留最近 **500 条**（`record --max` 可调），置顶条目不受裁剪影响
- 相邻相同内容自动去重，只更新时间
- 数据位置：`~/Library/Application Support/cue/history/`（每条一个 `.txt` + `index.json`）

## 交互式 TUI（cue ui）

全屏剪贴板面板，零第三方依赖（raw mode + ANSI 自绘）：

- `↑`/`↓`（或 `j`/`k`）选择，`PgUp`/`PgDn`/`Home`/`End` 翻页
- 直接输入文字即时搜索，Backspace 删除，Esc 清空搜索
- `回车`（或 `y`）复制到剪贴板，`v` 复制并 Cmd+V 粘贴
- `p` 置顶/取消置顶，`d` 删除，`u` 撤销删除，`q` 退出

## 后台常驻（daemon）

```bash
cue record --daemon   # 后台启动，随时复制自动入库
cue status            # 查看状态（PID/条数/最近记录/自启）
cue stop              # 停止
cue autostart on      # 开机自启（LaunchAgent + KeepAlive）
cue autostart off     # 关闭自启
```

- 日志：`~/Library/Logs/cue/clipd.log`
- PID 文件：`~/Library/Application Support/cue/clipd.pid`
- LaunchAgent plist：`~/Library/LaunchAgents/com.cue.clipd.plist`

## 开发

```bash
swift build          # 调试构建
swift run cue list  # 直接运行

# 测试（二选一）
swift test           # 需要完整 Xcode（XCTest）
./Scripts/test.sh    # 无 Xcode 的轻量自测（Command Line Tools 即可）
```
