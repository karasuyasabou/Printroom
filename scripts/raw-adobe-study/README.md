# RAW / Adobe 路径实验工具

这些是本地研究工具，不是 Printroom 的新 RAW 导入功能。结论与边界见 [实验记录](../../docs/raw-adobe-study-2026-09-09.md)。所有路径基于仓库根目录，输入只读 `TEST/RAW`，输出只写 `scratch/raw-adobe-study`。不运行在原始资产目录内，不修改桌面的 open_make_tiff 源码。

## 文件

- `adobe_matrix.py`：8 张原始 ARW 的单遍/两遍对照，输出 Adobe 调用参数、耗时与元数据。
- `adobe_variants.py`：默认 DNG 兼容级别、Camera Raw 5.4 预设、无损压缩实验。
- `adobe_order.py`：兼容预设与 `-l/-u` 顺序、缺少 `-l` 的对照。
- `decode.cpp`：LibRaw 0.22.1 驱动，镜像原始源码处理参数，输出 RGB16 与尺寸/计时；额外参数用于逐项对照。
- `compare.py`：完整 DNG/RGB 样本比较、参数变体。`affine_formula_diff` 特意保留被实验否定的归一化假设；`subtract_only_diff` 是本批数据验证通过的局部公式。
- `extra.py`：真正源码 TIFF 基准比较、首遍 CFA 比较、压缩/兼容变体、BOX 代理与 native 子进程 RSS。
- `source_reference.go`：最小入口，只调用从用户源码复制的 `internal/convert`，绕过已安装旧应用的 GUI/CLI 生命周期故障。
- `Probe.swift`：调用真正 PrintroomCore 的 TIFFCodec 验证完整读取、代理 TIFF 无损回读、11×11 原片 ROI；刻意附加普通 ProPhoto ICC 证明输入不受 ICC 隐式影响。

Adobe 脚本拒绝覆盖已有目标。解码/分析脚本只会重写自身命名的 scratch 产物。需重做 Adobe 转换时先备份需要保留的实验输出，再清理本实验产生的目标；不要清理 TEST。脚本使用绝对位置的已安装 Adobe/ExifTool，换机器需相应调整。

## 本次实际环境与准备

Python：Codex bundled Python 3.12，路径如下；已带 NumPy/Pillow。另将下列 PyPI 官方包安装在 scratch，未改变系统 Python：

```sh
STUDY_PYTHON=/Users/bao/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3
"$STUDY_PYTHON" -m pip install --target scratch/raw-adobe-study/pylibs --no-deps rawpy==0.27.1 tifffile==2026.8.23 imagecodecs==2026.8.16
```

匹配的 LibRaw 官方源码/头文件由 `https://www.libraw.org/data/LibRaw-0.22.1.tar.gz` 下载，解压在 scratch 下。rawpy wheel 携带 `libraw_r.25.dylib`；本次没有编译或安装系统级 LibRaw。

```sh
clang++ -std=c++17 -O2 -I scratch/raw-adobe-study/LibRaw-0.22.1 \
  scripts/raw-adobe-study/decode.cpp \
  scratch/raw-adobe-study/pylibs/rawpy/libraw_r.dylib \
  -Wl,-rpath,/Users/bao/Desktop/Printroom/scratch/raw-adobe-study/pylibs/rawpy \
  -o scratch/raw-adobe-study/decode
```

## 实际实验命令

在首次运行、目标尚不存在时：

```sh
"$STUDY_PYTHON" scripts/raw-adobe-study/adobe_matrix.py
"$STUDY_PYTHON" scripts/raw-adobe-study/adobe_variants.py
"$STUDY_PYTHON" scripts/raw-adobe-study/adobe_order.py
PYTHONPATH=scratch/raw-adobe-study/pylibs "$STUDY_PYTHON" scripts/raw-adobe-study/compare.py
```

Adobe 在 Codex 沙盒内被系统终止；本次已授权在沙盒外运行上述固定脚本，仍只向 scratch 写入。没有改动 Adobe 安装、权限或偏好。

