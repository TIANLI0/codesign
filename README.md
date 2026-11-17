# codesign

GitHub Actions 里用 **Certum 云端 OV 代码签名证书（SimplySign）** 做 Authenticode 签名的共享 Action。
本仓库**不含任何密钥**：凭据只存在各项目仓库的 `codesign` Environment 里，且该环境只允许 `main` 分支和 `v*` 标签使用。

| Action | 作用 |
|---|---|
| `TIANLI0/codesign@v1` | 在 Windows runner 上安装 SimplySign Desktop（固定版本、校验 SHA-256 和发布者签名），用 TOTP 自动登录，确认证书可用 |
| `TIANLI0/codesign/sign@v1` | 按通配符签名并逐个校验（签名者、证书链、RFC 3161 时间戳）；已被他人有效签名的文件（微软运行库等）一律跳过 |
| `TIANLI0/codesign/logout@v1` | 结束云端会话，配合 `if: always()` |

登录后 job 中可用的环境变量：

| 变量 | 用途 |
|---|---|
| `CODESIGN_THUMBPRINT` | 证书 SHA-1 指纹，`signtool /sha1` 或 `fluentsetup build --sign -D CodesignThumbprint=...` |
| `CODESIGN_SIGNTOOL` / `CODESIGN_TIMESTAMP_URL` | signtool 路径 / `http://time.certum.pl` |
| `CODESIGN_SIGN` | 签名脚本：`& $env:CODESIGN_SIGN -Root <目录> -Path 'App.exe','App*.dll' -Description 'App'` |

构建脚本可以用 `if ($env:CODESIGN_SIGN) { ... }` 判断：只有发布构建登录了才签，PR / 日常 CI 构建照常不签。

## 用法

```yaml
jobs:
  package:
    runs-on: windows-latest
    # 只有发布构建进入 codesign 环境（拿到密钥）；其他构建环境名为空 = 不使用环境
    environment: ${{ startsWith(github.ref, 'refs/tags/v') && 'codesign' || '' }}
    steps:
      - uses: actions/checkout@v4
      - run: ./build.ps1                       # 先构建：第三方依赖代码在登录前跑完
      - if: startsWith(github.ref, 'refs/tags/v')
        uses: TIANLI0/codesign@v1
        with:
          email: ${{ secrets.CERTUM_EMAIL }}
          otpauth: ${{ secrets.CERTUM_OTPAUTH }}
          thumbprint: ${{ vars.CERTUM_THUMBPRINT }}
      - if: startsWith(github.ref, 'refs/tags/v')
        uses: TIANLI0/codesign/sign@v1
        with:
          root: out/app
          files: |
            MyApp.exe
            MyApp*.dll
          description: MyApp
      - run: ./package.ps1                     # 打包签过名的文件；安装包本身由 FluentSetup --sign 签
      - if: always()
        uses: TIANLI0/codesign/logout@v1
```

## 签什么、不签什么

- **签**：自己编译的 exe / dll / 服务 / 凭据提供程序，以及最终安装包和 `uninstall.exe`（FluentSetup 的 `signing` 设置负责这两个）。
- **不签**：微软运行库（Windows App SDK、.NET、WebView2）、NuGet 第三方库、厂商安装包。它们要么已经有原厂签名，要么不该由你担保。
- **商店版 MSIX 不签**：提交到 Microsoft Store 的包由微软重新签名。
- **顺序**：先签内部文件，再打包（zip / 安装包），最后算 SHA256SUMS。

## 首次配置 / 轮换凭据

1. SimplySign 激活二维码里的 `otpauth://totp/...` 整行存进密码管理器（换手机也要用它）。
2. 本地运行（值通过 stdin 交给 `gh`，不进命令行和日志）：
   ```powershell
   ./tools/Set-CodesignSecrets.ps1 -Email <SimplySign 邮箱> -OtpAuthFile <otpauth 文件>
   ```
   之后把明文 otpauth 文件删掉。
3. 在本仓库手动运行 **Signing self-test**，日志里会给出证书指纹，再执行
   `./tools/Set-CodesignSecrets.ps1 -Thumbprint <指纹>` 把指纹固定到所有项目。
4. 证书续期后重复第 3 步。

## 安全说明

- **邮箱 + otpauth 等同于私钥**：拿到它们就能以你的名义签名。它们只放在 Environment secret 里，环境只允许 `main` 和 `v*`/`V*` 标签使用。来自 fork 的 PR 拿不到 secret。
- **登录放在构建之后**：npm、NuGet、MSBuild 这些第三方构建代码在登录前就已经跑完了。
- **生成的 TOTP 会在日志中屏蔽**；登录过程不截图。
- **SimplySign 安装包**固定为 9.4.3.90，同时校验 SHA-256 和 Asseco/Certum 的签名。升级时同步修改 `scripts/Install-SimplySign.ps1` 里的版本号和哈希。
- **登录方式**：首选 `SimplySignDesktop.exe /autologin <账号> <令牌>`，失败时改为在登录对话框里填写。每次重试都用新的 30 秒窗口：同一窗口里被拒过的令牌，Certum 不会再接受。
