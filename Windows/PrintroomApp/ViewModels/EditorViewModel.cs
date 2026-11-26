using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PrintroomApp.Interop;
using PrintroomApp.Models;

namespace PrintroomApp.ViewModels;

public sealed class FrameThumbnailItem : INotifyPropertyChanged
{
    private string _filename = "";
    private bool _isMissing;
    private bool _needsReview;
    private bool _isActive;
    private bool _isSelected;
    private ulong _thumbnailRevision;
    private WriteableBitmap? _thumbnailBitmap;
    private bool _isVisibleInFilmstrip = true;

    public string Id { get; init; } = "";
    public int Index { get; set; }
    public string DisplayNumber => $"{Index + 1:D2}";

    public string Filename
    {
        get => _filename;
        set { if (_filename != value) { _filename = value; OnPropertyChanged(); } }
    }

    public bool IsMissing
    {
        get => _isMissing;
        set { if (_isMissing != value) { _isMissing = value; OnPropertyChanged(); OnPropertyChanged(nameof(TileOpacity)); } }
    }

    public bool NeedsReview
    {
        get => _needsReview;
        set { if (_needsReview != value) { _needsReview = value; OnPropertyChanged(); } }
    }

    public bool IsActive
    {
        get => _isActive;
        set { if (_isActive != value) { _isActive = value; OnPropertyChanged(); } }
    }

    public bool IsSelected
    {
        get => _isSelected;
        set { if (_isSelected != value) { _isSelected = value; OnPropertyChanged(); } }
    }

    public double TileOpacity => IsMissing ? 0.4 : 1.0;

    public ulong ThumbnailRevision
    {
        get => _thumbnailRevision;
        set { if (_thumbnailRevision != value) { _thumbnailRevision = value; OnPropertyChanged(); } }
    }

    public WriteableBitmap? ThumbnailBitmap
    {
        get => _thumbnailBitmap;
        set { if (!ReferenceEquals(_thumbnailBitmap, value)) { _thumbnailBitmap = value; OnPropertyChanged(); OnPropertyChanged(nameof(HasBitmap)); } }
    }

    public bool HasBitmap => ThumbnailBitmap != null;

    public bool IsVisibleInFilmstrip
    {
        get => _isVisibleInFilmstrip;
        set { if (_isVisibleInFilmstrip != value) { _isVisibleInFilmstrip = value; OnPropertyChanged(); } }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class EditorViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly NativeBridge _bridge;
    private readonly DispatcherTimer _pollTimer;
    private ulong _lastStateRevision;
    private ulong _lastPreviewBitmapRevision;
    private WinUIStateSnapshot _state = new();
    private WriteableBitmap? _previewBitmap;
    private readonly Dictionary<string, FrameThumbnailItem> _frameMap = new();

    public ObservableCollection<FrameThumbnailItem> Frames { get; } = [];
    public WriteableBitmap? PreviewBitmap
    {
        get => _previewBitmap;
        private set
        {
            if (!ReferenceEquals(_previewBitmap, value))
            {
                _previewBitmap = value;
                OnPropertyChanged();
            }
        }
    }

    public WinUIStateSnapshot State => _state;

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<WinUIStateSnapshot>? StateUpdated;
    public event Action? PreviewBitmapUpdated;

    public EditorViewModel(string? assetsRoot = null)
    {
        _bridge = new NativeBridge(assetsRoot);
        PollNow();
        _pollTimer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(16)
        };
        _pollTimer.Tick += (_, _) => PollNow();
        _pollTimer.Start();
    }

    public void SetWindowHandle(nint hwnd) => _bridge.SetHwnd(hwnd);

    public JsonDocument Dispatch(object payload)
    {
        var reply = _bridge.Dispatch(payload);
        PollNow();
        return reply;
    }

