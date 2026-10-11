# wifi-country-us

[English](README.md) | [简体中文](README_CN.md)

让 macOS 在单台机器上通过 dyld 注入把 Wi-Fi 监管国家代码上报为 **US** 而不是
**CN**，并可跨重启持久生效。

编写与测试环境：macOS 27.0.1（build 26A434），arm64e，Apple 芯片。
**必须关闭 SIP** —— 否则这里的任何方法都不生效。

---

## 为什么国家代码是 CN

驱动在 Wi-Fi 的 IORegistry 节点上发布 `IO80211CountryCode`，其值来自**附近 AP
信标中的国家 IE** —— 也就是对扫描结果做多数投票。它不是一个可存储的偏好设置。
在目标机器上那次统计结果是 `CN, count 8` 对 `US, count 4`，所以驱动报 CN，于是
所有向驱动查询的读取方都跟着报 CN。

关键在于这个值**无法从用户态写入**：

- 对 DriverKit 节点调用 `IORegistryEntrySetCFProperty` 会返回 `KERN_SUCCESS`
  但什么也没改变 —— 写入被接受然后忽略。
- `airportd` 也无法把国家代码推给驱动。给所有 setter（`setCountryCode:source:`、
  `retrySetCountryCode:source:`、`setLocaleCountryCode:`、`setDeviceCountryCode:`、
  `updRD`）都挂上日志 swizzle 后，运行时**调用次数为零**。不存在可以劫持的
  airportd→驱动 推送路径。`RDUpdateCountryCodeFromWiFiAPs`（由
  `RegulatoryDomain.framework` 导出）是*反方向*的：airportd 把 AP 信标的国家代码
  喂给 countryd 做估算。

所以唯一的着力点是**读取端**：拦截那些*显示*国家代码的进程，交给它们 US 而不是
CN。这正是本项目所做的。

## 两个 dylib，两处注入点

### 1. `libcountryus.dylib` —— 守护进程侧

源码：[`src/hook_countryus.m`](src/hook_countryus.m)

注入到 **`airportd`** 和 **`countryd`**，把它们的内部状态维持在 US
（`countryCode`、`_rdCountryCode`、`NetworkCountryCodeAdvertised` /
`Applied`，以及 countryd 的缓存估算值）。dylib 自身按宿主进程的 basename 做门控，
因此在其他任何进程中都不会生效。

### 2. `libcountryus_reader.dylib` —— 读取端

源码：[`src/hook_reader.m`](src/hook_reader.m)

注入到上报国家代码的那些 CLI 工具。共有三处独立的拦截点，因为各读取方对数值来源
的说法并不一致：

| 读取方 | 取值路径 | 拦截方式 |
|---|---|---|
| `system_profiler` | `SPAirPortReporter` 插件自身的 model 对象 | `-[SPAirPortInterface countryCode]` / `-[SPAirPortNetwork countryCode]` 的 getter swizzle |
| CoreWLAN 客户端 | `-[CWInterface countryCodeInternal]` | 方法 swizzle（无定位授权时返回 `(nil)`，所以无条件强制赋值） |
| `ioreg` | `IORegistryEntryCreateCFProperty` / `SearchCFProperty` / `CreateCFProperties` | `__DATA,__interpose` —— 重写返回字典里的 `IO80211CountryCode` |

同时把插件的 `locale` 属性强制为 `USA`，使报告读作 `Locale: USA` 而不是
`Locale: Unknown`。

### *没有* hook 的部分，以及原因

`Apple80211CopyValue` —— `SPAirPortReporter` 导入的那个 IO80211 user-client 调用
—— 只被 interpose 用于**打日志**。它的原型没有出现在磁盘上任何头文件里，因此是从
插件中的调用点反推出来的：

```
bl   _Apple80211CopyValue
cbnz w0, ...            ; kern_return_t 从 w0 返回
ldr  x20, [sp, #0x80]   ; 出参值来自第 4 个参数槽
```