## 源码参考构建

隔离树为 `scratch/raw-adobe-study/omt-source`。复制用户源码的 `internal/{convert,config}` 与 `pkg/{golibraw,golibtiff,dngconverter,exiftool,icc}`，这些文件保持原样，将本目录的 `source_reference.go` 作为该模块的 main.go。最小模块使用 `module open-make-tiff`、Go 1.25、`github.com/google/uuid v1.6.0`。Go 1.25.12 官方工具链下载到 scratch；Go module/cache 同样位于 scratch。

实际 TIFF 库使用 `/Applications/Siril.app/Contents/Frameworks/libtiff.6.dylib`；官方 `https://download.osgeo.org/libtiff/tiff-4.7.1.tar.gz` 解压后执行 `./configure --disable-shared --disable-tools --disable-tests --disable-contrib --disable-docs` 生成匹配读取类型所需头文件。没有编译/安装系统 TIFF 库。

实验目录中的 `pkg-config` shim 仅向 Go CGo 提供上述 LibRaw/TIFF include、link 和 rpath 参数；`linklibs/libtiff.dylib` 是指向已安装库的符号链接。实际构建命令（cwd=omt-source）：

```sh
GOMODCACHE=/Users/bao/Desktop/Printroom/scratch/raw-adobe-study/go-mod \
GOCACHE=/Users/bao/Desktop/Printroom/scratch/raw-adobe-study/go-cache \
PKG_CONFIG=/Users/bao/Desktop/Printroom/scratch/raw-adobe-study/pkg-config CGO_ENABLED=1 \
/Users/bao/Desktop/Printroom/scratch/raw-adobe-study/go/bin/go build -a -mod=mod \
  -o /Users/bao/Desktop/Printroom/scratch/raw-adobe-study/omt-reference .
```

链接时 Siril 库的旧 install name 需要在**新测试可执行文件**上改为当前库路径并重新 ad-hoc 签名：

```sh
install_name_tool -change /Users/Shared/work/jhb-1.2/lib/libtiff.6.dylib \
 /Applications/Siril.app/Contents/Frameworks/libtiff.6.dylib scratch/raw-adobe-study/omt-reference
codesign --force --sign - scratch/raw-adobe-study/omt-reference
```

先将 ARW 复制到 `scratch/raw-adobe-study/reference`，再把这些副本作为参考驱动的输入。它会像原程序一样旁存 TIFF 和 DNG，因此**不得把 TEST 中原图直接传给该 Go 参考驱动**。

```sh
scratch/raw-adobe-study/omt-reference scratch/raw-adobe-study/reference/*.ARW
PYTHONPATH=scratch/raw-adobe-study/pylibs "$STUDY_PYTHON" scripts/raw-adobe-study/extra.py
```

原始源码默认允许 fallback，但本次所有执行日志均确认 Adobe 两遍成功，未走 fallback。这里的参考程序不附带 ExifTool 实例，因此不比较拍摄元数据，只比较像素。

## Printroom 实际读取验证

实验目录 `swift-probe` 是一个最小 Swift package，通过本地 package dependency 导入当前 PrintroomCore，Probe.swift 作为 executable main.swift。未在正式 Package.swift 添加任何 target。

```sh
CLANG_MODULE_CACHE_PATH=/Users/bao/Desktop/Printroom/scratch/raw-adobe-study/clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/Users/bao/Desktop/Printroom/scratch/raw-adobe-study/swift-cache \
swift run --disable-sandbox --package-path scratch/raw-adobe-study/swift-probe \
 --scratch-path scratch/raw-adobe-study/swift-build -c release Probe /Users/bao/Desktop/Printroom
shasum -a 256 -c scratch/raw-adobe-study/raw-before.sha256
```

主要 JSON 证据已归档到 docs，scratch 的大图/编译缓存可在无需复查后清理。没有运行整套既有应用回归，因为本轮未改产品代码。
