# AutoPurge Pro 开发变更记录

## 安全加固开发分支（基于 v4.4.2）

- 安装向导中的 APK 清理说明同步调整为仅处理配置下载目录，避免继续暗示会清理其他应用缓存。- 新增非破坏性清理预览：列出已启用的 Shell 管理型 APK 与本模块备份候选项，显示数量/逻辑大小；明确排除闭源二进制内部目标，不会在预览时删除文件。
- Clear.log 与 History_Files.log 超过 1 MiB 时轮转保留一个备份文件。
- 统计重置改为临时文件 + 原子替换，避免中断时写出半截 JSON。
- APK 清理和文件整理目标路径限制在配置的共享存储根目录内，并拒绝 /data、/system、/vendor、/proc、/sys、/dev 等系统根路径。
- 模块残留清理范围限制为当前模块目录，不再扫描其他模块目录或更新暂存目录。
- 清理锁不再按固定 40 分钟强制回收；增加 PID/命令行身份校验与保守的陈旧锁回收。
- 定时配置读取统一取最后一次键值定义，处理重复键时控制端与守护进程保持一致。
- APK 清理改为只处理 FilePaths.conf 配置的下载目录，不再进入其他应用私有缓存或 files/Download。
- 移除按删除文件数量估算释放空间的逻辑；统计改为记录 /data 可用空间正向变化，并明确标识为文件系统空间变化，不宣称是模块独占释放量。
- 新 UI 使用 observed_space_increase_kb 独立累计，从升级后重新统计；保留旧 total_freed_kb 字段供旧版界面兼容，避免把历史估算混入新指标。
- Counter 与 Stats.json 写入改为临时文件后原子替换。
- WebUI 全局开关、功能开关与日志阈值通过白名单 set_config 命令写入；配置重复键归一化并以临时文件原子替换。
- 定时 JSON 字段在输出前做白名单校验。
- 文件整理任务记录实际移动/失败数量，并按真实执行结果返回状态。
- 扫描和整理临时文件使用独立 PID 文件名，降低并发覆盖风险。
- 清理与文件任务后台 worker 使用独立锁目录、PID 身份检查和内部 worker 命令，减少启动竞态及重复任务。
- 间隔调度守护进程增加实例锁，防止并发启动；PID 文件清理检查实例归属。
- WebUI 统计标签调整为“累计可用空间增加”，避免把文件系统变化误称为本模块独占释放量。

### 验证边界

本开发分支尚需通过 Android 系统 Shell / BusyBox 实机语法与行为测试。闭源二进制对 Counter 的写入方式尚未确认，因此不能宣称二进制与 Shell 之间的计数竞争已彻底解决。

---

# AutoPurge Pro v4.4.2

## Root 桥接修复（重点）
- WebUI 打开时先做一次桥接探测，新增页面顶部状态横幅，把问题分开提示：
  未检测到桥接（预览模式）、MMRL 未授权 Shell、Root 权限不可用、
  模块文件缺失、命令超时/执行失败。
- 兼容 KernelSU / KernelSU Next / APatch / MMRL / WebUI X 的 `ksu` 接口；
  同时兼容异步回调和同步 `exec` 两种实现。
- 所有 Root 命令统一注入 `PATH=/system/bin:...`，避免部分管理器执行环境
  缺少 PATH 时 `sh: not found` 被误报成“模块读取失败”。
- 通过 `ksu.moduleInfo()` 自动纠正模块目录；控制脚本缺失时直接提示重新安装，
  不再只弹一句“请确认 Root 桥接可用”。
- 新增「重试」「复制诊断」按钮，诊断内容包含桥接类型、errno、stdout/stderr。
- 首页状态读取失败时同样写入顶部横幅，并只提示一次，不再反复弹 Toast。

## 新增：自定义清理间隔
- 定时方式新增「按间隔」：每 N 分钟（10-1440）/ 小时（1-720）/ 天（1-30）。
- 间隔模式使用独立守护进程 `bin/interval_daemon.sh`，按“上次计划时间 + 间隔”
  排期，避免 crond 的 `*/N` 在跨小时、跨天时产生 5/5/5/5/4 这类不等等间隔。
- 下次执行时间持久化在 `自定义定时设置/interval.state`，重启后继续原计划；
  修改间隔会从当前时间重新计时。
- 设置页提供 30 分钟 / 1 小时 / 6 小时 / 12 小时 / 2 天 / 7 天快捷预设，
  并显示约每天执行次数。
- 「每天固定时间」模式保留原 crond 实现，旧配置自动迁移（补 Set_Mode 等字段），
  升级不会覆盖已有时间与规则。

## 底层优化
- `autopurge_ctl.sh status` 改为一次扫描完成三个守护进程检测，减少多次
  `pgrep` 全表扫描；状态 JSON 增加 `schedule.mode / interval / next_run_epoch`。
- 状态读取超时 12s → 20s，并对控制脚本输出使用宽松 JSON 解析，
  容忍日志噪声或前置输出。
- 配置缺失时自动补齐定时字段；新增基于命令行校验的间隔守护 PID 检查，
  停止时只结束 sleep 子进程，不会打断正在执行的清理任务。

---

# AutoPurge Pro v4.4.1

## 安装向导修复（音量键）
- 修复安装向导一次按压音量键导致前两个问题被同时作答的问题。
  旧实现 `getevent -c 1` 每次只读一条事件；一次物理按压实际产生
  DOWN/SYN/UP/SYN 多条事件，同一次按压的残留事件会被下一个问题立即消费。
