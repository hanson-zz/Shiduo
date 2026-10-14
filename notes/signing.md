# 代码签名（自签名证书）

## 问题

拾掇没有 Apple 开发者账号，以前所有版本都是 **ad-hoc 签名**（`CODE_SIGN_IDENTITY="-"`）。
ad-hoc 签名的“指定要求”（designated requirement，DR）就是这一次构建的 cdhash：

```
designated => cdhash H"…"   # 每次构建都不一样
```

macOS 的隐私权限（TCC，例如“完全磁盘访问权限”）和钥匙串的访问控制都是按 DR 认 App 的。
所以每次更新，新版本都被当成另一个 App：完全磁盘访问权限悄悄失效，钥匙串里的授权信息也可能弹窗询问。

## 解决办法

用一张**固定的自签名代码签名证书**重新签名发布出去的 App。DR 变成：

```
designated => identifier "io.github.hanson-zz.shiduo" and certificate leaf = H"a44fd83b010c77948f37834b02d521c1c046462f"
```

只要证书不换，以后每个版本的 DR 都一样，权限会一直保留。

| 项目 | 值 |
| --- | --- |
| 证书名称（CN） | Shiduo Self-Signed Code Signing |
| 算法 | RSA 2048，SHA-256 |
| 扩展 | basicConstraints critical CA:FALSE；keyUsage critical digitalSignature；extendedKeyUsage critical codeSigning |
| 有效期 | 20 年（到 2046-10） |
| **SHA-1 指纹（公开，不是秘密）** | `A4:4F:D8:3B:01:0C:77:94:8F:37:83:4B:02:D5:21:C1:C0:46:46:2F` |

> 证书过期本身不影响已签好的 App 和 TCC（签名时 `--timestamp=none`，DR 只比对证书指纹）。
> **千万不要换证书**：换了 DR 就变，用户又得重新授权一次。

## 放在哪里

- 仓库 Actions secrets：`SIGNING_CERT_P12`（.p12 的 base64）和 `SIGNING_CERT_PASSWORD`。
- 私钥和密码**绝不提交到仓库**。维护者另有一份离线备份。
- 私钥要保密：谁拿到它，谁就能签出被 macOS 当成“拾掇”的程序，继承用户给拾掇的完全磁盘访问权限。

## 构建流程

1. `xcodebuild` 照旧 ad-hoc 签名（谁 clone 下来都能直接构建）。
2. `scripts/sign-app.sh <Shiduo.app>` 重新签名：
   - 建一个临时钥匙串，导入 .p12（`-T /usr/bin/codesign`），`set-key-partition-list`，加入搜索列表；
   - 由内向外签嵌套代码（目前没有），再签 App 本身，并用 `--requirements` 明确写出上面的 DR；
   - 保留原来的 identifier 和 entitlements，不开 hardened runtime（和以前一致）；
   - 打印 `codesign -d -r-`，日志里能看到 `certificate leaf = H"…"`；
   - 没有 secrets（fork、来自 fork 的 PR）时退回 ad-hoc，并给出警告。
3. 用到它的 workflow：`release.yml`（发布）、`dmg-test.yml`（DMG 测试）、`ci.yml`（有 secret 时）。`screenshots.yml` 只在 CI 机器上跑演示，不分发，仍是 ad-hoc。

## 对用户的影响

- **Gatekeeper 不变**：自签名证书不受 Apple 信任，App 仍然没有公证，第一次打开的步骤和以前一样（右键 › 打开，或“隐私与安全性 › 仍要打开”）。
- **从 ad-hoc 版本升级到第一个自签名版本时，还需要最后一次重新授权**完全磁盘访问权限（DR 从 cdhash 变成证书）。App 里会自动弹出「更新后需要重新授权一次」的指引（`Sources/Views/FullDiskAccessLost.swift`）。之后的更新不用再弄。
- 钥匙串（`Sources/Pro/License.swift`）：授权信息存成普通的 generic password，没有自定义访问控制；默认的 ACL 信任创建它的 App（按 DR）。证书固定后，以后更新不会再弹钥匙串询问。第一次升级时如果系统问“拾掇想使用钥匙串里的…”，点“始终允许”即可。

## 在 Mac 上检查

```sh
codesign -d -r- /Applications/拾掇.app
# designated => identifier "io.github.hanson-zz.shiduo" and certificate leaf = H"a44fd83b010c77948f37834b02d521c1c046462f"
```
