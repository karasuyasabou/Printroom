# 0.3.28 RAW代理返回与异步维护

用户要求优化已定位的缓存锁等待，保持4路并行。源任务完成后释放准备槽和读取锁，结果发布不等待维护；后台utility队列合并维护请求，继续使用跨进程独占锁。缓存存储契约以 architecture.md 为准，Adobe处理、代理采样、算法v5与schema6保持。

## 已执行验证

- RAWSourceServiceTests 19项通过，包括新增“另一实例转换持续阻塞时，6张其他原片仍能返回并复用槽位；阻塞解除后小容量缓存收敛”回归。原有四槽、跨实例复用、取消、损坏重建、显式清理和临时目录保护通过。清理断言改为等待后台维护完成。
- RAWPrewarmerTests 2项通过，固定4个请求及取消保持。
- 启用真实Adobe的RAWEditorIntegrationTests、RAWImageServiceTests、RAWGeometryTests及RAWPrewarmerTests共8项Swift Testing通过；同次19项核心测试通过。打开/切帧/保存重开、代理取样/几何及异步裁剪取消覆盖。首次受限执行被系统文件协调权限阻挡，放行后完整重跑通过。
- 同一用户卷2026-07-06-2/RAW共37张，独立空代理缓存、4路，优化前44.499秒，优化后19.485秒，缩短56.2%。首批四张优化后2.93–3.18秒返回；此前第二、第三张可能等待至整卷末尾。第一项返回时间优化前2.785秒、优化后2.930秒，不宣称首次出图更快。
- 重新创建服务后的已有缓存读取：1.469秒→0.556秒。测试主进程峰值RSS：3.01GiB→2.57GiB，不包含Adobe子进程。
- 37张proxy.tiff与thumbnail.tiff逐文件SHA256均与优化前一致，且与各自manifest一致；原片与原卷项目只读。
- 原始测量结果见 raw-preparation-0.3.28.json。上述为服务层单轮对照，不包含完整UI显示时间，未清空操作系统文件缓存；不等同于跨机器、冷磁盘或颜色外观验收。

## 打包

scripts/build-app.sh成功：release构建、包内ICC/LUT与四输出profile验证、Apple M4 Metal渲染及SDR预览冒烟、codesign严格验证均通过。已覆盖固定output/Printroom.app，0.3.28/1，应用标识保持studio.printroom.local.v3.3。git diff --check通过。