- 新逻辑等待一次完整按压（按下 → 消费到松开事件）才返回一次选择，
  按住期间的 REPEAT/另一枚音量键事件也被正确处理。
- 环境兜底：当前环境不支持 getevent 或连续读取失败 10 次时，
  不再无限等待，提示后采用模板默认配置。
- 向导文案更新：逐题说明功能作用与默认状态；问题顺序调整为
  文件整理 → APK 清理 → 模块残留，与 WebUI 开关一一对应。
- 解压结果校验：模块核心文件缺失时中止安装并提示重新下载。

## 其他
- apply_services 调用定时脚本时显式传入 AUTOPURGE_MODDIR，自定义配置目录下不再依赖默认路径推导。

---

# AutoPurge Pro v4.4.0

## 界面合并与排列优化
- 清理与整理合并为单页单卡：自动开关区、手动执行区、文件整理区三段一卡，滚动更连贯。
- 规则中心与文件路径管理合并为一张「规则与路径」卡，规则编辑默认折叠，路径保存按钮常驻底部。
- 设置中心将「定时清理计划」与「服务配置」合并为「定时与服务」卡；功能说明默认折叠。
- 首页增加「立即清理」快捷按钮，守护状态胶囊简化命名。
- 功能开关增加一行说明文字，明确每个开关的实际作用范围。

## 功能补全
- 设置中心新增「重置统计」入口（对应后台 reset_stats 命令）。
- 「关于模块」版本号改为运行时从 module.prop 读取，不再出现前后端版本号不一致。
- 开关提示语从变量名（如 mt_cleaning）改为中文名称。
- 修复设置页日志大小显示元素缺失、file_organize 开关引用错误等前端引用 bug。

## 底层与性能优化
- autopurge_ctl.sh 全量重构：公共工具函数去重（约 630 行 → 单一来源），修复后台清理任务状态码（local 作用域 bug）。
- 清理任务新增目录锁（.cleanup.lock），cron 与手动清理并发时不再产生统计竞争；陈旧锁 40 分钟自动回收。
- 配置.conf 缺失时自动重建默认值；Counter/Stats.json 损坏时保留清理前数值，避免统计回退。
- JSON 输出统一转义；守护进程检测使用完整模块路径，避免误匹配。
- style.css 由 1187 行 8 层历史叠加合并为单一来源（约 690 行），移除卡片 backdrop-filter 高成本模糊，暗色/配色变量集中声明。
- app.js 拆分主题同步与语言遍历：状态刷新不再每次全量遍历 DOM 文本节点；清理轮询间隔 1.8s → 2s。
- 新增 version 命令输出模块版本 JSON。

## 兼容性说明
- 所有后台命令与 JSON 结构向后兼容，WebUI 数据结构不变。
- 配置文件（配置.conf / 定时设置.conf / FilePaths.conf / 名单）升级时全部保留。

---

# AutoPurge Pro v4.3.0

## UI 升级与稳定性保护
- 采用高级轻科技视觉：蓝紫主题、分层卡片、统一按钮与状态组件。
- 优化首页数据卡片、存储进度、守护状态和清理操作区域的视觉层级。
- 优化规则、路径、设置区域的边框、间距与展开状态；路径仍默认折叠。
- 视觉升级仅使用 CSS，不引入动画框架、图表库或额外运行时依赖。
- 保留 v4.2.2 后台扫描/归档任务、任务状态轮询与重复点击保护。
- 保留 Root 命令串行队列和首页状态请求合并，避免因 UI 升级引入并发桥接压力。
- 支持减少动态效果偏好；避免高成本模糊和滤镜效果。

## 版本信息
- Module version: 4.3.0
- versionCode: 430

## 验证说明
- 需通过 JavaScript、Shell 语法检查及 ZIP 完整性检查。
- 不宣称未经真实设备验证的绝对不卡顿；KernelSU/APatch/Magisk WebView 仍需实机测试。

---

# AutoPurge Pro v4.2.2

## 性能与响应优化
- 文件扫描与文件归档改为后台任务执行，WebUI 仅轮询轻量状态，避免长时间 find/mv 占用 Root 桥接。
- 增加文件任务状态、结果与错误日志文件，异常退出时可定位原因。
- 文件扫描和归档按钮增加执行态与重复点击保护。
- Dashboard 状态刷新增加 single-flight 合并，避免页面切换时重复发起状态请求。
- 保留清理任务后台执行模式，减少前台等待。

## 版本信息
- Module version: 4.2.2
- versionCode: 422

## 注意
本版针对可见的长耗时任务和重复请求做了代码级优化；不同 Root 管理器/WebView 的桥接行为仍需在设备上实测。

---

## Previous release: v4.2.1

### UI refinement
- Collapsed blacklist, whitelist and MT rule editors by default.
- Collapsed storage root, scan source and category archive path panels by default.
- Path values are hidden until the corresponding panel is expanded, reducing visual height.
- Refined rules and settings page spacing and card hierarchy.
- Kept the v4.2.0 cleanup and file-organization master-switch layout.

### Version metadata
- Module version: 4.2.1
- Module versionCode: 421
- Updated the in-module header and About page version labels to v4.2.1.

### Validation
- Package metadata and in-module version labels synchronized.
- JavaScript syntax and shell syntax checked during packaging.
- Android Root device rendering and runtime behavior still require device-side verification.
