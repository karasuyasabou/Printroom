using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace PrintroomApp.Models;

public sealed class WinMatrixOptionDto
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("isBuiltIn")] public bool IsBuiltIn { get; set; }
    [JsonPropertyName("isSnapshot")] public bool IsSnapshot { get; set; }
    [JsonPropertyName("values")] public float[] Values { get; set; } = [];
}

public sealed class WinCropDto
{
    [JsonPropertyName("aspect")] public string Aspect { get; set; } = "free";
    [JsonPropertyName("centerX")] public double CenterX { get; set; }
    [JsonPropertyName("centerY")] public double CenterY { get; set; }
    [JsonPropertyName("width")] public double Width { get; set; }
    [JsonPropertyName("angleDegrees")] public double AngleDegrees { get; set; }
    [JsonPropertyName("portrait")] public bool Portrait { get; set; }
    [JsonPropertyName("freeRatio")] public double? FreeRatio { get; set; }
    [JsonPropertyName("ratio")] public double Ratio { get; set; }
    [JsonPropertyName("rectX")] public double RectX { get; set; }
    [JsonPropertyName("rectY")] public double RectY { get; set; }
    [JsonPropertyName("rectW")] public double RectW { get; set; }
    [JsonPropertyName("rectH")] public double RectH { get; set; }
}

public sealed class WinHistogramDto
{
    [JsonPropertyName("stage")] public int Stage { get; set; }
    [JsonPropertyName("sampleCount")] public int SampleCount { get; set; }
    [JsonPropertyName("binsR")] public ulong[] BinsR { get; set; } = [];
    [JsonPropertyName("binsG")] public ulong[] BinsG { get; set; } = [];
    [JsonPropertyName("binsB")] public ulong[] BinsB { get; set; } = [];
}

public sealed class WinFrameDto
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("filename")] public string Filename { get; set; } = "";
    [JsonPropertyName("isMissing")] public bool IsMissing { get; set; }
    [JsonPropertyName("needsReview")] public bool NeedsReview { get; set; }
    [JsonPropertyName("thumbnailRevision")] public ulong ThumbnailRevision { get; set; }
}

public sealed class WinExportSettingsDto
{
    [JsonPropertyName("format")] public string Format { get; set; } = "tiff";
    [JsonPropertyName("profile")] public string Profile { get; set; } = "sRGB";
    [JsonPropertyName("compression")] public string Compression { get; set; } = "deflate";
    [JsonPropertyName("applyCrop")] public bool ApplyCrop { get; set; } = true;
    [JsonPropertyName("overwriteExisting")] public bool OverwriteExisting { get; set; }
    [JsonPropertyName("destinationPath")] public string? DestinationPath { get; set; }
    [JsonPropertyName("filenamePrefix")] public string? FilenamePrefix { get; set; }
    [JsonPropertyName("rollDefaultPrefix")] public string RollDefaultPrefix { get; set; } = "Printroom";
}

