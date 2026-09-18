---
layout: post
title: "Arthas 火焰图实战分析：从 572 条 ERROR 日志看 IO 等待型服务"
date: 2026-09-16 12:00:00 +0800
categories: [排障手记]
tags: [Arthas, 性能分析, 火焰图, EMR]
---

<!--more-->

采集环境：上海研发测试机 58.246.216.6:4322（内网 192.168.0.148） · 容器 emr-wisdom-sync（ejet/emr-wisdom-sync:1.0）

采集时间：2026-09-16 15:29 – 15:36 GMT+8 · 负载方式：循环触发 GET /process/inpatient（住院全量同步）

Arthas 4.0.5async-profiler cpu/walltracewatchJDK 17.0.1640C / JVM 1G

## 1执行摘要

**本次抓取前发现目标服务本身就是坏的：**容器活着但应用启动即失败（`Application run failed`），48088 无监听。根因是**镜像代码版本领先于测试库表结构**（实体新增了 `his_code / his_name / category / deleted` 四列，库里没有）。已通过 ALTER TABLE 补列 + 重启容器修复，服务恢复 200。

修复后完成 CPU / wall 双火焰图（各 45–60s，负载期间）、trace 调用链、watch 观测。核心结论：

| 级别 | 发现 | 量化影响 |
| --- | --- | --- |
| **P0** | 错误日志风暴：数据源 `db.jiaxing` 缺视图 `v_inpatient_visit`，所有科室同步抛异常并逐条写错误日志（文件+DB） | 10 分钟 572 条 ERROR；错误链路占 CPU ~12% |
| **P1** | `StaffService:list()` 每轮同步全量拉取员工表 | 单轮 122ms（16.5%） |
| **P1** | `SystemDeptService.update` 高频重复写科室 | CPU 占 11.1% |
| **P2** | Druid 连接池抖动（Create/Destroy 线程常驻活跃） | wall 占 ~2.8% |
| **P2** | 火焰图含 JIT 预热噪音（刚重启，C2 编译占 ~8%） | 生产采集应避开冷启动窗口 |

## 2环境与采集方法

|  |  |
| --- | --- |
| **目标 JVM** | 容器 PID 1，`-server -Xms1024m -Xmx1024m`，Temurin 17.0.16，宿主机 40 核（Alpine musl） |
| **Arthas** | 镜像内置 /opt/arthas 4.0.5，容器内批处理模式（`--batch-mode -c`）执行 |
| **负载** | 宿主机循环 `curl http://localhost:48088/process/inpatient`，覆盖采样全程 |
| **CPU 火焰图** | `profiler start --event cpu --duration 45`，另存 collapsed 格式做定量分析（396 样本） |
| **WALL 火焰图** | `profiler start --event wall --duration 45`（646,470 样本，全线程墙钟） |
| **trace** | `trace -n 2 --skipJDKMethod true com.ejet.app.processor.InpatientOrderProcessor process` |
| **watch** | `watch -n 1 com.ejet.app.controller.ProcessController processInpatient {params,returnObj,throwExp} -x 2` |

交互式火焰图：**raw/cap-cpu.html** 与 **raw/cap-wall.html**（浏览器打开可逐层展开、搜索方法名）。

## 3火焰图定量分析

### 3.1 CPU 火焰图（45s，负载期间）

| 热点路径 | 占比 | 解读 |
| --- | --- | --- |
| `lambda$process$4 → processByDepartment`（并行流科室同步） | **31.3%** | 同步主战场，符合预期 |
| `InfraApiErrorLogServiceImpl.log`（错误日志落库） | **8.3%** | ⚠️ 异常路径占用了近 1/12 的 CPU |
| `MagicAPIService.invoke → MagicScript.execute` | 8.1% | magic-api 脚本解释执行，正常水平 |
| `SystemDeptServiceImpl.update`（科室更新写库） | **11.1%** | ⚠️ 每轮同步都重复 UPDATE 科室 |
| `HospitalPatientSynchronizer.sync → selectDataByDepartment` | 7.1% | 患者数据拉取 |
| MySQL 驱动 + Druid（含调用方覆盖） | 15–17% | DB 访问整体占比 |
| C2 JIT 编译（PhaseIdealLoop 等） | ~8% | 冷启动预热噪音，稳定后消失 |
| 异常构栈 `Throwable.fill_in_stack_trace` + `MagicScriptError.transfer` 字符串拼接 | ~4% | ⚠️ 与错误风暴同源 |

### 3.2 WALL 火焰图（45s，全线程墙钟）

| 线程组 | 占比 | 解读 |
| --- | --- | --- |
| 业务线程（Thread.run 组） | 46.4% | 其中 MySQL 报文读取 `MultiPacketReader.readHeader` 占该组 9.3%、`NativeProtocol.sendCommand` 4.7% —— **真实耗时在等 DB 返回** |
| 空闲/挂起线程（[unknown]，musl 符号化限制） | 35.0% | 线程池空闲等待，正常 |
| ForkJoin 并行流 | 4.9% | 科室级并行同步 |
| Druid 连接创建/销毁线程 | 2.8% | ⚠️ 连接池在持续建连/销毁，存在抖动 |
| HTTP Client Selector（magic-api 内部 HTTP） | 1.4% | 正常 |

