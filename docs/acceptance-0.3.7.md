# 0.3.7 Adobe静默与固定四路（2026-09-09）

用户要求固定4路，未做并行数选型。RAW样本策略、LibRaw参数、schema5和密度算法保持；同工作区Sony CMOS新需求由独立验收记录负责。

## 实现

Adobe通过临时LSUIElement外壳运行，链接原安装程序及资源，不修改Adobe安装文件；外壳失败报错，不退回可见启动。源服务固定4个跨进程准备槽，同源独立锁复用metadata/代理/full，缓存读者与维护屏障分开，8GiB淘汰及取消保持。界面RAW预先准备也保持4个在途请求，切帧/换卷取消并重排，避免服务支持并发但界面仍逐张调用。Final仍逐张渲染。

## 验证

- `scripts/test.sh`：173项核心测试，7项有条件跳过、0失败；91项应用Swift Testing通过（含性能项按原开关跳过）。日志scratch/raw-four-regression.log。
- RAWSourceServiceTests 15/15：8不同源峰值恰4，小容量最终淘汰；同源meta/thumb/full不抢占其他槽；跨实例共同上限；活动staging遇清理不删除；等待第5槽取消；原有故障、取消和缓存完整性全部通过。
- RAWPrewarmerTests 2/2：12帧始终最多4在途，一帧失败继续；取消后4个工作任务感知取消，不排下一批。
- AdobeShadowBundleTests 2/2，实际Process故障/取消fixture通过，原应用Info.plist和二进制不被修改，影子壳失败不回退。
- `PRINTROOM_TEST_REAL_RAW=1 PRINTROOM_VALIDATE_RAW=1 scripts/test.sh --filter 'RAWEditorIntegrationTests|RAWImageServiceTests'`：真实ARW打开、切帧、保存重开、精确ROI和方向2项通过，5.885秒，日志scratch/raw-four-editor-tests.log。
- `scripts/adobe-shadow-qa.sh 8`：4路直接Adobe八张RGB全同，0次regular进程状态，原Info.plist不变。
- `scripts/adobe-service-four-qa.sh`：正式RAWSourceService、新空缓存、8并发消费者；真实Adobe进程峰值恰4。通过child PID每5ms采样NSRunningApplication，1436次accessory、0次regular，验证不注册普通Dock应用。8张1600代理与独立源码参考样本完全一致；其后8张7008×4672全尺寸RGB hash全部等于0.3.6独立参考。

服务实测：八张代理最后返回7.445秒，含参考比对总7.670秒；8张全尺寸按需准备及hash串行3.980秒。探针峰值RSS3,296,083,968字节（约3.07GiB），包含四路LibRaw和比对缓冲，不含Adobe子进程。不是单张时延或全部应用峰值，也不与不同负载的旧测试作严格速度比较。数据保留于raw-four-0.3.7.json。

真实验证范围仍是当前Adobe18.1.1和八张ILCE-7CM2 ARW；未扩展到其他Adobe/macOS/机型版本。Dock验证采用运行进程activationPolicy，并未改变用户的Dock设置。

最终交付：scripts/build-app.sh成功覆盖output/Printroom.app，版本0.3.7/1、固定标识studio.printroom.local.v3.3。包内ICC/LUT、四输出profile、实际Metal Apple M4与SDR预览冒烟通过；codesign严格签名验证通过，包内LibRaw源码/许可证与工程逐文件一致。20个原始资产哈希全部通过，git diff --check通过。构建日志scratch/raw-four-build-app.log。同包保留Sony CMOS/RAW制作及L1导出，其单独证据见acceptance-cmos-raw.md。
