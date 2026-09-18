---
layout: post
title: "没有 AI 怎么自己一步步排障：现场工程师的方法论"
date: 2026-09-17 12:00:00 +0800
categories: [排障手记]
tags: [方法论, 排障, 实施工程师]
---

<!--more-->

目标：不依赖任何 AI，独立完成「连服务器 → 定位代码 → Arthas 诊断 → 出结论」全流程。所有命令都来自你自己的项目（ejet-emr-sync / emr-wisdom-sync），照抄即可跑通。

## 第 0 步：先记住三个「查询入口」，没有 AI 全靠它们

| 不知道什么 | 去哪查 | 怎么查 |
| --- | --- | --- |
| 服务器/账号/密码/仓库地址 | 《研发快速入门.docx》 | 文档里搜「Gitlab」「测试用主机」「数据库」 |
| 命令怎么用 | 官方文档 | Arthas：`arthas.aliyun.com/doc`（命令页都有在线演示）；tcpdump/wireshark 搜「命令名 + cheat sheet」 |
| 代码里谁调用了谁 | IDEA | 双击 Shift 搜类名；Ctrl+B 看实现；Ctrl+Alt+H 看调用链（比 AI 猜的准） |
| 报错什么意思 | 报错信息本身 | 把报错**最后一段 Caused by** 拿去搜——90% 的坑前人都踩过 |

## 第 1 步：拿到源码（一次性）

1. 打开 Git Bash（开始菜单搜 Git Bash），执行：

```bash
cd /d/003
git clone http://47.117.87.252:8080/yiliao/ejet-emr-sync.git
```

（公司 GitLab 的 HTTP 地址当前匿名可拉；如果以后要推代码，找管理员把自己的 SSH 公钥加到 GitLab → User Settings → SSH Keys）

2. IDEA → File → Open → 选 `D:\003\ejet-emr-sync`，等索引跑完。

💡 以后更新代码只需在项目目录执行 `git pull`。
## 第 2 步：连上服务器（Xshell，你已装）

1. 开始菜单搜 **Xshell** → 新建会话：主机 `58.246.216.6`，端口 `4322`
2. 连接 → 输入用户名 `root`、密码（研发档案里「测试用主机 amd64」那条）→ 保存会话，以后双击进
3. 进去先做体检三连（每次都做，养成习惯）：

```bash
uptime          # 负载
docker ps       # 容器状态
df -h           # 磁盘
```

| 命令 | 看什么 | 正常的样子 |
| --- | --- | --- |
| `uptime` | 负载 | load 远小于核数（这台 40 核） |
| `docker ps` | 容器列表 | 能看到 `emr-wisdom-sync` 且 STATUS 是 Up |
| `df -h` | 磁盘 | 使用率 < 85% |

## 第 3 步：进 Arthas（背下来这 3 条）

```bash
# 进 Arthas（数字 1 是容器里的 java 进程号）
docker exec -it emr-wisdom-sync java -jar /opt/arthas/arthas-boot.jar 1

# 退出并回收增强
stop
```

进去后是 `[arthas@1]$` 提示符。常用导航命令：`dashboard` 总览、`thread -n 5` 最忙线程、`sc -d 类名` 查类是否被加载（找不到类时先验证这个）、`help` 全部命令、`stop` 退出并回收。

⚠️ 用完一定 `stop`：trace/watch/profiler 都是字节码增强，挂着不退出会一直耗性能。
## 第 4 步：找到「该对哪个方法下命令」

没有 AI 替你读代码，用 IDEA 三板斧：

| 场景 | 操作 | 例子 |
| --- | --- | --- |
| 知道 URL，找处理方法 | IDEA 里 Ctrl+Shift+F 全局搜 URL 片段 | 搜 `process/inpatient` → 命中 `ProcessController` |
| 知道功能名，找类 | 双击 Shift 搜中文注释/类名关键词 | 搜 `inpatient` → 出一堆 Synchronizer |
| 知道方法，想知道谁调用它/它调用了谁 | 光标放方法名上：Ctrl+Alt+H（调用链）/ Ctrl+B（跳实现） | 看 `process()` 内部调了 `StaffService.list()` |
| 线上没有源码对照（版本不确定） | Arthas 里 `jad 类名` 反编译线上版本 | 我就是这么发现线上实体多了 4 个字段的 |

## 第 5 步：用插件生成命令（不用背语法）

1. 光标停在方法名上 → 右键 → **Arthas Command** → Watch / Trace / …
2. 命令已进剪贴板 → 粘贴到 Xshell 的 arthas 提示符后回车
3. 命令模板（也可手敲，就这三个形状）：