    public void PollNow()
    {
        var snapshot = _bridge.PollState(_lastStateRevision);
        if (snapshot == null) return;
        _lastStateRevision = snapshot.Revision;
        _state = snapshot;

        SyncFrames(snapshot);

        if (snapshot.PreviewBitmapRevision == 0)
        {
            if (_previewBitmap != null)
            {
                PreviewBitmap = null;
                PreviewBitmapUpdated?.Invoke();
            }
            _lastPreviewBitmapRevision = 0;
        }
        else if (snapshot.PreviewBitmapRevision != _lastPreviewBitmapRevision)
        {
            var bgra = _bridge.CopyPreviewBgra(out int w, out int h, out ulong rev);
            if (bgra != null && w > 0 && h > 0)
            {
                PreviewBitmap = UpdateOrCreateWriteableBitmap(_previewBitmap, w, h, bgra);
                _lastPreviewBitmapRevision = rev;
                PreviewBitmapUpdated?.Invoke();
            }
        }

        OnPropertyChanged(nameof(State));
        StateUpdated?.Invoke(snapshot);
    }

    private void SyncFrames(WinUIStateSnapshot s)
    {
        var selectedSet = new HashSet<string>(s.SelectedFrameIds);
        bool listChanged = Frames.Count != s.Frames.Count;
        if (!listChanged)
        {
            for (int i = 0; i < s.Frames.Count; i++)
            {
                if (Frames[i].Id != s.Frames[i].Id) { listChanged = true; break; }
            }
        }

        if (listChanged)
        {
            Frames.Clear();
            var nextMap = new Dictionary<string, FrameThumbnailItem>();
            for (int i = 0; i < s.Frames.Count; i++)
            {
                var dto = s.Frames[i];
                if (!_frameMap.TryGetValue(dto.Id, out var item))
                {
                    item = new FrameThumbnailItem { Id = dto.Id };
                }
                item.Index = i;
                item.Filename = dto.Filename;
                item.IsMissing = dto.IsMissing;
                item.NeedsReview = dto.NeedsReview;
                item.IsActive = dto.Id == s.ActiveFrameId;
                item.IsSelected = selectedSet.Contains(dto.Id);
                item.IsVisibleInFilmstrip = !s.IsCropping || !s.ReviewOnlyPendingCrops || dto.NeedsReview || dto.Id == s.ActiveFrameId;
                UpdateThumbnailIfNeeded(item, dto.ThumbnailRevision);
                nextMap[dto.Id] = item;
                Frames.Add(item);
            }
            _frameMap.Clear();
            foreach (var kv in nextMap) _frameMap[kv.Key] = kv.Value;
        }
        else
        {
            for (int i = 0; i < s.Frames.Count; i++)
            {
                var dto = s.Frames[i];
                var item = Frames[i];
                item.Index = i;
                item.Filename = dto.Filename;
                item.IsMissing = dto.IsMissing;
                item.NeedsReview = dto.NeedsReview;
                item.IsActive = dto.Id == s.ActiveFrameId;
                item.IsSelected = selectedSet.Contains(dto.Id);
                item.IsVisibleInFilmstrip = !s.IsCropping || !s.ReviewOnlyPendingCrops || dto.NeedsReview || dto.Id == s.ActiveFrameId;
                UpdateThumbnailIfNeeded(item, dto.ThumbnailRevision);
            }
        }
    }

    private void UpdateThumbnailIfNeeded(FrameThumbnailItem item, ulong targetRevision)
    {
        if (targetRevision == 0)
        {
            item.ThumbnailRevision = 0;
            item.ThumbnailBitmap = null;
            return;
        }
        if (item.ThumbnailRevision == targetRevision && item.ThumbnailBitmap != null) return;
        var bgra = _bridge.CopyThumbnailBgra(item.Id, out int w, out int h);
        if (bgra != null && w > 0 && h > 0)
        {
            item.ThumbnailBitmap = UpdateOrCreateWriteableBitmap(item.ThumbnailBitmap, w, h, bgra);
            item.ThumbnailRevision = targetRevision;
        }
    }

    private static WriteableBitmap UpdateOrCreateWriteableBitmap(WriteableBitmap? existing, int width, int height, byte[] bgra)
    {
        WriteableBitmap wb;
        if (existing != null && existing.PixelWidth == width && existing.PixelHeight == height)
        {
            wb = existing;
        }
        else
        {
            wb = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
        }
        wb.WritePixels(new Int32Rect(0, 0, width, height), bgra, width * 4, 0);
        return wb;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public void Dispose()
    {
        _pollTimer.Stop();
        _bridge.Dispose();
    }
}
