# Printroom 0.2.0 验收记录

日期：2026-09-07。本记录与交付源码一起保存在本地提交（`git log -1 --oneline`）；起始提交 `d744f60`，保留了任务开始时尚未提交的 0.1.0 显示与视口修正。无远端、无推送、无发布。

交付：`output/Printroom-0.2.0.app`，约 3.3 MiB，arm64，版本 0.2.0 / build 1，独立 identifier `studio.printroom.local.v2`。旧 `Printroom-0.1.0.app` 未被替换，旧偏好未修改。开始时未发现运行中的 Printroom 进程。schema 2，算法仍为 `printroom-density-v1`。

## 环境与可执行命令

Apple M4、macOS 26.6.2 (25G83)、Xcode 26.6、Swift 6.3.3；部署目标 macOS 14。GPU 与 NSFileCoordinator 测试使用宿主权限；最初受限沙盒的 Metal/文件协调失败没有记作通过。窗口验收在本机图形会话执行，无 Photoshop。

```sh
scripts/test.sh --full
scripts/test.sh --filter 'MetalTests|ExportColorTests|TIFFCodecTests'
scripts/measure-performance.sh
scripts/measure-performance.sh --export
scripts/viewport-window-qa.sh --release
scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 output/Printroom-0.2.0.app
shasum -a 256 -c assets/SHA256SUMS
```

实际日志均在被忽略的 `scratch/`：`test-v2-full.log`、`test-v2-final-edges.log`、`performance/*.log`、`window-v2-release-final.log`、`build-v2.log`、`runtime-v2-isolated.log`、`assets-v2.log`。窗口 PNG 位于 `scratch/viewport-qa/`。测试来源均为只读参考或临时副本，原始 `TEST/ICC/LUT` 不写入项目或测试产物。

## 实际结果

| 验收项 | 执行结果 |
| --- | --- |
| 完整自动验收 | 93 个 XCTest + 31 个应用测试通过，0 失败。另两个按需性能入口在普通 full 中按开关跳过，随后单独实际执行通过 |
| 最后导出边界修正回归 | Metal、11 个输出测试、9 个基础 TIFF 测试通过；此次未开 full 的两个 TIFF 大文件测试已在前述 full 中通过 |
| schema 1→2 | 读取时不写盘；ID、校准、Timing/Contrast不变，默认 identity/P3/无压缩；保存/重开恢复；损坏/未来字段拒绝 |
| 用户方向 | 八状态全组合、整像素及半开ROI逆映射；Undo/Redo/重开；复制只含Timing/Contrast；原TIFF方向与用户方向分别验证 |
| 直方图 | 合成 bins、0/1端点、域外、NaN/Inf、单位与取消；快速切帧/阶段/调参只发布最新结果；1:1局部不替换整图统计 |
| ICC与编码 | 四profile × 两压缩，3×16-bit、orientation=1；TIFFCodec与独立ImageIO回读样本一致、ICC字节一致 |
| 批量与单张 | 八方向的单张/批量输出字节一致；任务开始后改目标/参数/方向/profile不改变已固定任务；取消、缺失失败继续、重名、源保护、目标竞争重试通过 |
| 重新定位 | 实际TIFF预校验；稳定ID、调色和方向保留；默认占位帧合并、已有编辑冲突拒绝、片基来源复核；Undo/Redo后的实际选择与重开一致 |
| 缓存与取消 | 6项服务测试通过：条带ROI、TIFF八方向、原文件替换、LRU限额、取消、16-bit PNG/ICC、磁盘TTL/限额/陌生文件及symlink保护 |
| 真实参考 | 十张7008×4672 TIFF完整样本与独立Python/zlib解码一致；完整尺寸P3管线导出回读通过 |
| 原始资产 | 12/12 SHA-256一致 |
| 打包 | release构建、ad-hoc签名、deep/strict签名校验、Metal/四输出profile/展示格式冒烟通过 |
| 独立运行资源 | 将.app复制到系统临时目录，禁止读取工作区 `.build`、原始 `ICC/` 和 `LUT/`，从卷外运行 `--verify-resources` 成功；未依赖源码树资源 |

异步审查实际发现并修复了：同卷重新载入后的过期采样写回、旧帧读数错误弹到新帧、加载失败后spinner不结束、方向改变时旧图使用新几何、重连撤销后的lastActive不一致。均有回归测试。

## 数值证据

CPU/Metal：4099像素（固定种子及边界）×2矩阵×3调色配置×7阶段。最大绝对误差 `3.8146973e-6`；各阶段最差运行 RMS 如下，全部在规范预算内。

| 阶段 | 最大绝对误差 | 最差运行 RMS |
| --- | ---: | ---: |
| L0 / L1 | 0 | 0 |
| D0 | 1.1920929e-7 | 1.1294116e-8 |
| D1 | 2.3841858e-7 | 1.3525171e-8 |
| D2 | 2.3841858e-7 | 1.5455389e-8 |
| D3 | 3.8146973e-6 | 2.4693898e-7 |
| Final | 1.3709068e-6 | 3.3107147e-8 |

实际 `DSC07079.tiff`：片基ROI `(359,604,79,494)`，LED矩阵，Timing `(30,5,-3,7)`，Contrast `(1.05,.95,1.02,1.1)`；全尺寸导出与CPU抽样最大差 `7.748604e-6`（包含16-bit量化），原P3 ICC精确一致。debug全管线导出24.81秒，仅作为正确性执行记录；release性能另列。

