[CmdletBinding()]
param(
    [switch]$Run,
    # Manual tests remain open until the user closes the game. A positive value
    # opts into a bounded test; zero disables the deadline.
    [ValidateRange(0, 3600)]
    [int]$MaxSeconds = 0,
    [ValidateSet('Off', 'Audit', 'On')]
    [string]$TextureWriteWatch = 'On',
    [switch]$PerformanceCapture,
    [switch]$LightweightFps,
    [switch]$PresentWorkTrace,
    [switch]$FrameDeliveryTrace,
    # Diagnostic only: include existing shader compile/PSO phase counters.
    # Implies FrameDeliveryTrace; does not enable CPU sampling or GPU profiling.
    [switch]$ShaderPhaseTrace,
    # Diagnostic only: coarse draw preparation timing on the normal FIFO path.
    # Includes FrameDeliveryTrace; never enables the sampler or GCM2D profiler.
    [switch]$DrawCostTrace,
    # Diagnostic only: existing command-group timing plus low-rate CPU samples.
    # Its FPS includes profiler overhead and is not a performance comparison.
    [switch]$FifoDispatchTrace,
    # Diagnostic only: reuse CPU prefix and transfer-phase timers on the normal
    # scheduling path. No frame sampler, GPU timing or backend TJ_GCM2D_PERF mode.
    [switch]$TransferPhaseTrace,
    # Diagnostic only: guest HLE, SPURS dispatch/job-phase and job-chain timers.
    # Its FPS includes timer overhead and is not a performance comparison.
    [switch]$GuestPerf,
    [switch]$TextureChurnTrace,
    [switch]$TextureSnapshotRetention,
    [switch]$TextureSnapshotHintRetarget,
    [switch]$VertexProgramHashReuse,
    # Candidate only: skip CPU fetch/convert of VP attribute slots the VS never reads.
    [switch]$VpAttrUsedMask,
    [switch]$BlitSnapshotPool,
    [switch]$GpuQueueHighPriority,
    [switch]$GpuCompletionReuse,
    [switch]$PendingFlipPacing,
    [switch]$FifoKickWait,
    # Diagnostic only: skip per-frame Edge MLAA (no anti-aliasing).
    [switch]$DisableMlaa,
    # Candidate only: LOCAL inline-image stores skip the texture-label flush.
    [switch]$Non3dLabelPass,
    # Candidate only: treat NV3089 clip==out as an absolute destination clip.
    [switch]$BlitClipAbsolute,
    # Candidate only: keep default launches synchronous until transition and
    # longer gameplay checks pass. The renderer retains its own safety guards.
    [switch]$TextureLabelBatch,
    [switch]$PrefixOwnership,
    [switch]$PrefixOverlap,
    [switch]$PrefixReplayPrepare,
    [switch]$PrefixQueuedPair,
    [switch]$PrefixQueueAhead,
    [switch]$TextureReleaseNowait,
    # Candidate only: texture-label batch cap (8..32; 0 = unset = renderer default 8).
    [int]$TextureLabelCap = 0,
    # User-tested fast preset (2026-10-11): guest MLAA skipped + host FXAA,
    # texture-label cap 32, and the accepted prefix/label chain. Lightweight FPS log.
    [switch]$Recommended,
    # Candidate: vertex conversion threads for large draws (0 = off, 2..16).
    [int]$VertexParallel = 0,
    # Candidate: publish snapshot-only 0x1D74 texture labels at record time.
    [switch]$TextureLabelEarly,
    # Candidate: exact last-hit/hint lookups (texture slots, FP PSO, samplers, owner objects).
    [switch]$LookupFastpath,
    # Candidate: first-sight VS/PS compiles on worker threads (submitted at draw
    # record, waited for at replay). Same shaders/PSOs; off by default.
    [switch]$ShaderPrefetch,
    [string]$SaveRoot,
    # Folder holding the extracted title (contains USRDIR\, PARAM.SFO). Required with -Run.
    [string]$GameData
)

