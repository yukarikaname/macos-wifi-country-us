# macos-wifi-country-us

[English](README.md) | [简体中文](README_CN.md)

让 macOS 把 Wi-Fi 监管国家代码上报为 **US** 而不是 **CN** —— 通过 dyld 注入实现，
跨重启持久生效。测试环境：macOS 27.0.1（Apple 芯片）。

> [!IMPORTANT]
> **必须关闭 SIP**（`csrutil status` → `disabled`）。SIP 开启时，dyld 会把
> `DYLD_*` 环境变量从系统进程中剔除，而那正是本项目依赖的机制。
> `install.sh` 会先检查，不满足就直接退出。

## 安装

```sh
git clone https://github.com/yukarikaname/macos-wifi-country-us.git
cd macos-wifi-country-us
./install.sh
```

它会先检查 macOS、Xcode 命令行工具、SIP 和 sudo —— 任何一项不满足就在改动任何东西
之前中止 —— 然后构建两个 dylib、安装 launchd 覆盖 plist 和 `/usr/local/bin`
wrapper、重启 `airportd`/`countryd`（Wi-Fi 会断几秒；带看门狗，起不来会自动退回系统
配置），最后跑一遍验证。

```sh
./install.sh --dry-run      # 只跑所有检查，不做任何修改
./install.sh --uninstall    # 移除本项目安装的全部内容
```

## 验证

```sh
./scripts/verify.sh

/usr/local/bin/system_profiler SPAirPortDataType | grep -E 'Locale|Country Code'
```

`verify.sh` 对每项检查打印 `PASS`/`FAIL`，任何失败都会返回非零退出码。
`system_profiler` 的预期输出：`Locale: USA`、`Country Code: US`。

| 面向 | 之前 | 之后 |
|---|---|---|
| `system_profiler` | `Locale: Unknown`、`Country Code: CN` | `Locale: USA`、`Country Code: US` |
| CoreWLAN `CWInterface.countryCode` | `(nil)` | `US` |
| `ioreg`（已包装） | `IO80211CountryCode = "CN"` | `"US"` |
| airportd 内部状态 | `CN` | `US` |
| 驱动值（`/usr/sbin/ioreg`） | `CN` | 不变 —— 用户态不可写 |
| 跨重启的 SSH / Wi-Fi | —— | 完好 |

## 卸载

```sh
./install.sh --uninstall
```

## 工作原理

macOS 的国家代码来自对附近 AP 信标中「国家 IE」的多数投票。这个值**用户态不可写**
（往 IORegistry 写会被接受然后忽略），所以唯一的着力点是读取端：

- **`libcountryus.dylib`** → `airportd` 和 `countryd`，通过
  `/Library/LaunchDaemons` 覆盖 plist 里的按-job `DYLD_INSERT_LIBRARIES` 注入
  （`/System` 上的原件是封印只读的，改不了）。
- **`libcountryus_reader.dylib`** → 真正负责「显示」的那些工具 ——
  `system_profiler`、`ioreg`、CoreWLAN 客户端 —— 通过 `/usr/local/bin` 里的 PATH
  shim 注入，hook 报告插件的 model getter、`CWInterface` 和 ioreg 的属性读取。
- **`com.local.countryinj`** → 开机 LaunchDaemon。开机时 launchd 对重复 label 会优先
  选 `/System` 的 plist，没有这个任务覆盖就会被静默丢弃、机器退回 CN。它在开机
  45 秒后重新应用两个覆盖，并带看门狗，绝不会让机器断网。

一条硬规矩：**永远不要** `launchctl setenv DYLD_INSERT_LIBRARIES`。它会传播到每个
job，包括 hardened-runtime 的 `sshd-keygen-wrapper`，AMFI 会在加载阶段直接 SIGKILL
它 —— SSH 就没了。本项目里所有环境变量都限定在单个 job 或单条命令内。

反汇编细节、崩溃排查和移植踩坑见 [NOTES.md](NOTES.md)（目前只有英文版）。

## 常见问题

**重新开启 SIP 后还能用吗？**
不能，但也不会出事。SIP 开启后，dyld 会在启动系统进程之前丢弃 `DYLD_*`，注入静默
失效，全部退回 CN。所有文件都还在：进 Recovery 再关一次 SIP 并重启即可恢复，无需
重装。`verify.sh` 会把它作为独立的「SIP state」检查项报出来。这一条依据的是 Apple
的文档行为，未在本机实测（切换 SIP 每个方向都要进一次 Recovery 重启）。

**Option 点击 WiFi 菜单时 Hardware Address 是空的。**
和本项目无关。那一行来自 ControlCenter，它从不加载这些 dylib；它在登录时抓一次
WiFi 详情快照就不再刷新。`killall ControlCenter` 即可恢复。

**`wdutil info` 显示 `Country Code: (null)`。**
在本项目的开发机上本来就是这样 —— 整个 WIFI 段都是 null，带不带注入都一样。
不是本项目造成的。

**重启后退回 CN 了。**
跑 `./scripts/verify.sh`。它会报告 launchd 覆盖的 plist 路径、全局
`DYLD_INSERT_LIBRARIES`（必须为空）以及 dylib 是否加载；
`/usr/local/var/log/countryinj.log` 是开机任务的完整记录。

## 目录结构

```
install.sh   一键安装（前置检查：macOS、CLT、SIP、sudo）
src/         hook_countryus.m   守护进程侧 dylib（airportd、countryd）
             hook_reader.m      读取端 dylib（system_profiler、ioreg、CoreWLAN）
launchd/     airportd/countryd 覆盖 plist + com.local.countryinj
scripts/     build_*、install_*、restart_daemons、countryinj、verify、uninstall
wrappers/    system_profiler、wdutil、ioreg
tools/       sshexec/push/pull、mkoverride、pldiff（密码取自 MAC_SSH_PASS）
```
