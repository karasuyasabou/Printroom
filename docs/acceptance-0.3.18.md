# 0.3.18 Filmstrip 批量方向（2026-09-11）

新增用户要求的四个右键菜单项，数量与作用范围按 interaction.md。复用既有方向及裁剪契约，不改变算法或项目格式。

- `scripts/test.sh --filter 'EditingV2Tests|SelectionCropTests'`：15 项测试通过。新增集成测试覆盖四种操作、不同初始方向、未选帧保持、选择与锚点保持、一次撤销/重做、保存重开、裁剪期间禁用和目标文件丢失时整组不改。既有测试回归裁剪同步、旧几何迁移及主预览方向配对。
- 首次测试编译暴露测试代码使用了不可写状态及不匹配的选择 API，修正为现有方法和字段后编译通过。首次沙箱运行无法初始化 Metal 资源，允许访问本机 Metal 后全部通过；日志 `/tmp/printroom-batch-tests.log`。
- `scripts/build-app.sh`：release、ICC/LUT/四输出 profile、Apple M4 Metal、SDR 预览和严格签名验证通过，固定包 `output/Printroom.app`，0.3.18 / 构建 2。日志 `/tmp/printroom-batch-build.log`。
- `git diff --check` 通过。保留已有工作区修改。

未执行真实右键菜单点击或窗口视觉验收；本轮不重跑全尺寸 RAW 或全套原始 TIFF 验收。


## 构建 3：裁剪底色

裁剪暗色遮罩裁切到旋转后的照片范围，底色按 interaction.md 与普通预览一致。`scripts/test.sh --filter 'CropCanvasTests|PreviewCanvasTests'`：14 项通过。首次沙箱运行有一项因 Metal 资源不可用失败，允许本机 Metal 后通过。`scripts/build-app.sh` release、资源、Metal、SDR预览与严格签名验证通过，交付 0.3.18 / 3；首次沙箱验证失败时旧包保持，成功后覆盖。日志 `/tmp/printroom-crop-backdrop-tests.log`、`/tmp/printroom-crop-backdrop-build.log`。真实窗口视觉验收未执行。
