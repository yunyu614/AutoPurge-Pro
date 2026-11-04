# AutoPurge Pro

<p align="center">
  <strong>让 Android 清理管理变得更简单。</strong>
  <br/>
  面向 Root 用户的智能清理与系统维护工具
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Version-2.4.3-6366f1?style=for-the-badge" />
  <img src="https://img.shields.io/badge/Platform-Android-22c55e?style=for-the-badge" />
  <img src="https://img.shields.io/badge/Root-KernelSU-0891b2?style=for-the-badge" />
  <img src="https://img.shields.io/badge/Author-liancan-64748b?style=for-the-badge" />
</p>

<p align="center">
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest">
    <img src="https://img.shields.io/badge/立即下载-Release-2563eb?style=for-the-badge" />
  </a>
</p>

---

## ✦ About

AutoPurge Pro 是一款专为 Android Root 环境设计的清理管理模块。

以轻量化 Shell 后台为基础，结合可视化 WebUI，将清理任务、规则管理、定时调度与运行日志整合到统一界面。

不需要繁琐的命令操作，通过 WebUI 即可完成日常管理。

**简洁的界面、灵活的规则、可控的清理流程。**

---

## ✦ Core Features

<table>
<tr>
<td width="50%">

### 🧹 智能清理

- 预设清理任务
- 手动执行清理
- 黑名单与白名单
- 清理规则管理

</td>
<td width="50%">

### ⏱ 定时任务

- Cron 定时调度
- 自定义执行时间
- 后台任务管理
- 运行状态检测

</td>
</tr>
<tr>
<td width="50%">

### 📊 数据面板

- 清理数据统计
- 运行状态展示
- 历史记录查询
- 实时日志查看

</td>
<td width="50%">

### 🎨 WebUI

- 可视化操作界面
- 多种导航模式
- 个性化主题
- 移动端布局适配

</td>
</tr>
</table>

---

## ✦ Interface

<p align="center">
  <em>WebUI 界面预览</em>
</p>

<!-- 后续可在此处添加 WebUI 实际截图 -->

---

## ✦ Installation

**环境要求**

| 项目 | 说明 |
|---|---|
| 系统 | Android |
| Root | KernelSU 优先 |
| 运行环境 | Shell / BusyBox |
| 管理方式 | WebUI |

**安装步骤**

1. 前往 [Releases](https://github.com/yunyu614/AutoPurge-Pro/releases) 下载最新 ZIP。
2. 打开 KernelSU 管理器。
3. 进入模块管理，选择本地安装。
4. 选择下载的 ZIP 安装包。
5. 按提示完成安装并重新加载服务。

> 更新建议：覆盖安装前备份重要配置，避免意外丢失。

---

## ✦ Latest Release

<details open>
<summary><strong>v2.4.3 · 2026.11.04</strong></summary>

- 优化 Cron 定时任务启动逻辑。
- 提高 KernelSU BusyBox 环境兼容性。
- 优化进程状态检测。
- 修复导航栏设置区域布局错位。
- 优化移动端响应式布局。
- 改进后台脚本路径识别。
- 优化 WebUI 版权声明页面。

</details>

更多更新内容请查看 [CHANGELOG.md](CHANGELOG.md)。

---

## ✦ Project Links

| 项目 | 地址 |
|---|---|
| 最新版本 | [GitHub Releases](https://github.com/yunyu614/AutoPurge-Pro/releases/latest) |
| 更新记录 | [CHANGELOG.md](CHANGELOG.md) |
| 项目主页 | [AutoPurge Pro](https://github.com/yunyu614/AutoPurge-Pro) |

---

## ✦ Disclaimer

AutoPurge Pro 需要 Root 权限才能执行部分系统级操作。

清理操作可能影响用户数据，请在执行前确认清理规则及目标范围。因设备环境、第三方模块或用户配置差异造成的问题，需要结合实际情况排查。

---

## ✦ Copyright

**AutoPurge Pro**

版权所有 © 2026 liancan

未经作者书面许可，不得擅自复制、修改、分发或将本项目用于其他商业项目。

详细条款请阅读项目中的 `COPYRIGHT.txt`。

<p align="center">
  <strong>Designed for Android Root Users.</strong>
  <br/>
  <sub>AutoPurge Pro · liancan · 2026</sub>
</p>