$ErrorActionPreference = 'Stop'
if ($Recommended) {
    $DisableMlaa = $true
    if ($TextureLabelCap -eq 0) { $TextureLabelCap = 32 }
    $LightweightFps = $true
    $TextureSnapshotRetention = $true; $TextureSnapshotHintRetarget = $true
    $VertexProgramHashReuse = $true; $BlitSnapshotPool = $true
    $GpuCompletionReuse = $true; $FifoKickWait = $true; $TextureLabelBatch = $true
    $PrefixOwnership = $true; $PrefixOverlap = $true; $PrefixReplayPrepare = $true
    $PrefixQueuedPair = $true; $PrefixQueueAhead = $true
    # Hidden same-spot A/B 2026-10-11: label pass cut waits ~42%; map clip fix user-confirmed.
    # VpAttrUsedMask left out: 2026-10-12 DrawCostTrace A/B showed vertex convert +37%/input.
    # Non3dLabelPass left out: 2026-10-12 repeated DrawCostTrace A/B, total work 16.6-17.0 -> 20.2 ms/frame (waits move into upload drains).
    $BlitClipAbsolute = $true
    # 2026-10-13 user long run: ~30 FPS busy areas, no HUD loss/freeze (384 tex slots, 4096 VS cache).
    $TextureLabelEarly = $true; $LookupFastpath = $true
    if ($VertexParallel -eq 0) { $VertexParallel = 8 }
    # 2026-10-13 hidden cold-cache A/B: worst first-sight frame 678 -> 161 ms, identical cache output.
    $ShaderPrefetch = $true
}
if ($DrawCostTrace -and ($PerformanceCapture -or $FifoDispatchTrace)) {
    throw '-DrawCostTrace requires -PerformanceCapture OFF.'
}
$PerformanceCapture = [bool]($PerformanceCapture -or $FifoDispatchTrace)
$FrameDeliveryTrace = [bool]($FrameDeliveryTrace -or $DrawCostTrace -or $FifoDispatchTrace -or $TransferPhaseTrace -or $ShaderPhaseTrace)
if ($TransferPhaseTrace -and $TextureReleaseNowait) {
    throw '-TransferPhaseTrace requires -TextureReleaseNowait OFF to preserve completion behavior.'
}
if ($PrefixOverlap -and -not $PrefixOwnership) {
    throw '-PrefixOverlap requires -PrefixOwnership.'
}
if ($PrefixReplayPrepare -and -not $PrefixOverlap) {
    throw '-PrefixReplayPrepare requires -PrefixOverlap and -PrefixOwnership.'
}
if ($PrefixQueuedPair -and -not $PrefixReplayPrepare) {
    throw '-PrefixQueuedPair requires -PrefixReplayPrepare, -PrefixOverlap and -PrefixOwnership.'
}
if ($PrefixQueueAhead -and -not $PrefixQueuedPair) {
    throw '-PrefixQueueAhead requires -PrefixQueuedPair, -PrefixReplayPrepare, -PrefixOverlap and -PrefixOwnership.'
}
if ($TextureReleaseNowait -and ($PrefixOwnership -or $PrefixOverlap -or $TextureLabelBatch)) {
    throw '-TextureReleaseNowait requires ownership, overlap and batching OFF.'
}
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$executable = Join-Path $repoRoot 'build-clang\tokyojungle.exe'
$workingDirectory = $repoRoot
if ([string]::IsNullOrWhiteSpace($GameData)) { throw 'Pass -GameData <folder with the extracted game (USRDIR, PARAM.SFO)>.' }
$vfsRoot = $GameData
if ([string]::IsNullOrWhiteSpace($SaveRoot)) {
    $SaveRoot = Join-Path $repoRoot 'savedata'
    [void](New-Item -ItemType Directory -Force -Path $SaveRoot)
}
foreach ($path in @($executable, (Join-Path $workingDirectory 'input\EBOOT.ELF'),
                     (Join-Path $workingDirectory 'input\PARAM.SFO'), $vfsRoot, $SaveRoot)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required launch path missing: $path" }
}
if (-not (Test-Path -LiteralPath $SaveRoot -PathType Container)) {
    throw "SaveRoot must be an existing directory: $SaveRoot"
}
$SaveRoot = (Resolve-Path -LiteralPath $SaveRoot).ProviderPath

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $executable
$info.WorkingDirectory = $workingDirectory
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true

