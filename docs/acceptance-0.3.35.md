# 0.3.35 RAW 缓存快速命中

## 变更

RAW 缓存命中不再先通读原片计算 SHA256；已有代理继续验证完整性，旧缓存自动迁移。缓存契约见 architecture.md 的 0.3.35 节。图像算法、项目数据、TIFF 路径和四路并发保持。

## 验证

- `scripts/test.sh --filter 'RAWSourceServiceTests|RAWImageServiceTests|RAWPrewarmerTests|DiskCachePolicyTests'`：26 项 XCTest 通过；2 项 RAWPrewarmer Swift Testing 通过，1 项真实 Adobe 集成测试因未启用环境变量跳过。
- 新建服务实例（空内存缓存）读取已有代理：与首次生成像素完全相同，原片摘要读取从首次生成的 64 MiB 降为 **0 字节**，代理摘要仍读取。合成3202×11图像的本次命中约2.1ms，仅用于路径验证，不代表真实照片或用户磁盘速度。
- 旧布局迁移后连续两次新建服务均无需读取原片或调用转换器。
- 同大小改写并恢复mtime仍因完整文件修订变化而失效；旧冻结身份被拒绝，新请求重新转换。
- 既有损坏代理重建、Adobe版本变化、取消、跨实例互斥、四槽限制和缓存淘汰回归通过。
- `scripts/build-app.sh`：release构建、ICC/LUT及四输出profile校验、Apple M4 Metal渲染、UInt16预览格式及严格签名验证通过。交付 `output/Printroom.app`，0.3.35（构建1），应用标识保持。受限环境首次验证无法创建Metal上下文，保留原应用；随后在正常本机权限下验证成功后替换。

## 待验收

用户实际胶卷首次打开速度与真实窗口体验尚未计时或人工验收；本轮不宣称真实 Adobe 数值复验通过。
