<!-- Historical release note: this file documents the v4.4.1 release only. See README.md for the project overview. -->

# AutoPurge Pro v4.4.1

- 版本号：`4.4.1`
- versionCode：`441`
- 正式发布： [GitHub Release v4.4.1](https://github.com/yunyu614/AutoPurge-Pro/releases/tag/v4.4.1)
- 安装包：`AutoPurge_Pro_v4.4.1.zip`

## 重要修复：安装向导音量键识别

- 修复一次物理按压音量键导致安装向导前两个问题被同时作答的问题。
- 新逻辑等待完整按压周期（按下至松开）后才返回一次选择，并正确处理长按重复事件及另一枚音量键事件。
- 当环境不支持 `getevent` 或连续读取失败 10 次时，不再无限等待，提示后采用模板默认配置。
- 重写向导文案，逐题说明功能作用与默认状态；问题顺序调整为文件整理 → APK 清理 → 模块残留，与 WebUI 开关保持一致。
- 增加解压结果校验；模块核心文件缺失时中止安装并提示重新下载。

## 引擎、界面与性能优化

- `autopurge_ctl.sh` 重构：公共函数去重、修复后台清理任务状态码问题。
- 新增清理目录锁（`.cleanup.lock`），避免定时任务与手动清理并发造成统计竞争；陈旧锁 40 分钟自动回收。
- 配置文件缺失时自动重建默认值；统计 JSON 损坏时保留清理前数值，避免统计回退。
- 统一 JSON 输出转义；守护进程检测使用完整模块路径；新增 `version` 命令。
- CSS 历史叠加层合并为单一来源，移除卡片高成本模糊效果。
- 前端清理死代码，拆分主题与语言更新流程，补齐开关中文提示、重置统计入口和动态版本显示。
- 首页快捷清理入口、页面合并及缺失元素修复随 v4.4.1 包含。

## 兼容性

以下文件保持不变：`Main.sh`、`service.sh`、`action.sh`、`uninstall.sh`、`bin/` 下五个二进制文件，以及 `Configuration_File/` 全部配置模板。

因此本次升级按原设计支持覆盖升级，旧配置和统计数据保留。升级前仍建议备份重要配置。

## 安装

1. 下载本 Release 附件中的 `AutoPurge_Pro_v4.4.1.zip`。
2. 在 KernelSU 或兼容的 Root 模块管理器中选择本地安装。
3. 按安装向导逐项选择，完成后按管理器提示重载模块或重启设备。

> 不同设备、Root 管理器与 WebView 环境仍需实机验证；本说明不代表未经测试的绝对兼容性承诺。