# Child-only settings. Do not alter the user's environment, assets or saves.
$removedSettings = @(
    'TJ_FENCE_SHORT_POLL', 'TJ_FENCE_VBLANK_SERVICE',
    'TJ_BACKGROUND_TEST_WINDOW', 'TJ_NO_PRESENT', 'AUDIO_SILENT_OUTPUT',
    'PS3_PAD_DISABLE_XINPUT', 'PS3_PAD_DISABLE_KEYBOARD', 'PS3_PAD_DEBUG_CHANNEL',
    'PS3_PAD_ONESHOT_MS', 'PS3_PAD_ONESHOT_BTN', 'PS3_PAD_ONESHOT_HOLD_MS',
    'YDKJ_INJECT_PAD', 'YDKJ_PAD_BTN', 'YDKJ_PAD_DELAY', 'LBP_AUTOPRESS',
    'TJ_TITLE_GATE', 'TJ_TITLE_SAVE_PROBE', 'TJ_SCENE_READY', 'TJ_PERF_TRACE', 'TJ_FP_BLOB_TRACE', 'TJ_FPS_TRACE', 'TJ_TEXTURE_WRITE_WATCH', 'TJ_FIFO_PERF', 'TJ_GCM2D_PERF', 'TJ_FIFO_KICK_WAIT', 'TJ_DISABLE_MLAA', 'TJ_HOST_AA', 'TJ_NON3D_LABEL_PASS', 'TJ_BLIT_CLIP_ABSOLUTE', 'TJ_VERTEX_PARALLEL', 'TJ_TEXTURE_LABEL_EARLY', 'TJ_LOOKUP_FASTPATH',
    'TJ_TEXTURE_LABEL_BATCH', 'TJ_TEXTURE_LABEL_CAP', 'TJ_TEXTURE_COPY_LABEL_BATCH', 'TJ_PREFIX_OWNERSHIP', 'TJ_PREFIX_OVERLAP', 'TJ_TEXTURE_RELEASE_NOWAIT', 'TJ_TEXTURE_CHURN_TRACE', 'TJ_TEXTURE_SNAPSHOT_RETAIN', 'TJ_TEXTURE_SNAPSHOT_HINT_RETARGET', 'TJ_VP_UCODE_HASH_REUSE', 'TJ_VP_ATTR_USED_MASK', 'TJ_BLIT_SNAPSHOT_POOL', 'TJ_GPU_QUEUE_HIGH_PRIORITY', 'TJ_PENDING_FLIP_PACING', 'TJ_TEXTURE_CACHE_FILL_EMPTY', 'TJ_PREFIX_COST', 'TJ_PREFIX_COST_NOWAIT', 'TJ_PREFIX_GPU_COST', 'TJ_MAIN_OVERWRITE', 'TJ_MAIN_DIRECT_READBACK', 'TJ_MAIN_MAPPED_COMMIT',
    'TJ_FRAME_PROF', 'TJ_FRAME_PROF_MAIN_ONLY', 'TJ_FRAME_PROF_EARLY',
    'TJ_FRAME_PROF_MS', 'TJ_FRAME_PROF_FRAMES',
    'TJ_INDEXED_DIAG', 'TJ_INDEXED_CAPTURE_DIR', 'TJ_COMPOSE_CAPTURE_DIR',
    'TJ_SHADER_CACHE', 'TJ_SHADER_CACHE_DIR', 'TJ_SHADER_PREFETCH',
    'TJ_HLE_PERF', 'TJ_SPURS_DISPATCH_PERF', 'TJ_SPURS_JOB_PHASE_PERF', 'TJ_JOBCHAIN_PERF',
    'RSX_CAP', 'RSX_CAP_DIR', 'RSX_CAP_HOTKEY', 'CELLMARK_DUMP', 'CELLMARK_DUMP_DIR'
)
foreach ($name in $removedSettings) { $info.EnvironmentVariables.Remove($name) }
$info.EnvironmentVariables.Remove('TJ_GPU_COMPLETION_REUSE')
$info.EnvironmentVariables.Remove('TJ_PRESENT_WORK_TRACE')
$info.EnvironmentVariables.Remove('TJ_PRESENT_LOOP_TRACE')
$info.EnvironmentVariables.Remove('TJ_FLIP_TIMELINE')
$info.EnvironmentVariables.Remove('TJ_FLIP_PERF')
$info.EnvironmentVariables.Remove('TJ_DRAW_COST_TRACE')
$info.EnvironmentVariables.Remove('TJ_VERBOSE_STATS')
$info.EnvironmentVariables.Remove('TJ_CONTROLS_FILE')
# Per-second diagnostic lines (label-early, non-3D flush, GPU reuse, loader waits) only for traced runs.
if ($FrameDeliveryTrace -or $GuestPerf -or $PresentWorkTrace -or $ShaderPhaseTrace -or $FifoDispatchTrace -or $TransferPhaseTrace -or $DrawCostTrace) {
    $info.EnvironmentVariables['TJ_VERBOSE_STATS'] = '1'
}
if ($DrawCostTrace) {
    $info.EnvironmentVariables['TJ_DRAW_COST_TRACE'] = '1'
}
if ($ShaderPhaseTrace) {
    $info.EnvironmentVariables['TJ_PERF_TRACE'] = '1'
}
if ($PresentWorkTrace -or $FrameDeliveryTrace) {
    $info.EnvironmentVariables['TJ_PRESENT_WORK_TRACE'] = '1'
}
if ($FrameDeliveryTrace) {
    $info.EnvironmentVariables['TJ_PRESENT_LOOP_TRACE'] = '1'
    $info.EnvironmentVariables['TJ_FLIP_TIMELINE'] = '1'
}
if ($FifoDispatchTrace -or $TransferPhaseTrace) {
    $info.EnvironmentVariables['TJ_FIFO_PERF'] = '1'
}
if ($TransferPhaseTrace) {
    $info.EnvironmentVariables['TJ_PREFIX_COST'] = '1'
}
if ($GuestPerf) {
    $info.EnvironmentVariables['TJ_HLE_PERF'] = '1'
    $info.EnvironmentVariables['TJ_SPURS_DISPATCH_PERF'] = '1'
    $info.EnvironmentVariables['TJ_SPURS_JOB_PHASE_PERF'] = '1'
    $info.EnvironmentVariables['TJ_JOBCHAIN_PERF'] = '1'
}
if ($GpuCompletionReuse) {
    $info.EnvironmentVariables['TJ_GPU_COMPLETION_REUSE'] = '1'
}
$info.EnvironmentVariables['PS3_VFS_ROOT'] = $vfsRoot
$info.EnvironmentVariables['PS3_HDD_GAME_ROOT'] = $vfsRoot
$info.EnvironmentVariables['PS3_VFS_READONLY'] = '1'
$info.EnvironmentVariables['PS3_TITLE'] = 'Tokyo Jungle'
$info.EnvironmentVariables['PS3_SAVEDATA_ROOT'] = $SaveRoot
$info.EnvironmentVariables['TJ_GCM_INTERRUPT_WORKER'] = '1'
# Persistent runtime shader bytecode cache shared by every run; the backend
# creates the folder on first use. TJ_SHADER_CACHE stays unset (default on).
$info.EnvironmentVariables['TJ_SHADER_CACHE_DIR'] = Join-Path $repoRoot 'shader-cache'
# Key/controller bindings (change in game with F1, or with scripts/controls_editor.ps1).
$info.EnvironmentVariables['TJ_CONTROLS_FILE'] = Join-Path $repoRoot 'controls.ini'
if ($TextureLabelBatch) {
    $info.EnvironmentVariables['TJ_TEXTURE_LABEL_BATCH'] = '1'
}
if ($TextureLabelCap -gt 0) {
    $info.EnvironmentVariables['TJ_TEXTURE_LABEL_CAP'] = [string]$TextureLabelCap
}
if ($PrefixOwnership) {
    $info.EnvironmentVariables['TJ_PREFIX_OWNERSHIP'] = '1'
}
if ($PrefixOverlap) {
    $info.EnvironmentVariables['TJ_PREFIX_OVERLAP'] = '1'
}
$info.EnvironmentVariables.Remove('TJ_PREFIX_REPLAY_PREPARE')
$info.EnvironmentVariables.Remove('TJ_PREFIX_QUEUED_PAIR')
$info.EnvironmentVariables.Remove('TJ_PREFIX_QUEUE_AHEAD')
if ($PrefixQueueAhead) {
    $info.EnvironmentVariables['TJ_PREFIX_QUEUE_AHEAD'] = '1'
}
if ($PrefixQueuedPair) {
    $info.EnvironmentVariables['TJ_PREFIX_QUEUED_PAIR'] = '1'
}
if ($PrefixReplayPrepare) {
    $info.EnvironmentVariables['TJ_PREFIX_REPLAY_PREPARE'] = '1'
}
if ($PendingFlipPacing) {
    $info.EnvironmentVariables['TJ_PENDING_FLIP_PACING'] = '1'
}

