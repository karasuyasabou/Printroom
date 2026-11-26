using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using PrintroomApp.Interop;
using PrintroomApp.Models;
using Xunit;

namespace Printroom.Windows.Tests;

public class BridgeIntegrationTests
{
    private static bool WaitUntil(NativeBridge bridge, ref ulong rev, ref WinUIStateSnapshot state, Func<WinUIStateSnapshot, bool> predicate, int timeoutMs = 30000)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            var next = bridge.PollState(rev);
            if (next != null)
            {
                rev = next.Revision;
                state = next;
            }
            if (predicate(state)) return true;
            Thread.Sleep(25);
        }
        return predicate(state);
    }

    private static void WriteTest16BitRgbTiff(string path, int width, int height, ushort r, ushort g, ushort b)
    {
        // Minimal uncompressed baseline 16-bit RGB TIFF for end-to-end roll tests
        using var fs = File.Create(path);
        using var bw = new BinaryWriter(fs);

        int pixelBytes = width * height * 3 * 2;
        uint pixelOffset = 8;
        uint bitsOffset = pixelOffset + (uint)pixelBytes;
        uint ifdOffset = bitsOffset + 6;

        // TIFF header (little endian)
        bw.Write((byte)'I'); bw.Write((byte)'I');
        bw.Write((ushort)42);
        bw.Write(ifdOffset);

        // Image data
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                // Make left 8 columns brighter film base, inner area darker negative frame
                bool isBorder = x < 8 || x >= width - 8 || y < 8 || y >= height - 8;
                bw.Write(isBorder ? (ushort)48000 : r);
                bw.Write(isBorder ? (ushort)32000 : g);
                bw.Write(isBorder ? (ushort)22000 : b);
            }
        }

        // BitsPerSample [16, 16, 16]
        bw.Write((ushort)16); bw.Write((ushort)16); bw.Write((ushort)16);

        // IFD (9 entries sorted by tag)
        void WriteEntry(ushort tag, ushort type, uint count, uint val)
        {
            bw.Write(tag); bw.Write(type); bw.Write(count); bw.Write(val);
        }

        bw.Write((ushort)9);
        WriteEntry(256, 4, 1, (uint)width);          // ImageWidth
        WriteEntry(257, 4, 1, (uint)height);         // ImageLength
        WriteEntry(258, 3, 3, bitsOffset);           // BitsPerSample
        WriteEntry(259, 3, 1, 1);                    // Compression = None
        WriteEntry(262, 3, 1, 2);                    // Photometric = RGB
        WriteEntry(273, 4, 1, pixelOffset);          // StripOffsets
        WriteEntry(277, 3, 1, 3);                    // SamplesPerPixel
        WriteEntry(278, 4, 1, (uint)height);         // RowsPerStrip
        WriteEntry(279, 4, 1, (uint)pixelBytes);     // StripByteCounts
        bw.Write((uint)0);                           // Next IFD
    }

    [Fact]
    public void VerifyResourcesReportsGPUAndLibRaw()
    {
        bool ok = NativeBridge.VerifyResources(null, out string msg);
        Assert.True(ok, msg);
        Assert.Contains("GPU=", msg);
        Assert.Contains("LibRaw=", msg);
    }

    [Fact]
    public void EndToEndRollImportCalibrateEditCropUndoSyncAndExport()
    {
        string root = Path.Combine(Path.GetTempPath(), "printroom-win-e2e-" + Guid.NewGuid().ToString("N"));
        string exportDir = Path.Combine(root, "exports");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(exportDir);

        try
        {
            for (int i = 1; i <= 4; i++)
            {
                WriteTest16BitRgbTiff(Path.Combine(root, $"frame_{i:D2}.tiff"), 96, 64,
                    (ushort)(14000 + i * 1000), (ushort)(10000 + i * 800), (ushort)(8000 + i * 600));
            }

            using var bridge = new NativeBridge();
            ulong rev = 0;
            var state = bridge.PollState(0) ?? throw new InvalidOperationException("Initial state null");
            rev = state.Revision;

            using var openReply = bridge.Dispatch(new { action = "openFolder", path = root });
            Assert.True(openReply.RootElement.GetProperty("ok").GetBoolean());

            Assert.True(WaitUntil(bridge, ref rev, ref state,
                s => !s.IsImporting && s.HasProject && s.Frames.Count == 4 && s.HasImage && s.PreviewWidth > 0),
                $"Roll did not finish loading: err={state.ErrorMessage} importErr={state.ImportFailure}");

            var bgra = bridge.CopyPreviewBgra(out int pw, out int ph, out ulong prevRev);
            Assert.NotNull(bgra);
            Assert.True(pw > 0 && ph > 0 && prevRev > 0);
            Assert.Equal(pw * ph * 4, bgra!.Length);
            Assert.Equal(255, bgra[3]); // Alpha == 255 for WPF Bgra32

            // Sample film base on border
            bridge.Dispatch(new { action = "beginFilmBaseSelection", boolValue = false });
            bridge.Dispatch(new { action = "sampleDisplayedBase", x = 0, y = 0, width = 6, height = 16 });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => s.HasFilmBase && s.CanAdjustColors));

            // Simple Timing -> Undo -> Redo
            bridge.Dispatch(new { action = "setSimpleTiming", axis = "exposure", doubleValue = 40.0 });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => Math.Abs(s.SimpleExposure - 40.0) < 2.0 && s.CanUndo));
            bridge.Dispatch(new { action = "undo" });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => Math.Abs(s.SimpleExposure) < 2.0 && s.CanRedo));
            bridge.Dispatch(new { action = "redo" });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => Math.Abs(s.SimpleExposure - 40.0) < 2.0));

            // Manual Crop & Commit
            bridge.Dispatch(new { action = "beginCrop" });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => s.IsCropping));
            bridge.Dispatch(new { action = "nudgeCropAngle", doubleValue = 1.5 });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => Math.Abs((s.PresentedCropDisplay?.AngleDegrees ?? 0) - 1.5) < 0.05));
            bridge.Dispatch(new { action = "commitCrop" });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => !s.IsCropping && !s.IsRendering));

            // Sprocket whitening & Sync all
            bridge.Dispatch(new { action = "setSprocketWhitening", boolValue = true, doubleValue = 30.0 });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => s.SprocketWhiteningEnabled));

            bridge.Dispatch(new { action = "selectAll" });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => s.SelectedFrameIds.Count == 4 && s.CanSync));
            using var syncReply = bridge.Dispatch(new { action = "syncSettings", timing = true, contrast = true, lut = true, crop = true });
            Assert.True(syncReply.RootElement.GetProperty("ok").GetBoolean());

            // Export JPEG (Display P3)
            bridge.Dispatch(new
            {
                action = "startExport",
                allFrames = false,
                boolValue = true,
                path = exportDir,
                filenamePrefix = "TestRoll",
                format = "jpeg",
                profile = "displayP3",
                compression = "none",
                applyCrop = true,
                overwriteExisting = true
            });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => !s.IsExporting && s.ExportFinished, timeoutMs: 30000),
                $"JPEG export failed/timed out: {state.ExportResultMessage} / {state.ExportResultDetail}");
            Assert.Contains("导出成功", state.ExportResultMessage ?? "");
            Assert.True(File.Exists(Path.Combine(exportDir, "TestRoll-01.jpg")));

            // Rename roll & verify project save
            bridge.Dispatch(new { action = "renameRoll", name = "My Win Roll" });
            Assert.True(WaitUntil(bridge, ref rev, ref state, s => s.RollName == "My Win Roll"));
            Assert.True(File.Exists(Path.Combine(root, ".printroom.json")));

            // Return home & verify preview bitmap and revision are cleared
            bridge.Dispatch(new { action = "returnHome" });
            Assert.True(WaitUntil(bridge, ref rev, ref state,
                s => !s.HasProject && !s.HasImage && s.PreviewBitmapRevision == 0 && s.PreviewWidth == 0 && s.PreviewHeight == 0));
            var clearedBgra = bridge.CopyPreviewBgra(out int clearedW, out int clearedH, out ulong clearedRev);
            Assert.Null(clearedBgra);
            Assert.Equal(0, clearedW);
            Assert.Equal(0, clearedH);
            Assert.Equal(0UL, clearedRev);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }
}
