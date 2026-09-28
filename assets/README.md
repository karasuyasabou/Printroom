# 资产与复现

原始文件身份见 [manifest.json](manifest.json)、[SHA256SUMS](SHA256SUMS) 和 [RAW-SHA256SUMS](RAW-SHA256SUMS)。清单中的参考照片仅在本机保留，不随仓库提供。

运行资源使用 `ICC/DCIP3_D65.icc` 与 `DerivedLUTs/diffuse-white-v1/` 下的两份电影表。原始表位于 `LUT/`，不重复打入应用。派生表的 [manifest](DerivedLUTs/diffuse-white-v1/manifest.json) 记录来源、目标和哈希，可用 `scripts/generate-white-luts.py`（需要 NumPy）复现；公式见 [算法规范](../docs/pipeline.md)。图标源码和重建命令见 [AppIcon/README.md](AppIcon/README.md)。

## 开发约定

- 原始 `TEST/`、`ICC/`、`LUT/` 不覆盖、不重编码、不移动。不要为了通过检查重写资产哈希。
- 测试项目、缓存、截图与导出写入 `scratch/`、`output/` 或临时目录。需要旁存项目时先复制照片到临时卷。
- 参考照片齐备后，可用以下命令复核全部原始文件；缺失照片必须记录为未完成，不能以占位文件代替：

```sh
shasum -a 256 -c assets/SHA256SUMS
shasum -a 256 -c assets/RAW-SHA256SUMS
```

哈希检查只证明文件字节身份，不代表图像算法或视觉验收。`manifest.json` 的 `schema_version` 是清单结构版本，不是应用项目版本。
