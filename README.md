# Printroom

macOS 原生 SwiftUI 应用，计划将彩色负片的 16-bit 线性 RGB TIFF，经密度调色和 Kodak 2383 D65 LUT 转为预览与 16-bit TIFF 输出。一个文件夹就是一卷底片。

**当前状态：工程准备完成，尚无应用代码、Xcode 项目、构建或应用测试结果。** 下一步由用户明确启动开发。

## 从这里开始

| 文件 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 代理执行规则与阅读顺序 |
| [产品规范](docs/product.md) | 定位、范围、用户流程 |
| [算法与色彩管线](docs/pipeline.md) | 单位、矩阵、校准、LUT、色彩管理 |
| [架构与数据](docs/architecture.md) | 模块边界、项目模型、保存与恢复 |
| [交互规范](docs/interaction.md) | Filmstrip、多选、复制参数、应用、撤销 |
| [验收计划](docs/validation.md) | 数值、文件、GPU 和交互验收 |
| [阶段计划](docs/roadmap.md) | 阶段交付物与当前状态 |
| [决策记录](docs/decisions.md) | 用户确认、工程默认、待验证项 |
| [资产说明](assets/README.md) | 现有资产事实与只读策略 |
| [资产清单](assets/manifest.json) | 大小、SHA-256、TIFF/ICC/LUT 元信息 |

## 目录

```text
Printroom/
├── AGENTS.md
├── README.md
├── .gitignore
├── .gitattributes
├── docs/
├── assets/
├── ICC/             原始 profile，纳入本地版本管理
├── LUT/             原始 LUT，纳入本地版本管理
└── TEST/            10 张原始参考 TIFF，仅本地保存，Git 忽略
```

目前不预建空的应用模块、代理角色配置或自定义技能。未来代码目录随阶段实现创建。

## 本地环境与工程默认

2026-09-07 实测：macOS 26.6.2（25G83），Apple Silicon arm64，Xcode 26.6（17F113），Apple Swift 6.3.3，Git 2.50.1。Developer Directory 为 `/Applications/Xcode.app/Contents/Developer`。

拟定开发目标：macOS 14.0+、Apple Silicon、Swift 6 语言模式、SwiftUI + Metal；CPU 核心拟采用可单独测试的本地 Swift Package。实际最低系统兼容性尚未测试；第一版不承诺 Intel 支持。工具链更新须记录新的实测环境。

## 工程准备验证

在仓库根目录执行：

```sh
shasum -a 256 -c assets/SHA256SUMS
python3 -m json.tool assets/manifest.json > /dev/null
git status --short --branch
```

第一条会读取约 1.64 GB 参考 TIFF。其他机器缺少 `TEST/` 时，会报告参考文件缺失；根据清单恢复原始文件，不用占位图片冒充。JSON 验证需要 Python 3，应用本身无 Python 依赖。

没有应用构建命令可执行。阶段 M1 创建工程后再补充已验证的构建与测试命令。

## Git 与输出

默认分支 `main`，仅本地仓库。记录规范、资产清单及原始 ICC/LUT；参考 TIFF、缓存、构建产物、测试临时项目和导出文件不进入 Git。新生成内容使用 `scratch/` 或 `output/`。Git 忽略不是文件保护措施，仍须遵守原始资产不变约定。
