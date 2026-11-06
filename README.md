<!-- AutoPurge Pro README -->

<div align="center">

# 🧹 AutoPurge Pro

### 智能清理 · 文件整理 · 系统管理

**让清理更智能，让管理更简单。**

面向 Android Root 用户的可视化清理与系统维护模块

<p>
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest"><img src="https://img.shields.io/github/v/release/yunyu614/AutoPurge-Pro?style=for-the-badge&logo=github&label=最新版本&color=6366f1" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/Android-Root-22c55e?style=for-the-badge&logo=android&logoColor=white" alt="Android Root">
  <img src="https://img.shields.io/badge/KernelSU-兼容-0891b2?style=for-the-badge" alt="KernelSU">
  <img src="https://img.shields.io/badge/WebUI-可视化管理-8b5cf6?style=for-the-badge" alt="WebUI">
</p>

<p>
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest">⬇️ 下载最新版</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases">📦 历史版本</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/yunyu614/AutoPurge-Pro/issues">💬 问题反馈</a>
</p>

</div>

---

## 📌 项目简介

**AutoPurge Pro** 是一款运行于 Android Root 环境的清理与文件管理模块。

项目采用 **Shell 后台执行 + WebUI 可视化管理** 的方式，将日常清理、文件归档、规则配置、定时任务、运行日志与数据统计整合在统一入口中。

我们希望把复杂的系统维护操作变得更直观：重要数据一目了然，功能开关集中管理，规则按需配置，运行情况随时可查。

### ✨ 设计理念

| 🧭 理念 | 📖 说明 |
|:---|:---|
| **简洁直观** | 页面分区清晰，减少重复说明与冗余信息 |
| **灵活配置** | 根据使用习惯调整清理规则与文件路径 |
| **安全可控** | 通过黑名单、白名单和路径配置控制操作范围 |
| **自动执行** | 支持定时任务，减少重复手动操作 |

---

## 🚀 核心功能

<table>
  <tr>
    <td width="50%">
      <h3>🧹 智能清理</h3>
      集中管理清理项目，按需启用功能并执行清理任务。
    </td>
    <td width="50%">
      <h3>📁 文件整理</h3>
      扫描指定位置，将文件按规则分类并归档到目标目录。
    </td>
  </tr>
  <tr>
    <td>
      <h3>🛡️ 黑名单 / 白名单</h3>
      排除不希望处理的路径，或对需要保护的目录进行规则管理。
    </td>
    <td>
      <h3>⏱️ 定时任务</h3>
      通过 Cron 调度任务，按设定计划执行自动化操作。
    </td>
  </tr>
  <tr>
    <td>
      <h3>📊 数据统计</h3>
      首页集中查看存储信息、清理统计、规则数量与服务状态。
    </td>
    <td>
      <h3>📋 分类日志</h3>
      在设置中心按功能查看运行日志，方便定位执行情况。
    </td>
  </tr>
  <tr>
    <td>
      <h3>🎛️ 可视化 WebUI</h3>
      通过统一管理界面完成常用配置与操作。
    </td>
    <td>
      <h3>⚙️ 集中设置</h3>
      统一管理外观、服务配置、定时任务、功能说明与日志入口。
    </td>
  </tr>
</table>

---

## 🖥️ WebUI 页面结构

v4.2.1 对页面布局和信息层级进行了整理，主要管理区域如下：

| 页面 | 主要内容 |
|:---|:---|
| **01 · 📊 首页** | 运行数据、清理统计、规则数量、服务状态 |
| **02 · 🎛️ 清理与整理** | 清理功能开关、文件整理开关及相关操作 |
| **03 · 🛡️ 规则中心** | 黑名单、白名单、MT 规则、扫描来源与归档目标 |
| **04 · ⚙️ 设置中心** | 功能介绍、服务配置、外观设置、定时任务与分类日志 |

> 💡 **界面设计方向：** 首页以数据为主；功能开关集中展示；路径默认折叠，点击后再查看完整内容，减少长路径对页面布局的占用。

---

## 📱 运行环境

| 项目 | 说明 |
|:---|:---|
| **系统平台** | Android |
| **运行权限** | Root |
| **优先适配** | KernelSU |
| **脚本环境** | Shell / BusyBox |
| **管理方式** | WebUI |
| **其他环境** | 以具体发布包及设备环境为准 |

