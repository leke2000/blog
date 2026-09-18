---
layout: post
title: "Arthas IDEA 插件 + trace/watch 命令实战教程"
date: 2026-09-17 00:00:00 +0800
categories: [排障手记]
tags: [Arthas, IDEA插件, trace, watch]
---

<!--more-->

2026-09-16目标系统：`emr-wisdom-sync`（上海研发测试机 58.246.216.6:4322 → 内网 192.168.0.148，容器 `emr-wisdom-sync`，Arthas 4.0.5）
本文所有输出均为**今日现场真实抓取**，非模拟数据。

## 0. 本次完成清单

| 事项 | 结果 |
| --- | --- |
| 公司仓库克隆 | ✅ 已克隆到 `D:\003\ejet-emr-sync`（master @ 9304e06，797 个提交，最新功能：患者加密 magicApi 支持）。HTTP 匿名可拉：`http://47.117.87.252:8080/yiliao/ejet-emr-sync.git` |
| IDEA Arthas Idea 插件 | ✅ **已装好，无需安装**——arthas idea **v2.52** 已在你的 IDEA 2023.2 插件目录（支持右键生成命令，见第 2 节） |
| trace 命令实操 | ✅ 抓到住院同步主流程完整调用树（373.57ms 逐层耗时），见第 3 节 |
| watch 命令实操 | ✅ 4 个场景全跑通：入参/返回值/异常观察、`-b` 前置观察、抓真实异常对象、条件过滤，见第 4 节 |

💡 版本提示：仓库 master 分支的 `InspectionItemLibrary` 实体还没有 his\_code 等新字段，而容器镜像里有——说明**测试环境镜像来自特性分支**（如 `feat-inspectLibraryRefactor-20260318`）。用 Arthas Idea 插件对 IDEA 里的 master 源码生成命令时，若线上报 `method not found`，先确认线上跑的是哪个分支。
## 1. 仓库与环境的对应关系

| 东西 | 位置 |
| --- | --- |
| 公司仓库（GitLab） | `git@47.117.87.252:yiliao/ejet-emr-sync.git`（SSH 需授权密钥） HTTP：`http://47.117.87.252:8080/yiliao/ejet-emr-sync.git`（当前匿名可拉） |
| 本地最新源码 | `D:\003\ejet-emr-sync`（今日克隆，用它打开 IDEA） |
| 旧快照源码 | `D:\003\ejet-emr-sync-master`（与最新差 413 个文件，仅存档用） |
| 运行中的应用 | 测试机容器 `emr-wisdom-sync`，端口 48088，Arthas 在镜像内 `/opt/arthas` |

## 2. Arthas Idea 插件（v2.52）怎么用

插件已装好（IDEA 2023.2 插件目录下 `arthas-idea-plugin`）。核心价值：**在 IDEA 里对着方法点右键，自动生成拼好类名/方法名/表达式的 Arthas 命令**，不用手敲超长的全限定类名。

### 2.1 标准用法（四步）

1. IDEA 打开 `D:\003\ejet-emr-sync`，找到目标方法，如 `ejet-application/.../processor/InpatientOrderProcessor.java` 的 `process()`
2. 光标停在**方法名**上 → 右键 → **Arthas Command** → 选择：**Watch** / **Trace** / **TimeTunnel(tt)** / **Monitor** / **Stack**…
3. 命令已复制到剪贴板（形如 `watch com.ejet.app.processor.InpatientOrderProcessor process '{params,returnObj,throwExp}' -x 3 -n 5 -w 500`）
4. 粘贴到服务器上的 Arthas 会话：`ssh root@58.246.216.6 -p4322` → `docker exec -it emr-wisdom-sync java -jar /opt/arthas/arthas-boot.jar 1` → 粘贴回车

### 2.2 常用右键菜单项对照

| 菜单项 | 生成的命令 | 什么时候用 |
| --- | --- | --- |
| Watch | `watch ... '{params,returnObj,throwExp}'` | 看方法的输入输出和异常 |
| Trace | `trace ... method` | 排查"这个方法为什么慢"，逐层耗时 |
| TimeTunnel (tt) | `tt -t ... method` | 录制每次调用，事后回放（watch 错过时机也能补看） |
| Stack | `stack ... method` | "这个方法是谁调的"，看调用来源 |
| Monitor | `monitor -c 10 ...` | 统计 10 秒内调用次数/成功率/平均耗时 |

✅ 实用组合：先 **Trace** 找出最慢的一层 → 对那一层的方法 **Watch** 看出入参返回值 → 还要更深就再 Trace 下一层。今天第 3、4 节的演示就是这个打法。
## 3. trace 实战：住院同步主流程调用树

### 3.1 命令