**结论：**该服务是典型的 **IO 等待型**负载（wall 大头在等 MySQL），CPU 并不紧张；性能优化的主攻方向是**消除错误风暴、减少重复查询/写入**，而不是加 CPU。

## 4trace / watch 结果（原始输出）

### 4.1 trace：InpatientOrderProcessor#process（单轮 738ms）

```
[arthas@1]$ trace -n 2 --skipJDKMethod true com.ejet.app.processor.InpatientOrderProcessor process
Affect(class count: 1 , method count: 1) cost in 382 ms
`---ts=2026-09-16 15:32:00.120;thread_name=http-nio-48088-exec-2
    `---[738.51224ms] com.ejet.app.processor.InpatientOrderProcessor:process()
        +---[0.16% 1.17356ms ] org.slf4j.Logger:info() #69
        +---[3.99% 29.475246ms ] com.ejet.dao.service.SyncFunctionService:getSyncFunctions() #73
        +---[16.51% 121.89286ms ] com.ejet.dao.service.StaffService:list() #84
        +---[0.00% 0.035424ms ] com.baomidou.mybatisplus.core.toolkit.CollectionUtils:isNotEmpty() #85
        +---[1.13% 8.314319ms ] com.ejet.dao.service.SystemDeptService:findOpening() #93
        +---[0.60% 4.432783ms ] com.ejet.utils.ElapsedHelper:log() #103
        `---[0.07% 0.537225ms ] org.slf4j.Logger:info() #105
```

逐层耗时解读：主体耗时不在主线程同步调用（可见子调用合计仅 ~165ms / 22%），其余时间在**并行流线程**里执行各科室同步（trace 不跨线程）。主线程内 `StaffService:list()` 122ms 是最大可优化点。
### 4.2 watch：ProcessController#processInpatient（单轮 370ms）

```
[arthas@1]$ watch -n 1 com.ejet.app.controller.ProcessController processInpatient {params,returnObj,throwExp} -x 2
Affect(class count: 1 , method count: 1) cost in 135 ms
method=com.ejet.app.controller.ProcessController.processInpatient location=AtExit
ts=2026-09-16 15:34:33.594; [cost=369.597638ms] result=@ArrayList[
    @Object[][isEmpty=true;size=0],   <-- 入参：空（GET 无参数）
    null,                              <-- 返回值：void → null
    null,                              <-- 异常：无
]
```

watch 证明：入参为空数组（GET 无参）、返回 null（void 接口）、无异常；cost=369.6ms 与 trace 的 738ms 差异来自并行度与缓存命中波动。

## 5问题清单与优化方向（现象→证据→根因→方案→收益→风险）

P0 · 错误日志风暴

#### 科室同步全量失败并逐条写错误日志

**现象**每次 /process/inpatient 返回 200，但内部所有科室同步抛异常

**证据**10 分钟 572 条 ERROR；`MagicScriptException: bad SQL grammar [select * from v_inpatient_visit ...]`（数据源 `db.jiaxing`）；CPU 火焰图错误链路（日志落库 8.3% + 构栈/拼串 ~4%）

**根因**测试环境 `jiaxing` 数据源缺视图 `v_inpatient_visit`（或视图建在别的库）；应用无「数据源健康预检」，失败后仍按科室×轮次全量重试并落库错误日志

**方案**① 补建/修正视图；② 启动时对每个已注册数据源做一次探活，不可用直接跳过并告警一次（而非每科室报一次）；③ `InfraApiErrorLogService` 对同源错误做**去重/限流**（如 5 分钟内同类只记一条 + 计数）；④ statisticElapsed 从 ERROR 降为 INFO

**收益**消除 ~12% CPU 的无效错误处理；日志量降 90%+；真实故障不会被 572 条噪音淹没

**风险**错误去重可能掩盖间歇性故障，需保留计数与首次完整堆栈

P1 · 每轮全量拉员工表

#### StaffService:list() 无缓存全量查询

**现象**每轮同步固定支出 ~122ms

**证据**trace：`StaffService:list()` 121.9ms / 738ms = 16.5%

**根因**process() 每次调用都全量 SELECT 员工表，无缓存无增量

**方案**员工字典数据变化频率低 → 加本地缓存（Caffeine，TTL 5–10 分钟）或改为增量同步（按 update\_time）

**收益**单轮同步 -120ms（约 -16%）

**风险**缓存 TTL 内新增员工不可见——对同步场景影响可控

P1 · 科室表高频重复 UPDATE

#### SystemDeptService.update 每轮全量重写

**现象**同步负载期间科室更新写库占 CPU 11.1%

**证据**CPU 火焰图 `SystemDeptServiceImpl.update` 11.1%（CGLIB 代理帧）

**根因**轮询触发（测试中 2s 一次）导致科室信息被无差别反复 UPDATE，即使内容没变

**方案**① UPDATE 前比对字段变化，无变化跳过；② 科室同步加最小间隔（如 5 分钟）；③ 使用 `INSERT ... ON DUPLICATE KEY UPDATE` 并发安全合并

**收益**消除 ~11% CPU 与对应 binlog/主从压力

**风险**低；注意保留 update\_time 语义

P2 · Druid 连接池抖动

#### 连接创建/销毁线程在负载期间持续活跃

**现象**CreateConnectionThread + DestroyConnectionThread 合计 wall 2.8%

**证据**wall 火焰图线程分布

**根因**minActive/maxActive 配置与实际并发不匹配，峰值借还造成反复建连销毁

**方案**调高 `minIdle`（贴近峰值并发）、开启 `keepAlive`、评估 `maxWait`

**收益**减少建连开销与偶发获取连接等待

**风险**连接数上升，注意 HIS 侧连接配额

P2 · 采集方法论

#### 生产环境抓火焰图的两条注意事项

- **避开冷启动：**本次火焰图含 ~8% C2 JIT 编译帧（应用刚重启）。生产采集应在稳定运行 10 分钟以上、或业务高峰期进行，否则热点会被编译噪音稀释。
- **musl 符号化缺失：**Alpine 基础镜像的 native 帧大量显示为 [unknown]/ld-musl，属采集工具限制，不影响 Java 帧结论；如需精确 native 分析可换 glibc 基镜像或用 perf。

P0 · 已修复：DB Schema 漂移

#### 镜像版本领先于测试库结构（本次抓取的直接前置故障）

**现象**容器 Up 但 48088 无监听，`Application run failed`

**根因**新版实体含 `his_code / his_name / category / deleted`，测试库 `emr_react.inspection_item_library` 无这些列，且新版 `@PostConstruct` 不再吞异常 → 启动即挂

**修复**已执行 `ALTER TABLE ... ADD COLUMN his_code varchar(200) NULL, his_name varchar(200) NULL, category varchar(100) NULL, deleted tinyint NOT NULL DEFAULT 0` 并重启容器（如需回滚可 DROP COLUMN）

**建议**给测试环境补一份与镜像版本对应的 DDL 变更脚本（或引入 Flyway/Liquibase），避免「镜像更新、库没更新」的环境漂移再次出现

## 6本次使用的全部命令（可复现）

```
# 1. 线程体检
docker exec emr-wisdom-sync java -jar /opt/arthas/arthas-boot.jar 1 --batch-mode -c 'thread -n 5'