public sealed class WinRecentRollDto
{
    [JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonPropertyName("projectID")] public string ProjectId { get; set; } = "";
    [JsonPropertyName("openedAtUnix")] public double OpenedAtUnix { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "";
    [JsonPropertyName("isAvailable")] public bool IsAvailable { get; set; }
}

public sealed class WinUIStateSnapshot
{
    [JsonPropertyName("revision")] public ulong Revision { get; set; }
    [JsonPropertyName("isImporting")] public bool IsImporting { get; set; }
    [JsonPropertyName("importCompleted")] public int ImportCompleted { get; set; }
    [JsonPropertyName("importTotal")] public int ImportTotal { get; set; }
    [JsonPropertyName("importFailure")] public string? ImportFailure { get; set; }
    [JsonPropertyName("hasProject")] public bool HasProject { get; set; }
    [JsonPropertyName("projectID")] public string? ProjectId { get; set; }
    [JsonPropertyName("rollName")] public string RollName { get; set; } = "Printroom";
    [JsonPropertyName("folderPath")] public string? FolderPath { get; set; }
    [JsonPropertyName("needsInitialRollNaming")] public bool NeedsInitialRollNaming { get; set; }
    [JsonPropertyName("dirty")] public bool Dirty { get; set; }
    [JsonPropertyName("saveFailure")] public bool SaveFailure { get; set; }
    [JsonPropertyName("errorMessage")] public string? ErrorMessage { get; set; }
    [JsonPropertyName("isLoading")] public bool IsLoading { get; set; }
    [JsonPropertyName("isRendering")] public bool IsRendering { get; set; }
    [JsonPropertyName("isPreviewPlaceholder")] public bool IsPreviewPlaceholder { get; set; }
    [JsonPropertyName("isPreparingGeometry")] public bool IsPreparingGeometry { get; set; }
    [JsonPropertyName("isAutoCropping")] public bool IsAutoCropping { get; set; }
    [JsonPropertyName("autoCropProgressText")] public string AutoCropProgressText { get; set; } = "";
    [JsonPropertyName("autoCropCompletedRun")] public int AutoCropCompletedRun { get; set; }
    [JsonPropertyName("isAnalyzingRollTiming")] public bool IsAnalyzingRollTiming { get; set; }
    [JsonPropertyName("showMissingFilmBaseDialog")] public bool ShowMissingFilmBaseDialog { get; set; }
    [JsonPropertyName("showRollTimingConfirmation")] public bool ShowRollTimingConfirmation { get; set; }
    [JsonPropertyName("showRollTimingDialog")] public bool ShowRollTimingDialog { get; set; }
    [JsonPropertyName("rollTimingProgress")] public string RollTimingProgress { get; set; } = "";
    [JsonPropertyName("rollTimingError")] public string? RollTimingError { get; set; }
    [JsonPropertyName("isExporting")] public bool IsExporting { get; set; }
    [JsonPropertyName("exportProgress")] public double ExportProgress { get; set; }
    [JsonPropertyName("exportDetail")] public string ExportDetail { get; set; } = "";
    [JsonPropertyName("exportFinished")] public bool ExportFinished { get; set; }
    [JsonPropertyName("exportResultMessage")] public string? ExportResultMessage { get; set; }
    [JsonPropertyName("exportResultDetail")] public string? ExportResultDetail { get; set; }
    [JsonPropertyName("canUndo")] public bool CanUndo { get; set; }
    [JsonPropertyName("canRedo")] public bool CanRedo { get; set; }
    [JsonPropertyName("undoActionName")] public string? UndoActionName { get; set; }
    [JsonPropertyName("redoActionName")] public string? RedoActionName { get; set; }
    [JsonPropertyName("activeFrameID")] public string? ActiveFrameId { get; set; }
    [JsonPropertyName("selectedFrameIDs")] public List<string> SelectedFrameIds { get; set; } = [];
    [JsonPropertyName("activeFilename")] public string? ActiveFilename { get; set; }
    [JsonPropertyName("hasImage")] public bool HasImage { get; set; }
    [JsonPropertyName("hasFilmBase")] public bool HasFilmBase { get; set; }
    [JsonPropertyName("canAdjustColors")] public bool CanAdjustColors { get; set; }
    [JsonPropertyName("canPickNeutral")] public bool CanPickNeutral { get; set; }
    [JsonPropertyName("canApply")] public bool CanApply { get; set; }
    [JsonPropertyName("canSync")] public bool CanSync { get; set; }
    [JsonPropertyName("canChangeSelectedOrientations")] public bool CanChangeSelectedOrientations { get; set; }
    [JsonPropertyName("canStartAutoCrop")] public bool CanStartAutoCrop { get; set; }
    [JsonPropertyName("canStartRollTiming")] public bool CanStartRollTiming { get; set; }
    [JsonPropertyName("canOpenRollTiming")] public bool CanOpenRollTiming { get; set; }
    [JsonPropertyName("sampling")] public bool Sampling { get; set; }
    [JsonPropertyName("neutralPicking")] public bool NeutralPicking { get; set; }
    [JsonPropertyName("isNeutralSampling")] public bool IsNeutralSampling { get; set; }
    [JsonPropertyName("stage")] public int Stage { get; set; }
    [JsonPropertyName("histogramStage")] public int HistogramStage { get; set; }
    [JsonPropertyName("cropPreviewEnabled")] public bool CropPreviewEnabled { get; set; }
    [JsonPropertyName("sprocketWhiteningEnabled")] public bool SprocketWhiteningEnabled { get; set; }
    [JsonPropertyName("sprocketWhiteningThreshold")] public double SprocketWhiteningThreshold { get; set; }
    [JsonPropertyName("canAdjustSprocketWhitening")] public bool CanAdjustSprocketWhitening { get; set; }
    [JsonPropertyName("sourceWidth")] public int SourceWidth { get; set; }
    [JsonPropertyName("sourceHeight")] public int SourceHeight { get; set; }
    [JsonPropertyName("displayWidth")] public int DisplayWidth { get; set; }
    [JsonPropertyName("displayHeight")] public int DisplayHeight { get; set; }
    [JsonPropertyName("isCropping")] public bool IsCropping { get; set; }
    [JsonPropertyName("canEditCrop")] public bool CanEditCrop { get; set; }
    [JsonPropertyName("cropRatioLocked")] public bool CropRatioLocked { get; set; }
    [JsonPropertyName("cropViewportToken")] public int CropViewportToken { get; set; }
    [JsonPropertyName("presentsCrop")] public bool PresentsCrop { get; set; }
    [JsonPropertyName("cropTransitionSizeWidth")] public int? CropTransitionSizeWidth { get; set; }
    [JsonPropertyName("cropTransitionSizeHeight")] public int? CropTransitionSizeHeight { get; set; }
    [JsonPropertyName("presentedCropDisplay")] public WinCropDto? PresentedCropDisplay { get; set; }
    [JsonPropertyName("cropReviewAvailable")] public bool CropReviewAvailable { get; set; }
    [JsonPropertyName("reviewOnlyPendingCrops")] public bool ReviewOnlyPendingCrops { get; set; }
    [JsonPropertyName("pendingAutoCropFrameIDs")] public List<string> PendingAutoCropFrameIds { get; set; } = [];
    [JsonPropertyName("previewBitmapRevision")] public ulong PreviewBitmapRevision { get; set; }
    [JsonPropertyName("previewWidth")] public int PreviewWidth { get; set; }
    [JsonPropertyName("previewHeight")] public int PreviewHeight { get; set; }
    [JsonPropertyName("histogram")] public WinHistogramDto? Histogram { get; set; }
    [JsonPropertyName("histogramProbe")] public float[]? HistogramProbe { get; set; }
    [JsonPropertyName("cmosMatrixID")] public string CmosMatrixId { get; set; } = "identity";
    [JsonPropertyName("cmosOptions")] public List<WinMatrixOptionDto> CmosOptions { get; set; } = [];
    [JsonPropertyName("densityMatrixID")] public string DensityMatrixId { get; set; } = "identity";
    [JsonPropertyName("densityOptions")] public List<WinMatrixOptionDto> DensityOptions { get; set; } = [];
    [JsonPropertyName("matrixLibraryError")] public string? MatrixLibraryError { get; set; }
    [JsonPropertyName("cmosCalibBusy")] public bool CmosCalibBusy { get; set; }
    [JsonPropertyName("cmosCalibValues")] public float[]? CmosCalibValues { get; set; }
    [JsonPropertyName("cmosCalibIdentifications")] public List<string> CmosCalibIdentifications { get; set; } = [];
    [JsonPropertyName("cmosCalibError")] public string? CmosCalibError { get; set; }
    [JsonPropertyName("cmosCalibSuggestedName")] public string? CmosCalibSuggestedName { get; set; }
    [JsonPropertyName("timingMode")] public string TimingMode { get; set; } = "simple";
    [JsonPropertyName("simpleExposure")] public double SimpleExposure { get; set; }
    [JsonPropertyName("simpleTemperature")] public double SimpleTemperature { get; set; }
    [JsonPropertyName("simpleTint")] public double SimpleTint { get; set; }
    [JsonPropertyName("timingMaster")] public int TimingMaster { get; set; }
    [JsonPropertyName("timingRed")] public int TimingRed { get; set; }
    [JsonPropertyName("timingGreen")] public int TimingGreen { get; set; }
    [JsonPropertyName("timingBlue")] public int TimingBlue { get; set; }
    [JsonPropertyName("contrastMaster")] public float ContrastMaster { get; set; }
    [JsonPropertyName("contrastRed")] public float ContrastRed { get; set; }
    [JsonPropertyName("contrastGreen")] public float ContrastGreen { get; set; }
    [JsonPropertyName("contrastBlue")] public float ContrastBlue { get; set; }
    [JsonPropertyName("cineonLogLUT")] public string CineonLogLut { get; set; } = "kodak2383";
    [JsonPropertyName("copiedSourceName")] public string? CopiedSourceName { get; set; }
    [JsonPropertyName("frames")] public List<WinFrameDto> Frames { get; set; } = [];
    [JsonPropertyName("exportSettings")] public WinExportSettingsDto ExportSettings { get; set; } = new();
    [JsonPropertyName("recentRolls")] public List<WinRecentRollDto> RecentRolls { get; set; } = [];
    [JsonPropertyName("removedRecentRoll")] public WinRecentRollDto? RemovedRecentRoll { get; set; }
    [JsonPropertyName("cacheLimitGB")] public double CacheLimitGb { get; set; }
    [JsonPropertyName("cacheRetentionDays")] public int CacheRetentionDays { get; set; }
    [JsonPropertyName("cacheBytes")] public long? CacheBytes { get; set; }
    [JsonPropertyName("cacheError")] public string? CacheError { get; set; }
    [JsonPropertyName("availableUpdateVersion")] public string? AvailableUpdateVersion { get; set; }
}
