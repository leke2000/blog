---
layout: post
title: "EMR 同步 · 内训周执行手册（Arthas + tcpdump + 时序图）"
date: 2026-09-18 00:00:00 +0800
categories: [排障手记]
tags: [周计划, EMR, 内训]
---

<!--more-->

实施交付 · 内训任务
周期 2026-09-21（周一）～ 09-25（周五） · Arthas 火焰图性能排查 · tcpdump / Wireshark 抓包分析 · 住院回写时序图

Arthas 火焰图trace / watchIDEA Arthas 插件tcpdumpWireshark飞书时序图

[0 任务总览](#plan)
[1 周一/二 · Arthas](#arthas)
[2 周三 · 抓包分析](#tcpdump)
[3 周四/五 · 时序图](#seq)
[4 附录速查](#appendix)

## 0任务总览

| 时间 | 任务 | 交付物 / 验收证据 |
| --- | --- | --- |
| **周一 09-21 周二 09-22** | 在自己负责的 1 家医院环境里，用 Arthas 抓取火焰图；安装 IDEA Arthas 插件；掌握 `trace` / `watch` 命令 | ① CPU / wall 火焰图 HTML ② 性能与优化方向分析报告 ③ 插件截图 + trace/watch 记录 |
| **周三 09-23** | 用 `tcpdump` 抓包，用 Wireshark 分析本系统的 HTTP 请求并截图 | ① pcap 抓包文件 ② Wireshark 分析截图（含过滤条件） |
| **周四 09-24 周五 09-25** | 绘制「住院内嵌 / 悬浮窗」×「前端回写 / 后端回写」共 4 张时序图（飞书文档） | ① 飞书文档（4 张图） ② 本文档第 3 节可直接复制 |

### 本环境的已知事实（省去你现场摸索）

- 同步服务镜像基于 **Temurin JDK 17**，启动参数 `-Xms1024m -Xmx1024m`，容器内暴露端口 **48088**。
- **Arthas 已内置在镜像里**：`/opt/arthas`（含 arthas-boot / as.sh / async-profiler），无需联网下载。
- Arthas 配置：telnet **3658**、http **8563**、`arthas.ip=127.0.0.1`（默认只允许容器内本地连接，免密）。
- magic-api 控制台：**192.168.0.12:48080**；回写脚本路径 `/back/transfer`、`/back/transfer/new`、`/clinic/write_back`。
- 配置文件挂载在容器 `/emr-wisdom-sync/conf/application.yml`，日志与堆转储在 `/emr-wisdom-sync/data`、`/emr-wisdom-sync/logs`。

## 1周一 / 周二 · Arthas 火焰图 + trace / watch + IDEA 插件

### 1.1 前置确认（5 分钟）

先确认在哪台机器、哪个容器、哪个进程上操作，避免抓错实例。

```
# 1) 找到容器（在部署机上执行）
docker ps | grep -i wisdom-sync

# 2) 确认容器端口映射与内网 IP
docker port <容器名>
docker inspect -f '{{.NetworkSettings.IPAddress}} {{.Name}}' <容器名>

# 3) 宿主机上监听端口是否正常
ss -lntp | grep -E '48088|3658|8563'

# 4) 容器内 JDK 版本
docker exec -it <容器名> java -version
```

容器名可用 `docker ps --format '{{.Names}}'` 一次列出。生产环境改动前先确认是不是自己负责的那家医院。
### 1.2 启动 Arthas

镜像里已带 Arthas，**优先在容器内用 as.sh**，最省事且默认免密。

```
# 进入容器（镜像极简时用 sh）
docker exec -it <容器名> bash

# 方式一：as.sh（推荐，容器内一键启动，默认本地免密）
/opt/arthas/as.sh

# 方式二：arthas-boot，交互选择进程
java -jar /opt/arthas/arthas-boot.jar
#   会列出容器内所有 java 进程，输入 wisdom-sync 前面的序号并回车

# 方式三：直接指定 pid 附着
java -jar /opt/arthas/arthas-boot.jar <pid>
```

**关于远程连接：**`arthas.properties` 里 `arthas.ip=127.0.0.1`，即 Arthas 只监听容器本地，容器外 telnet 3658 是连不上的。想在宿主机直连需要：
① `docker run` 时映射 `-p 3658:3658 -p 8563:8563`；② 把 `arthas.ip` 改为 `0.0.0.0`；③ 建议同时配置 `arthas.username/password`。**日常直接用容器内 as.sh 最省事。**
### 1.3 快速体检：先看「谁在忙」再决定抓什么

抓火焰图之前，先用几个命令建立第一印象，能帮你判断是 CPU 打满、还是卡在等待。

```
# 实时面板：线程 / 内存 / GC，Ctrl+C 退出
dashboard

# 最忙的 5 个线程（排查 CPU 热点第一招）
thread -n 5

# 找出阻塞其他线程的线程（锁竞争 / 死锁）
thread -b

# 指定线程的堆栈（pid 用 thread 输出里的 id）
thread <线程id>

# JVM 信息：堆、GC、线程数、启动参数
jvm

# 各内存区使用情况
memory

# 确认目标类已加载（类没加载就无法 trace）
sc -d cn.ejet.emr.module.policy.controller.admin.MedicalRecordController
```

| 命令 | 看什么 / 结论怎么用 |
| --- | --- |
| `dashboard` | 实时面板：线程 / 堆 / GC。看 CPU 是否持续高、GC 次数是否频繁。`Ctrl+C` 退出。 |
| `thread -n 5` | **排查 CPU 热点的第一招**。列出最忙的 5 个线程及其栈顶。若反复是同一个业务线程 → 进入 1.4 抓 CPU 火焰图。 |
| `thread -b` | 找出「阻塞其他线程」的线程（锁竞争 / 死锁）。同步任务卡死时先跑这个。 |
| `jvm` / `memory` | 堆使用、GC 类型与次数、各内存区占用。`-Xmx1024m` 偏小，GC 频繁时要警惕。 |
| `sc -d cn.ejet.emr.*` | 确认目标类已被加载（类没加载就没法 trace）。 |

**判断分叉口：**若 `thread -n 5` 反复指向同一个业务线程 → 抓 **cpu** 火焰图；若线程都在等待、CPU 不高但接口慢 → 抓 **wall** 火焰图。
### 1.4 抓火焰图（Arthas 内置 async-profiler）

三种事件按目的选：**cpu** 找热点代码、**wall** 找真实耗时（含等待/IO/网络）、**alloc** 找内存分配大户。

```
# ① CPU 火焰图：找 CPU 热点（最常用）
profiler start --event cpu --duration 30 --file /tmp/cpu.html

# ② 墙钟火焰图：找真实耗时（含等待 / IO / 网络），排查「同步慢」首选
profiler start --event wall --duration 60 --file /tmp/wall.html

# ③ 内存分配火焰图：找疯狂 new 对象的代码
profiler start --event alloc --duration 30 --file /tmp/alloc.html

# 查看可用事件类型 / 当前状态 / 手动停止
profiler list
profiler status
profiler stop

# 简写形式与上面等价
profiler start -e cpu -d 30 -f /tmp/cpu.html
```

#### 把火焰图拷出来

```
# 宿主机执行：把火焰图从容器拷出来
docker cp <容器名>:/tmp/cpu.html  ./arthas-$(date +%Y%m%d%H%M)-cpu.html
docker cp <容器名>:/tmp/wall.html ./arthas-$(date +%Y%m%d%H%M)-wall.html

# 更稳的做法：直接输出到挂载目录，避免容器重启丢文件
profiler start --event wall --duration 60 --file /emr-wisdom-sync/data/wall.html
```

**采集时机的关键：**火焰图必须在「真实业务正在跑」的窗口内采样。先触发一次同步/回写（或并发压几个请求），再执行 `profiler start`。采到一潭死水的火焰图没有任何意义。
### 1.5 火焰图怎么读（3 个要点）

**横轴 = 样本占比**

越宽的块，占用 CPU / 时间越多。**不是时间顺序**，别按左右顺序读流程。

**纵轴 = 调用栈**

下方是父调用，上方是子调用。从下往上找「由窄变宽」的那一层。

**找「宽顶」**

最上层的宽块方法名 = 最终热点。若宽在中间层，说明它自己或其子调用耗资源。

| 火焰图特征 | 说明 |
| --- | --- |
| 顶部宽块是业务方法 | CPU 型瓶颈，改代码（循环/拼接/正则/序列化）能直接见效。 |
| 大量 `park` / `socketRead` / `await`（wall 图） | **等待型瓶颈**：DB 慢 SQL、外部接口慢、大模型调用等待。加 CPU 没用，要治等待。 |
| 「平顶 / 塔状」 | 典型的慢 SQL 或慢接口形状。 |
| GC 线程占比高 | 内存压力大，转去抓 `alloc` 火焰图定位大对象来源。 |
| `org.ssssssss.magicapi.*` 变宽 | 瓶颈在 magic-api 脚本解释执行，考虑脚本缓存 / 精简脚本逻辑。 |
| `com.alibaba.druid.*getConnection` | 连接池等待，调 `maxActive` 或治理慢查询。 |

### 1.6 trace 命令：追一条链路，看每一步耗时

```
# 基本用法：追踪指定类的方法，打印每层调用耗时
trace cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync

# 只追踪 5 次，避免刷屏（-n 为执行次数限制）
trace -n 5 cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync

# 只看耗时超过 100ms 的调用（性能分析神器）
trace cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync '#cost > 100'

# 展开 3 层调用栈，看清里面调了谁
trace -x 3 cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync

# 追踪前端回写入口
trace -n 5 cn.ejet.emr.module.xemr.controller.admin.opd.OpdAssistantController writeBack

# 列出该类的所有可追踪方法（方法重载时用得上）
trace --list cn.ejet.emr.module.xemr.service.opd.OpdAssistantServiceImpl

# 指定方法名匹配（--match）
trace -n 3 --match 'sync*' cn.ejet.emr.module.policy.controller.admin.MedicalRecordController
```

**实战读法：**trace 输出按耗时倒序列出每一层调用。找到**第一层耗时骤增**的地方 —— 例如业务 Service 只花 3ms，但 `magicAPIService.invoke` 花了 1800ms，那瓶颈就在 magic-api / 远程接口，而不是业务代码。
### 1.7 watch 命令：看入参 / 返回值 / 异常

```
# 看入参 + 返回值，展开 2 层（不展开对象会打印成 {...}）
watch cn.ejet.emr.module.xemr.controller.admin.opd.OpdAssistantController writeBack '{params, returnObj}' -x 2

# 只在抛异常时观察 —— 定位回写失败原因
watch cn.ejet.emr.module.xemr.controller.admin.opd.OpdAssistantController writeBack '{params, throwExp}' -e -x 2

# 方法正常返回后观察，限制 5 次
watch cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync '{params[0], returnObj}' -f -n 5 -x 2

# 精确取字段，避免对象太大刷屏
watch cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync '{params[0].medicalRecordId, returnObj.result}' -f -x 1
```

#### watch 的观察表达式变量

| 变量 | 含义 |
| --- | --- |
| `params` | 方法入参数组，`params[0]` 是第一个参数 |
| `returnObj` | 返回值 |
| `throwExp` | 抛出的异常（配合 `-e` 使用） |
| `target` | 当前对象（可写 `target.xxx` 看字段） |
| `#cost` | 方法耗时(ms)，在 trace 的条件表达式里可用 |

**触发时机选项：**`-b` 调用前 · `-e` 抛异常后 · `-s` 正常返回后 · `-f` 方法结束后（默认） · `-n` 次数限制 · `-x` 展开层级。

**小技巧：**入参是对象时一定要加 `-x 2`，否则只打印 `{...}` 看不到内容；对象太大时用 `params[0].xxx` 精确取值，避免刷屏。
### 1.8 高频补充命令

```
# 反查调用来源：这个方法到底是谁在调
stack cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync

# 记录调用现场，事后重放（-t 记录，-i 索引，-p 重放）
tt -t cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync
tt -l
tt -i 1000 -p

# 每 5 秒统计一次 QPS / RT / 成功率（-c 为周期，单位秒）
monitor -c 5 cn.ejet.emr.module.policy.controller.admin.MedicalRecordController sync

# 反编译类，确认线上实际运行的代码（排查「代码没生效」）
jad cn.ejet.emr.module.policy.controller.admin.MedicalRecordController

# 查看类的静态字段值
getstatic cn.ejet.emr.module.policy.controller.admin.MedicalRecordController MAGIC_API_BASE_PATH
```

### 1.9 IDEA 安装 Arthas 插件

1. IDEA → `File → Settings → Plugins → Marketplace`，搜索 **Arthas Idea**（作者 wangji / 汪小哥）。另有 **Arthas Hot Swap** 用于线上类热替换，建议一并了解。
2. 点击 **Install** → 重启 IDEA。离线环境可从 `plugins.jetbrains.com` 下载 zip，再用 `Plugins → ⚙ → Install Plugin from Disk...` 安装。
3. 打开目标类，例如 `MedicalRecordController.java`，在 `sync` **方法名上右键** → `Arthas Command` → 选择 `Trace` / `Watch` / `Stack` / `Monitor` / `TT` / `Profiler`。
4. 按提示勾选 `--skipJDKMethod`、展开层级、条件表达式，插件会自动生成完整命令。
5. **复制生成的命令**，粘贴到 Arthas 控制台执行。

**注意：**IDEA 插件只负责**生成命令**，不负责连接服务器。生成后仍需到 Arthas 控制台粘贴执行。

备选：IDEA 自带 Terminal 里直接跑 as.sh；或安装 **Alibaba Cloud Toolkit** 插件，其内置 Arthas 面板可连接远程 host 执行。

### 1.10 性能与优化方向分析（报告主体）

报告按「**现象 → 证据 → 根因 → 方案 → 预期收益 → 风险**」六段写。先填采集信息表：

| 项目 | 填写内容 |
| --- | --- |
| 环境 / 医院 | 例：长桥医院 · 生产 · 容器 wisdom-sync |
| 采集时间窗 | 例：2026-09-21 10:20–10:26（覆盖一次完整同步） |
| 采集场景 | 例：住院病历同步 / 病程记录回写 / 病历生成 |
| 并发与数据量 | 例：单次同步 320 条医嘱、8 个科室并发拉取 |
| 采集命令 | `profiler start --event cpu --duration 60 --file /tmp/cpu.html` |
| JVM 参数 | `-Xms1024m -Xmx1024m`（来自 entrypoint.sh） |

#### 常见瓶颈与优化方向对照表

| 维度 | 火焰图 / 命令特征 | 本项目常见原因 | 优化方向 |
| --- | --- | --- | --- |
| **CPU** | 业务方法顶部宽块；`thread -n 5` 固定同一线程 | 大循环、字符串拼接、正则反复编译、JSON 深拷贝 | 批量化处理、`StringBuilder`、预编译正则、避免重复序列化大对象 |
| **等待** | wall 图 `socketRead` / `park` 宽 | HIS 库慢 SQL、magic-api 脚本执行慢、大模型 HTTP 等待 | 加索引 / 改 SQL、脚本逻辑精简、异步化、加超时与熔断降级 |
| **DB** | `druid getConnection` 宽；`thread -b` 有阻塞 | 连接池耗尽、慢查询、大批量单条 writes | 调 `maxActive` / `maxWait`、慢 SQL 治理、批量写、必要时读写分离 |
| **GC** | GC 线程占比高；`jvm` 显示 Full GC 频繁 | `-Xmx1024m` 偏小、临时大对象多 | 减少临时对象、适当调堆、评估 G1 / ZGC 参数 |
| **锁** | `thread -b` 命中；BLOCKED 堆栈集中 | 单例锁 / `synchronized` 粒度过粗、批次串行 | 缩小锁范围、无状态化、按患者/科室分片并行 |
| **序列化** | fastjson / jackson 调用宽 | 大 `medicalRecord` 反复 `toJSONString` | 只序列化必要字段、对象复用、避免日志里打全量 JSON |
| **同步吞吐** | `parallelFetching` 消费不均 | 医院接口串行 / 限流、失败重试放大 | 分批 + 并发度控制、失败隔离与重试退避 |

**报告结论的写法：**每条结论都要能对上证据 —— 「`thread -n 5` 显示 xxx 线程占用 78% CPU」→ 「火焰图显示 `MedicalRecordController.sync` 下 `magicAPIService.invoke` 占比 62%」→ 「根因：magic-api 脚本执行耗时」→ 「方案：脚本逻辑精简 + 结果缓存」→ 「预期：单次回写从 1.8s 降至 0.6s」→ 「风险：缓存需按医院/患者维度失效」。
### 1.11 周二验收清单

- 选定 1 家医院，抓 CPU 火焰图（≥30s）1 份
- 抓 wall 火焰图（≥60s，完整覆盖一次同步/回写）1 份
- 用 `thread -n 5` 与 `thread -b` 记录最忙线程与阻塞线程
- `trace` 至少 2 个接口，输出「每步耗时表」
- `watch` 观察 1 个正常方法的入参+返回值，1 个异常场景
- IDEA Arthas 插件安装完成，右键生成命令的截图 1 张
- 产出性能分析报告（含火焰图截图 + 热点表 + 优化建议 + 风险）

## 2周三 · tcpdump 抓包 + Wireshark 分析 HTTP 请求

### 2.1 先判断「在哪抓」

- **容器内抓（推荐）**：抓到的是容器网卡真实流量，最准确。
- **宿主机抓**：抓 `any` 或 `docker0`，需要 `sudo`。

```
# 找容器名与端口映射
docker ps | grep -i wisdom-sync
docker port <容器名>

# 宿主机上看谁在监听 48088
ss -lntp | grep 48088

# 容器内有没有 tcpdump（没有就先临时安装）
docker exec -it <容器名> which tcpdump
docker exec -it <容器名> bash -c 'apt-get update && apt-get install -y tcpdump'
```

### 2.2 tcpdump 命令

```
# 看有哪些网卡
tcpdump -D

# ① 抓本系统端口 48088 的全部流量，写文件给 Wireshark
docker exec -it <容器名> tcpdump -i any -s 0 -nn 'tcp port 48088' -w /tmp/cap-http.pcap

# ② 抓与 magic-api 主机之间的流量
docker exec -it <容器名> tcpdump -i any -s 0 -nn 'host 192.168.0.12 and tcp port 48080' -w /tmp/cap-magic.pcap

# ③ 控制台直接看 HTTP 明文（只抓 GET / POST 请求行）
docker exec -it <容器名> tcpdump -i any -s 0 -A -nn 'tcp port 48088 and (tcp[((tcp[12:1] & 0xf0) >> 2):4] = 0x47455420 or tcp[((tcp[12:1] & 0xf0) >> 2):4] = 0x504f5354)'

# ④ 抓满 100 个包自动停止（生产环境建议限制）
docker exec -it <容器名> tcpdump -i any -s 0 -nn -c 100 'tcp port 48088' -w /tmp/cap100.pcap

# ⑤ 宿主机抓（无权限进容器时）
sudo tcpdump -i any -s 0 -nn 'tcp port 48088' -w /tmp/cap-host.pcap
```

| 参数 | 作用 |
| --- | --- |
| `-i any` | 监听所有网卡（不确定走哪块网卡时用它） |
| `-s 0` | **抓完整包，必须加**。不加默认截断，HTTP body 会丢，Wireshark 里看不到 JSON |
| `-nn` | 不做域名 / 端口名解析，输出更快更直观 |
| `-w file.pcap` | 写二进制文件（给 Wireshark 用） |
| `-r file.pcap` | 读取已有文件 |
| `-A` | 以 ASCII 打印报文（控制台直接肉眼读 HTTP 明文） |
| `-c 100` | 抓满 100 个包自动停止（生产环境务必限制，避免文件暴涨） |

**四个易踩的坑：**
① `-s 0` 忘了加 → body 被截断，Wireshark 里看不到 JSON；
② 抓 `https/443` 只能看到加密内容，本系统内部调用多为 `http:48080/48088` 明文，可直接读；
③ 不加 `-c` 限制在生产环境可能几秒写出几个 G；
④ pcap 可能含患者隐私数据，用完及时删除、不要外传。
### 2.3 把 pcap 拷到本地

```
# 从容器拷到当前目录
docker cp <容器名>:/tmp/cap-http.pcap ./cap-http.pcap

# 用 Wireshark 打开
#   命令行启动（Windows 装了 Wireshark 时）
#   "C:\Program Files\Wireshark\Wireshark.exe" cap-http.pcap
```

### 2.4 Wireshark 分析步骤

1. 打开 pcap，顶部**显示过滤栏**输入 `http` → 只看 HTTP，屏蔽握手 / ACK 噪音。
2. 按 URL 精确定位目标请求（把下面表达式逐个试一遍）：

```
http
http.request.method == "POST"
http.request.uri contains "write_back"
http.request.uri contains "medical-record"
http.request.uri contains "third/sync"
http.response.code == 503
tcp.port == 48080
```

3. 选中一条请求包 → 右键 `Follow → HTTP Stream`，可看到**完整请求头 + 请求体 JSON + 响应体**。
4. 若包被识别成 TCP：右键该包 → `Decode As...` → 选 `HTTP`。
5. 统计视图：`Statistics → Conversations` 看会话；`Statistics → HTTP → Requests` 看请求列表与耗时。
6. 导出报文：`File → Export Objects → HTTP`。

### 2.5 截图要求（周三交付的核心证据）

| 序号 | 截图内容 | 要点 |
| --- | --- | --- |
| 1 | 过滤栏 `http` + 请求列表 | 能看到 URI 与响应码 |
| 2 | 目标请求的 **请求头 + 请求体 JSON** | 展开 HTTP 协议树，展示回写字段 |
| 3 | `Follow HTTP Stream` 的请求 / 响应对照 | 一张图讲清一次完整交互 |
| 4 | 响应状态码与响应体 | 例：200 同步成功 / 503 同步失败 |

**截图规范：**每张截图必须包含 Wireshark 顶部的**过滤表达式**，证明是按条件精确过滤的，而不是随便截一段流量。
### 2.6 周三验收清单

- 至少 1 个 pcap 文件，覆盖一次「页面回写 / 同步」请求
- Wireshark 过滤出本系统的 HTTP 请求并截图（含过滤表达式）
- 能说清：请求 URL、方法、请求体关键字段、响应码与响应体
- 形成一条抓包用例记录：操作 → 抓到的请求 → 结论

## 3周四 / 周五 · 住院回写时序图（飞书文档）

### 3.1 在飞书里怎么画

- 方式一（推荐）：飞书文档输入 `/` → 搜索 **代码块** → 语言选 **mermaid** → 粘贴下方源码，自动渲染成时序图。
- 方式二：输入 `/` → 选择飞书原生 **UML 图 / 时序图** 块，按本图结构手工添加参与者与消息。
- 方式三（保底）：用飞书**画板**手工拖拽绘制。

下面是每张图的**渲染效果**（可直接用于评审），以及对应 **Mermaid 源码**（折叠在每张图下方，点开即可复制到飞书）。
### 3.2 四张图

#### 图1 住院 · 内嵌（iframe） × 前端回写（jsCallback）

图1 住院·内嵌（iframe） × 前端回写（jsCallback）

医生

HIS 住院病历页

EMR 内嵌页(iframe)

EMR 后端 wisdom

magic-api:48080

主库 MySQL

打开患者住院病历

iframe 加载 EMR 页面(/editor.html)

生成 / 编辑病历内容

点击「回写」

POST /third/sync/doc {docId}

docInfoService.getInfo(docId)

invoke("/back/transfer", {docInfo})

该医院配置为「前端回写」模式：magic-api 不直接落 HIS 库，
而是返回一段 jsCallback 脚本交给 HIS 前端执行

BackReturnDTO{result:true, data.jsCallback:脚本}

updateDocSync() 记录同步ID + 更新统计

"jsCallback:<脚本>"

window.parent 执行 JS 脚本写值

病历字段回填成功

后端只返回脚本，**不直接落 HIS 库**。HIS 前端拿到 `jsCallback` 后在宿主页面执行写值 —— 这是「前端回写」的本质。
Mermaid 源码（点开复制）
```
sequenceDiagram
    autonumber
    participant D as 医生
    participant HIS as HIS 住院病历页
    participant EMR as EMR 内嵌页(iframe)
    participant B as EMR 后端 wisdom
    participant M as magic-api:48080
    participant DB as 主库 MySQL

    D->>HIS: 打开患者住院病历
    HIS->>EMR: iframe 加载 EMR 页面(/editor.html)
    D->>EMR: 生成 / 编辑病历内容
    D->>EMR: 点击「回写」
    EMR->>B: POST /third/sync/doc {docId}
    B->>B: docInfoService.getInfo(docId)
    B->>M: invoke("/back/transfer", {docInfo})
    Note over M: 前端回写模式：不落 HIS 库，返回脚本
    M-->>B: BackReturnDTO{result:true, data.jsCallback:脚本}
    B->>DB: updateDocSync() 记录同步ID + 更新统计
    B-->>EMR: "jsCallback:<脚本>"
    EMR->>HIS: window.parent 执行 JS 脚本写值
    HIS-->>D: 病历字段回填成功
```

#### 图2 住院 · 内嵌（iframe） × 后端回写（接口推送 PUSH\_SYNC）

图2 住院·内嵌（iframe） × 后端回写（接口推送 PUSH\_SYNC）

医生

HIS 住院病历页

EMR 内嵌页(iframe)

EMR 后端 wisdom

magic-api:48080

HIS 回写接口

主库 MySQL

打开患者住院病历

iframe 加载 EMR 页面

生成 / 编辑病历内容

点击「回写」

POST /medical-record/sync {medicalRecordId}

buildContent() 组装病历 + 变量 + 科室

invoke("/back/transfer/new", {medicalRecord, param})

「后端回写」模式：由后端直接调 HIS 提供的接口把数据写进去，
前端只负责发起与展示结果

HTTP POST 推送病历数据

返回写入记录ID

BackReturnDTO{result:true, recordSyncId}

syncCallback() 记录同步ID；病历数字签名

action = redirectTo / syncCompleted

提示回写完成 / 跳转 HIS 页面

后端直接调 magic-api → HIS 接口推送数据（**PUSH\_SYNC**），前端只负责发起和展示 `action` 结果。
Mermaid 源码（点开复制）
```
sequenceDiagram
    autonumber
    participant D as 医生
    participant HIS as HIS 住院病历页
    participant EMR as EMR 内嵌页(iframe)
    participant B as EMR 后端 wisdom
    participant M as magic-api:48080
    participant HAPI as HIS 回写接口
    participant DB as 主库 MySQL

    D->>HIS: 打开患者住院病历
    HIS->>EMR: iframe 加载 EMR 页面
    D->>EMR: 生成 / 编辑病历内容
    D->>EMR: 点击「回写」
    EMR->>B: POST /medical-record/sync {medicalRecordId}
    B->>B: buildContent() 组装病历 + 变量 + 科室
    B->>M: invoke("/back/transfer/new", {medicalRecord, param})
    Note over M: 后端回写模式：后端直接调 HIS 接口落数据
    M->>HAPI: HTTP POST 推送病历数据
    HAPI-->>M: 返回写入记录ID
    M-->>B: BackReturnDTO{result:true, recordSyncId}
    B->>DB: syncCallback() 记录同步ID；病历数字签名
    B-->>EMR: action = redirectTo / syncCompleted
    EMR-->>D: 提示回写完成 / 跳转 HIS
```

#### 图3 住院 · 悬浮窗 × 前端回写（jsCallback）

图3 住院·悬浮窗 × 前端回写（jsCallback）

医生

HIS 住院病历页

EMR 悬浮助手窗

EMR 后端 wisdom

magic-api:48080

主库 MySQL

打开患者住院病历

打开浮动助手窗（携带患者上下文）

生成 / 编辑病历内容

点击「回写」

POST /third/sync/doc {docId}

docInfoService.getInfo(docId)

invoke("/back/transfer", {docInfo})

「前端回写」模式：后端只返回 jsCallback 脚本，
由悬浮窗把脚本投递到 HIS 主页面执行写值

BackReturnDTO{result:true, data.jsCallback:脚本}

updateDocSync() 记录同步ID

"jsCallback:<脚本>"

postMessage / window.opener 执行脚本

病历字段回填成功

与图 1 的回写机制完全一致，差别只在载体：悬浮窗通过 `postMessage` / `window.opener` 把脚本投递给 HIS 主页面。
Mermaid 源码（点开复制）
```
sequenceDiagram
    autonumber
    participant D as 医生
    participant HIS as HIS 住院病历页
    participant WIN as EMR 悬浮助手窗
    participant B as EMR 后端 wisdom
    participant M as magic-api:48080
    participant DB as 主库 MySQL

    D->>HIS: 打开患者住院病历
    HIS->>WIN: 打开浮动助手窗(携带患者上下文)
    D->>WIN: 生成 / 编辑病历内容
    D->>WIN: 点击「回写」
    WIN->>B: POST /third/sync/doc {docId}
    B->>B: docInfoService.getInfo(docId)
    B->>M: invoke("/back/transfer", {docInfo})
    Note over M: 前端回写模式：返回 jsCallback 脚本
    M-->>B: BackReturnDTO{result:true, data.jsCallback:脚本}
    B->>DB: updateDocSync() 记录同步ID
    B-->>WIN: "jsCallback:<脚本>"
    WIN->>HIS: postMessage / window.opener 执行脚本
    HIS-->>D: 病历字段回填成功
```

#### 图4 住院 · 悬浮窗 × 后端回写（接口推送）

图4 住院·悬浮窗 × 后端回写（接口推送）

医生

HIS 住院病历页

EMR 悬浮助手窗

EMR 后端 wisdom

magic-api:48080

HIS 回写接口

主库 MySQL

打开患者住院病历

打开浮动助手窗（携带患者上下文）

生成 / 编辑病历内容

点击「回写」

POST /medical-record/sync {medicalRecordId}

buildContent() 组装病历 + 变量

invoke("/back/transfer/new", {medicalRecord, param})

「后端回写」模式：后端调 magic-api → HIS 接口，
直接把数据写进 HIS，悬浮窗只负责发起与提示

HTTP POST 推送病历数据

返回写入记录ID

BackReturnDTO{result:true, recordSyncId}

syncCallback() 记录同步ID

action = syncCompleted

postMessage 通知 HIS 刷新

病历已回写

与图 2 的回写机制完全一致，悬浮窗额外需要 `postMessage` 通知 HIS 刷新页面。
Mermaid 源码（点开复制）
```
sequenceDiagram
    autonumber
    participant D as 医生
    participant HIS as HIS 住院病历页
    participant WIN as EMR 悬浮助手窗
    participant B as EMR 后端 wisdom
    participant M as magic-api:48080
    participant HAPI as HIS 回写接口
    participant DB as 主库 MySQL

    D->>HIS: 打开患者住院病历
    HIS->>WIN: 打开浮动助手窗(携带患者上下文)
    D->>WIN: 生成 / 编辑病历内容
    D->>WIN: 点击「回写」
    WIN->>B: POST /medical-record/sync {medicalRecordId}
    B->>B: buildContent() 组装病历 + 变量
    B->>M: invoke("/back/transfer/new", {medicalRecord, param})
    Note over M: 后端回写模式：后端直接调 HIS 接口落数据
    M->>HAPI: HTTP POST 推送病历数据
    HAPI-->>M: 返回写入记录ID
    M-->>B: BackReturnDTO{result:true, recordSyncId}
    B->>DB: syncCallback() 记录同步ID
    B-->>WIN: action = syncCompleted
    WIN->>HIS: postMessage 通知 HIS 刷新
    HIS-->>D: 病历已回写
```

### 3.3 四种组合的差异（写进飞书文档的说明段）

#### 载体差异：内嵌 vs 悬浮窗

| 对比项 | 内嵌（iframe） | 悬浮窗 |
| --- | --- | --- |
| 载体 | HIS 病历页内的 iframe，随页面布局与刷新 | 独立浮动窗口，覆盖在 HIS 之上 |
| 与 HIS 通信 | `window.parent` / `postMessage` | `window.opener` / `postMessage` |
| 患者上下文 | 随页面参数自动带入 | 需在打开时显式携带、并自行保持同步 |

#### 回写机制差异：前端回写 vs 后端回写

| 对比项 | 前端回写（jsCallback） | 后端回写（接口推送） |
| --- | --- | --- |
| 代码入口 | `POST /third/sync/doc` → `ThirdSyncServiceImpl.sync()` | `POST /medical-record/sync` → `MedicalRecordController.sync()` |
| magic-api 脚本 | `/back/transfer` | `/back/transfer/new` |
| 落数据方 | HIS 前端执行脚本写入表单字段 | 后端调 HIS 接口写入 HIS |
| 返回标识 | 字符串 `"jsCallback:<脚本>"` | `BackReturnDTO{action, recordSyncId}` |
| 适用场景 | HIS 不允许后端直连库，只能由前端落值 | HIS 提供标准回写接口 |
| 排查要点 | 脚本是否被 HIS 前端正确执行（浏览器控制台看报错） | `syncCallback` 是否记录到 `recordSyncId`、签名是否成功 |

### 3.4 周四 / 周五验收清单

- 飞书文档建好，含 4 张时序图（内嵌/悬浮窗 × 前端/后端回写）
- 每张图标注清楚：参与者、请求接口、返回标识
- 补齐「载体差异」「回写机制差异」两张对照表
- 文档中附上对应代码位置（类名 + 方法名 + 接口路径）

## 4附录 · 速查

### 关键地址 / 路径

| 项 | 值 |
| --- | --- |
| 同步服务端口（容器内） | `48088` |
| magic-api 控制台 | `http://192.168.0.12:48080` |
| Arthas 目录（容器内） | `/opt/arthas`（as.sh / arthas-boot.jar / async-profiler） |
| Arthas 端口 | telnet `3658` · http `8563` |
| 配置文件（容器内） | `/emr-wisdom-sync/conf/application.yml` |
| 日志 / 堆转储目录（容器内） | `/emr-wisdom-sync/logs` · `/emr-wisdom-sync/data` |

### Arthas 命令速查

| 命令 | 用途 |
| --- | --- |
| `profiler start --event cpu --duration 30 --file /tmp/cpu.html` | 抓 CPU 火焰图，30 秒自动结束 |
| `profiler start --event wall --duration 60 --file /tmp/wall.html` | 抓墙钟火焰图（含等待/IO） |
| `profiler list` / `profiler status` / `profiler stop` | 可用事件 / 当前状态 / 手动停止 |
| `thread -n 5` / `thread -b` | 最忙线程 / 阻塞线程 |
| `trace -n 5 <类> <方法>` | 追踪调用链与每层耗时 |
| `trace <类> <方法> '#cost > 100'` | 只看耗时超过 100ms 的调用 |
| `watch <类> <方法> '{params, returnObj}' -x 2` | 看入参与返回值 |
| `watch <类> <方法> '{params, throwExp}' -e -x 2` | 只在抛异常时观察 |
| `stack <类> <方法>` | 反查该方法被谁调用 |
| `tt -t <类> <方法>` / `tt -i 1000 -p` | 记录调用现场 / 事后重放 |
| `monitor -c 5 <类> <方法>` | 每 5 秒统计 QPS / RT / 成功率 |
| `jad <类全名>` | 反编译，确认线上跑的真实代码 |

### tcpdump 速查

| 命令 | 用途 |
| --- | --- |
| `tcpdump -D` | 列出可用网卡 |
| `tcpdump -i any -s 0 -nn 'tcp port 48088' -w /tmp/cap.pcap` | 抓应用端口全部流量 |
| `tcpdump -i any -s 0 -nn 'host 192.168.0.12' -w /tmp/cap.pcap` | 抓与指定主机之间的流量 |
| `tcpdump -i any -s 0 -A -nn 'tcp port 48088'` | 控制台直接看 HTTP 明文 |
| `tcpdump -i any -s 0 -nn -c 100 'tcp port 48088' -w /tmp/cap100.pcap` | 抓满 100 个包停止 |

### Wireshark 显示过滤器速查

| 过滤器 | 用途 |
| --- | --- |
| `http` | 只看 HTTP |
| `http.request.method == "POST"` | 只看 POST 请求 |
| `http.request.uri contains "write_back"` | 定位病历回写请求 |
| `http.request.uri contains "medical-record"` | 定位病历同步请求 |
| `http.request.uri contains "third/sync"` | 定位第三方同步回写请求 |
| `http.response.code == 503` | 只看失败响应 |
| `tcp.port == 48080` | 只看 magic-api 的 TCP 流 |

本手册基于 `ejet-emr-wisdom` / `ejet-emr-sync` 实际代码与部署配置整理，命令可直接在对应环境执行。

生成于 2026-09-16 · 供实施交付内训使用