ICC真实转换按固定profile的matrix/TRC、D50 PCS计算；源/目标曲线取自ICC，未对Final重复Gamma编码。公开原色+独立Bradford/transfer参考最大误差：sRGB `2.01957e-4`、Adobe RGB `9.84460e-5`、ProPhoto `7.09138e-5`，包含ICC定点精度和标准白点差异。正常域与CoreGraphics参考最大差分别 `1.19925e-4`、`1.33663e-4`、`5.96046e-8`；P3直接输出差0。

暗部解析检查实际发现系统CMM的附加线性段：P3中性 `.02` → ProPhoto，标准ICC结果 `.00061205094`，系统Float32路径约 `.01999999955`。因此生产输出使用固定ICC的matrix/TRC求值，Double计算后统一量化。另为ProPhoto使用正确D50和编码域`1/32`断点的新profile；系统ROMM的断点不采用。原始ICC、LUT和密度算法均未修改，详细契约见 pipeline §11 和资源PROVENANCE。

## 窗口与性能

实际 EditorView 窗口验证了0.25–16倍缩放、四向拖动、视口外选区、大小窗口、原TIFF旋转/镜像、用户追加方向、1:1、RGB与密度直方图及已校准真实参考图。鼠标事件经NSApplication/NSWindow派发到真实Fit、框选、Filmstrip、1:1控件。发现附加空contextMenu使Filmstrip点击不可靠，改为可用帧原生Button、缺失帧单独contextMenu后回归通过。

最终截图 `21-v2-calibrated-reference.png` 已人工查看：主预览、方向和缩略图符合当前模型，白边、皮肤及衣物可辨，画面和选区无越界，直方图单位可读。该观察不替代用户调色审美或硬件色度验收。

下表为release、独立进程、温热文件系统缓存的本机测量；没有强制清空系统缓存。对照“完整解码策略”也使用修复后的底层读取，不能当作0.1.0二进制的完整性能对比。

| 场景 | 条带/按需策略 | 完整解码策略 |
| --- | ---: | ---: |
| 首次1600预览解码 | 0.394秒 | 0.404秒 |
| 首次解码阶段峰值RSS | 77.81MiB | 255.50MiB |
| 十张240缩略图 | 0.813秒 | 4.042秒 |
| 十张连续切图解码 | 3.687秒 | 4.067秒 |
| 最近帧缓存命中 | 0.095毫秒 | 388.6毫秒 |
| 整个测量流程峰值RSS | 403.28MiB | 529.17MiB |

20次串行调参GPU+UInt16显示准备：平均12.71毫秒、最大16.07毫秒；不是滑杆端到端延迟或FPS。2048×1536原始区域读取0.171秒；当前参考条带布局的中途解码取消约0.483毫秒。源LRU为54,579,200bytes/2项，低于64MiB预算。

实际release窗口连续30次调参：20毫秒计时请求，实到中位27.81毫秒、P95 29.55毫秒、最大32.72毫秒；包含事件循环、SwiftUI和绘制竞争。debug对应约200毫秒，交付使用release。

两张实际全尺寸照片，第二张顺时针90°；LED及调色参数同上：

| 输出 | 两张耗时 | 峰值RSS | 文件大小（字节） |
| --- | ---: | ---: | --- |
| P3 / 无压缩 | 1.720695秒 | 252.78MiB | 196450226 / 196450810 |
| ProPhoto / Deflate | 11.496380秒 | 257.86MiB | 171394236 / 168656587 |

回读尺寸分别7008×4672、4672×7008，正确profile及原生8×8区域解码通过。第二帧峰值未累加完整原图；总体低于初始RSS+单张UInt16原图+128MiB工作空间预算。初次性能测试错误要求malloc立即将释放页归还OS，断言失败；随后改用跨帧峰值增长和总预算检查，原失败日志保留 `export-p3-rss-assumption.log`，没有把RSS常驻直接等同于Swift对象泄漏。

本机后续回归目标（工程默认，非跨设备承诺）：预览解码≤0.75秒、10缩略图≤1.5秒、20次串行GPU/显示平均≤25毫秒、窗口20毫秒计时P95≤50毫秒、上述预览测量流程峰值≤512MiB；两帧P3≤3秒、ProPhoto Deflate≤20秒、导出峰值≤初始RSS+单图+128MiB。均由以上实测制定，不以降低数值精度实现。

## 简短操作与剩余限制

打开新版 → 打开胶卷副本 → 框选片基 → 调Timing/Contrast → 方向菜单旋转/翻转及撤销 → 点1:1和平移 → 看RGB/单通道及阶段直方图 → 选择输出ICC/压缩 → 导出当前/所选/整卷 → 导出中继续编辑或取消 → 查看逐张结果 → 重开确认恢复。缺失帧右键重新定位；输出面板可清理缓存。

- schema2被新版保存后，0.1.0会明确拒绝新结构；算法和默认画面保持不变，避免两个版本同时编辑同一卷。
- 当前只支持classic RGB UInt16条带TIFF，不支持BigTIFF、tile、多页、alpha等扩展；导出只提供四个已验证的固定ICC。
- 1:1单区域最多8,388,608像素；超大窗口超限会报错，不降精度。巨大压缩条带仍需整条解压，内存/取消延迟可能高于当前参考文件。
- 手动重连限定卷内直接子文件；内存中保留全卷缩略图展示副本，但不会常驻整卷全尺寸原图。本次10张卷之外的超大卷可用性未实测。
- 未执行真实磁盘写满、进程强杀时文件系统耐久性、旧macOS/Intel/更多显示设备或硬件色度仪验收。写入失败/竞争/取消的可控注入已验证，未将其等同于上述全部场景。
- LUT的精确扫描标定、Cineon物理衔接及用户最终色彩外观验收继续保留边界；不宣称与未提供的第三方软件逐像素相同。
