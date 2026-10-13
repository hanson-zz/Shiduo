#!/bin/bash
# 生成带背景图的安装 DMG。
# 用法：scripts/dmg/make-dmg.sh <Shiduo.app 路径> <标签，如 v0.10.0> <输出 .dmg 路径>
#
# 窗口里：左边是“拾掇”，右边是“应用程序”快捷方式，中间箭头写着“拖到应用程序”，
# 下面放两张首次打开指南图片（中文 / English）。
# 优先用 create-dmg（需要 Finder 的 AppleScript）；它在无界面的 CI 机器上偶尔会超时，
# 失败时退回到普通的 hdiutil 打包（没有背景，但指南图片和“应用程序”快捷方式都在），
# 保证发布不会因为美化失败而中断。
set -euo pipefail

APP="$1"
TAG="$2"
OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VOLNAME="拾掇 ${TAG}"
APP_NAME="拾掇.app"
GUIDE_ZH="首次打开请看我.png"
GUIDE_EN="First launch guide.png"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME"
cp "$ROOT/docs/guide/open-zh.png" "$STAGE/$GUIDE_ZH"
cp "$ROOT/docs/guide/open-en.png" "$STAGE/$GUIDE_EN"

# 背景：1x + 2x 合成一个 HiDPI TIFF（Retina 屏上更清晰），不行就用 1x PNG
BG="$HERE/background.png"
if command -v tiffutil > /dev/null 2>&1 && \
   tiffutil -cathidpicheck "$HERE/background.png" "$HERE/background@2x.png" -out "$WORK/background.tiff" > /dev/null 2>&1; then
  BG="$WORK/background.tiff"
fi
echo "背景图：$BG"

# 最多等 N 秒，超时就杀掉（macOS 自带没有 timeout 命令）
with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2> /dev/null; pkill -f "osascript" 2> /dev/null ) &
  local watcher=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$watcher" 2> /dev/null || true
  wait "$watcher" 2> /dev/null || true
  return $rc
}

rm -f "$OUT"
pretty_ok=0
if ! command -v create-dmg > /dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --quiet create-dmg || true
fi
if command -v create-dmg > /dev/null 2>&1; then
  for attempt in 1 2; do
    echo "create-dmg 第 $attempt 次尝试"
    # 清理上一次失败可能留下的挂载和临时镜像
    for v in /Volumes/"拾掇 ${TAG}"*; do [ -d "$v" ] && hdiutil detach "$v" -force > /dev/null 2>&1 || true; done
    rm -f "$(dirname "$OUT")"/rw.*."$(basename "$OUT")"
    if with_timeout 600 create-dmg \
        --volname "$VOLNAME" \
        --background "$BG" \
        --window-pos 200 120 \
        --window-size 660 500 \
        --icon-size 110 \
        --text-size 13 \
        --icon "$APP_NAME" 165 180 \
        --hide-extension "$APP_NAME" \
        --app-drop-link 495 180 \
        --icon "$GUIDE_ZH" 250 385 \
        --icon "$GUIDE_EN" 410 385 \
        --no-internet-enable \
        --hdiutil-retries 10 \
        --applescript-sleep-duration 10 \
        "$OUT" "$STAGE"; then
      pretty_ok=1
      break
    fi
    echo "::warning::create-dmg 第 $attempt 次失败"
    rm -f "$OUT"
    sleep 5
  done
fi

if [ "$pretty_ok" != 1 ]; then
  echo "::warning::create-dmg 不可用或失败，改用普通 hdiutil 打包（无背景图）"
  for v in /Volumes/"拾掇 ${TAG}"*; do [ -d "$v" ] && hdiutil detach "$v" -force > /dev/null 2>&1 || true; done
  rm -f "$(dirname "$OUT")"/rw.*."$(basename "$OUT")"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
fi

hdiutil verify "$OUT"
ls -l "$OUT"
echo "DMG_STYLE=$([ "$pretty_ok" = 1 ] && echo create-dmg || echo plain)" >> "${GITHUB_ENV:-/dev/null}"
rm -rf "$WORK"