$info.EnvironmentVariables['TJ_TEXTURE_WRITE_WATCH'] = $(if ($TextureWriteWatch -eq 'Audit') { '2' }
    elseif ($TextureWriteWatch -eq 'On') { '1' } else { '0' })
if ($TextureReleaseNowait) {
    $info.EnvironmentVariables['TJ_TEXTURE_RELEASE_NOWAIT'] = '1'
}
if ($TextureChurnTrace) {
    $info.EnvironmentVariables['TJ_TEXTURE_CHURN_TRACE'] = '1'
}
if ($TextureSnapshotRetention) {
    $info.EnvironmentVariables['TJ_TEXTURE_SNAPSHOT_RETAIN'] = '1'
}
if ($TextureSnapshotHintRetarget) {
    $info.EnvironmentVariables['TJ_TEXTURE_SNAPSHOT_HINT_RETARGET'] = '1'
}
if ($VertexProgramHashReuse) {
    $info.EnvironmentVariables['TJ_VP_UCODE_HASH_REUSE'] = '1'
}
if ($VpAttrUsedMask) {
    $info.EnvironmentVariables['TJ_VP_ATTR_USED_MASK'] = '1'
}
if ($BlitSnapshotPool) {
    $info.EnvironmentVariables['TJ_BLIT_SNAPSHOT_POOL'] = '1'
}
if ($GpuQueueHighPriority) {
    $info.EnvironmentVariables['TJ_GPU_QUEUE_HIGH_PRIORITY'] = '1'
}
if ($FifoKickWait) {
    $info.EnvironmentVariables['TJ_FIFO_KICK_WAIT'] = '1'
}
if ($LookupFastpath) {
    $info.EnvironmentVariables['TJ_LOOKUP_FASTPATH'] = '1'
}
if ($ShaderPrefetch) {
    $info.EnvironmentVariables['TJ_SHADER_PREFETCH'] = '1'
}
if ($TextureLabelEarly) {
    $info.EnvironmentVariables['TJ_TEXTURE_LABEL_EARLY'] = '3'
}
if ($VertexParallel -gt 1) {
    $info.EnvironmentVariables['TJ_VERTEX_PARALLEL'] = [string]$VertexParallel
}
if ($BlitClipAbsolute) {
    $info.EnvironmentVariables['TJ_BLIT_CLIP_ABSOLUTE'] = '1'
}
if ($Non3dLabelPass) {
    $info.EnvironmentVariables['TJ_NON3D_LABEL_PASS'] = '1'
}
if ($DisableMlaa) {
    $info.EnvironmentVariables['TJ_DISABLE_MLAA'] = '1'
}
if ($LightweightFps -or $PerformanceCapture -or $PresentWorkTrace -or $FrameDeliveryTrace) {
    $info.EnvironmentVariables['TJ_FPS_TRACE'] = '1'
}
if ($PerformanceCapture) {
    # Reuse the existing sampler across the whole manual run, including later
    # areas. No automated input or detailed per-draw renderer tracing.
    $info.EnvironmentVariables['TJ_FRAME_PROF'] = '1'
    $info.EnvironmentVariables['TJ_FRAME_PROF_EARLY'] = '1'
    $info.EnvironmentVariables['TJ_FRAME_PROF_MS'] = '32'
    $info.EnvironmentVariables['TJ_FRAME_PROF_FRAMES'] = '120'
}

