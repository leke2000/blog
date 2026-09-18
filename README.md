# 实施工程师的排障手记 🌉

> 博客：[leke2000.github.io/blog](https://leke2000.github.io/blog/)

这是我从实施工程师转向 Java 开发的学习笔记博客。每一篇都来自**真实环境**的实操：
亲手跑过的命令、真实截图、可复现的步骤。

## 📚 内容系列

| 系列 | 文章 |
| --- | --- |
| 🔥 **性能分析** | [Arthas 火焰图实战分析](https://leke2000.github.io/blog/2026/09/16/arthas-flame-graph-analysis/) |
| | [Arthas IDEA 插件 + trace/watch 实战教程](https://leke2000.github.io/blog/2026/09/17/arthas-idea-plugin-tutorial/) |
| 🌐 **网络抓包** | [tcpdump + Wireshark 抓包分析](https://leke2000.github.io/blog/2026/09/17/tcpdump-wireshark/) |
| 🧭 **排障方法论** | [没有 AI 怎么自己一步步排障](https://leke2000.github.io/blog/2026/09/17/no-ai-self-help/) |
| | [EMR 同步 · 内训周执行手册](https://leke2000.github.io/blog/2026/09/18/emr-sync-weekly-handbook/) |
| 🧬 **系统设计** | [住院回写时序图合集（4 张）](https://leke2000.github.io/blog/2026/09/18/writeback-sequence-diagrams/) |

## 🛠 技术栈

- **博客框架**：Jekyll + GitHub Pages（minima 主题 + 自定义样式）
- **内容**：Markdown + 代码块 + 真实截图 + mermaid/PNG 时序图
- **素材来源**：真实部署环境（Spring Boot + magic-api + MySQL）

## 🚀 本地预览

```bash
bundle install
bundle exec jekyll serve
# 浏览器打开 http://localhost:4000/blog
```

## 📂 仓库结构

```
blog/
├── _config.yml          # Jekyll 站点配置
├── _layouts/            # post / default 模板
├── _posts/              # 6 篇文章（YYYY-MM-DD-slug.md）
├── assets/
│   ├── images/          # Wireshark / 终端截图
│   ├── diagrams/        # 时序图 PNG
│   └── pcap/            # 真实抓包的 pcap 文件
├── index.md             # 首页
├── about.md             # 关于
└── push-to-github.ps1   # 一键推送到 GitHub
```

## ✍️ 如何加新文章

1. 在 `_posts/` 新建 `YYYY-MM-DD-slug.md`
2. 文件开头加 front matter：
   ```yaml
   ---
   layout: post
   title: "你的标题"
   date: 2026-09-19 10:00:00 +0800
   categories: [排障手记]
   tags: [标签1, 标签2]
   ---
   ```
3. 截图放到 `assets/images/`，在文章里用：
   ```markdown
   ![描述]({{ "/assets/images/xxx.png" | relative_url }})
   ```
4. 本地预览后提交、推送

## 📮 反馈

提 Issue 或 PR 都欢迎：[github.com/leke2000/blog](https://github.com/leke2000/blog)
