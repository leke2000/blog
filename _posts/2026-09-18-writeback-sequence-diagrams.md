---
layout: post
title: "住院回写时序图合集（前端回写 × 后端回写 × 内嵌 × 悬浮窗）"
date: 2026-09-18 00:00:00 +0800
categories: [排障手记]
tags: [时序图, 回写, magic-api]
---

<!--more-->

## 系列背景

住院回写是 EMR 系统的核心场景：医生在 HIS 里写病历 → 数据回到 EMR → 用户在 EMR 里
继续完成病程记录、检查报告等更复杂的文书。

回写有 **4 种组合**：

| 载体 | 触发方 | 时序图 |
| --- | --- | --- |
| **内嵌（iframe）** | 前端回写 | 时序图 1 |
| **内嵌（iframe）** | 后端回写（PUSH_SYNC） | 时序图 2 |
| **悬浮窗** | 前端回写 | 时序图 3 |
| **悬浮窗** | 后端回写 | 时序图 4 |

> ⚠️ magic-api 同步脚本不在 git 仓库里 —— 它们存在 `emr_react.sync_magic_api_file`
> 表的 `file_content` 字段，排查时只能查库。

---

## 时序图 1：内嵌载体 + 前端回写

![内嵌+前端回写]({{ "/assets/diagrams/seq-1.png" | relative_url }})

**关键链路**

1. HIS 前端（病历编辑器）触发保存
2. 经 iframe `window.parent` 消息通道传到 EMR 前端
3. EMR 前端调用 `POST /third/sync/doc`（`ThirdSyncController`）
4. → `ThirdSyncServiceImpl.sync()` → magic-api `/back/transfer`
5. magic-api 返回 `data.jsCallback`，后端把它包装成 `"jsCallback:<脚本>"`
6. 响应回到 HIS 前端，**前端执行**这段 JS 完成字段回写

**特征**：回写动作发生在 HIS 前端，回写脚本由 magic-api 返回。

---

## 时序图 2：内嵌载体 + 后端回写（PUSH_SYNC）

![内嵌+后端回写]({{ "/assets/diagrams/seq-2.png" | relative_url }})

**关键链路**

1. HIS 后端（PUSH_SYNC）主动推送
2. `POST /medical-record/sync`（`MedicalRecordController.sync()`）
3. → magic-api `/back/transfer/new`
4. → `syncCallback()` 记录 `recordSyncId` + 数字签名
5. 返回 `action=redirectTo|syncCompleted`，由 HIS 后端执行

**特征**：回写动作发生在 **HIS 后端**，通过 HTTP 回调完成。

---

## 时序图 3：悬浮窗 + 前端回写

![悬浮窗+前端回写]({{ "/assets/diagrams/seq-3.png" | relative_url }})

**关键链路**

- 与时序图 1 类似，但跨窗通信用 `window.opener` + `postMessage`
- 悬浮窗里的 EMR 与 HIS 主窗是**两个独立窗口**（不是父子关系）
- 鉴权与状态保持更复杂，需要带 `opener.postMessage` 的 origin 校验

---

## 时序图 4：悬浮窗 + 后端回写

![悬浮窗+后端回写]({{ "/assets/diagrams/seq-4.png" | relative_url }})

**关键链路**

- 与时序图 2 类似，载体换成悬浮窗
- 后端回调的目标 URL 必须指向悬浮窗内的 EMR 服务（不是父窗）

---

## 源码定位

| 类 / 接口 | 路径 |
| --- | --- |
| `ThirdSyncController.sync` | `com.ejet.app.controller` |
| `ThirdSyncServiceImpl.sync` | `com.ejet.app.service.impl` |
| `MedicalRecordController.sync` | `com.ejet.app.controller` |
| `OpdAssistantController.writeBack` | `com.ejet.app.controller` |
| magic-api `/back/transfer` | `sync_magic_api_file` 表 |
| magic-api `/back/transfer/new` | `sync_magic_api_file` 表 |
| magic-api `/clinic/write_back` | `sync_magic_api_file` 表 |

> 上面这张表是我**真实在源码里 grep** 出来的，不是猜的。

---

## 实操建议

如果你正在排查"回写不生效"：

1. **先看响应体**：是 `jsCallback` 字符串还是 `redirectTo` URL？前者是前端回写路径，后者是后端回写路径
2. **看 magic-api 日志**：控制台 192.168.0.12:48080 找对应脚本的执行记录
3. **看 `syncCallback` 记录**：`select * from emr_react.sync_log order by id desc limit 20;`
4. **抓包确认链路**：用 tcpdump 抓 `tcp port 48088`，看 HTTP 请求是否真实到达

---

> 配套：可下载 [pcap 文件](/assets/pcap/emr-http.pcap) 用 Wireshark 打开复现。
