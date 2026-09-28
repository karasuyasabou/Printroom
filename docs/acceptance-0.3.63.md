# 0.3.63 Filmstrip黄点移除验收

2026-09-20，构建1，交付 `output/Printroom.app`。

- 移除缩略图右下角的已编辑圆点，其原触发条件为调色偏离默认、方向非单位或存在裁剪。仅删除展示代码，参数与保存保持。
- `scripts/build-app.sh` release构建、ICC/LUT与五输出空间资源检查、Metal渲染、签名验证通过。日志 `/tmp/printroom-0363-build.log`，包内版本已核对为0.3.63。
- `git diff --check`通过。本次为单一装饰元素删除，未新增测试，未运行数值回归和窗口截图；实际窗口视觉验收待执行。