即 `kern_return_t Apple80211CopyValue(a11Ref, key, options, CFTypeRef *out)`，
出参指针在 **x3** 而不是 x2。这里猜错正是[踩坑记](#踩坑记)里两种崩溃模式的来源
—— 按三参数声明会把出参指针放进 x2（调用方那里永远是 NULL），而用 `dlsym` 解析原
函数则会一路递归直到线程撞上栈保护页。反正这个调用里也读不到数值（国家代码是通过
插件的 model 对象到达的），所以 interpose 保持只记日志。

---

## 持久化 —— 以及为何不得不绕开的那个坑

### 读取端：PATH wrapper

`system_profiler`、`wdutil` 和 `ioreg` 是用户手动调用的 CLI 工具，不是 launchd
job，因此按 job 注入 plist 的办法对它们无效。它们改为在 `/usr/local/bin` 下放一层
薄 wrapper，而该目录在登录 shell 的 PATH 中排在 `/usr/bin` 之前：

```sh
#!/bin/sh
export DYLD_INSERT_LIBRARIES=/usr/local/lib/libcountryus_reader.dylib
exec /usr/sbin/system_profiler "$@"
```

磁盘上的文件本身就跨重启存活。任何直接调用真实路径（`/usr/sbin/system_profiler`）
的程序不受影响。

### 守护进程侧：`/Library` 覆盖 plist 中的按 job 环境变量

`/Library/LaunchDaemons/com.apple.{airportd,countryd}.plist` 是 `/System` 原件的
克隆，只多了一个键：

```xml
<key>EnvironmentVariables</key>
<dict><key>DYLD_INSERT_LIBRARIES</key><string>/usr/local/lib/libcountryus.dylib</string></dict>
```

`/System` 卷是 APFS 封印的只读卷，原件无法编辑。`tools/pldiff.py` 可确认克隆与原件
的差异恰好只有这一个键。

### 那个坑：launchd 在开机时优先选 `/System`

显式执行 `launchctl bootout` 加 `bootstrap system /Library/...` 会让 launchd 选择
`/Library` 覆盖。**但正常开机不会** —— launchd 处理重复 label 时偏向 `/System`，
于是 dylib 静默地不再加载，机器退回报 CN。

`com.local.countryinj`（[`scripts/countryinj.sh`](scripts/countryinj.sh)）补上了这个
缺口：一个开机时运行的 LaunchDaemon，等待 45 秒让协议栈稳定下来，然后用已验证有效
的 bootout+bootstrap 序列重新应用两个覆盖。它带一个看门狗，若 Wi-Fi 没有恢复就把
airportd 退回系统 plist，因此不可能让机器断网。日志写入
`/usr/local/var/log/countryinj.log`。

---

## ⚠️ 不要使用全局 `DYLD_INSERT_LIBRARIES`

试过 `launchctl setenv DYLD_INSERT_LIBRARIES=...`，结果**把目标机器的 SSH 干掉了**。
该变量会经由 launchd 传播到每个 job，包括 hardened-runtime 的
`sshd-keygen-wrapper`。AMFI 拒绝向加固进程加载未签名 dylib，在 dyld 加载阶段就
SIGKILL —— 此时 dylib 里的代码还没开始执行，因此构造函数中的进程名门控保护不了任何
东西。

本项目中所有环境变量都保持作用域受限：在 launchd plist 中按 job 设置，在 wrapper
脚本中按命令设置。**不要重新引入机器级 `setenv`。**

---

## 安装

一条命令完成，带前置检查：

```sh
./install.sh
```

它会确认当前是 macOS、Xcode 命令行工具已安装，以及 —— 真正关键的 —— **SIP 已关闭**。
若 SIP 处于开启状态，它会在动任何东西之前中止，因为对本项目所 hook 的这些守护进程，
dyld 会忽略 `DYLD_INSERT_LIBRARIES`：什么都不会崩溃，守护进程只是继续报 CN，而安装
看起来像是成功了。

其他用法：

```sh
./install.sh --dry-run      # 只跑所有检查，不做任何修改
./install.sh --uninstall    # 移除本项目安装的全部内容
```

它按顺序执行以下步骤，每一步都可以单独运行：

```sh
# 1. 守护进程侧 dylib
./scripts/build_countryus.sh

# 2. 读取端 dylib
./scripts/build_reader.sh

# 3. launchd 覆盖 plist + 开机重注入任务
./scripts/install_launchd.sh

# 4. 读取端 PATH wrapper
./scripts/install_wrappers.sh

# 5. 重启守护进程以应用覆盖（--wait 表示前台执行）
./scripts/restart_daemons.sh --wait
```

检查结果：

```sh
./scripts/verify.sh
```

`verify.sh` 对每项检查打印 `PASS`/`FAIL`，任何失败都会返回非零退出码，因此可以放进
脚本里用。它会检查全局 `DYLD_INSERT_LIBRARIES` 为空（这是 sshd 安全性的前提）、两个
守护进程都在运行且已加载 dylib、launchd 选中了 `/Library` 覆盖，以及
`system_profiler` 只报 US。

### 如果之后重新开启 SIP

文件全部都还在 —— `/usr/local`、`/Library/LaunchDaemons` 和 PATH wrapper 都不在 SIP
的保护范围内，而且 `install.sh` 只在 SIP 开启时**拒绝开始安装**，绝不会去动已经装好
的东西。失效的是加载这一步：SIP 开启后，dyld 会在启动受保护（系统内置）可执行文件
之前清掉 `DYLD_*` 环境变量，所以覆盖 plist 和 wrapper 照样在设置这个变量，而
airportd、countryd、`system_profiler` 等照旧不理会它。

按听起来吓人的程度排序，后果是：

- **不会崩溃，也不会断网。** 这和上面那场全局 `setenv` 的事故正好相反：dyld 在加载
  任何东西**之前**就把变量丢弃了，dylib 根本不会被加载，也就永远不会走到 AMFI 那一
  关。重新开启 SIP 不会搞挂 SSH。
- **静默退回 CN。** 所有读取方都会重新上报驱动基于信标得出的值。
- **不需要重装。** 进 Recovery 关掉 SIP 再重启，`com.local.countryinj` 会在下次开机
  时照常重新应用覆盖。
- `verify.sh` 会把它作为独立检查项（“SIP state”）报出来，所以一次普通验证就能发现，
  不会变成事后才察觉的“莫名其妙回归”。

这一条没有在本机实测 —— 每个方向切换 SIP 都需要进一次 Recovery 重启 —— 所以上述内容
是 Apple 文档记录的行为（Runtime Protections：*“Any dynamic linker (dyld) environment
variables … are purged when launching protected processes”*），不是实测结果。

## 手动验证

```sh
/usr/local/bin/system_profiler SPAirPortDataType | grep -E 'Locale|Country Code'
/usr/local/bin/ioreg -l -w0 | grep IO80211CountryCode
/usr/sbin/ioreg -l -w0 | grep IO80211CountryCode     # 未包装：显示驱动的真实值
```

预期：经过包装的读取方报 US；未包装的 `/usr/sbin/ioreg` 显示驱动基于信标得出的值，
除非本地射频环境恰好统计成 US，否则为 CN。

诊断标记（注意 `/tmp` 在每次 macOS 开机时都会被清空，所以这些会在每次开机后重新生成）：

- `/tmp/opencode/HOOK_LOADED` —— 每个加载了 dylib 的进程一行
- `/tmp/opencode/SWIZZLE.txt` —— 每个安装成功的 swizzle 一个 `OK`
- `/usr/local/var/log/countryinj.log` —— 开机重注入任务的完整记录

## 卸载

```sh
./install.sh --uninstall
# 等价于
./scripts/uninstall.sh
```

会移除 wrapper、两个 dylib、覆盖 plist 和重注入任务，并把 airportd/countryd 交还给
它们的 `/System` plist。

---

## 结果

| 面向 | 之前 | 之后 |
|---|---|---|
| `system_profiler SPAirPortDataType` | `Locale: Unknown`、`Country Code: CN` | `Locale: USA`、`Country Code: US`（所有网络行） |
| CoreWLAN `CWInterface.countryCode` | `(nil)` | `US` |
| `ioreg`（已包装） | `IO80211CountryCode = "CN"` | `"US"` |
| 驱动值（未包装的 `ioreg`） | `CN` | `CN` —— 未改变，且不可写 |
| airportd 内部状态 | `CN` | `US` |
| 跨重启的 SSH / Wi-Fi | —— | 完好 |

`wdutil info` 在**两种**状态下都报 `Country Code: (null)`。这是该机器上本来就有的
问题（它整个 WIFI 段都是 null），通过带注入与不带注入的 A/B 对照验证过，不是本项目
造成的。

## 踩坑记

如果你要把这套东西移植到别的 macOS 版本，以下内容值得了解：

- **`otool` 需要 `-arch arm64e`** —— 这些二进制是 arm64e 而非 arm64，
  `otool -arch arm64` 会报告 "does not contain architecture"，看上去却像成功了。
  `llvm-objdump` 没有安装；`/usr/bin/objdump` 有。
- **私有框架可能只是存根。** 磁盘上的 `IO80211.framework` 没有二进制 —— 代码在
  dyld 共享缓存里，所以 `nm -gU` 报告零导出。`dyld_info -exports` 可用，而 SDK 的
  `.tbd` 可以满足链接：`-F "$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks"
  -framework IO80211`。
- **zsh 把 `path` 与 `PATH` 绑定。** 在 zsh 脚本里写 `path=$(...)` 会覆盖 `PATH`，
  之后表现为 `command not found: grep`。全部改名为 `pl_path`。这一条让一整轮开机
  重注入白跑。
- **macOS 上没有 `/usr/bin/test`** —— 用 shell 内建。
- **`/tmp` 在开机时被清空** —— 任何期望跨重启保留的东西都应放在 `/usr/local` 或
  `/var` 下，而不是 `/tmp`。
- **`system_profiler` 会 fork** —— 每次调用有两个 PID，各自都会执行注入的构造函数。
- **arm64e 指针带 PAC 签名。** 读取 interpose 的 `orig` 槽会得到带签名的值；转型后
  通过它调用没问题，但对同一个符号用 `dlsym` 可能解析回你自己的替换函数（见上面关于
  递归的说明）。
- **用 `CFGetTypeID` 检查返回值类型**是发现 `Apple80211CopyValue` 原型声明错误的
  办法：一个值为 `0` 的 `kern_return_t` 被当成 `CFTypeRef` 读，看起来完全像个
  合理的空值。
- **`plutil -insert -dict` 不支持** —— 用 Python 的 `plistlib`。
- **`log show` 需要 sudo**，且它的 `--end` 会被忽略；改用 `awk` 按时间戳过滤。
- **Option 点击 WiFi 菜单时「Hardware Address」为空，不是你的问题。** 那一行来自
  ControlCenter，而它从不加载本项目的任何 dylib。这是启动时序造成的缓存问题：
  ControlCenter 在登录时启动并抓取一次 WiFi 详情快照，而 `com.local.countryinj` 在
  开机约 45 秒后重启 `airportd` —— 所以 ControlCenter 通常比它所读取的守护进程**更
  旧**，且从不刷新。`killall ControlCenter` 即可重新填充。另外开启「私有 WiFi
  地址」时系统里同时存在两个 MAC：`ifconfig` 显示本地管理的那个（`06:...`），
  `networksetup -getmacaddress` 显示出厂那个，而菜单要的是出厂那个。
- **`shutdown_stall` 报告与本项目无关。** 这台机器上 `/Library/Logs/DiagnosticReports`
  里的此类报告可追溯到本项目存在之前，且每一份中卡住的都是普通用户会话进程和系统
  守护进程 —— `airportd` 和 `countryd` 从未出现，因为它们退出得很干脆。不要把它们
  当作注入引入的回归去查。

## 目录结构

```
install.sh      一键安装（前置检查：macOS、CLT、SIP）
src/          hook_countryus.m   守护进程侧 dylib（airportd、countryd）
              hook_reader.m      读取端 dylib（system_profiler、CoreWLAN、ioreg）
launchd/      com.apple.airportd.plist     /Library 覆盖 + dylib env
              com.apple.countryd.plist     /Library 覆盖 + dylib env
              com.local.countryinj.plist   开机重注入任务
scripts/      build_countryus.sh  构建并安装守护进程侧 dylib
              build_reader.sh     构建并安装读取端 dylib
              install_launchd.sh  安装覆盖 plist + 重注入任务
              install_wrappers.sh 安装 /usr/local/bin wrapper
              restart_daemons.sh  重启 airportd/countryd（带看门狗）
              countryinj.sh       开机重注入脚本本体
              verify.sh           状态检查（退出码反映失败）
              uninstall.sh        移除全部内容
wrappers/     system_profiler、wdutil、ioreg
tools/        sshexec.py、push.py、pull.py   远程辅助脚本（密码取自
                                             MAC_SSH_PASS 环境变量，不写死）
              mkoverride.py、pldiff.py       plist 克隆 + 漂移检查
```
