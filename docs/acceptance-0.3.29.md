# 0.3.29 裁剪切图保存

日期：2026-09-12。交付 output/Printroom.app，版本 0.3.29 / 1。算法 v5、schema 6、几何版本 2 保持；保留工作区既有修改，未提交 Git。

- 切图前提交当前裁剪并立即自动保存，保持裁剪模式。具体行为以 interaction.md 为准，帮助文字同步更新。
- `scripts/test.sh --filter 'SelectionCropTests|CropEditingTests|RAWGeometryTests|EditorKeyboardRoutingTests'`：25 项测试、4 个 suite 全部通过，含点击与左右键两种参数化用例。覆盖即时项目回读、重置全图、逐帧撤销重做、旋转坐标、目标扩选、快速切图、加载中取消、RAW 几何及键盘路由。
- 首次沙盒运行无法创建 Metal 上下文，改在可访问本机 Metal 的环境执行。回归发现旧快速切图测试把独立 Final 直方图当作 L0；改为比较同一均匀源裁前裁后的通道分布和像素数，随后全部通过。
- `scripts/build-app.sh`：release 构建、包内 ICC/LUT、四输出 profile、Metal Apple M4、UInt16 展示与严格签名验证通过，固定包已替换；包内版本回读为 0.3.29。
- 临时日志：/tmp/printroom-crop-tests.log、/tmp/printroom-crop-build.log，可清理。
- 未执行真实窗口手动切图验收、真实 RAW 转换或全套导出回归；本轮未改变图像管线，原始 TIFF、ICC、LUT 未改动。实际切图手感待用户试用。
