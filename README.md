# cue

macOS 剪贴板历史管理器，参考 [snip](https://github.com/clanzhang/snip) 实现的精简版。

复制的内容自动入库，支持增删改查、置顶、搜索、过滤、导入导出、统计、后台常驻与开机自启。

## 特性

- **自动记录**：前台 / 后台监控剪贴板，复制即入库
- **全功能管理**：增删改查、置顶、搜索（预览 + 全文）、按来源 / 类型过滤
- **多类型**：文本存全文；图片可选落盘（≤25MB）；文件仅记元数据
- **导入导出**：JSON 备份与恢复（`export` / `import`）
- **统计**：类型分布、来源 Top、近 7 / 30 天新增
- **规则**：忽略指定来源、敏感词过滤，避免误录
- **后台常驻**：`--daemon` 守护进程 + LaunchAgent 开机自启（KeepAlive 自动拉起）
- **交互式 TUI**：全屏面板，键盘操作，零第三方依赖
- **一键粘贴**：复制并模拟 Cmd+V
- **隐私安全**：纯本地存储，绝不联网、绝不上传任何数据

## 环境要求

- macOS 13+
- Swift 5.9+

> 无需任何授权即可使用 `list / show / add / edit / pin / delete / clear / export / import / stats / record`。
> 仅 `cue paste` 模拟 Cmd+V 粘贴需要「辅助功能」权限（系统设置 > 隐私与安全性 > 辅助功能）。

## 安装

```bash
# 从源码编译
swift build -c release
cp .build/release/cue /usr/local/bin/
```

## 快速开始

```bash
# 后台常驻，之后复制的内容都会自动入库
cue record --daemon

# 可选：开机自启
cue autostart on

# 查看最近 20 条
cue

# 搜索
cue list --search python
```

## 命令参考

> `cue <子命令>` 与 `cue clip <子命令>` 等价，两种写法均可。

### 查看

```bash
cue                            # 显示最近 20 条
cue list                       # 列出全部
cue list --search 关键词        # 搜索（预览 + 全文）
cue list --limit N             # 限制条数
cue list --app Safari          # 按来源 App / 包名过滤
cue list --type text           # 按类型过滤（text / image / file）
cue list --pinned              # 只看置顶
cue list --json                # JSON Lines 输出

cue show <id>                  # 查看完整内容并复制到剪贴板
cue show <id> --no-copy        # 只看不复制
cue show <id> --json           # JSON 输出
cue show <imgId>               # 图片条目可拷回剪贴板
```

### 管理

```bash
cue add "文本"                 # 写入剪贴板并入库
cue edit <id> "新文本"         # 修改内容，同步写入剪贴板
cue pin <id>                  # 置顶
cue unpin <id>                # 取消置顶
cue delete <id>               # 删除一条
cue clear                     # 清空全部（默认需确认）
cue clear --yes               # 跳过确认（也可用 -y）
cue paste <id>                # 复制内容并模拟 Cmd+V 粘贴
```

### 备份

```bash
cue export [<path>]           # 导出全部（含全文）为 JSON，默认存桌面
cue import <file>             # 导入 JSON（同 id 自动跳过）
cue import <file> --replace   # 导入并覆盖同 id 条目
```

### 统计与清理

```bash
cue stats                     # 类型分布 / 来源 Top / 近 7·30 天
cue stats --json              # JSON 输出
cue prune --ttl 30            # 清理 30 天前的旧记录（置顶豁免）
```

### 规则

```bash
cue ignore                   # 查看忽略来源列表
cue ignore <App>             # 该来源（App 名 / 包名）不入库
cue ignore --clear           # 清空忽略来源列表

cue sensitive                # 查看敏感词列表
cue sensitive <词>           # 含此词的文本不入库
cue sensitive --clear        # 清空敏感词列表
```

### 后台记录

```bash
cue record                   # 前台监控：复制自动入库（Ctrl+C 停止）
cue record --json            # 每条记录以 JSON 输出
cue record --interval 0.5    # 轮询间隔（秒，默认 0.3）
cue record --max 1000        # 历史上限（默认 500）
cue record --ttl 30          # 自动清理 30 天前的记录

cue record --daemon          # 后台常驻记录
cue stop                     # 停止后台记录
cue status                   # 查看后台记录状态
cue autostart on             # 开机自启（LaunchAgent + KeepAlive）
cue autostart off            # 关闭开机自启
```

### 其他

```bash
cue ui                       # 交互式 TUI
cue help                     # 帮助
cue --version                # 版本号
```

## 数据存储

所有数据仅保存在本地：

| 路径 | 说明 |
| --- | --- |
| `~/Library/Application Support/cue/history/index.json` | 条目索引（元数据） |
| `~/Library/Application Support/cue/history/<id>.txt` | 文本内容 |
| `~/Library/Application Support/cue/history/<id>.img` | 图片数据（≤25MB） |
| `~/Library/Application Support/cue/history/ignore.txt` | 忽略来源列表 |
| `~/Library/Application Support/cue/history/sensitive.txt` | 敏感词列表 |
| `~/Library/Application Support/cue/clipd.pid` | 后台进程 PID |
| `~/Library/Logs/cue/clipd.log` | 后台记录日志 |
| `~/Library/LaunchAgents/com.cue.clipd.plist` | 开机自启配置 |

清空数据：`cue clear`，或直接删除 `~/Library/Application Support/cue/history/` 目录。

## 交互式 TUI（cue ui）

全屏剪贴板面板，raw mode + ANSI 自绘，零第三方依赖：

| 按键 | 功能 |
| --- | --- |
| `↑` / `↓`（或 `j` / `k`） | 选择 |
| `PgUp` / `PgDn` / `Home` / `End` | 翻页 |
| 直接输入文字 | 即时搜索 |
| `Backspace` | 删除搜索字符 |
| `Esc` | 清空搜索 |
| `回车`（或 `y`） | 复制到剪贴板 |
| `v` | 复制并 Cmd+V 粘贴 |
| `p` | 置顶 / 取消置顶 |
| `d` | 删除 |
| `u` | 撤销删除 |
| `q` | 退出 |

## 说明

- 历史默认保留最近 **500 条**（`record --max` 可调），置顶条目不受裁剪影响
- 相邻相同内容自动去重，仅更新时间
- 排序规则：置顶优先，其次按更新时间倒序

## 开发

```bash
swift build            # 调试构建
swift run cue list     # 直接运行

# 测试（二选一）
swift test             # 需要完整 Xcode（XCTest）
./Scripts/test.sh      # 无 Xcode 的轻量自测（Command Line Tools 即可）
```

## 许可证

[MIT](https://github.com/kael-wq/cue/blob/main/LICENSE)