$record = [ordered]@{
    Executable = $executable
    ExecutableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash
    WorkingDirectory = $workingDirectory
    VfsRoot = $vfsRoot
    SaveRoot = $SaveRoot
    ShaderCacheDir = $info.EnvironmentVariables['TJ_SHADER_CACHE_DIR']
    MaxSeconds = $MaxSeconds
    AutoCloseEnabled = $MaxSeconds -gt 0
    TextureWriteWatch = $TextureWriteWatch
    PerformanceCapture = [bool]$PerformanceCapture
    LightweightFps = [bool]$LightweightFps
    PresentWorkTrace = [bool]($PresentWorkTrace -or $FrameDeliveryTrace)
    FrameDeliveryTrace = [bool]$FrameDeliveryTrace
    ShaderPhaseTrace = [bool]$ShaderPhaseTrace
    ShaderPhaseTraceEnabled = $info.EnvironmentVariables.ContainsKey('TJ_PERF_TRACE')
    FpBlobTraceEnabled = $info.EnvironmentVariables.ContainsKey('TJ_FP_BLOB_TRACE')
    DrawCostTrace = [bool]$DrawCostTrace
    DrawCostTraceEnabled = $info.EnvironmentVariables.ContainsKey('TJ_DRAW_COST_TRACE')
    FifoDispatchTrace = [bool]$FifoDispatchTrace
    TransferPhaseTrace = [bool]$TransferPhaseTrace
    GuestPerf = [bool]$GuestPerf
    PrefixCostEnabled = $info.EnvironmentVariables.ContainsKey('TJ_PREFIX_COST')
    Gcm2dPerfEnabled = $info.EnvironmentVariables.ContainsKey('TJ_GCM2D_PERF')
    PrefixGpuCostEnabled = $info.EnvironmentVariables.ContainsKey('TJ_PREFIX_GPU_COST')
    MainDirectReadbackEnabled = $info.EnvironmentVariables.ContainsKey('TJ_MAIN_DIRECT_READBACK')
    PresentLoopTraceEnabled = $info.EnvironmentVariables.ContainsKey('TJ_PRESENT_LOOP_TRACE')
    FlipTimelineEnabled = $info.EnvironmentVariables.ContainsKey('TJ_FLIP_TIMELINE')
    FlipPerfEnabled = $info.EnvironmentVariables.ContainsKey('TJ_FLIP_PERF')
    FifoPerfEnabled = $info.EnvironmentVariables.ContainsKey('TJ_FIFO_PERF')
    TextureChurnTrace = [bool]$TextureChurnTrace
    TextureSnapshotRetention = [bool]$TextureSnapshotRetention
    TextureSnapshotHintRetarget = [bool]$TextureSnapshotHintRetarget
    VertexProgramHashReuse = [bool]$VertexProgramHashReuse
    VpAttrUsedMask = $info.EnvironmentVariables.ContainsKey('TJ_VP_ATTR_USED_MASK')
    BlitSnapshotPool = [bool]$BlitSnapshotPool
    GpuQueueHighPriority = [bool]$GpuQueueHighPriority
    GpuCompletionReuse = [bool]$GpuCompletionReuse
    FifoKickWait = $info.EnvironmentVariables.ContainsKey('TJ_FIFO_KICK_WAIT')
    BlitClipAbsolute = $info.EnvironmentVariables.ContainsKey('TJ_BLIT_CLIP_ABSOLUTE')
    Non3dLabelPass = $info.EnvironmentVariables.ContainsKey('TJ_NON3D_LABEL_PASS')
    DisableMlaa = $info.EnvironmentVariables.ContainsKey('TJ_DISABLE_MLAA')
    HostAa = $info.EnvironmentVariables.ContainsKey('TJ_DISABLE_MLAA') # backend FXAA follows MLAA skip
    TextureLabelBatch = $info.EnvironmentVariables.ContainsKey('TJ_TEXTURE_LABEL_BATCH')
    TextureLabelCap = $TextureLabelCap
    Recommended = [bool]$Recommended
    VertexParallel = $VertexParallel
    LookupFastpath = $info.EnvironmentVariables.ContainsKey('TJ_LOOKUP_FASTPATH')
    ShaderPrefetch = $info.EnvironmentVariables.ContainsKey('TJ_SHADER_PREFETCH')
    TextureLabelEarly = $info.EnvironmentVariables.ContainsKey('TJ_TEXTURE_LABEL_EARLY')
    TextureCopyLabelBatch =$info.EnvironmentVariables.ContainsKey('TJ_TEXTURE_COPY_LABEL_BATCH')
    PrefixOwnership = $info.EnvironmentVariables.ContainsKey('TJ_PREFIX_OWNERSHIP')
    PrefixOverlap = $info.EnvironmentVariables.ContainsKey('TJ_PREFIX_OVERLAP')
    PrefixReplayPrepare = $info.EnvironmentVariables.ContainsKey('TJ_PREFIX_REPLAY_PREPARE')
    PrefixQueuedPair = $info.EnvironmentVariables.ContainsKey('TJ_PREFIX_QUEUED_PAIR')
    PrefixQueueAhead = $info.EnvironmentVariables.ContainsKey('TJ_PREFIX_QUEUE_AHEAD')
    PendingFlipPacing = $info.EnvironmentVariables.ContainsKey('TJ_PENDING_FLIP_PACING')
    TextureReleaseNowait = $info.EnvironmentVariables.ContainsKey('TJ_TEXTURE_RELEASE_NOWAIT')
    FpsTraceEnabled = [bool]($LightweightFps -or $PerformanceCapture -or $PresentWorkTrace -or $FrameDeliveryTrace)
    FrameProfileSampleMs = $(if ($PerformanceCapture) { 32 } else { 0 })
    Visible = -not $info.EnvironmentVariables.ContainsKey('TJ_BACKGROUND_TEST_WINDOW')
    KeyboardEnabled = -not $info.EnvironmentVariables.ContainsKey('PS3_PAD_DISABLE_KEYBOARD')
    ControllerEnabled = -not $info.EnvironmentVariables.ContainsKey('PS3_PAD_DISABLE_XINPUT')
    AudioMuted = $info.EnvironmentVariables.ContainsKey('AUDIO_SILENT_OUTPUT')
    AutomatedInput = @($removedSettings | Where-Object {
        $_ -match 'ONESHOT|INJECT_PAD|AUTOPRESS|DEBUG_CHANNEL' -and
        $info.EnvironmentVariables.ContainsKey($_)
    }).Count -ne 0
    LaunchAuthorized = [bool]$Run
    ProcessId = $null
    StartedUtc = $null
    EndedUtc = $null
    StopReason = $null
    ExitCode = $null
    LogDrainCompleted = $false
}
if (-not $Run) { [pscustomobject]$record; return }
if (Get-Process -Name tokyojungle -ErrorAction SilentlyContinue) {
    throw 'Tokyo Jungle is already running. No second instance launched and no process stopped.'
}

