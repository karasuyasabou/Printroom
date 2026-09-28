# 0.3.69 模块精简验收

日期：2026-09-28。固定交付 `output/Printroom.app`，版本 0.3.69 / build 1，标识 `studio.printroom.local.v3.3`。用户授权由只读分析进入清理实现。本轮没有算法、schema或几何版本变化；0.3.68 的用户手动确认不作为本版人工验收。

## 实现范围

- 删除 EditorModel 无消费者的状态文字、嵌入 profile 文案和片基统计，以及旧缓存清理、矩阵/导出设置包装、旧裁剪同步和快捷键包装入口。错误仍由实际错误字段展示。
- ImageService 删除无生产调用的全图读取、单像素、导出和手工失效接口；调用者分别使用 SourceImageIO、区域读取和 ExportEngine。日常片基校准不再计算无人使用的统计；Core诊断算法和测试保留。
- SourceStamp 合并预览、缩略图与整卷分析的源身份校验，复用一次文件属性读取。RAW底层完整修订、几何准备校验、分层缓存、任务取消均保留。
- ProjectPersistence 集中两秒延迟保存与成功保存令牌；冲突不推进令牌，dirty、撤销及保存失败处理继续由编辑器持有。
- ParameterSnapshot 统一完整调色复制和选择性同步；FrameRecord 共用手动裁框约束和来源标记。单帧提交、其他所选帧同步仍为各自撤销事务，先验证全部目标再发布。
- RAW生产缓存容量只由 ManagedDiskCache 统计；旧中间文件清理及测试专用限额保持。删除未使用的可选manifest字段，旧JSON额外字段仍可解码。
- 六个窗口QA脚本共用构建函数。裁剪脚本改用当前“完成→同步”流程，并明确同步命令为程序调用。导出脚本更新为当前独立设置sheet、ZIP/应用裁剪复选框；删除已无调用的旧附件挂载方法。
- 五份一次性白点补偿工具归档到 `scripts/archive/white-compensation/`，历史验收原文保留。README改为当前入口，架构文档优先给出现行职责，旧正文保留在历史附录。
- 应用包去掉两份不参与运行的原始LUT副本，减少 **1,941,199字节** 资源载荷（不等于整个应用净体积差）；仓库原始资产不删除。包内两份派生LUT与源文件逐字节相同，LibRaw源码/许可证保留。

## 工程验证

日志在被Git忽略的 `scratch/cleanup-0.3.69/`，本文件保留可复核结论。

1. `scripts/test.sh --build-system native --no-parallel`：XCTest记录234项，其中11项跳过、0失败；Swift Testing记录158项，其中6项跳过、0失败。共392项，实际执行375项通过、17项跳过。日志 `default-tests.log`。
2. 重点编辑/裁剪/缓存/矩阵/快捷键回归：77项通过；更新旧布局和矩阵断言后，22项通过。日志 `targeted-serial.log`、`layout-tests.log`。最后删除无调用的导出附件方法后，4项ExportProfileOptionsTests复测通过，日志 `export-options-tests.log`。
3. CPU/Metal阶段比较通过：D3最大绝对误差 `3.8146973e-06`，Final最大绝对误差 `1.2516975e-06`、最坏单轮RMS `3.2846768e-08`；未放宽容差。导出、取消、覆盖保护、旧项目迁移、外部修改冲突和缓存源替换回归均包含在默认套件中。
4. 六个独立窗口驱动完成编译：Crop、Editor、Viewport、Matrix、RAW使用debug，Export另以release重编译。共享构建脚本和全部修改的shell脚本通过 `bash -n`。日志 `qa-build-local.log`、`export-panel-final.log`。真实RAW/Viewport/Crop完整键鼠路径未执行，编译不代表其全部运行模式通过。
5. `scripts/build-app.sh`：release构建、随包ICC/LUT及五个输出profile、Apple M4 Metal渲染、SDR UInt16预览检查、ad-hoc签名及严格复核通过；验证成功后替换固定应用。日志 `package.log`。
6. 原始ICC及两份清单登记的LUT SHA-256与基线相同。`TEST/` 当前不存在，完整资产清单核对明确报告10张TIFF缺失，不将其记为通过。源资产、算法规范和用户项目未修改。

## 窗口导出验证

更新后的 ExportPanelQA 已实际通过：3次取消保持项目字节和输出目录不变，4次确认覆盖当前/所选/整卷入口，7份24×16合成TIFF独立回读，核对原卷编号、16-bit、ICC字节及ZIP/无压缩。五个ICC选项与ZIP/应用裁剪控件映射通过；实际导出回读使用Display P3、sRGB、Adobe RGB及ProPhoto四种。真实生产设置sheet承载在隔离测试窗口，使用真实导出/取消按钮动作；目的地直接设为临时目录，系统文件夹选择器人工交互未执行。日志 `window-final.log`，输出位置记于其 `OUTPUT` 行。

旧导出QA既引用移除的压缩下拉框，也假定NSSavePanel附件和同步模态返回；已改为独立设置sheet及异步完成等待。首次窗口回归遇到摘要sheet/焦点竞争，最后用隔离宿主并明确等待主窗口成为key，完整导出流程通过。

EditorWindowQA 的 `--crop-preview --appearance` 已完成深/浅主题×开/关四个状态渲染；抽查深色开启、浅色关闭两张截图，工具栏、画布、右侧参数和Filmstrip均正常显示。该驱动使用无裁框的合成内存画面，只作为窗口渲染检查；裁剪像素及直方图语义由默认自动测试覆盖。日志 `editor-window-run.log`，图片位于 `scratch/editor-ui-qa/crop-preview-*.png`。直接调用驱动首次缺少输出目录，补齐原shell入口负责创建的目录后成功。

## 验证中发现的旧问题与边界

- 初次并行AppKit集成套件出现预览超时；串行复测及完整默认回归通过。README已给出串行命令。沙盒内不能创建Metal上下文或启动SwiftUI宏插件，改在本机权限环境执行；未修改运行算法规避检查。
- 全量 `--full` 曾实际执行，但因缺少 `TEST/TIFF/` 在实片读取相关测试失败；同时暴露旧测试仍预期104px内嵌工具栏，以及向当前LED默认值再次设置LED后等待刷新。布局断言按实际38px行+1px分隔改为39px，并补充“找到裁剪控件”的非空检查；矩阵测试改为LED→Identity后检查全部缩略图更新。
- 真实十张参考TIFF、全尺寸实片导出、真实Adobe RAW、专项性能测量和用户主观色彩/交互外观验收未完成。没有用合成素材替代实片测试，也没有自动放宽算法阈值。
- 独立SwiftUI编译保留原有并发隔离警告；构建成功不代表已清零这些警告。未扩大本轮范围重写界面或底层数值管线。
