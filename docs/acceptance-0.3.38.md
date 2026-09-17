# 0.3.38 裁剪角度快捷键

2026-09-16，交付 `output/Printroom.app`，构建 1。

裁剪 Q/E 接入显示角度调整，与角度按钮共用步进实现；帮助窗口和按钮悬停提示同步更新。交互以 interaction.md 为准，算法、几何和项目版本保持。

- `scripts/test.sh --filter 'EditorKeyboardRoutingTests|CropEditingTests|SelectionCropTests'`：允许本机图形访问后，23 项测试全部通过。新增覆盖 Q/E 正负步进、重复按键、±10° 边界、修饰键和文本保护、加载禁用、重置后调角度、草稿不提前写入及取消恢复。既有测试覆盖裁剪提交/撤销、切图保存和方向转换。
- `scripts/build-app.sh`：release、包内 ICC/LUT、四输出配置、Apple M4 Metal 渲染、UInt16 预览及签名验证通过，已替换固定应用路径。
- 初次沙盒测试与打包因无法创建 Metal 上下文失败；旧应用保留，提升执行权限后重跑成功。
- `git diff --check` 通过。工作区既有及并行修改保留；未改动原始 TEST/ICC/LUT。

真实窗口的 Q/E 长按手感尚未人工验收；本轮未执行全套图像数值与导出回归。
