using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace PrintroomApp.Interop;

public sealed class NativeBridge : IDisposable
{
    private const string DllName = "PrintroomWinBridge.dll";
    private nint _handle;
    private readonly object _gate = new();

    static NativeBridge()
    {
        NativeLibrary.SetDllImportResolver(typeof(NativeBridge).Assembly, ResolveNativeLibrary);
    }

    private static nint ResolveNativeLibrary(string libraryName, System.Reflection.Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, DllName, StringComparison.OrdinalIgnoreCase))
            return 0;

        string baseDir = AppContext.BaseDirectory;
        string[] candidates =
        [
            Path.Combine(baseDir, DllName),
            Path.GetFullPath(Path.Combine(baseDir, @"..\..\..\..\..\.build\x86_64-unknown-windows-msvc\release", DllName)),
            Path.GetFullPath(Path.Combine(baseDir, @"..\..\..\..\..\.build\x86_64-unknown-windows-msvc\debug", DllName)),
            Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, @".build\x86_64-unknown-windows-msvc\release", DllName)),
            Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, @".build\x86_64-unknown-windows-msvc\debug", DllName)),
        ];

        foreach (var path in candidates)
        {
            if (File.Exists(path) && NativeLibrary.TryLoad(path, out nint lib))
                return lib;
        }
        return 0;
    }

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pr_bridge_verify_resources(nint assetsRootUtf8, out nint outMessageUtf8);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern nint pr_bridge_create(nint assetsRootUtf8, out nint outErrorUtf8);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pr_bridge_destroy(nint handle);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pr_bridge_set_hwnd(nint handle, nint hwnd);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern nint pr_bridge_dispatch(nint handle, nint commandJsonUtf8);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern nint pr_bridge_poll_state(nint handle, ulong lastRevision);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pr_bridge_copy_preview_bgra(
        nint handle, out int outWidth, out int outHeight, out ulong outRevision,
        nint destBuffer, nuint destCapacity);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pr_bridge_copy_thumbnail_bgra(
        nint handle, nint frameIdUtf8, out int outWidth, out int outHeight,
        nint destBuffer, nuint destCapacity);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pr_bridge_free_string(nint ptr);

    public static string? ResolveDefaultAssetsRoot()
    {
        string baseDir = AppContext.BaseDirectory;
        string[] candidates =
        [
            Path.Combine(baseDir, "Assets"),
            baseDir,
            Environment.CurrentDirectory,
            Path.GetFullPath(Path.Combine(baseDir, @"..\..\..\..")),
            Path.GetFullPath(Path.Combine(baseDir, @"..\..\..\..\..")),
        ];
        foreach (var c in candidates)
        {
            if (File.Exists(Path.Combine(c, "ICC", "DCIP3_D65.icc")))
                return c;
        }
        return null;
    }

    public static bool VerifyResources(string? assetsRoot, out string message)
    {
        nint rootPtr = Marshal.StringToCoTaskMemUTF8(assetsRoot ?? ResolveDefaultAssetsRoot());
        try
        {
            int rc = pr_bridge_verify_resources(rootPtr, out nint msgPtr);
            message = ConsumeBridgeString(msgPtr) ?? (rc == 0 ? "OK" : "Unknown verification failure");
            return rc == 0;
        }
        finally
        {
            Marshal.FreeCoTaskMem(rootPtr);
        }
    }

    public NativeBridge(string? assetsRoot = null)
    {
        nint rootPtr = Marshal.StringToCoTaskMemUTF8(assetsRoot ?? ResolveDefaultAssetsRoot());
        try
        {
            _handle = pr_bridge_create(rootPtr, out nint errPtr);
            string? err = ConsumeBridgeString(errPtr);
            if (_handle == 0)
            {
                throw new InvalidOperationException(err ?? "无法初始化 Printroom 核心引擎");
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(rootPtr);
        }
    }

    public void SetHwnd(nint hwnd)
    {
        lock (_gate)
        {
            if (_handle != 0) pr_bridge_set_hwnd(_handle, hwnd);
        }
    }

    public JsonDocument Dispatch(object commandPayload)
    {
        string json = JsonSerializer.Serialize(commandPayload);
        nint cmdPtr = Marshal.StringToCoTaskMemUTF8(json);
        try
        {
            lock (_gate)
            {
                if (_handle == 0)
                    return JsonDocument.Parse("{\"ok\":false,\"error\":\"Bridge disposed\"}");
                nint resPtr = pr_bridge_dispatch(_handle, cmdPtr);
                string res = ConsumeBridgeString(resPtr) ?? "{\"ok\":false,\"error\":\"Null reply\"}";
                return JsonDocument.Parse(res);
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(cmdPtr);
        }
    }

    public Models.WinUIStateSnapshot? PollState(ulong lastRevision)
    {
        string? json;
        lock (_gate)
        {
            if (_handle == 0) return null;
            nint ptr = pr_bridge_poll_state(_handle, lastRevision);
            if (ptr == 0) return null;
            json = ConsumeBridgeString(ptr);
        }
        if (string.IsNullOrEmpty(json)) return null;
        return JsonSerializer.Deserialize<Models.WinUIStateSnapshot>(json);
    }

    public unsafe byte[]? CopyPreviewBgra(out int width, out int height, out ulong revision)
    {
        width = 0;
        height = 0;
        revision = 0;
        lock (_gate)
        {
            if (_handle == 0) return null;
            int probe = pr_bridge_copy_preview_bgra(_handle, out width, out height, out revision, 0, 0);
            if (probe == 0) return null;
            int needed = probe < 0 ? -probe : probe;
            var buffer = new byte[needed];
            fixed (byte* p = buffer)
            {
                int copied = pr_bridge_copy_preview_bgra(_handle, out width, out height, out revision, (nint)p, (nuint)needed);
                return copied == needed ? buffer : null;
            }
        }
    }

    public unsafe byte[]? CopyThumbnailBgra(string frameId, out int width, out int height)
    {
        width = 0;
        height = 0;
        nint idPtr = Marshal.StringToCoTaskMemUTF8(frameId);
        try
        {
            lock (_gate)
            {
                if (_handle == 0) return null;
                int probe = pr_bridge_copy_thumbnail_bgra(_handle, idPtr, out width, out height, 0, 0);
                if (probe == 0) return null;
                int needed = probe < 0 ? -probe : probe;
                var buffer = new byte[needed];
                fixed (byte* p = buffer)
                {
                    int copied = pr_bridge_copy_thumbnail_bgra(_handle, idPtr, out width, out height, (nint)p, (nuint)needed);
                    return copied == needed ? buffer : null;
                }
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(idPtr);
        }
    }

    private static string? ConsumeBridgeString(nint ptr)
    {
        if (ptr == 0) return null;
        try
        {
            return Marshal.PtrToStringUTF8(ptr);
        }
        finally
        {
            pr_bridge_free_string(ptr);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_handle != 0)
            {
                pr_bridge_destroy(_handle);
                _handle = 0;
            }
        }
    }
}
