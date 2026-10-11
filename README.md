<p align="center"><img src="docs/icon.png" width="160" alt="拾掇图标"></p>

<h1 align="center">拾掇 Shiduo</h1>

<p align="center"><b>Mac 上的文件，一眼看清，一句话找到，放心清理。</b><br>开源、免费、全部在本机完成的“访达”好帮手。</p>

<p align="center">
  <a href="https://github.com/hanson-zz/Shiduo/releases/latest"><img src="https://img.shields.io/github/v/release/hanson-zz/Shiduo?label=%E4%B8%8B%E8%BD%BD&color=ff7a59" alt="下载"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20%E8%8A%AF%E7%89%87%20%2F%20Intel-%E9%80%9A%E7%94%A8-blue" alt="通用">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
</p>

<p align="center"><img src="docs/screenshots/home.png" alt="拾掇首页" width="880"></p>

拾掇是一款开源的 macOS 文件整理助手，和“访达”配合使用：把散落在各处的图片、视频、文稿、安装包按类型归拢，用一句话就能找到文件，还能帮你找出重复文件和可以放心清理的东西。所有处理都在本机完成，不上传任何文件。

> 截图使用的是内置演示数据（`--demo`），由 GitHub Actions 在 macOS 上自动截取。

## 一眼看清整台 Mac

首页把图片、视频、音乐、文稿、压缩包、应用各占多少空间排成彩色卡片，下面紧跟着“能腾出多少空间”的清理卡片和下载来源。窗口是磨砂玻璃质感，跟随系统浅色 / 深色模式。

<p align="center"><img src="docs/screenshots/home-dark.png" alt="深色模式首页" width="880"></p>

- **资料库侧边栏**：最近使用、图片、视频、音乐、文稿、压缩包、应用程序，基于 Spotlight 索引，打开就有，旁边直接显示数量。
- **智能文件夹**：大文件、截图、下载来源；还可以固定任意文件夹。

## 像浏览相册一样浏览文件

网格 / 列表随时切换，缩略图大小可调，按种类、日期、大小排序。空格键快速查看，⌘I 打开简介面板，右键菜单和拖出到其他应用都支持。

<p align="center"><img src="docs/screenshots/images.png" alt="图片网格" width="880"></p>

- **识别图中文字**：用 Vision 在本机识别截图和照片里的中文、英文，一键拷贝，识别后还能按文字筛选。

## 一句话搜索

中文英文都行，拾掇会把这句话拆成可以单独去掉的筛选标签。

<p align="center"><img src="docs/screenshots/search.png" alt="一句话搜索" width="880"></p>

试试这些：

- `上周超过5MB的pdf`
- `最近三天的照片`、`超过30天的截图`
- `从github下载的dmg`
- `来自微信的图片`、`qq邮箱收到的发票`、`pdfs from gmail`
- `large videos from youtube.com this month`

## 记得每个文件从哪来

自动认出 Gmail、QQ 邮箱、网易邮箱、微信、飞书、钉钉、小红书、百度网盘、阿里云盘、ChatGPT、Figma、GitHub、浏览器扩展等 30 多个来源，其余按网站分组。

<p align="center"><img src="docs/screenshots/downloads.png" alt="下载来源" width="880"></p>

## 放心清理

用过的安装包、被遗忘的下载、旧截图、很久没看的大视频、不常用的应用，分成卡片告诉你各能腾出多少空间。

<p align="center"><img src="docs/screenshots/cleanup.png" alt="清理建议" width="880"></p>

- 一律只**移到废纸篓**，随时可以恢复；只在 iCloud 云端的文件一律跳过。
- **重复文件**：按大小和 SHA-256 指纹比对，只有内容完全相同才算重复。
- **相似照片**：用 Vision 图像特征找出连拍、重复截图等看起来差不多的照片。


## 安装

1. 到 [Releases](https://github.com/hanson-zz/Shiduo/releases) 下载最新的 `Shiduo-*.dmg`
2. 打开 DMG，把“拾掇”拖进“应用程序”
3. 第一次打开会被系统拦截（应用没有经过 Apple 公证）：打开“系统设置 ▸ 隐私与安全性”，在下方点“仍要打开”。也可以在“终端”运行 `xattr -cr /Applications/拾掇.app`

系统要求：macOS 14 Sonoma 或更新版本，Apple 芯片和 Intel 芯片均可。

## 权限说明

拾掇第一次读取“桌面”“文稿”“下载”里的文件时，系统会询问是否允许，请点“允许”。拾掇的分类和搜索依赖 Spotlight，如果你在系统设置里关闭了 Spotlight 索引，列表会是空的。

## 联网

拾掇唯一的联网功能是“检查更新”（设置里可开关，默认关闭），只会向 GitHub 读取最新版本号。

## 自己构建

需要 Xcode 16 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
open Shiduo.xcodeproj
```

工程使用 ad-hoc 签名，不需要 Apple 开发者账号。推送 `v*` 标签后，GitHub Actions 会自动构建通用二进制并把 DMG 发布到 Releases。

README 里的截图由“截图”工作流生成：在 Actions 里手动运行它，会用演示数据启动拾掇（`Shiduo --demo --page=home|images|search|downloads|cleanup|duplicates [--dark]`），截下各个页面并提交到 `docs/screenshots`。

## 支持拾掇

拾掇完全免费、开源。如果它帮你省了时间、腾出了空间，可以：

- ⭐ 在 GitHub 上点个星
- 📤 分享给朋友
- ☕ 请作者喝杯咖啡（微信 / 支付宝扫一扫，金额随意）

<p>
  <img src="docs/sponsor/wechat.png" width="220" alt="微信收款码">
  &nbsp;&nbsp;
  <img src="docs/sponsor/alipay.png" width="220" alt="支付宝收款码">
</p>

问题和建议请发邮件到 694561981@qq.com，或在 [Issues](https://github.com/hanson-zz/Shiduo/issues) 里留言。

## 许可

[MIT](LICENSE)
