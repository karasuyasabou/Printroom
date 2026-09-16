"""
胶片数学操作模块
包含所有核心的数学处理操作，从业务逻辑中分离出来
支持并行和分块处理优化
"""

import numpy as np
from typing import List, Tuple, Optional, Dict, Any, Union
from concurrent.futures import ThreadPoolExecutor
import time
from collections import OrderedDict

from .data_types import ImageData, ColorGradingParams, PreviewConfig
from .gpu_accelerator import get_gpu_accelerator

# 注意：之前实验的SIMD/Numba/NumExpr优化已移除
# 实测发现这些技术在当前场景下反而降低性能
# 保持简洁的NumPy + 多线程并行方案，现在加上GPU加速


class FilmMathOps:
    """胶片数学操作核心引擎 - 多线程并行优化版"""
    
    def __init__(self, max_cache_size: int = 64, 
                 preview_config: Optional[PreviewConfig] = None):
        # LUT缓存
        self._lut1d_cache: "OrderedDict[Any, np.ndarray]" = OrderedDict()
        self._curve_lut_cache: "OrderedDict[Any, np.ndarray]" = OrderedDict()
        self._max_cache_size: int = max_cache_size
        self._LOG65536: float = np.log10(65536.0)
        
        # 预览配置（统一管理）
        self.preview_config = preview_config or PreviewConfig()
        
        # GPU加速器
        self.gpu_accelerator = get_gpu_accelerator()
        
        # 多线程并行参数
        self.num_threads = self._get_optimal_threads()  # 自动检测最优线程数
        self.block_size = self._get_optimal_block_size()  # 自动调整分块大小
        self.parallel_threshold = 512 * 512  # 超过此像素数才启用并行
        
        # 曲线质量设置
        self.curve_quality = 'fast'  # 'fast' 或 'high_quality'
        
        # 曲线优化设置
        self.curve_chunk_size = 64 * 1024  # 分块处理大小（64K像素）
        
        # 数据类型优化
        self.use_float32_everywhere = True  # 强制使用float32减少内存带宽
        
        # 注意：移除了SIMD相关配置（实验证明效果不佳）
        
        # 线程池复用（避免频繁创建销毁）
        self._thread_pool: Optional[ThreadPoolExecutor] = None
        

    def _get_optimal_threads(self) -> int:
        """自动检测最优线程数"""
        import os
        cpu_count = os.cpu_count() or 4
        # 使用CPU核心数，但不超过8（避免过度竞争）
        return min(cpu_count, 8)
    
    def _get_optimal_block_size(self) -> int:
        """自动调整分块大小"""
        # 根据线程数调整块大小，确保有足够的并行任务
        base_size = 256
        return max(base_size, 1024 // self.num_threads)
    
    def _get_thread_pool(self) -> ThreadPoolExecutor:
        """获取线程池（懒加载+复用）"""
        if self._thread_pool is None:
            self._thread_pool = ThreadPoolExecutor(max_workers=self.num_threads)
        return self._thread_pool
    
    def _should_use_parallel(self, array_size: int, use_parallel: bool = True) -> bool:
        """判断是否应该使用并行处理"""
        return (use_parallel and 
                array_size > self.parallel_threshold and 
                self.num_threads > 1)
    
    # 注意：移除了SIMD策略相关方法（实验证明效果不佳）
        
    def clear_caches(self) -> None:
        """清空内部缓存"""
        self._lut1d_cache.clear()
        self._curve_lut_cache.clear()
    
    def __del__(self):
        """析构函数，确保线程池被正确关闭"""
        if self._thread_pool is not None:
            self._thread_pool.shutdown(wait=False)
    
    def _cache_put(self, cache: "OrderedDict[Any, np.ndarray]", key: Any, value: np.ndarray) -> None:
        """LRU缓存操作"""
        cache[key] = value
        cache.move_to_end(key)
        if len(cache) > self._max_cache_size:
            cache.popitem(last=False)

    # =======================
    # 0. 前置幂次变换（IDT Gamma）
    # =======================
    def apply_power(self, image_array: np.ndarray, exponent: float,
                    use_optimization: bool = True,
                    use_parallel: bool = True) -> np.ndarray:
        """
        对输入图像前3通道应用逐像素幂次变换（保护Alpha）。
        I_out = clip(I_in,0,1) ** exponent
        
        Args:
            image_array: 输入数组 [H,W,C]
            exponent: 幂次（idt.gamma）
            use_optimization: 是否使用1D LUT查表优化
            use_parallel: 是否并行（大图有效）
        """
        if image_array is None or image_array.size == 0:
            print("[ERROR]: apply_power(): image_array is None")
            return image_array
        exp_f = float(exponent)
        if abs(exp_f - 1.0) < 1e-6:
            return image_array

        original_shape = image_array.shape
        
        # 处理单通道图像
        if len(original_shape) == 2:
            # 2D灰度图像
            rgb_clipped = np.clip(image_array, 0.0, 1.0)
            if use_optimization:
                lut_size = 32768
                lut = self._get_power_lut(exp_f, lut_size)
                indices = np.round(rgb_clipped * (lut_size - 1)).astype(np.uint16)
                return np.take(lut, indices).astype(image_array.dtype)
            else:
                return np.power(rgb_clipped, exp_f).astype(image_array.dtype)
        
        elif len(original_shape) == 3 and original_shape[2] == 1:
            # 单通道3D图像
            rgb_clipped = np.clip(image_array, 0.0, 1.0)
            if use_optimization:
                lut_size = 32768
                lut = self._get_power_lut(exp_f, lut_size)
                indices = np.round(rgb_clipped * (lut_size - 1)).astype(np.uint16)
                return np.take(lut, indices).astype(image_array.dtype)
            else:
                return np.power(rgb_clipped, exp_f).astype(image_array.dtype)
        
        else:
            # 多通道图像
            has_alpha = (len(original_shape) == 3 and original_shape[2] >= 4)
            if use_optimization:
                # LUT路径（32K级别足以用于预览，导出可选择关闭优化以走高精度pow）
                lut_size = 32768
                lut = self._get_power_lut(exp_f, lut_size)
                # 按通道处理，仅前3通道
                h, w = original_shape[:2]
                result = image_array.copy()
                if original_shape[2] >= 3:
                    rgb = result[:, :, :3]
                    rgb = np.clip(rgb, 0.0, 1.0)
                    indices = np.round(rgb * (lut_size - 1)).astype(np.uint16)
                    # 调试：检测有没有越界
                    bad = (indices < 0) | (indices >= lut_size)
                    if bad.any():
                        print(
                            "[WARN] apply_power: LUT index out of range, "
                            f"min={indices.min()}, max={indices.max()}, "
                            f"exponent={exp_f}, num_bad={bad.sum()}",
                            flush=True
                        )
                        # 强制裁剪，防止 np.take 抛异常
                        indices = np.clip(indices, 0, lut_size - 1)

                    rgb_out = np.take(lut, indices)
                    result[:, :, :3] = rgb_out.astype(result.dtype)
                return result
            else:
                # 直接pow路径（导出建议走此路径）
                result = image_array.copy()
                if original_shape[2] >= 3:
                    rgb = np.clip(result[:, :, :3], 0.0, 1.0)
                    rgb_out = np.power(rgb, exp_f)
                    result[:, :, :3] = rgb_out.astype(result.dtype)
                return result

    def _get_power_lut(self, exponent: float, size: int = 32768) -> np.ndarray:
        key = ("pow", round(float(exponent), 6), int(size))
        lut = self._lut1d_cache.get(key)
        if lut is None:
            xs = np.linspace(0.0, 1.0, int(size), dtype=np.float64)
            lut = np.power(xs, float(exponent)).astype(np.float64)
            self._cache_put(self._lut1d_cache, key, lut)
        return lut
    
    # =======================
    # 1. 密度反相操作
    # =======================
    
    def density_inversion(self, image_array: np.ndarray, gamma: float, dmax: float,
                         pivot: float = 0.7, invert: bool = True, use_optimization: bool = True,
                         use_parallel: bool = True, use_gpu: bool = True) -> np.ndarray:
        """
        密度反相操作（支持GPU加速、多线程并行）

        Args:
            image_array: 输入图像数组 [H, W, 3]，值域 [0, 1]
            gamma: gamma值
            dmax: dmax值
            pivot: 转轴值，默认0.9（三档曝光）
            invert: 是否反转密度（True: -log, False: +log）
            use_optimization: 是否使用优化版本（LUT查表）
            use_parallel: 是否使用并行处理
            use_gpu: 是否尝试使用GPU加速

        Returns:
            反相后的图像数组
        """
        if image_array is None or image_array.size == 0:
            return image_array

        # GPU加速（仅在优化模式下启用，导出时强制使用CPU保证精度）
        if (use_gpu and use_optimization and
            self.gpu_accelerator and
            self.preview_config.should_use_gpu(image_array.size)):
            try:
                return self.gpu_accelerator.density_inversion_accelerated(
                    image_array, gamma, dmax, pivot, invert
                )
            except Exception as e:
                # GPU失败，回退到CPU
                print(f"⚠️  GPU加速失败，回退到CPU: {e}")

        # CPU处理路径
        should_parallel = self._should_use_parallel(image_array.size, use_parallel)

        if use_optimization:
            if should_parallel:
                return self._density_inversion_lut_parallel(image_array, gamma, dmax, pivot, invert)
            else:
                return self._density_inversion_lut_optimized(image_array, gamma, dmax, pivot, invert)
        else:
            if should_parallel:
                return self._density_inversion_direct_parallel(image_array, gamma, dmax, pivot, invert)
            else:
                return self._density_inversion_direct(image_array, gamma, dmax, pivot, invert)
    
    def _density_inversion_direct(self, image_array: np.ndarray, gamma: float,
                                 dmax: float, pivot: float, invert: bool = True) -> np.ndarray:
        """直接计算版本的密度反相（优化：使用exp代替power）"""
        # 避免log(0)
        safe_array = np.maximum(image_array, 1e-10)

        # 计算原始密度（根据 invert 控制正负号）
        log_img = np.log10(safe_array)
        original_density = -log_img if invert else log_img

        # 应用gamma和dmax调整
        adjusted_density = pivot + (original_density - pivot) * gamma - dmax

        # 转回线性空间（优化：使用exp代替power，性能提升1.5-2倍）
        # 10^x = exp(x * ln(10))
        ln10 = np.log(10.0)
        result = np.exp(adjusted_density * ln10)

        return result.astype(image_array.dtype)
    
    def _density_inversion_lut_optimized(self, image_array: np.ndarray, gamma: float,
                                        dmax: float, pivot: float, invert: bool = True) -> np.ndarray:
        """优化版本：使用对数空间LUT查表"""
        lut_size = 32768  # 32K + 对数空间，欠曝光区域精度提升 30-300 倍
        lut = self._get_density_inversion_lut(gamma, dmax, pivot, invert, lut_size)

        # 对数空间索引（解决欠曝光区域色阶断裂问题）
        LOG_MIN = -6.0  # 对应 img = 10^-6 = 0.000001
        LOG_MAX = 0.0   # 对应 img = 10^0 = 1.0

        # 将图像值 clip 到对数空间范围
        img_clipped = np.clip(image_array, 10**LOG_MIN, 1.0)

        # 转换到对数空间
        log_img = np.log10(img_clipped)

        # 在对数空间归一化到 [0, 1]
        normalized = (log_img - LOG_MIN) / (LOG_MAX - LOG_MIN)

        # 计算索引
        indices = np.round(normalized * (lut_size - 1)).astype(np.uint16)

        # 查表
        result_array = np.take(lut, indices)

        return result_array.astype(image_array.dtype)
    
    def _density_inversion_lut_parallel(self, image_array: np.ndarray, gamma: float,
                                       dmax: float, pivot: float, invert: bool = True) -> np.ndarray:
        """并行版本：分块处理+对数空间LUT查表"""
        lut_size = 32768
        lut = self._get_density_inversion_lut(gamma, dmax, pivot, invert, lut_size)

        h, w, c = image_array.shape
        result = np.zeros_like(image_array)

        # 计算分块数量
        blocks_h = (h + self.block_size - 1) // self.block_size
        blocks_w = (w + self.block_size - 1) // self.block_size

        # 对数空间参数（与单线程版本一致）
        LOG_MIN = -6.0
        LOG_MAX = 0.0

        def process_block(args):
            i, j = args
            start_h = i * self.block_size
            end_h = min((i + 1) * self.block_size, h)
            start_w = j * self.block_size
            end_w = min((j + 1) * self.block_size, w)

            # 提取块
            block = image_array[start_h:end_h, start_w:end_w, :]

            # 对数空间LUT查表处理
            img_clipped = np.clip(block, 10**LOG_MIN, 1.0)
            log_img = np.log10(img_clipped)
            normalized = (log_img - LOG_MIN) / (LOG_MAX - LOG_MIN)
            indices = np.round(normalized * (lut_size - 1)).astype(np.uint16)
            block_result = np.take(lut, indices)

            return (start_h, end_h, start_w, end_w, block_result.astype(block.dtype))
        
        # 并行处理所有块
        block_coords = [(i, j) for i in range(blocks_h) for j in range(blocks_w)]
        
        executor = self._get_thread_pool()
        results = list(executor.map(process_block, block_coords))
        
        # 重组结果
        for start_h, end_h, start_w, end_w, block_result in results:
            result[start_h:end_h, start_w:end_w, :] = block_result
        
        return result
    
    def _density_inversion_direct_parallel(self, image_array: np.ndarray, gamma: float,
                                          dmax: float, pivot: float, invert: bool = True) -> np.ndarray:
        """并行版本：分块处理+直接计算（优化：使用exp代替power）"""
        h, w, c = image_array.shape
        result = np.zeros_like(image_array)

        # 计算分块数量
        blocks_h = (h + self.block_size - 1) // self.block_size
        blocks_w = (w + self.block_size - 1) // self.block_size

        # 预计算常量
        ln10 = np.log(10.0)

        def process_block(args):
            i, j = args
            start_h = i * self.block_size
            end_h = min((i + 1) * self.block_size, h)
            start_w = j * self.block_size
            end_w = min((j + 1) * self.block_size, w)

            # 提取块
            block = image_array[start_h:end_h, start_w:end_w, :]

            # 直接计算密度反相（根据 invert 控制正负号）
            safe_block = np.maximum(block, 1e-10)
            log_img = np.log10(safe_block)
            original_density = -log_img if invert else log_img
            adjusted_density = pivot + (original_density - pivot) * gamma - dmax

            # 优化：使用exp代替power
            block_result = np.exp(adjusted_density * ln10)

            return (start_h, end_h, start_w, end_w, block_result.astype(block.dtype))

        # 并行处理所有块
        block_coords = [(i, j) for i in range(blocks_h) for j in range(blocks_w)]

        executor = self._get_thread_pool()
        results = list(executor.map(process_block, block_coords))

        # 重组结果
        for start_h, end_h, start_w, end_w, block_result in results:
            result[start_h:end_h, start_w:end_w, :] = block_result

        return result
    
    def _get_density_inversion_lut(self, gamma: float, dmax: float, pivot: float,
                                  invert: bool = True, size: int = 32768) -> np.ndarray:
        """获取或生成密度反相LUT（对数空间优化版）"""
        # 使用新的缓存 key（区分对数空间版本）
        key = ("dens_inv_log", round(float(gamma), 6), round(float(dmax), 6),
               round(float(pivot), 6), bool(invert), int(size))
        lut = self._lut1d_cache.get(key)

        if lut is None:
            # 在对数空间生成采样点（解决欠曝光区域精度问题）
            LOG_MIN = -6.0  # 对应 img = 10^-6 = 0.000001
            LOG_MAX = 0.0   # 对应 img = 10^0 = 1.0

            log_xs = np.linspace(LOG_MIN, LOG_MAX, int(size), dtype=np.float64)
            xs = np.power(10.0, log_xs)  # 对数空间 → 线性空间

            # 原有的 density inversion 数学（保持不变）
            safe = np.maximum(xs, 1e-10)
            log_img = np.log10(safe)
            original_density = -log_img if invert else log_img
            adjusted_density = pivot + (original_density - pivot) * gamma - dmax
            lut = np.power(10.0, adjusted_density).astype(np.float64)

            self._cache_put(self._lut1d_cache, key, lut)

        return lut
    
    # =======================
    # 2. Gamma和Dmax调整（图片级别）
    # =======================
    
    def gamma_dmax_adjustment(self, image_array: np.ndarray, gamma: float, dmax: float,
                             pivot: float = 0.7) -> np.ndarray:
        """
        Gamma和Dmax调整（作为图片级别调整）
        
        Args:
            image_array: 输入图像数组
            gamma: gamma值
            dmax: dmax值  
            pivot: 转轴值
            
        Returns:
            调整后的图像数组
        """
        # 这个操作与密度反相本质上是相同的数学过程
        return self.density_inversion(image_array, gamma, dmax, pivot)
    
    # =======================
    # 3. 密度校正矩阵
    # =======================
    
    def apply_density_matrix(self, density_array: np.ndarray, matrix: np.ndarray,
                               dmax: float, pivot: float = 4.8-0.7,
                               channel_gamma_r: float = 1.0,
                               channel_gamma_b: float = 1.0,
                               use_parallel: bool = True) -> np.ndarray:
        """
        应用密度校正矩阵和分层反差

        Args:
            density_array: 密度空间图像 [H, W, 3]
            matrix: 3x3校正矩阵
            dmax: dmax值，用于矩阵应用的参考点
            pivot: 转轴值
            channel_gamma_r: R通道分层反差系数 (新增)
            channel_gamma_b: B通道分层反差系数 (新增)
            use_parallel: 是否使用并行处理

        Returns:
            校正后的密度数组
        """
        if matrix is None:
            return density_array

        # 准备输入：添加dmax偏移
        input_density = density_array + dmax

        if use_parallel and input_density.size > self.block_size * self.block_size:
            return self._apply_matrix_parallel(input_density, matrix, pivot, dmax,
                                               channel_gamma_r, channel_gamma_b)
        else:
            return self._apply_matrix_sequential(input_density, matrix, pivot, dmax,
                                                 channel_gamma_r, channel_gamma_b)
    
    def _apply_matrix_sequential(self, input_density: np.ndarray, matrix: np.ndarray,
                                pivot: float, dmax: float,
                                channel_gamma_r: float = 1.0,
                                channel_gamma_b: float = 1.0) -> np.ndarray:
        """顺序版本的矩阵应用 + 分层反差"""
        original_shape = input_density.shape
        n_channels = input_density.shape[-1] if len(input_density.shape) == 3 else 1

        # 确定性地处理不同通道数的图像
        reshaped = input_density.reshape(-1, n_channels)

        if n_channels == 3:
            # RGB图像，直接应用变换
            # 1. 应用密度校正矩阵
            adjusted = pivot + np.dot(reshaped - pivot, matrix.T)

            # 2. 应用分层反差
            if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                adjusted = pivot + (adjusted - pivot) * diag

            result = adjusted.reshape(original_shape) - dmax
        elif n_channels == 4:
            # 4通道图像（RGBA或RGB+IR），仅对前3个RGB通道应用密度矩阵变换
            # 保留第4通道原值不变（alpha或IR通道不应受密度变换影响）
            rgb_part = reshaped[:, :3]
            # 1. 应用密度校正矩阵
            adjusted_rgb = pivot + np.dot(rgb_part - pivot, matrix.T)

            # 2. 应用分层反差
            if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                adjusted_rgb = pivot + (adjusted_rgb - pivot) * diag

            adjusted = reshaped.copy()
            adjusted[:, :3] = adjusted_rgb
            result = adjusted.reshape(original_shape) - dmax
        elif n_channels == 1:
            # TODO: 未来实现真正的单色模式处理
            # 暂时将单通道复制为3通道进行处理
            mono_channel = reshaped[:, 0:1]
            rgb_expanded = np.tile(mono_channel, (1, 3))
            # 1. 应用密度校正矩阵
            adjusted = pivot + np.dot(rgb_expanded - pivot, matrix.T)

            # 2. 应用分层反差
            if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                adjusted = pivot + (adjusted - pivot) * diag

            # 取平均值作为单通道结果
            result = (adjusted.mean(axis=1, keepdims=True).reshape(original_shape)) - dmax
        elif n_channels > 4:
            # 多通道图像（>4通道），仅处理前3个RGB通道
            # 保留其他通道原值不变
            rgb_part = reshaped[:, :3]
            # 1. 应用密度校正矩阵
            adjusted_rgb = pivot + np.dot(rgb_part - pivot, matrix.T)

            # 2. 应用分层反差
            if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                adjusted_rgb = pivot + (adjusted_rgb - pivot) * diag

            adjusted = reshaped.copy()
            adjusted[:, :3] = adjusted_rgb
            result = adjusted.reshape(original_shape) - dmax
        else:
            # 2通道等其他情况（不应出现，但作为fallback）
            # 将前N个通道扩展到3通道处理
            if n_channels >= 2:
                rgb_expanded = np.zeros((reshaped.shape[0], 3), dtype=reshaped.dtype)
                rgb_expanded[:, :n_channels] = reshaped
                # 1. 应用密度校正矩阵
                adjusted_rgb = pivot + np.dot(rgb_expanded - pivot, matrix.T)

                # 2. 应用分层反差
                if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                    diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                    adjusted_rgb = pivot + (adjusted_rgb - pivot) * diag

                adjusted = reshaped.copy()
                adjusted[:, :min(n_channels, 3)] = adjusted_rgb[:, :min(n_channels, 3)]
                result = adjusted.reshape(original_shape) - dmax
            else:
                # 无法处理的情况，返回原数组减dmax
                result = input_density - dmax

        return result
    
    def _apply_matrix_parallel(self, input_density: np.ndarray, matrix: np.ndarray,
                              pivot: float, dmax: float,
                              channel_gamma_r: float = 1.0,
                              channel_gamma_b: float = 1.0) -> np.ndarray:
        """并行版本的矩阵应用 + 分层反差"""
        original_shape = input_density.shape
        h, w, c = original_shape

        # 计算分块
        blocks_h = (h + self.block_size - 1) // self.block_size
        blocks_w = (w + self.block_size - 1) // self.block_size

        result = np.zeros_like(input_density)

        def process_block(args):
            i, j = args
            start_h = i * self.block_size
            end_h = min((i + 1) * self.block_size, h)
            start_w = j * self.block_size
            end_w = min((j + 1) * self.block_size, w)

            block = input_density[start_h:end_h, start_w:end_w, :]

            # 确定性地处理不同通道数的图像
            if c == 3:
                # RGB图像，直接处理
                block_reshaped = block.reshape(-1, 3)
                # 1. 应用密度校正矩阵
                adjusted_block = pivot + np.dot(block_reshaped - pivot, matrix.T)

                # 2. 应用分层反差
                if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                    diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                    adjusted_block = pivot + (adjusted_block - pivot) * diag

                result_block = adjusted_block.reshape(block.shape)
            elif c == 4:
                # 4通道图像（RGBA或RGB+IR），仅对前3个RGB通道应用密度矩阵变换
                # 保留第4通道原值不变（alpha或IR通道不应受密度变换影响）
                block_reshaped = block.reshape(-1, 4)
                rgb_part = block_reshaped[:, :3]
                # 1. 应用密度校正矩阵
                adjusted_rgb = pivot + np.dot(rgb_part - pivot, matrix.T)

                # 2. 应用分层反差
                if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                    diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                    adjusted_rgb = pivot + (adjusted_rgb - pivot) * diag

                adjusted_block = block_reshaped.copy()
                adjusted_block[:, :3] = adjusted_rgb
                result_block = adjusted_block.reshape(block.shape)
            elif c == 1:
                # TODO: 未来实现真正的单色模式处理
                # 暂时将单通道复制为3通道进行处理
                block_reshaped = block.reshape(-1, 1)
                mono_channel = block_reshaped[:, 0:1]
                rgb_expanded = np.tile(mono_channel, (1, 3))
                # 1. 应用密度校正矩阵
                adjusted = pivot + np.dot(rgb_expanded - pivot, matrix.T)

                # 2. 应用分层反差
                if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                    diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                    adjusted = pivot + (adjusted - pivot) * diag

                # 取平均值作为单通道结果
                result_mono = adjusted.mean(axis=1, keepdims=True)
                result_block = result_mono.reshape(block.shape)
            elif c > 4:
                # 多通道图像（>4通道），仅处理前3个RGB通道
                # 保留其他通道原值不变
                block_reshaped = block.reshape(-1, c)
                rgb_part = block_reshaped[:, :3]
                # 1. 应用密度校正矩阵
                adjusted_rgb = pivot + np.dot(rgb_part - pivot, matrix.T)

                # 2. 应用分层反差
                if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                    diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                    adjusted_rgb = pivot + (adjusted_rgb - pivot) * diag

                adjusted_block = block_reshaped.copy()
                adjusted_block[:, :3] = adjusted_rgb
                result_block = adjusted_block.reshape(block.shape)
            else:
                # 2通道等其他情况（不应出现，但作为fallback）
                # 将前N个通道扩展到3通道处理
                if c >= 2:
                    block_reshaped = block.reshape(-1, c)
                    rgb_expanded = np.zeros((block_reshaped.shape[0], 3), dtype=block_reshaped.dtype)
                    rgb_expanded[:, :c] = block_reshaped
                    # 1. 应用密度校正矩阵
                    adjusted_rgb = pivot + np.dot(rgb_expanded - pivot, matrix.T)

                    # 2. 应用分层反差
                    if abs(channel_gamma_r - 1.0) > 1e-6 or abs(channel_gamma_b - 1.0) > 1e-6:
                        diag = np.array([channel_gamma_r, 1.0, channel_gamma_b])
                        adjusted_rgb = pivot + (adjusted_rgb - pivot) * diag

                    adjusted_block = block_reshaped.copy()
                    adjusted_block[:, :min(c, 3)] = adjusted_rgb[:, :min(c, 3)]
                    result_block = adjusted_block.reshape(block.shape)
                else:
                    # 无法处理的情况，返回原块
                    result_block = block

            return (start_h, end_h, start_w, end_w, result_block)

        # 并行处理所有块
        block_coords = [(i, j) for i in range(blocks_h) for j in range(blocks_w)]

        executor = self._get_thread_pool()
        results = list(executor.map(process_block, block_coords))

        # 重组结果
        for start_h, end_h, start_w, end_w, block_result in results:
            result[start_h:end_h, start_w:end_w, :] = block_result

        # 减去dmax
        return result - dmax
    
    # =======================
    # 4. RGB曝光调整
    # =======================
    
    def apply_rgb_gains(self, density_array: np.ndarray, rgb_gains: Tuple[float, float, float],
                       use_parallel: bool = True) -> np.ndarray:
        """
        应用RGB增益调整（在密度空间）
        
        Args:
            density_array: 密度空间图像
            rgb_gains: (r_gain, g_gain, b_gain)
            use_parallel: 是否使用并行处理
            
        Returns:
            调整后的密度数组
        """
        if not rgb_gains or all(g == 0.0 for g in rgb_gains):
            return density_array
            
        result = density_array.copy()
        
        # RGB增益在密度空间的应用：正增益降低密度（变亮），负增益增加密度（变暗）
        num_channels = min(result.shape[2], len(rgb_gains))
        for i in range(num_channels):
            result[:, :, i] -= rgb_gains[i]
            
        return result
    
    # =======================
    # 5. 密度曲线调整
    # =======================
    
    def apply_density_curve(self, density_array: np.ndarray, 
                           curve_points: Optional[List[Tuple[float, float]]] = None,
                           channel_curves: Optional[Dict[str, List[Tuple[float, float]]]] = None,
                           lut_size: int = 8192,
                           use_parallel: bool = True,
                           use_optimization: bool = True,
                           screen_glare_compensation: float = 0.0) -> np.ndarray:
        """
        应用密度曲线调整，然后转换到线性空间并应用屏幕反光补偿（支持高精度导出模式）
        
        Args:
            density_array: 密度空间的输入数组
            curve_points: RGB通用曲线控制点 
            channel_curves: 单通道曲线控制点字典
            lut_size: LUT大小
            use_parallel: 是否使用并行处理
            use_optimization: 是否使用LUT优化。False时使用高精度模式（导出用）
            screen_glare_compensation: 屏幕反光补偿量(0.0-0.2)，在线性空间应用
            
        Returns:
            处理后的线性空间数组
        """
        # 第1步：应用密度曲线（在密度空间）
        density_result = density_array
        
        has_rgb_curve = curve_points and len(curve_points) >= 2
        has_channel_curves = (channel_curves and 
                             any(curves and len(curves) >= 2 
                                 for curves in channel_curves.values()))
        
        if has_rgb_curve or has_channel_curves:
            # 根据模式选择处理方式
            if not use_optimization:
                # 高精度模式（导出用）：使用32K LUT或直接数学插值
                density_result = self._apply_curves_high_precision(density_array, curve_points, 
                                                               channel_curves, use_parallel)
            else:
                # 优化模式（预览用）：使用512点LUT
                should_parallel = self._should_use_parallel(density_array.size, use_parallel)
                
                if should_parallel:
                    density_result = self._apply_curves_merged_lut_parallel(density_array, curve_points, 
                                                                        channel_curves, lut_size)
                else:
                    density_result = self._apply_curves_merged_lut(density_array, curve_points, 
                                                               channel_curves, lut_size)
        
        # 第2步：转换到线性空间
        linear_result = self.density_to_linear(density_result)
        
        # 第3步：应用屏幕反光补偿（在线性空间）
        if screen_glare_compensation > 0.0:
            # 在线性空间中减去补偿值，确保不会产生负值
            linear_result = np.maximum(0.0, linear_result - screen_glare_compensation)
        
        return linear_result
    
    def _apply_curves_merged_lut(self, density_array: np.ndarray,
                               curve_points: Optional[List[Tuple[float, float]]],
                               channel_curves: Optional[Dict[str, List[Tuple[float, float]]]],
                               lut_size: int) -> np.ndarray:
        """
        合并曲线LUT实现 - 内存访问优化版本

        优化策略：
        1. 原地操作，减少内存分配
        2. 预计算常量，避免重复计算
        3. 向量化所有操作
        4. 延迟拷贝：只在真正需要修改时才拷贝
        """
        # 预计算常量（只算一次）
        inv_range = 1.0 / self._LOG65536
        log65536 = self._LOG65536
        lut_scale = lut_size - 1

        # 预计算所有通道的LUT（批量操作）
        channel_luts = []
        channel_map = ['r', 'g', 'b']

        for channel_name in channel_map:
            merged_lut = self._get_merged_channel_lut(
                curve_points,
                channel_curves.get(channel_name) if channel_curves else None,
                lut_size
            )
            channel_luts.append(merged_lut)

        # 检查是否有任何曲线需要处理
        if not any(lut is not None for lut in channel_luts):
            return density_array  # 无需处理，直接返回原数组

        # 延迟拷贝：只在真正需要修改时才拷贝
        result = density_array.copy()

        # 一次性归一化所有通道（向量化）
        normalized = 1.0 - np.clip(result * inv_range, 0.0, 1.0)
        indices = np.round(normalized * lut_scale).astype(np.uint16, copy=False)

        # 向量化处理所有通道
        for channel_idx, merged_lut in enumerate(channel_luts):
            if merged_lut is not None:
                # 直接在结果数组上操作（原地）
                channel_indices = indices[:, :, channel_idx]
                curve_output = np.take(merged_lut, channel_indices)
                result[:, :, channel_idx] = (1.0 - curve_output) * log65536

        return result
    
    def _apply_curves_merged_lut_parallel(self, density_array: np.ndarray,
                                        curve_points: Optional[List[Tuple[float, float]]],
                                        channel_curves: Optional[Dict[str, List[Tuple[float, float]]]],
                                        lut_size: int) -> np.ndarray:
        """并行版本的曲线合并LUT实现（优化：减少内存拷贝）"""
        h, w, c = density_array.shape

        # 预计算常量和LUT
        inv_range = 1.0 / self._LOG65536
        log65536 = self._LOG65536
        lut_scale = lut_size - 1

        # 预计算所有通道的LUT
        channel_luts = []
        channel_map = ['r', 'g', 'b']

        for channel_name in channel_map:
            merged_lut = self._get_merged_channel_lut(
                curve_points,
                channel_curves.get(channel_name) if channel_curves else None,
                lut_size
            )
            channel_luts.append(merged_lut)

        # 检查是否有任何曲线需要处理
        if not any(lut is not None for lut in channel_luts):
            return density_array

        # 延迟分配结果数组
        result = np.empty_like(density_array)

        # 计算分块数量
        blocks_h = (h + self.block_size - 1) // self.block_size
        blocks_w = (w + self.block_size - 1) // self.block_size

        def process_block(args):
            i, j = args
            start_h = i * self.block_size
            end_h = min((i + 1) * self.block_size, h)
            start_w = j * self.block_size
            end_w = min((j + 1) * self.block_size, w)

            # 提取块（视图，不拷贝）
            block = density_array[start_h:end_h, start_w:end_w, :]

            # 归一化处理（创建新数组）
            normalized = 1.0 - np.clip(block * inv_range, 0.0, 1.0)
            indices = np.round(normalized * lut_scale).astype(np.uint16, copy=False)

            # 创建输出块（只在需要时分配内存）
            block_result = np.empty_like(block)

            # 处理每个通道
            for channel_idx, merged_lut in enumerate(channel_luts):
                if merged_lut is not None:
                    channel_indices = indices[:, :, channel_idx]
                    curve_output = np.take(merged_lut, channel_indices)
                    block_result[:, :, channel_idx] = (1.0 - curve_output) * log65536
                else:
                    # 没有曲线的通道直接拷贝
                    block_result[:, :, channel_idx] = block[:, :, channel_idx]

            return (start_h, end_h, start_w, end_w, block_result)

        # 并行处理所有块
        block_coords = [(i, j) for i in range(blocks_h) for j in range(blocks_w)]

        executor = self._get_thread_pool()
        results = list(executor.map(process_block, block_coords))

        # 重组结果
        for start_h, end_h, start_w, end_w, block_result in results:
            result[start_h:end_h, start_w:end_w, :] = block_result

        return result
    
    def _get_merged_channel_lut(self, rgb_curve_points: Optional[List[Tuple[float, float]]],
                               channel_curve_points: Optional[List[Tuple[float, float]]],
                               lut_size: int) -> Optional[np.ndarray]:
        """
        生成合并的通道曲线LUT
        
        合并策略：先应用RGB曲线，再应用单通道曲线
        """
        # 生成缓存键
        rgb_key = tuple((round(float(x), 6), round(float(y), 6)) for x, y in rgb_curve_points) if rgb_curve_points else None
        ch_key = tuple((round(float(x), 6), round(float(y), 6)) for x, y in channel_curve_points) if channel_curve_points else None
        
        cache_key = ("merged_curve", rgb_key, ch_key, lut_size)
        merged_lut = self._curve_lut_cache.get(cache_key)
        
        if merged_lut is None:
            merged_lut = self._generate_merged_channel_lut(rgb_curve_points, channel_curve_points, lut_size)
            if merged_lut is not None:
                self._cache_put(self._curve_lut_cache, cache_key, merged_lut)
        
        return merged_lut
    
    def _generate_merged_channel_lut(self, rgb_curve_points: Optional[List[Tuple[float, float]]],
                                   channel_curve_points: Optional[List[Tuple[float, float]]],
                                   lut_size: int) -> Optional[np.ndarray]:
        """生成合并通道曲线LUT"""
        has_rgb = rgb_curve_points and len(rgb_curve_points) >= 2
        has_channel = channel_curve_points and len(channel_curve_points) >= 2
        
        if not has_rgb and not has_channel:
            return None
        
        # 生成输入密度值
        x_values = np.linspace(0.0, 1.0, lut_size, dtype=np.float64)
        
        # 初始化为恒等映射
        y_values = x_values.copy()
        
        # 应用RGB曲线（如果存在）
        if has_rgb:
            rgb_lut = self._generate_curve_lut_fast(rgb_curve_points, lut_size)
            # 链式应用：先通过RGB曲线变换
            y_values = np.interp(y_values, x_values, rgb_lut)
        
        # 应用单通道曲线（如果存在）
        if has_channel:
            channel_lut = self._generate_curve_lut_fast(channel_curve_points, lut_size)
            # 链式应用：再通过单通道曲线变换
            y_values = np.interp(y_values, x_values, channel_lut)
        
        return y_values.astype(np.float64)
    
    def _should_use_3d_lut(self, image_shape: tuple) -> bool:
        """判断是否应该使用3D LUT（智能决策）"""
        pixel_count = image_shape[0] * image_shape[1]
        # 只对超大图像（4MP+）且参数复杂时使用3D LUT
        # 因为3D LUT生成成本高，只有重复使用时才值得
        return pixel_count > 2048 * 2048  # 4MP以上使用3D LUT
    
    def _apply_curves_3d_lut(self, density_array: np.ndarray,
                           curve_points: Optional[List[Tuple[float, float]]],
                           channel_curves: Optional[Dict[str, List[Tuple[float, float]]]],
                           lut_size: int) -> np.ndarray:
        """
        使用3D LUT进行极速曲线处理
        
        原理：预计算所有可能的RGB密度值组合的曲线结果
        优势：将N次1D查表变成1次3D查表
        """
        # 生成3D LUT
        lut_3d = self._get_curves_3d_lut_cached(curve_points, channel_curves, lut_size)
        
        # 应用3D LUT
        return self._apply_3d_lut_to_density(density_array, lut_3d, lut_size)
    
    def _get_curves_3d_lut_cached(self, curve_points: Optional[List[Tuple[float, float]]],
                                 channel_curves: Optional[Dict[str, List[Tuple[float, float]]]],
                                 lut_size: int) -> np.ndarray:
        """获取或生成曲线3D LUT"""
        # 生成缓存键
        rgb_key = tuple((round(float(x), 6), round(float(y), 6)) for x, y in curve_points) if curve_points else None
        ch_key = {}
        if channel_curves:
            for ch, points in channel_curves.items():
                if points and len(points) >= 2:
                    ch_key[ch] = tuple((round(float(x), 6), round(float(y), 6)) for x, y in points)
        
        cache_key = ("curves_3d", rgb_key, tuple(sorted(ch_key.items())), lut_size)
        lut_3d = self._curve_lut_cache.get(cache_key)
        
        if lut_3d is None:
            lut_3d = self._generate_curves_3d_lut(curve_points, channel_curves, lut_size)
            self._cache_put(self._curve_lut_cache, cache_key, lut_3d)
        
        return lut_3d
    
    def _generate_curves_3d_lut(self, curve_points: Optional[List[Tuple[float, float]]],
                               channel_curves: Optional[Dict[str, List[Tuple[float, float]]]],
                               lut_size: int) -> np.ndarray:
        """生成曲线3D LUT"""
        # 为速度优化，使用较小的3D LUT
        lut_3d_size = min(64, lut_size)  # 64^3 = 262K 条目，合理的内存使用
        
        # 创建密度空间的采样点
        density_max = float(self._LOG65536)
        density_samples = np.linspace(0.0, density_max, lut_3d_size, dtype=np.float64)
        
        # 创建3D网格
        r_grid, g_grid, b_grid = np.meshgrid(density_samples, density_samples, density_samples, indexing='ij')
        
        # 重塑为 [N, 3] 以便处理
        input_densities = np.stack([r_grid.ravel(), g_grid.ravel(), b_grid.ravel()], axis=1)
        
        # 逐像素处理（虽然慢，但只做一次）
        output_densities = np.empty_like(input_densities)
        
        for i in range(input_densities.shape[0]):
            pixel_density = input_densities[i:i+1].reshape(1, 1, 3)
            processed = self._apply_curves_vectorized(pixel_density, curve_points, channel_curves, lut_size)
            output_densities[i] = processed.ravel()
        
        # 重塑回3D
        lut_3d = output_densities.reshape(lut_3d_size, lut_3d_size, lut_3d_size, 3)
        
        return lut_3d
    
    def _apply_3d_lut_to_density(self, density_array: np.ndarray, lut_3d: np.ndarray, lut_size: int) -> np.ndarray:
        """将3D LUT应用到密度数组"""
        density_max = float(self._LOG65536)
        lut_3d_size = lut_3d.shape[0]
        original_shape = density_array.shape
        
        # 处理单通道图像
        if len(original_shape) == 2 or (len(original_shape) == 3 and original_shape[2] == 1):
            # 单通道图像，复制为三通道
            if len(original_shape) == 2:
                mono_density = density_array[..., np.newaxis]
            else:
                mono_density = density_array
            rgb_density = np.repeat(mono_density, 3, axis=-1)
        else:
            rgb_density = density_array
        
        # 归一化密度值到LUT索引范围
        normalized = np.clip(rgb_density / density_max, 0.0, 1.0)
        indices = (normalized * (lut_3d_size - 1)).astype(np.int32)
        
        # 裁剪索引以防越界
        indices = np.clip(indices, 0, lut_3d_size - 1)
        
        # 3D查表
        lut_result = lut_3d[indices[:, :, 0], indices[:, :, 1], indices[:, :, 2]]
        
        # 如果原图是单通道，转换回单通道（取绿色通道）
        if len(original_shape) == 2 or (len(original_shape) == 3 and original_shape[2] == 1):
            if len(original_shape) == 2:
                result = lut_result[:, :, 1]  # 取绿色通道
            else:
                result = lut_result[:, :, 1:2]  # 保持单通道维度
        else:
            result = lut_result
        
        return result
    
    def _apply_curves_vectorized(self, density_array: np.ndarray,
                               curve_points: Optional[List[Tuple[float, float]]],
                               channel_curves: Optional[Dict[str, List[Tuple[float, float]]]],
                               lut_size: int) -> np.ndarray:
        """
        向量化曲线处理 - 核心性能优化
        
        策略：
        1. 预计算所有曲线LUT
        2. 单次内存操作处理所有通道
        3. 利用NumPy的向量化操作
        """
        result = density_array.copy()
        inv_range = 1.0 / self._LOG65536
        log65536 = self._LOG65536
        
        # 预计算归一化（只做一次）
        normalized = 1.0 - np.clip(result * inv_range, 0.0, 1.0)
        
        # 转换为整数索引（只做一次）
        indices = np.round(normalized * (lut_size - 1)).astype(np.uint16)  # uint16更快
        
        # 应用RGB通用曲线（如果存在）
        if curve_points and len(curve_points) >= 2:
            rgb_lut = self._get_curve_lut_cached(curve_points, lut_size)
            curve_output = np.take(rgb_lut, indices)
            result[:] = (1.0 - curve_output) * log65536
            
            # 重新计算归一化（因为值已改变）
            normalized = 1.0 - np.clip(result * inv_range, 0.0, 1.0)
            indices = np.round(normalized * (lut_size - 1)).astype(np.uint16)
        
        # 应用单通道曲线（向量化版本）
        if channel_curves:
            channel_map = {'r': 0, 'g': 1, 'b': 2}
            
            for channel_name, curve_points_c in channel_curves.items():
                if (channel_name not in channel_map or 
                    not curve_points_c or len(curve_points_c) < 2):
                    continue
                
                channel_idx = channel_map[channel_name]
                lut_c = self._get_curve_lut_cached(curve_points_c, lut_size)
                
                # 向量化处理单通道
                channel_indices = indices[:, :, channel_idx]
                curve_output_c = np.take(lut_c, channel_indices)
                result[:, :, channel_idx] = (1.0 - curve_output_c) * log65536
        
        return result
    
    def _apply_curves_high_precision(self, density_array: np.ndarray,
                                   curve_points: Optional[List[Tuple[float, float]]],
                                   channel_curves: Optional[Dict[str, List[Tuple[float, float]]]],
                                   use_parallel: bool = True) -> np.ndarray:

        # legacy: 全精度导出
        return self._apply_curves_pure_interpolation(density_array, curve_points, channel_curves)

        # """
        # 高精度密度曲线处理（导出专用）- 使用65536点LUT（16位精度）
        #
        # 优化策略：使用65536点的高精度LUT代替逐像素插值
        # - 65536点 = 16位精度，对于任何导出格式都完全足够
        # - 相比np.interp逐像素插值，性能提升10-50倍
        # - 精度损失几乎为零（16位 vs 浮点数的差异人眼不可见）
        # """
        # # 使用65536点的超大LUT，保持导出精度
        # lut_size = 65536
        #
        # # 判断是否需要并行处理
        # should_parallel = self._should_use_parallel(density_array.size, use_parallel)
        #
        # if should_parallel:
        #     return self._apply_curves_merged_lut_parallel(
        #         density_array, curve_points, channel_curves, lut_size
        #     )
        # else:
        #     return self._apply_curves_merged_lut(
        #         density_array, curve_points, channel_curves, lut_size
        #     )
    
    def _apply_curves_pure_interpolation(self, density_array: np.ndarray,
                                       curve_points: Optional[List[Tuple[float, float]]],
                                       channel_curves: Optional[Dict[str, List[Tuple[float, float]]]]) -> np.ndarray:
        """
        纯数学插值曲线处理 - 完全避免LUT，逐像素计算
        
        使用numpy的高精度插值函数，保持float64精度
        """
        result = density_array.copy()
        inv_range = 1.0 / self._LOG65536
        log65536 = self._LOG65536
        
        # 处理每个通道
        for channel_idx in range(result.shape[2]):
            channel_data = result[:, :, channel_idx]
            
            # 1. 先应用RGB通用曲线（如果存在）
            if curve_points and len(curve_points) >= 2:
                # 将密度转换为归一化值 [0,1]
                normalized = 1.0 - np.clip(channel_data * inv_range, 0.0, 1.0)
                
                # 提取曲线控制点
                x_points = np.array([p[0] for p in curve_points], dtype=result.dtype)
                y_points = np.array([p[1] for p in curve_points], dtype=result.dtype)
                
                # 高精度插值
                interpolated = np.interp(normalized, x_points, y_points)
                
                # 转回密度空间
                channel_data = (1.0 - interpolated) * log65536
            
            # 2. 再应用单通道曲线（如果存在）
            channel_key = ['r', 'g', 'b'][channel_idx] if channel_idx < 3 else 'a'
            if (channel_curves and channel_key in channel_curves and 
                channel_curves[channel_key] and len(channel_curves[channel_key]) >= 2):
                
                channel_curve = channel_curves[channel_key]
                
                # 再次归一化
                normalized = 1.0 - np.clip(channel_data * inv_range, 0.0, 1.0)
                
                # 单通道曲线插值
                x_points = np.array([p[0] for p in channel_curve], dtype=result.dtype)
                y_points = np.array([p[1] for p in channel_curve], dtype=result.dtype)
                
                interpolated = np.interp(normalized, x_points, y_points)
                channel_data = (1.0 - interpolated) * log65536
            
            # 更新结果
            result[:, :, channel_idx] = channel_data
        
        return result
    
    def _apply_curve_to_array(self, density_array: np.ndarray, 
                             curve_points: List[Tuple[float, float]],
                             lut_size: int) -> np.ndarray:
        """应用曲线到整个数组"""
        lut = self._get_curve_lut_cached(curve_points, lut_size)
        
        # 归一化密度值到[0,1]
        inv_range = 1.0 / float(self._LOG65536)
        normalized = 1.0 - np.clip(density_array * inv_range, 0.0, 1.0)
        
        # 计算LUT索引并查表
        lut_indices = (normalized * (lut_size - 1)).astype(np.int32)
        curve_output = np.take(lut, lut_indices)
        
        # 映射回密度范围
        result = (1.0 - curve_output) * float(self._LOG65536)
        
        return result
    
    def _apply_channel_curves(self, density_array: np.ndarray,
                             channel_curves: Dict[str, List[Tuple[float, float]]],
                             lut_size: int) -> np.ndarray:
        """应用单通道曲线"""
        result = density_array.copy()
        inv_range = 1.0 / float(self._LOG65536)
        
        channel_map = {'r': 0, 'g': 1, 'b': 2}
        
        for channel_name, curve_points in channel_curves.items():
            if channel_name not in channel_map or not curve_points or len(curve_points) < 2:
                continue
                
            channel_idx = channel_map[channel_name]
            lut_c = self._get_curve_lut_cached(curve_points, lut_size)
            
            # 当前通道处理
            channel_density = result[:, :, channel_idx]
            normalized_c = 1.0 - np.clip(channel_density * inv_range, 0.0, 1.0)
            lut_indices_c = (normalized_c * (lut_size - 1)).astype(np.int32)
            result[:, :, channel_idx] = (1.0 - np.take(lut_c, lut_indices_c)) * float(self._LOG65536)
            
        return result
    
    def _get_curve_lut_cached(self, control_points: List[Tuple[float, float]], 
                             num_samples: int) -> np.ndarray:
        """获取或生成曲线LUT（优化版）"""
        if not control_points or len(control_points) < 2:
            return np.linspace(0.0, 1.0, int(num_samples), dtype=np.float64)
            
        key_points = tuple((round(float(x), 6), round(float(y), 6)) for x, y in control_points)
        key = ("curve_v2", key_points, int(num_samples))  # v2标记新版本
        lut = self._curve_lut_cache.get(key)
        
        if lut is None:
            # 根据质量设置选择生成方法
            if self.curve_quality == 'high_quality':
                # 高质量：单调三次插值
                curve_samples = self._generate_monotonic_curve(control_points, int(num_samples))
                lut = np.array([p[1] for p in curve_samples], dtype=np.float64)
            else:
                # 快速：线性插值
                lut = self._generate_curve_lut_fast(control_points, int(num_samples))
            self._cache_put(self._curve_lut_cache, key, lut)
            
        return lut
    
    def _generate_curve_lut_fast(self, control_points: List[Tuple[float, float]], 
                                num_samples: int) -> np.ndarray:
        """快速曲线LUT生成（优化版）"""
        if len(control_points) < 2:
            return np.linspace(0.0, 1.0, num_samples, dtype=np.float64)
        
        # 预分配输出数组
        lut = np.empty(num_samples, dtype=np.float64)
        
        # 向量化生成x值
        x_values = np.linspace(0.0, 1.0, num_samples, dtype=np.float64)
        
        # 转换控制点为numpy数组以加速
        points_array = np.array(control_points, dtype=np.float64)
        x_points = points_array[:, 0]
        y_points = points_array[:, 1]
        
        # 使用NumPy的interp进行线性插值（比单调三次插值快很多）
        # 对于大多数情况，线性插值的视觉效果已经足够好
        lut = np.interp(x_values, x_points, y_points).astype(np.float64)
        
        return lut
    
    def _generate_monotonic_curve(self, control_points: List[Tuple[float, float]], 
                                 num_samples: int) -> List[Tuple[float, float]]:
        """生成单调曲线样本点"""
        if len(control_points) < 2:
            return [(i / (num_samples - 1), i / (num_samples - 1)) for i in range(num_samples)]
        
        samples = []
        for i in range(num_samples):
            x = i / (num_samples - 1)
            y = self._monotonic_cubic_interpolate(x, control_points)
            samples.append((x, y))
        
        return samples
    
    def _monotonic_cubic_interpolate(self, x: float, points: List[Tuple[float, float]]) -> float:
        """单调三次插值"""
        if len(points) < 2:
            return x
        
        # 找到x所在的区间
        for i in range(len(points) - 1):
            x1, y1 = points[i]
            x2, y2 = points[i + 1]
            
            if x1 <= x <= x2:
                # 计算区间内的插值
                t = (x - x1) / (x2 - x1) if x2 > x1 else 0
                
                # 计算端点导数（使用有限差分）
                if i == 0:
                    h1 = x2 - x1
                    h2 = points[i + 2][0] - x2 if i + 2 < len(points) else h1
                    m0 = (y2 - y1) / h1
                    m1 = (y2 - y1) / h1
                    m2 = (points[i + 2][1] - y2) / h2 if i + 2 < len(points) else m1
                elif i == len(points) - 2:
                    h0 = x1 - points[i - 1][0]
                    h1 = x2 - x1
                    m0 = (y1 - points[i - 1][1]) / h0
                    m1 = (y2 - y1) / h1
                    m2 = m1
                else:
                    h0 = x1 - points[i - 1][0]
                    h1 = x2 - x1
                    h2 = points[i + 2][0] - x2 if i + 2 < len(points) else h1
                    m0 = (y1 - points[i - 1][1]) / h0
                    m1 = (y2 - y1) / h1
                    m2 = (points[i + 2][1] - y2) / h2 if i + 2 < len(points) else m1
                
                # 单调性约束
                if m0 * m1 <= 0:
                    m0 = 0
                if m1 * m2 <= 0:
                    m2 = 0
                
                # Hermite插值
                t2 = t * t
                t3 = t2 * t
                h00 = 2 * t3 - 3 * t2 + 1
                h10 = t3 - 2 * t2 + t
                h01 = -2 * t3 + 3 * t2
                h11 = t3 - t2
                
                return h00 * y1 + h10 * h1 * m1 + h01 * y2 + h11 * h1 * m2
        
        # 超出范围处理
        if x <= points[0][0]:
            return points[0][1]
        else:
            return points[-1][1]
    
    # =======================
    # 6. 转线性
    # =======================
    
    def density_to_linear(self, density_array: np.ndarray, use_parallel: bool = True) -> np.ndarray:
        """
        将密度空间转换为线性空间（支持并行）
        
        使用NumPy优化的exp函数，比LUT查表更快
        """
        should_parallel = self._should_use_parallel(density_array.size, use_parallel)
        
        if should_parallel:
            return self._density_to_linear_parallel(density_array)
        else:
            return self._density_to_linear_direct(density_array)
    
    def _density_to_linear_direct(self, density_array: np.ndarray) -> np.ndarray:
        """直接版本的密度转线性"""
        # 密度转线性：linear = 10^(-density) = exp(-density * ln(10))
        # 使用exp替代power，因为exp通常更快
        ln10 = np.log(10.0)
        result = np.exp(-density_array * ln10).astype(density_array.dtype)
        
        # 裁剪到有效范围
        result = np.clip(result, 0.0, 1.0)
        
        return result.astype(density_array.dtype)
    
    def _density_to_linear_parallel(self, density_array: np.ndarray) -> np.ndarray:
        """并行版本的密度转线性"""
        h, w, c = density_array.shape
        result = np.zeros_like(density_array)
        
        # 预计算常量
        ln10 = np.log(10.0)
        
        # 计算分块数量
        blocks_h = (h + self.block_size - 1) // self.block_size
        blocks_w = (w + self.block_size - 1) // self.block_size
        
        def process_block(args):
            i, j = args
            start_h = i * self.block_size
            end_h = min((i + 1) * self.block_size, h)
            start_w = j * self.block_size
            end_w = min((j + 1) * self.block_size, w)
            
            # 提取块并处理
            block = density_array[start_h:end_h, start_w:end_w, :]
            block_result = np.exp(-block * ln10).astype(density_array.dtype)
            block_result = np.clip(block_result, 0.0, 1.0)
            
            return (start_h, end_h, start_w, end_w, block_result.astype(block.dtype))
        
        # 并行处理所有块
        block_coords = [(i, j) for i in range(blocks_h) for j in range(blocks_w)]
        
        executor = self._get_thread_pool()
        results = list(executor.map(process_block, block_coords))
        
        # 重组结果
        for start_h, end_h, start_w, end_w, block_result in results:
            result[start_h:end_h, start_w:end_w, :] = block_result
        
        return result
    
    def linear_to_density(self, linear_array: np.ndarray, use_parallel: bool = True) -> np.ndarray:
        """
        将线性空间转换为密度空间（支持并行）
        
        Args:
            linear_array: 线性空间图像
            use_parallel: 是否使用并行处理
            
        Returns:
            密度空间图像
        """
        should_parallel = self._should_use_parallel(linear_array.size, use_parallel)
        
        if should_parallel:
            return self._linear_to_density_parallel(linear_array)
        else:
            return self._linear_to_density_direct(linear_array)
    
    def _linear_to_density_direct(self, linear_array: np.ndarray) -> np.ndarray:
        """直接版本的线性转密度"""
        # 避免log(0)
        safe_array = np.maximum(linear_array, 1e-10)
        
        # 线性转密度：density = -log10(linear)
        result = -np.log10(safe_array)
        
        return result
    
    def _linear_to_density_parallel(self, linear_array: np.ndarray) -> np.ndarray:
        """并行版本的线性转密度"""
        h, w, c = linear_array.shape
        result = np.zeros_like(linear_array)
        
        # 计算分块数量
        blocks_h = (h + self.block_size - 1) // self.block_size
        blocks_w = (w + self.block_size - 1) // self.block_size
        
        def process_block(args):
            i, j = args
            start_h = i * self.block_size
            end_h = min((i + 1) * self.block_size, h)
            start_w = j * self.block_size
            end_w = min((j + 1) * self.block_size, w)
            
            # 提取块并处理
            block = linear_array[start_h:end_h, start_w:end_w, :]
            safe_block = np.maximum(block, 1e-10)
            block_result = -np.log10(safe_block)
            
            return (start_h, end_h, start_w, end_w, block_result)
        
        # 并行处理所有块
        block_coords = [(i, j) for i in range(blocks_h) for j in range(blocks_w)]
        
        executor = self._get_thread_pool()
        results = list(executor.map(process_block, block_coords))
        
        # 重组结果
        for start_h, end_h, start_w, end_w, block_result in results:
            result[start_h:end_h, start_w:end_w, :] = block_result
        
        return result
    
    # =======================
    # 完整数学管线
    # =======================
    
    def apply_full_math_pipeline(self, image_array: np.ndarray, params: ColorGradingParams,
                               include_curve: bool = True, 
                               enable_density_inversion: bool = True,
                               use_optimization: bool = True,
                               profile: Optional[Dict[str, float]] = None) -> np.ndarray:
        """
        应用完整的数学处理管线
        
        Args:
            image_array: 输入图像数组 [H, W, 3]
            params: 颜色分级参数
            include_curve: 是否包含曲线处理
            enable_density_inversion: 是否启用密度反相
            use_optimization: 是否使用优化版本
            profile: 性能分析字典
            
        Returns:
            处理后的图像数组
        """
        if image_array is None:
            # 你可以选择直接返回 None，或者抛一个更清晰的异常
            raise ValueError("apply_full_math_pipeline() got image_array=None")

        if profile is not None:
            profile.clear()

        result_array = image_array.copy()

        # 如果密度反相未启用，检查是否需要完全跳过密度处理
        if not enable_density_inversion:
            # 检查是否有任何密度空间处理需要执行
            has_density_processing = (
                params.enable_density_matrix or
                params.enable_rgb_gains or
                (include_curve and params.enable_density_curve)
            )

            if not has_density_processing:
                # 完全跳过密度处理，直接返回输入
                if profile is not None:
                    profile['density_inversion_ms'] = 0.0
                    profile['to_density_ms'] = 0.0
                    profile['density_matrix_ms'] = 0.0
                    profile['rgb_gains_ms'] = 0.0
                    profile['density_curves_ms'] = 0.0
                return result_array

        # 1. 密度反相（始终执行，通过 invert 参数控制正负号）
        t0 = time.time()
        result_array = self.density_inversion(
            result_array, params.density_gamma, params.density_dmax,
            invert=enable_density_inversion,
            use_optimization=use_optimization
        )
        if profile is not None:
            profile['density_inversion_ms'] = (time.time() - t0) * 1000.0

        # 2. 转为密度空间
        t1 = time.time()
        density_array = self.linear_to_density(result_array)
        if profile is not None:
            profile['to_density_ms'] = (time.time() - t1) * 1000.0
        
        # 3. 密度校正矩阵
        if params.enable_density_matrix:
            t2 = time.time()
            matrix = self._get_density_matrix(params)
            if matrix is not None and not np.allclose(matrix, np.eye(3)):
                density_array = self.apply_density_matrix(
                    density_array, matrix, params.density_dmax,
                    channel_gamma_r=params.channel_gamma_r,
                    channel_gamma_b=params.channel_gamma_b
                )
            if profile is not None:
                profile['density_matrix_ms'] = (time.time() - t2) * 1000.0
        
        # 4. RGB增益调整
        if params.enable_rgb_gains:
            t3 = time.time()
            density_array = self.apply_rgb_gains(density_array, params.rgb_gains)
            if profile is not None:
                profile['rgb_gains_ms'] = (time.time() - t3) * 1000.0
        
        # 5. 密度曲线调整和转换回线性空间
        t4 = time.time()
        
        if include_curve and params.enable_density_curve:
            # RGB通用曲线
            curve_points = params.curve_points if not self._is_default_curve(params.curve_points) else None
            
            # 单通道曲线
            channel_curves = {}
            if not self._is_default_curve(params.curve_points_r):
                channel_curves['r'] = params.curve_points_r
            if not self._is_default_curve(params.curve_points_g):
                channel_curves['g'] = params.curve_points_g
            if not self._is_default_curve(params.curve_points_b):
                channel_curves['b'] = params.curve_points_b

            if curve_points or channel_curves:
                # apply_density_curve现在包含了转线性和屏幕反光补偿
                result_array = self.apply_density_curve(
                    density_array, curve_points, channel_curves,
                    use_optimization=use_optimization,
                    screen_glare_compensation=params.screen_glare_compensation
                )
            else:
                # 没有曲线时，需要手动转换到线性空间并应用屏幕反光补偿
                result_array = self.density_to_linear(density_array)
                if params.screen_glare_compensation > 0.0:
                    result_array = np.maximum(0.0, result_array - params.screen_glare_compensation)
        else:
            # 密度曲线被禁用时，仍需要将density_array转换回线性空间
            # 这确保了RGB增益等在密度空间的处理结果能正确返回
            result_array = self.density_to_linear(density_array)
            # 没有密度曲线时，应同时关闭反光校正。
            # if params.screen_glare_compensation > 0.0:
            #     result_array = np.maximum(0.0, result_array - params.screen_glare_compensation)
        
        if profile is not None:
            profile['density_curves_ms'] = (time.time() - t4) * 1000.0
        
        return result_array

    def _is_default_curve(self, points: list) -> bool:
        """检查曲线是否为默认直线"""
        return points == [(0.0, 0.0), (1.0, 1.0)] or not points
    
    def _get_density_matrix(self, params: ColorGradingParams) -> Optional[np.ndarray]:
        """获取密度校正矩阵（与新参数结构对齐）。"""
        # 新结构：直接使用 ColorGradingParams.density_matrix（若存在）
        try:
            if getattr(params, 'density_matrix', None) is not None:
                return np.array(params.density_matrix)
        except Exception:
            pass
        return None

