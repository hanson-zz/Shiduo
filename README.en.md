<p align="center"><img src="docs/icon.png" width="160" alt="Shiduo icon"></p>

<h1 align="center">Shiduo 拾掇</h1>

<p align="center"><b>See your Mac’s files at a glance, find them with a sentence, and clean up safely.</b><br>A free, open-source companion to Finder. Everything happens on your Mac.</p>

<p align="center"><a href="README.md">简体中文</a> · English</p>

<p align="center">
  <a href="https://github.com/hanson-zz/Shiduo/releases/latest"><img src="https://img.shields.io/github/v/release/hanson-zz/Shiduo?label=download&color=ff7a59" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%2F%20Intel-universal-blue" alt="Universal">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
</p>

<p align="center"><a href="https://hanson-zz.github.io/Shiduo/#demo"><img src="docs/demo/readme-en.png" alt="Watch the Shiduo demo video" width="720"></a></p>

<p align="center"><img src="docs/screenshots/en/home.png" alt="Shiduo home" width="880"></p>

Shiduo (拾掇, “to tidy up”) gathers the images, videos, documents and installers scattered around your Mac into one visual library. Search in plain English or Chinese, see where every download came from, and find duplicates and files you can safely remove. Nothing is uploaded.

The app is in English and Simplified Chinese. It follows your system language, and you can switch in **Settings › Language** (takes effect after a relaunch).

## Features

- **Visual library**: images, videos, music, documents, archives and apps, with big thumbnails, grid or list view, and Quick Look.
- **Plain-language search**: try `pdfs over 5MB last week`, `images from wechat`, `large videos from youtube.com this month`. The sentence becomes filters you can remove one by one.
- **Downloaded from**: recognizes Gmail, Google Drive, ChatGPT, WeChat, GitHub, Figma, browser extensions and 30+ other sources, and groups the rest by website.
- **Safe cleanup**: used installers, forgotten downloads, old screenshots, big old videos and rarely used apps. Files only go to the Trash, and iCloud-only files are skipped.
- **Duplicates and similar photos**: exact copies by size and SHA-256, look-alike photos with Vision.
- **Shelf**: drop files from anywhere onto the Shelf in the sidebar to park them for a moment (only their locations are saved, nothing is copied), then drag them all out together, or move, copy, zip or AirDrop them in one go.
- **Handy tools**: text recognition in images (on-device), storage map, batch rename, convert to JPG, Finder tags, and a global quick-search panel (⌥Space).

## Shiduo Pro

Everything above is free forever. **Shiduo Pro** ($9.90 USD, one-time, 7-day free trial, payments by Creem) adds auto-organize rules, weekly cleanup reminders, photo search by content, external drives in the sidebar, a menu bar helper, and a floating shelf that pops up when you drag files to the edge of the screen. Enter your license key in **Settings › License**.

## Install

1. Download the latest `Shiduo-*.dmg` from [Releases](https://github.com/hanson-zz/Shiduo/releases).
2. Open it and drag Shiduo to Applications.
3. The app isn’t notarized by Apple, so the first launch is blocked. Open **System Settings › Privacy & Security** and click **Open Anyway**, or run `xattr -cr /Applications/拾掇.app` in Terminal.

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

## Privacy

Shiduo only goes online to check for updates (GitHub) and to activate or verify a Pro license. Your files, file names and searches never leave your Mac. See the [Privacy Policy](https://hanson-zz.github.io/Shiduo/privacy.html), [Terms of Service](https://hanson-zz.github.io/Shiduo/terms.html) and [Refund Policy](https://hanson-zz.github.io/Shiduo/refund.html).

## Build it yourself

Needs Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Shiduo.xcodeproj
```

UI strings live in `Resources/Localizable.xcstrings` (source language: Simplified Chinese, with English translations).

## Contact

Email 694561981@qq.com or open an [issue](https://github.com/hanson-zz/Shiduo/issues). Website: https://hanson-zz.github.io/Shiduo/

## License

[MIT](LICENSE)
