#!/bin/bash
# 给打好的 Shiduo.app 重新签名。
# 用法：scripts/sign-app.sh <Shiduo.app 路径>
#
# 为什么要这样做：拾掇没有 Apple 开发者证书。纯 ad-hoc 签名时，App 的“指定要求”
# （designated requirement）就是它的 cdhash，每次更新 cdhash 都会变，macOS 的隐私
# 权限（TCC，例如“完全磁盘访问权限”）和钥匙串就会把新版本当成另一个 App，权限悄悄失效。
#
# 改用一张固定的自签名代码签名证书后，指定要求变成
#   identifier "io.github.hanson-zz.shiduo" and certificate leaf = H"<证书 SHA-1>"
# 只要证书不换，以后每个版本的指定要求都一样，授权会一直保留。详见 notes/signing.md。
#
# 证书来自仓库的 Actions secrets：
#   SIGNING_CERT_P12       .p12 文件的 base64
#   SIGNING_CERT_PASSWORD  .p12 的密码
# 没有这两个 secret（例如 fork 出去的仓库）时退回 ad-hoc 签名，并给出警告。
set -euo pipefail

APP="${1:?用法：sign-app.sh <Shiduo.app>}"
[ -d "$APP" ] || { echo "找不到 $APP"; exit 1; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# 嵌套的代码（框架、插件、XPC、dylib）要先签，由内向外，最后签 App 本身。
nested_code() {
  local dir
  for dir in Frameworks PlugIns XPCServices Library/LoginItems Helpers; do
    [ -d "$APP/Contents/$dir" ] || continue
    find "$APP/Contents/$dir" -depth \( -name "*.framework" -o -name "*.appex" -o -name "*.xpc" \
      -o -name "*.app" -o -name "*.bundle" -o -name "*.dylib" \) -print
  done
}

sign_all() {
  # $@：codesign 的签名参数（--sign … 等）
  local item
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    echo "签名嵌套代码：$item"
    codesign --force --timestamp=none --preserve-metadata=identifier,entitlements "$@" "$item"
  done < <(nested_code)
}

if [ -z "${SIGNING_CERT_P12:-}" ] || [ -z "${SIGNING_CERT_PASSWORD:-}" ]; then
  echo "::warning::没有配置 SIGNING_CERT_P12 / SIGNING_CERT_PASSWORD，退回 ad-hoc 签名。这样打出来的版本每次更新后都要重新授权“完全磁盘访问权限”。"
  sign_all --sign -
  codesign --force --timestamp=none --preserve-metadata=identifier,entitlements --sign - "$APP"
  echo "SIGNING_MODE=adhoc" >> "${GITHUB_ENV:-/dev/null}"
else
  WORK="$(mktemp -d)"
  KC="$WORK/shiduo-signing.keychain-db"
  KC_PASS="$(uuidgen)"
  cleanup() {
    security delete-keychain "$KC" > /dev/null 2>&1 || true
    rm -rf "$WORK"
  }
  trap cleanup EXIT

  printf '%s' "$SIGNING_CERT_P12" | base64 --decode > "$WORK/cert.p12"

  # 临时钥匙串：只在这次构建里存在，结束时删除。
  security create-keychain -p "$KC_PASS" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KC_PASS" "$KC"
  security import "$WORK/cert.p12" -k "$KC" -P "$SIGNING_CERT_PASSWORD" -f pkcs12 -T /usr/bin/codesign > /dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" > /dev/null
  # 加到搜索列表里（放在最前面），codesign 才找得到私钥。
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  rm -f "$WORK/cert.p12"

  # 自签名证书不受系统信任，所以不加 -v（-v 只列“有效”身份）。
  IDENTITY="$(security find-identity -p codesigning "$KC" | awk '/[0-9]+\) [0-9A-F]{40}/ { print $2; exit }')"
  [ -n "$IDENTITY" ] || { echo "::error::导入证书后找不到代码签名身份"; security find-identity -p codesigning "$KC"; exit 1; }
  echo "使用自签名证书签名，证书 SHA-1：$IDENTITY"

  sign_all --keychain "$KC" --sign "$IDENTITY"
  # 明确写出指定要求：只认 bundle id + 这张证书本身，跟 cdhash 无关。
  codesign --force --timestamp=none --preserve-metadata=identifier,entitlements \
    --keychain "$KC" --sign "$IDENTITY" \
    --requirements "=designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$IDENTITY\"" \
    "$APP"
  echo "SIGNING_MODE=self-signed" >> "${GITHUB_ENV:-/dev/null}"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
echo "== 签名信息 =="
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Format|Authority|Signature|TeamIdentifier|CDHash)=" || true
echo "== 指定要求（designated requirement） =="
codesign -d -r- "$APP" 2>&1
