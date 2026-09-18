---
layout: default
title: 首页
---

# {{ site.title }}

> {{ site.tagline }}

我是 **leke2000**，一位医疗信息化行业的实施工程师，正在转型做 Java 开发。这个博客记录我在内训周里完成的实战练习 —— 从 Arthas 火焰图、tcpdump 抓包，到 magic-api 同步脚本的 SQL 方言踩坑。**每一篇都来自真实环境，能复现、能照抄。**

## 最新文章

<ul class="post-list">
{% for post in site.posts limit:20 %}
  <li>
    <span class="date">{{ post.date | date: "%Y-%m-%d" }}</span>
    <a href="{{ post.url | relative_url }}"><strong>{{ post.title }}</strong></a>
    {% if post.tags %}
      {% for t in post.tags %}<span class="tag">{{ t }}</span>{% endfor %}
    {% endif %}
    <div style="color:#57606a;font-size:0.9em;margin-top:4px">
      {{ post.excerpt | strip_html | truncate: 120 }}
    </div>
  </li>
{% endfor %}
</ul>

## 系列索引

### 🔥 性能分析系列
- [Arthas 火焰图实战分析](/blog/2026/09/16/arthas-flame-graph-analysis/)
- [Arthas 插件与 trace/watch 实战教程](/blog/2026/09/17/arthas-idea-plugin-tutorial/)

### 🌐 网络抓包系列
- [tcpdump + Wireshark 抓包分析实战](/blog/2026/09/17/tcpdump-wireshark/)

### 🧭 排障方法论
- [没有 AI 怎么一步步自己排障](/blog/2026/09/17/no-ai-self-help/)
- [EMR 同步 · 内训周执行手册](/blog/2026/09/18/emr-sync-weekly-handbook/)
- [住院回写时序图合集（4 张）](/blog/2026/09/18/writeback-sequence-diagrams/)

---

📮 反馈：[GitHub Issues](https://github.com/leke2000/blog/issues) · 邮箱：{{ site.email }}
