<#
.SYNOPSIS
  一键把本地 blog/ 推送到 GitHub 仓库 leke2000/blog，并开启 GitHub Pages。

.DESCRIPTION
  - 自动 git init / add / commit
  - 自动创建远程仓库（如已存在则跳过）
  - 推送 main 分支
  - 提示用户去 GitHub 开启 Pages（首次需要手动点一下）

.PARAMETER GitHubToken
  （可选）Personal Access Token。如果提供，自动创建仓库；不提供则假设仓库已经手动建好。

.EXAMPLE
  .\push-to-github.ps1
  # 假设仓库已经手动创建好

.EXAMPLE
  .\push-to-github.ps1 -GitHubToken ghp_xxxxxxxx
  # 自动创建 + 推送
#>

param(
    [string]$GitHubToken = ""
)

$ErrorActionPreference = "Stop"
$RepoOwner = "leke2000"
$RepoName = "blog"
$LocalPath = $PSScriptRoot

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  推送博客到 GitHub: $RepoOwner/$RepoName" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ---- 1. 检查 git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "❌ 没找到 git，请先安装 Git for Windows" -ForegroundColor Red
    exit 1
}

# ---- 2. 创建远程仓库（如提供了 token）
if ($GitHubToken) {
    Write-Host "📡 创建远程仓库 ..." -ForegroundColor Yellow
    $headers = @{
        "Authorization" = "token $GitHubToken"
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "push-script"
    }
    $body = @{
        name = $RepoName
        description = "实施工程师的排障手记 - Jekyll 博客"
        homepage = "https://$RepoOwner.github.io/$RepoName/"
        private = $false
        auto_init = $false
    } | ConvertTo-Json
    try {
        $resp = Invoke-RestMethod -Method POST `
            -Uri "https://api.github.com/repos/$RepoOwner/$RepoName" `
            -Headers $headers -Body $body -ContentType "application/json"
        Write-Host "✅ 仓库已创建: $($resp.html_url)" -ForegroundColor Green
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 422) {
            Write-Host "ℹ️  仓库已存在，跳过创建" -ForegroundColor Yellow
        } else {
            Write-Host "❌ 创建失败: $_" -ForegroundColor Red
            exit 1
        }
    }
} else {
    Write-Host "ℹ️  未提供 GitHubToken，请确认已在 https://github.com/new 创建空仓库 $RepoOwner/$RepoName" -ForegroundColor Yellow
    $ans = Read-Host "继续？[Y/n]"
    if ($ans -eq "n") { exit 0 }
}

# ---- 3. git init / add / commit
Push-Location $LocalPath
try {
    Write-Host ""
    Write-Host "📂 初始化 git 仓库 ..." -ForegroundColor Yellow

    if (-not (Test-Path ".git")) {
        git init -b main | Out-Null
    }

    # 配置用户信息（如未配置）
    $userName = git config --global user.name 2>$null
    if (-not $userName) { git config --global user.name "leke2000" }
    $userEmail = git config --global user.email 2>$null
    if (-not $userEmail) { git config --global user.email "1793023565@qq.com" }

    git add -A | Out-Null
    $status = git status --porcelain
    if ($status) {
        git commit -m "init: 部署 Jekyll 博客，6 篇内训周文章" | Out-Null
        Write-Host "✅ 提交完成" -ForegroundColor Green
    } else {
        Write-Host "ℹ️  没有新文件需要提交" -ForegroundColor Yellow
    }

    # ---- 4. 设置 remote 并 push
    $remoteUrl = "https://github.com/$RepoOwner/$RepoName.git"
    $existing = git remote get-url origin 2>$null
    if ($existing -ne $remoteUrl) {
        if ($existing) { git remote remove origin }
        git remote add origin $remoteUrl
        Write-Host "🔗 remote 已设置: $remoteUrl" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "🚀 推送到 GitHub ..." -ForegroundColor Yellow
    git push -u origin main
    Write-Host ""
    Write-Host "✅ 推送成功！" -ForegroundColor Green
} finally {
    Pop-Location
}

# ---- 5. 开启 GitHub Pages 提示
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  最后一步：开启 GitHub Pages" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. 打开 https://github.com/$RepoOwner/$RepoName/settings/pages" -ForegroundColor White
Write-Host "2. Source 选择 'Deploy from a branch'" -ForegroundColor White
Write-Host "3. Branch 选 main，目录 / (root)" -ForegroundColor White
Write-Host "4. Save，几分钟后访问：" -ForegroundColor White
Write-Host "   👉 https://$RepoOwner.github.io/$RepoName/" -ForegroundColor Green
Write-Host ""