```bash
# watch：看出入参/返回/异常（-x 展开层级，-n 执行次数）
watch 全类名 方法名 '{params, returnObj, throwExp}' -x 2 -n 3

# trace：看逐层耗时（'#cost > 100' 只记慢调用）
trace 全类名 方法名 '#cost > 100' -n 3 --skipJDKMethod true

# 火焰图（60 秒后自动停，产物是可交互 HTML）
profiler start --event cpu --duration 60 --file /tmp/cap-cpu.html
```
## 第 6 步：触发业务，让命令有数据可抓

Arthas 命令是「钓鱼」，业务不跑就钓不到。再开一个 Xshell 标签（Shift+Ctrl+T）触发：

```bash
# 另开标签，触发住院同步（Arthas 那边别关）
curl http://localhost:48088/process/inpatient
```
## 第 7 步：读结果（判断力，AI 替代不了的部分）

### trace 树怎么读

- 根节点 `[373ms] process()` = 这轮总耗时；找**百分比最大的一层**下钻
- `#84` = 源码第 84 行，回 IDEA 看那行在干嘛
- 各层加起来 ≪ 根节点 → 大头在别的线程（并行流/异步），换 `profiler start --event wall` 抓火焰图

### watch 输出怎么读

- `location=AtExit` 正常返回 / `AtExceptionExit` 抛了异常（重点看 throwExp）
- `cost=xx ms` = 这次调用耗时；`@ArrayList[...] -x 2` 展开层级
- 打印出 `null` 不一定是错——void 方法返回值就是 null

### 火焰图怎么读（三步）

- ① 看最宽的塔（横向宽度 = CPU/时间占比）② 点它看方法名 ③ 搜索可疑关键词（如 `parse`、`selectList`、`error`）

## 第 8 步：产物落地

```bash
# Arthas 里导出会话/文件
cat /tmp/trace-output.txt     # 批处理产物查看
# 容器 → 宿主机
docker cp emr-wisdom-sync:/tmp/cap-cpu.html /tmp/
```

火焰图 HTML 用 Xshell 的文件传输（new Xftp / 直接拖文件到会话窗口）拉回本机，浏览器打开即可交互。

## 报错自查对照表（无 AI 时代的主要救生圈）

| 报错/现象 | 原因 | 自己怎么解 |
| --- | --- | --- |
| `Connection refused / 48088 CLOSED` | 应用没起来 | `docker ps` 看 STATUS；看日志尾部找 `Application run failed`，读 Caused by |
| `method not found / no class affected` | 类名/方法名拼错，或线上版本不同 | `sc -d 全类名` 确认类存在；`jad` 反编译确认方法存在；核对包名大小写 |
| 命令敲完没输出 | 业务没被触发，或条件不满足 | 另开窗口 curl 触发；检查 `#cost>阈值` 是否设太高 |
| `Permission denied (publickey)` | SSH 密钥没授权 | 改用 HTTP 地址拉代码；推代码找管理员加公钥 |
| SQL 报 `Unknown column` | 代码版本 > 库表结构 | 对照实体类字段，`ALTER TABLE ... ADD COLUMN` 补列（测试库可做，生产找 DBA） |
| `sh: syntax error` | 引号嵌套被 shell 吃掉 | 交互式直接进 arthas 再粘贴命令，不要套 `sh -c "..."` 双层引号 |
| trace 挂着不返回 | 没加 `-n` | 交互模式按 Q；以后命令都带 `-n 次数` |

## 真正卡住了：怎么正确求助（同事/AI 通用）

✅ 模板：「我在 **什么环境**（测试机 emr-wisdom-sync 容器），执行了 **什么命令**（原样贴），得到 **什么报错**（贴最后一段 Caused by），我期望 **什么结果**，我已经试过 **什么**。」——带上这五要素，任何人都能 5 分钟内帮你解决；缺一项就是半小时起步。
## 把今天的手法固化成肌肉记忆（一周训练计划）

| 天 | 只练一件事 | 达标标准 |
| --- | --- | --- |
| 周一 | Xshell 连服务器 + 体检三连 + 进出 Arthas | 不看笔记 2 分钟内进到 `[arthas@1]$` |
| 周二 | IDEA 搜代码 → 右键插件生成 watch → 粘贴执行 | 对任意 Controller 方法抓到一次出入参 |
| 周三 | trace 一条你负责的同步链路并读树 | 能说出最大耗时在哪一层、对应源码哪一行 |
| 周四 | 火焰图抓一次（cpu + wall 各一遍） | 能找到最宽的塔并说出方法名 |
| 周五 | 故意制造一个报错，用对照表自查解决 | 不问人独立解决 |

配套：《Arthas插件与trace-watch实战教程.html》《性能分析报告-Arthas火焰图.html》｜ 2026-09-16