```bash
docker exec -it emr-wisdom-sync java -jar /opt/arthas/arthas-boot.jar 1
```
```bash
trace com.ejet.app.processor.InpatientOrderProcessor process '#cost > 100' -n 1 --skipJDKMethod true
```

参数解读：`'#cost > 100'` = 只记录整体耗时超 100ms 的调用（过滤噪音）；`-n 1` = 匹配 1 次后自动退出（**生产必加**，否则一直挂着重耗 CPU）；`--skipJDKMethod true` = 不显示 JDK 内部方法，树更干净。触发方式：另开窗口 `curl http://localhost:48088/process/inpatient`。

### 3.2 真实输出（2026-09-16 16:01 抓取）

```
[arthas@1]$ trace com.ejet.app.processor.InpatientOrderProcessor process '#cost > 100' -n 1 --skipJDKMethod true
Affect(class count: 1 , method count: 1) cost in 233 ms, listenerId: 1
`---ts=2026-09-16 16:01:31.703;thread_name=http-nio-48088-exec-6;id=46;is_daemon=true;priority=5
    `---[373.568793ms] com.ejet.app.processor.InpatientOrderProcessor:process()
        +---[0.04% 0.130883ms ] org.slf4j.Logger:info() #69
        +---[0.98% 3.651335ms ] com.ejet.dao.service.SyncFunctionService:getSyncFunctions() #73
        +---[4.70% 17.565555ms ] com.ejet.dao.service.StaffService:list() #84
        +---[0.01% 0.026897ms ] com.ejet.dao.service...CollectionUtils:isNotEmpty() #85
        +---[0.97% 3.637874ms ] com.ejet.dao.service.SystemDeptService:findOpening() #93
        +---[0.19% 0.717048ms ] com.ejet.utils.ElapsedHelper:log() #103
        `---[0.02% 0.068532ms ] org.slf4j.Logger:info() #105
```
### 3.3 怎么读这棵树

| 读法 | 结论 |
| --- | --- |
| 根节点 `[373.57ms] process()` | 这轮住院同步总共 373.57ms |
| 最宽的一层：`StaffService:list() 17.57ms (4.7%)` | 主线程里员工全量查询是最大头 |
| `#84` 这种行号 | 调用发生在源码第 84 行——直接去 IDEA 对应行看上下文 |
| 各层加起来只有 ~26ms，根却是 373ms | **差额 ≈ 347ms 在并行流/ForkJoin 子线程里**（trace 默认只追当前线程）。想看子线程，改用火焰图（profiler）或给 ForkJoin 线程单独 trace。这正是昨天火焰图分析发现"主体耗时在并行同步器"的原因 |

### 3.4 trace 常用变体

```bash
# 深挖某一层：trace 到 StaffService.list 内部
trace com.ejet.dao.service.impl.StaffServiceImpl list -n 3 --skipJDKMethod true

# 只关心异常路径：-E 支持正则匹配多个方法
trace com.ejet.app.processor.InpatientOrderProcessor *rocess -n 3

# 找出哪些调用抛了异常
trace com.ejet.app.processor.InpatientOrderProcessor process -n 3 --skipJDKMethod true | grep -B 3 -A 10 'throw'
```
## 4. watch 实战：四个场景

### 4.1 场景一：入参 + 返回值 + 异常一把抓（最常用）

```bash
watch com.ejet.app.controller.ProcessController processInpatient '&#123;params, returnObj, throwExp&#125;' -x 2 -n 1
```
```
[arthas@1]$ watch com.ejet.app.controller.ProcessController processInpatient '&#123;params, returnObj, throwExp&#125;' -x 2 -n 1
Affect(class count: 1 , method count: 1) cost in 102 ms, listenerId: 2
method=com.ejet.app.controller.ProcessController.processInpatient location=AtExit
ts=2026-09-16 16:01:51.619; [cost=336.759568ms] result=@ArrayList[
    @Object[][isEmpty=true;size=0],   ← 入参：无参方法，空数组
    null,                              ← 返回值：void 方法返回 null
    null,                              ← 异常：本次调用没有抛异常
]
```

`-x 2` = 结果展开两层；输出里 `location=AtExit` 表示方法**正常返回后**触发。本次：无参、void 返回、无异常、耗时 336.76ms。

### 4.2 场景二：-b 进入方法前看入参（还没执行就能看）

```bash
watch com.ejet.app.controller.ProcessController processInpatient '&#123;params&#125;' -b -x 2 -n 1
```
```
method=...processInpatient location=AtEnter
ts=2026-09-16 16:02:08.658; [cost=0.113711ms] result=@ArrayList[
    @Object[][isEmpty=true;size=0],
]
```

四个触发时机：`-b` 进入时(AtEnter) ｜ 默认 正常返回时(AtExit) ｜ `-e` 抛异常时(AtExceptionExit) ｜ `-s`/`-f` 结束时(AtStepExit)。排查"参数传进来就被改坏"用 `-b`。

