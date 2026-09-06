# 原始资产登记

清单日期：2026-09-07。所有路径相对于仓库根目录。资产由用户放入工作空间，原始 ICC/LUT 作者和许可未独立核验；当前仅本地开发登记。

| 资产 | 数量 | 用途 | Git 策略 |
| --- | ---: | --- | --- |
| `ICC/DCIP3_D65.icc` | 1 | 解释 Final、默认 TIFF 嵌入 | 跟踪原始字节 |
| `LUT/DCI-P3 Kodak 2383 D65.cube` | 1 | 密度到最终 Kodak 2383 外观 | 跟踪原始字节 |
| `TEST/DSC07079.tiff` 至 `TEST/DSC07088.tiff` | 10 | 导入、片基、预览、导出实际样本 | 仅本地；清单入 Git |

参考 TIFF 共 1,639,705,084 字节（约 1.64 GB）。每张均 7008×4672、16-bit RGB、Deflate 压缩，嵌入 `ProPhoto RGB Linear`，三个 TRC 的 Gamma 为 1.0。这是元信息实测，不等于像素内容和物理线性已经验证。

独立工作 ICC 描述 `P3 D65 Gamma 2.6`，Gamma 实际编码约 2.6000061。ICC 的 PCS 为 XYZ；其 D50 连接空间或色适应 tag 不等于工作显示白点应改为 D50。

LUT 为 33³，输入域 0–1，文件头注明 Cineon Log、Kodak 2383 D65、DCI-P3 Gamma 2.6。精确数据与 SHA-256 见 [manifest.json](manifest.json)。

## 只读与复核

不重命名、不移动、不覆盖、不重新压缩原始资产。测试只读原文件，输出到 `scratch/`、`output/` 或临时目录；测试旁存卷项目时先复制 TIFF 到临时卷目录。不要在 `TEST/` 生成缩略图或 `.printroom.json`。

在仓库根目录：

```sh
shasum -a 256 -c assets/SHA256SUMS
```

该命令只读原始文件，不修改清单。当前检查覆盖文件字节、第一 IFD 与 profile/LUT 元信息，不包含图像像素解码或完整色彩验证。后续若资产有意更换，应新增版本或路径、记录来源与原因，再显式更新清单；不可在验证失败后直接重写哈希使之“通过”。

原始 LUT 第 2 行注释自带尾随空格，初始提交的完整 `git diff --check` 会报告它；按原始字节保留。文档空白检查应排除该不可变 LUT，不为通过格式检查改写资产。

## 清单字段

- 顶层 `schema_version` 是资产清单结构版本，不是应用项目版本。
- `path`、`bytes`、`sha256` 是文件身份基线；`immutable_source` 标记原始资产。
- `kind`、`purpose`、`git_policy` 表示用途和版本管理方式。
- `metadata` 保存实测头信息。TIFF 缺省的 orientation/sample format 在来源字段明确标注，不能误称文件内显式 tag。
- `input_policy` 是参考 TIFF 的拟采用处理方式，属于工程约定而非文件原生元信息。
- `verification_scope` 明确本轮检查范围。

新机器克隆本地工程副本后，按清单放回原始参考 TIFF 并核对 SHA-256。缺少参考图片不影响阅读文档，但实际 TIFF 验收必须明确标记未运行，不能用空文件代替。
