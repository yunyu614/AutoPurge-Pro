# AutoPurge Pro v4.4.2

- 版本号：`4.4.2`
- versionCode：`442`
- 正式发布： [GitHub Release v4.4.2](https://github.com/yunyu614/AutoPurge-Pro/releases/tag/v4.4.2)
- 安装包：`AutoPurge_Pro_v4.4.2.zip`
- 源码目录：[`source/`](https://github.com/yunyu614/AutoPurge-Pro/tree/main/source)

## 重点修复：WebUI 误报“Root 桥接不可用”

- 根因：首页渲染函数末尾调用了不存在的 `applyTheme()`（实际函数名为 `applyThemeOnly()`）。
  异常被包在“解析状态 JSON”的 `try` 中，于是被误报成
  “模块状态读取失败，请确认 Root WebUI 桥接可用”。
- 修复渲染调用，并把状态读取、JSON 解析与界面渲染分开处理。
- 新增启动探测与页面顶部横幅，区分：无桥接（预览模式）、MMRL 未授权 Shell、
  Root 权限不可用、模块文件缺失、命令超时/执行失败。
- 兼容 KernelSU / KernelSU Next / APatch / MMRL / WebUI X，兼容异步回调与同步 `exec`。
- 所有 Root 命令统一注入 `PATH`，避免执行环境缺少 PATH 时 `sh: not found`。
- 通过 `ksu.moduleInfo()` 自动纠正模块目录；控制脚本缺失时提示重新安装。
- 新增「重试」「复制诊断」。

## 新增：自定义清理间隔

- 设置中心 → 定时与服务 → 按间隔。
- 支持每 N 分钟（10–1440）/ 小时（1–720）/ 天（1–30）。
- 提供 30 分钟、1/6/12 小时、2/7 天快捷预设。
- 独立守护进程保持等间隔；下次执行时间持久化，重启后继续原计划。
- 每天固定时间模式保留 crond；旧配置自动迁移，不覆盖已有时间与规则。

## 底层优化

- `status` 改为一次扫描进程，减少 `pgrep` 全表扫描。
- 状态 JSON 增加定时模式、间隔、下次执行时间与调度器状态。
- 状态读取超时 12s → 20s，JSON 解析容错。
- 间隔守护 PID 校验基于 `/proc/<pid>/cmdline`；停止时不会打断正在执行的清理。

## 兼容性

- 模块 ID、配置目录、清理规则与统计文件保持不变，支持覆盖升级。
- 旧版 `定时设置.conf` 会自动补齐间隔字段，原有每天时间保留。
- `source/bin/` 内的五个二进制为预编译文件，仓库暂未包含其 C++ 源码。

## 安装

1. 下载本 Release 附件中的 `AutoPurge_Pro_v4.4.2.zip`。
2. 在 KernelSU / APatch / MMRL 等模块管理器中选择本地安装。
3. 覆盖安装后按提示重载模块或重启设备；配置、规则和统计会保留。

> 不同设备、Root 管理器与 WebView 环境仍需实机验证。
