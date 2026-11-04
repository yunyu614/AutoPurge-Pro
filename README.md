# AutoPurge Pro

<p align="center">
  <strong>SMART CLEANING · SYSTEM MANAGEMENT</strong>
</p>

<h3 align="center">让清理更智能，让管理更简单。</h3>

<p align="center">
  面向 Android Root 用户的智能清理与系统维护模块
</p>

<p align="center">
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest">
    <img src="https://img.shields.io/github/v/release/yunyu614/AutoPurge-Pro?style=flat-square&color=6366f1&label=Latest%20Release" />
  </a>
  <img src="https://img.shields.io/badge/Android-Root-22c55e?style=flat-square" />
  <img src="https://img.shields.io/badge/KernelSU-Compatible-0891b2?style=flat-square" />
  <img src="https://img.shields.io/badge/WebUI-Integrated-8b5cf6?style=flat-square" />
  <img src="https://img.shields.io/badge/Language-Shell%20%2F%20JavaScript-f59e0b?style=flat-square" />
</p>

<p align="center">
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest">下载最新版本</a>
  ·
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases">历史版本</a>
  ·
  <a href="https://github.com/yunyu614/AutoPurge-Pro/issues">问题反馈</a>
</p>

---

## 01 / 项目简介

**AutoPurge Pro** 是一款面向 Android Root 环境的系统清理与管理模块。

项目采用 Shell 后台执行架构，结合独立 WebUI 管理界面，将清理任务、规则配置、定时调度、运行日志及数据统计整合到一个统一的管理入口。

我们希望减少繁琐的手动操作，让系统清理过程更加直观、灵活、可控。

**核心理念：**
- 简洁：统一的可视化管理界面。
- 灵活：根据使用需求配置清理规则。
- 可控：清理任务与配置由用户管理。
- 高效：后台执行与定时任务相结合。

---

## 02 / 核心功能

| 功能模块 | 功能说明 |
|:---|:---|
| 智能清理 | 集中管理预设清理任务，支持手动执行 |
| 黑名单 | 排除指定路径，避免目标被误清理 |
| 白名单 | 对需要保护的目录进行规则管理 |
| 定时任务 | 基于 Cron 实现自动化清理调度 |
| 数据统计 | 查看清理数据及运行状态 |
| 清理记录 | 查询历史清理任务 |
| 运行日志 | 查看后台任务运行情况 |
| WebUI | 通过可视化界面管理模块 |
| 个性化 | 支持主题及导航栏显示模式设置 |

---

## 03 / WebUI 管理中心

AutoPurge Pro 使用独立 WebUI，将主要功能划分为四个管理区域。

**01 — Overview**

运行概览与数据统计，集中展示模块运行信息。

**02 — Rules & Schedule**

黑名单、白名单及定时清理配置。

**03 — History & Logs**

清理历史、任务记录与后台运行日志。

**04 — Personalization**

界面主题、导航栏模式及版权声明。

---

## 04 / 运行环境

| 项目 | 要求 |
|:---|:---|
| 系统平台 | Android |
| 权限环境 | Root |
| 优先适配 | KernelSU |
| 脚本环境 | Shell / BusyBox |
| 管理界面 | WebUI |
| 架构 | 以发布包实际包含的二进制组件为准 |

不同设备、Android 版本、Root 管理器及 BusyBox 实现可能存在兼容性差异。

---

## 05 / 安装与升级

### 全新安装

1. 前往 GitHub Releases 下载最新 ZIP 安装包。
2. 打开 KernelSU 管理器。
3. 进入模块管理页面。
4. 选择本地安装模块。
5. 选择 AutoPurge Pro 安装包。
6. 根据安装提示完成操作。

### 版本升级

1. 下载最新版本安装包。
2. 建议提前备份重要配置。
3. 通过 KernelSU 覆盖安装。
4. 按照提示重新加载模块或重启设备。

> 不建议在没有备份的情况下直接删除旧模块后重新安装，以免丢失已有配置及历史记录。

---

## 06 / 版本更新

### v2.4.3 — 2026.11.04

**Cron 定时任务**
- 优化 Cron 启动逻辑。
- 提高 BusyBox 环境兼容性。
- 改进进程状态检测。
- 优化定时任务停止逻辑。

**WebUI**
- 修复导航栏设置区域布局问题。
- 优化移动端响应式布局。
- 调整卡片间距、文字换行及按钮对齐。
- 优化主题初始化体验。
- 优化版权声明页面。

**后台优化**
- 改进模块目录识别。
- 优化快捷清理入口。
- 改进开机服务路径兼容性。

更多版本记录请查看 [CHANGELOG.md](CHANGELOG.md)。

---

## 07 / 下载中心

<p align="center">
  <a href="https://github.com/yunyu614/AutoPurge-Pro/releases/latest">
    <img src="https://img.shields.io/badge/DOWNLOAD-AutoPurge%20Pro-6366f1?style=for-the-badge&logo=github&logoColor=white" />
  </a>
</p>

<p align="center">
  获取最新安装包、版本说明及历史发布记录。
</p>

- [最新稳定版本](https://github.com/yunyu614/AutoPurge-Pro/releases/latest)
- [全部历史版本](https://github.com/yunyu614/AutoPurge-Pro/releases)
- [提交问题与反馈](https://github.com/yunyu614/AutoPurge-Pro/issues)

---

## 08 / 注意事项

- 本模块需要 Root 权限，部分功能可能对系统目录执行操作。
- 执行清理前请确认目标路径及规则。
- 请谨慎配置黑名单、白名单及定时任务。
- 不同系统环境可能存在行为差异。
- 重要数据请提前备份。

因用户配置、设备环境、第三方模块或误操作造成的数据损失，需要由使用者自行承担。

---

## 09 / 版权声明

**AutoPurge Pro**

版权所有 © 2026 liancan

未经作者书面许可，不得擅自复制、修改、分发、反编译、逆向工程或将项目用于其他商业用途。

完整版权及使用限制请参阅项目中的 `COPYRIGHT.txt`。

---

<p align="center">
  <strong>AutoPurge Pro</strong>
  <br/>
  <sub>Clean · Control · Optimize</sub>
  <br/>
  <sub>Designed by liancan · 2026</sub>
</p>