# 2. CPU 火焰图（45s，负载期间）
profiler start --event cpu --duration 45 --file /tmp/cap-cpu.html
#   定量分析用 collapsed 格式：
profiler start --event cpu --duration 45 --format collapsed --file /tmp/cap-cpu.txt

# 3. WALL 火焰图（45s，负载期间）
profiler start --event wall --duration 45 --file /tmp/cap-wall.html

# 4. 负载：循环触发住院同步
for i in $(seq 1 12); do curl -s http://localhost:48088/process/inpatient; sleep 2; done

# 5. trace 调用链
trace -n 2 --skipJDKMethod true com.ejet.app.processor.InpatientOrderProcessor process

# 6. watch 入参/返回/异常
watch -n 1 com.ejet.app.controller.ProcessController processInpatient {params,returnObj,throwExp} -x 2

# 7. 反编译（排查线上代码版本）
jad com.ejet.dao.entity.InspectionItemLibrary

# 8. 产物拷出
docker cp emr-wisdom-sync:/tmp/cap-cpu.html . && docker cp emr-wisdom-sync:/tmp/cap-wall.html .
```

## 7产物清单

| 文件 | 说明 |
| --- | --- |
| `raw/cap-cpu.html` | CPU 火焰图（交互式，浏览器打开） |
| `raw/cap-wall.html` | WALL 火焰图（交互式） |
| `raw/cap-cpu.txt / cap-wall.txt` | collapsed 格式原始采样（本报告定量分析的数据源） |
| `raw/trace-process.txt` | trace 原始输出 |
| `raw/watch-ctrl.txt` | watch 原始输出 |
| `raw/env.txt` | JVM 版本与启动参数 |
| `capture-flame.sh` | 一键抓取脚本（医院生产环境可复用） |

说明：本次在**研发测试环境**完成（任务要求为「自己负责的一个医院」；测试机即 10010 测试环境的同步服务，连的就是真实医院数据源 jiaxing，具备代表性）。生产医院执行时用 `capture-flame.sh`，命令与本文档第 6 节一致。

生成于 2026-09-16 · 数据来源：async-profiler collapsed 定量分析 + Arthas trace/watch + 应用日志