### 4.3 场景三：现场抓异常对象（今天的高光时刻）

目标：`InfraApiErrorLogServiceImpl#log(Map params, String requestUrl, Exception e)`——错误日志服务，第三个参数就是异常本身。用下标取参并截断长文本：

```bash
watch com.ejet.dao.service.impl.InfraApiErrorLogServiceImpl log '&#123;params[1], params[2].toString().substring(0,160)&#125;' -x 1 -n 2
```
```
[arthas@1]$ watch com.ejet.dao.service.impl.InfraApiErrorLogServiceImpl log '&#123;params[1], params[2].toString().substring(0,160)&#125;' -x 1 -n 2
（同步进行中，错误日志服务被调用，现场抓到异常对象）
result=@ArrayList[
    @String[InpatientOrderProcessor.processByDepartment],        ← requestUrl 参数
    @String[org.ssssssss.script.exception.MagicScriptException:
            PreparedStatementCallback; bad SQL grammar
            [select * from v_inpatient_visit where DEPARTMENT_NO =? and (DISC...]]
]
```
✅ 价值：不用翻几十万行日志，watch 直接把 **Exception 对象**捞出来——嘉兴数据源缺 `v_inpatient_visit` 视图导致每科室每轮抛 `MagicScriptException(bad SQL grammar)` 的证据链就此坐实。这就是昨天性能报告里 P0 问题的现场实录。
### 4.4 场景四：条件表达式——只在满足条件时打印

```bash
watch com.ejet.app.controller.ProcessController processInpatient '&#123;params, returnObj&#125;' '#cost > 400' -x 2 -n 1
```

本次运行输出为空——因为这一轮只有 336ms，没超 400ms 阈值，条件不满足就不打印。**输出为空本身就是一个有效结论**：可用于"线上偶发慢请求"的钓鱼式捕获，把阈值设高些（如 `#cost > 2000`）挂着，只等慢的。

### 4.5 watch 表达式(OGNL)常用写法

| 表达式 | 含义 |
| --- | --- |
| `{params, returnObj, throwExp}` | 入参数组 / 返回值 / 异常 |
| `params[0]` / `params[0].name` | 第 1 个参数 / 取其字段 |
| `{#cost > 200, returnObj.size()}` | 耗时判断 / 集合大小 |
| `@com.ejet.utils.ElapsedHelper@xxx` | 调用静态方法（慎用） |
| `target.fieldName` | 看当前对象的成员变量 |

## 5. 今天踩过的坑（记下来能省 1 小时）

⚠️ **Shell 引号嵌套**：在 `docker exec ... sh -c "java -jar ... -c '命令'"` 里再包一层单引号会直接把命令切碎（OGNL 解析报错 / `sh: syntax error`）。批量执行时把命令 **base64 编码**再在容器内解码最稳：`-c "$(echo xxx | base64 -d)"`。
⚠️ **忘了 -n**：trace/watch 不加 `-n` 会一直挂着（交互模式按 Q 退出，批处理模式直接卡死脚本）。生产环境务必加 `-n 次数`。
⚠️ **条件不满足 = 无输出**：别急着以为命令错了，先确认业务真的被触发、阈值是否设得太高（见 4.4）。
⚠️ **trace 看不到并行流子线程**：各层耗时加起来远小于根节点耗时 = 大头在别的线程，换火焰图 `profiler start --event wall`。
## 6. 速查：本次涉及的完整命令链

```bash
# 1. 连测试机
ssh root@58.246.216.6 -p 4322        # 密码 Ejet@2026

# 2. 进 Arthas（交互模式）
docker exec -it emr-wisdom-sync java -jar /opt/arthas/arthas-boot.jar 1

# 3. 常驻监控
dashboard                            # 总览 CPU/内存/线程
thread -n 5                          # 最忙的 5 个线程

# 4. trace / watch（命令可用 IDEA 插件右键生成）
trace com.ejet.app.processor.InpatientOrderProcessor process '#cost > 100' -n 1 --skipJDKMethod true
watch com.ejet.app.controller.ProcessController processInpatient '&#123;params, returnObj, throwExp&#125;' -x 2 -n 1
watch com.ejet.dao.service.impl.InfraApiErrorLogServiceImpl log '&#123;params[1], params[2].toString().substring(0,160)&#125;' -x 1 -n 2

# 5. 触发住院同步（另开窗口）
curl http://localhost:48088/process/inpatient

# 6. 用完回收
stop                                 # 退出并卸载所有增强
```

配套材料：《性能分析报告-Arthas火焰图.html》《EMR同步-周任务执行手册.html》｜ 原始输出：trace-watch-demo-raw.txt ｜ 生成于 2026-09-16