# Keep the 10 newest play logs; older ones go to the Recycle Bin (never deleted outright).
try {
    Add-Type -AssemblyName Microsoft.VisualBasic
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'run-logs')) { Get-ChildItem (Join-Path $repoRoot 'run-logs') -Directory -Filter 'visible-user-test-*' |
        Sort-Object Name -Descending | Select-Object -Skip 10 | ForEach-Object {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($_.FullName,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        } }
} catch {
    Write-Output ('Old log tidy skipped: ' + $_.Exception.Message)
}

$runDirectory = Join-Path $repoRoot ('run-logs\visible-user-test-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $PID)
[void](New-Item -ItemType Directory -Path $runDirectory)
$summaryPath = Join-Path $runDirectory 'summary.json'
$process = New-Object Diagnostics.Process
$process.StartInfo = $info
$stdout = $stderr = $null
$started = $false
$timer = [Diagnostics.Stopwatch]::new()
try {
    $stdout = [IO.File]::Open((Join-Path $runDirectory 'tokyojungle.stdout.log'),
        [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stderr = [IO.File]::Open((Join-Path $runDirectory 'tokyojungle.stderr.log'),
        [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    if (-not $process.Start()) { throw 'Tokyo Jungle process creation failed.' }
    $started = $true
    $timer.Start()
    $record.ProcessId = $process.Id
    $record.StartedUtc = [DateTime]::UtcNow.ToString('o')
    $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    [IO.File]::WriteAllText($summaryPath, ($record | ConvertTo-Json))
    $limitDescription = if ($MaxSeconds -gt 0) { "$MaxSeconds seconds" } else { 'none (user-controlled)' }
    Write-Output "Started visible Tokyo Jungle PID=$($process.Id); logs=$runDirectory; limit=$limitDescription"
    Write-Output 'Controls: Space/Z = Cross, Enter = Start, arrows = D-pad, WASD = left stick, numpad 4/6/8/2 = right stick.'
    Write-Output 'Click the game window to enable keyboard input. Close its window when finished.'
    # Best effort: bring the new game window to the front so keyboard input works at once.
    try {
        if (-not ('TjLaunch.Win' -as [type])) {
            Add-Type -Namespace TjLaunch -Name Win -ErrorAction Stop -MemberDefinition `
                '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);'
        }
        for ($i = 0; $i -lt 80 -and -not $process.HasExited; $i++) {
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                [void][TjLaunch.Win]::SetForegroundWindow($process.MainWindowHandle)
                break
            }
            Start-Sleep -Milliseconds 250
        }
    } catch {}
    while (-not $process.WaitForExit(250)) {
        if ($MaxSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $MaxSeconds) {
            $record.StopReason = 'hands-on test deadline'
            Write-Output 'Test deadline reached; requesting a normal window close, with 30 seconds to exit.'
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit() }
            break
        }
    }
    $record.ExitCode = $process.ExitCode
    if (-not $record.StopReason) { $record.StopReason = 'game process exited' }
    $record.LogDrainCompleted = [Threading.Tasks.Task]::WaitAll(
        [Threading.Tasks.Task[]]@($outTask, $errTask), 10000)
} catch {
    $record.StopReason = 'launcher error: ' + $_.Exception.Message
    throw
} finally {
    if ($started -and -not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit() }
    }
    if ($stdout) { $stdout.Dispose() }
    if ($stderr) { $stderr.Dispose() }
    $record.EndedUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($summaryPath, ($record | ConvertTo-Json))
    $process.Dispose()
}
Write-Output "Test ended: $($record.StopReason); exit=$($record.ExitCode); logs=$runDirectory"
if ($record.ExitCode) { exit $record.ExitCode }