<sub>⚠️ 不同 Android 版本、设备厂商系统、Root 管理器及 BusyBox 实现可能存在兼容性差异。请以实际设备测试结果为准。</sub>

---

## 📥 安装与升级

### 🆕 全新安装

1. 点击下方 **下载最新版**，进入 GitHub Releases。
2. 下载最新的 AutoPurge Pro ZIP 安装包。
3. 打开 KernelSU 或兼容的 Root 模块管理器。
4. 进入模块管理页面，选择本地安装。
5. 选择下载的 ZIP 文件并按照提示完成安装。
6. 根据提示重新加载模块或重启设备。

### 🔄 更新升级

1. 前往 [Releases](https://github.com/yunyu614/AutoPurge-Pro/releases) 下载新版本。
2. **建议先备份现有配置及重要数据。**
3. 使用模块管理器安装新版本。
4. 按照提示完成重载或重启。
5. 更新后检查功能开关、规则和路径配置是否符合预期。

> 📝 不同 Root 管理器的安装入口可能略有区别，请以管理器界面提示为准。

---

## 🆕 更新记录

### <img src="https://img.shields.io/badge/v4.2.1-2026.11.06-6366f1?style=flat-square" alt="v4.2.1">

**UI Refined · 界面与交互优化**

- 🎨 优化规则中心与设置中心的卡片层级、间距和对齐。
- 📂 黑名单、白名单、MT 规则及扫描/归档路径默认折叠，按需展开。
- 📊 首页聚焦数据展示，减少不必要的信息干扰。
- 🎛️ 清理与文件整理功能开关集中管理。
- 📋 功能说明与分类日志统一收纳至设置中心。
- 🗑️ 移除壁纸功能。

### <img src="https://img.shields.io/badge/v2.4.3-2026.11.04-64748b?style=flat-square" alt="v2.4.3">

**Cron 定时任务与后台优化**

- ⏱️ 优化 Cron 启动逻辑与 BusyBox 环境兼容性。
- 🔍 改进进程状态检测及定时任务停止逻辑。
- 🧩 修复导航栏设置区域布局问题。
- 📱 优化移动端响应式布局、卡片间距与按钮对齐。
- ⚙️ 改进模块目录识别、快捷清理入口及开机服务路径兼容性。

📚 更多版本记录请查看 [CHANGELOG.md](CHANGELOG.md)（如仓库中提供）。

---

## ⬇️ 下载中心

<div align="center">

<a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest">
  <img src="https://img.shields.io/badge/⬇%20DOWNLOAD-获取%20AutoPurge%20Pro%20最新版-6366f1?style=for-the-badge&logo=github&logoColor=white" alt="Download AutoPurge Pro">
</a>

**获取最新安装包、版本说明及历史发布记录**

<p>
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest">🚀 最新稳定版本</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases">📦 全部历史版本</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/yunyu614/AutoPurge-Pro/issues">📝 提交问题与反馈</a>
</p>

</div>

---

## ⚠️ 使用须知

- 🔐 本模块需要 Root 权限，部分功能可能对系统目录执行操作。
- 📁 执行清理或文件整理前，请仔细确认扫描路径、目标路径及规则。
- 🛡️ 请谨慎配置黑名单、白名单、MT 规则与定时任务。
- 💾 修改配置或升级前，建议备份重要数据。
- 📱 不同设备、系统版本及第三方模块环境可能导致功能表现不同。

**请在理解功能和操作范围后使用。** 因用户配置、设备环境、第三方模块或误操作造成的数据损失，请使用者自行承担相应风险。

---

## 📄 版权声明

**AutoPurge Pro**

版权所有 © 2026 **liancan**

未经作者书面许可，不得擅自复制、修改、分发、反编译、逆向工程或将项目用于其他商业用途。

完整版权及使用限制请参阅项目中的 `COPYRIGHT.txt`。

---

<div align="center">

### 🧹 AutoPurge Pro

**Clean · Control · Optimize**

<sub>让系统维护更简单，让每一次操作都清晰可控。</sub>

<sub>Designed by liancan · 2026</sub>

</div>
