# Data loader and analyzer for JLab

### Keeps updating by Xuefei Yu, from Mar 6th, 2026

MATLAB-based data analysis toolkit for both cage trainer and data recorded using BlackRock hardware.

## Prerequisites

### 1. MATLAB Path (handled automatically)

`BlackRockFileLoader.m` sets up its own path on startup, in two steps:

1. **JLab code** — adds the repo root (for the top-level scripts) and the
   `ToolsAndFunctions` tree (the `BlackrockLoader` class + analyze tools). The
   repo root is _not_ added recursively, so dot-folders at the root (`.git`,
   `.claude`, …) are never placed on the MATLAB path.
2. **NPMK** — if `openNEV` is already found (e.g. NPMK lives under
   `ToolsAndFunctions/NPMK`), nothing more happens. Otherwise the script prompts
   you to select your NPMK folder and adds it; cancelling aborts with an
   install hint.

So no manual `addpath` is needed on a fresh clone, wherever you put the repo.

If you prefer to set the path yourself (or run the other scripts directly), you
can still add the folder manually in MATLAB:
**Home → Set Path → Add with Subfolders** → select the JLab folder → Save.

### 2. Install BlackRock NPMK Toolkit

This repository requires the **BlackRock Neurotech NPMK (Neural Processing MATLAB Kit)** toolkit to load `.ns2`, `.nev`, and other BlackRock file formats.

Download it from the official GitHub repository:
👉 https://github.com/BlackrockNeurotech/NPMK

**Installation steps:**

1. Download or clone the NPMK repository.
2. Move the downloaded NPMK folder into this repo's **`ToolsAndFunctions`** folder, so
   it lives at `JLab/ToolsAndFunctions/NPMK`. The loader's auto-path step (above)
   then picks it up automatically — no manual `addpath` is needed.

If you would rather keep NPMK somewhere else, add it to the path yourself instead:

```matlab
addpath(genpath('/path/to/NPMK'))
savepath
```

> ⚠️ Without NPMK, BlackRock data files cannot be loaded and the scripts will not run.
> NPMK is third-party and **gitignored** — it is not shipped with this repo. The
> loader depends on its `openNEV`, `openNSx`, and `ts2sec` functions.

## File Structure

```
JLab/
├── BlackRockFileLoader.m         # driver: sets config, runs the batch loop, exports CSV/txt
├── BlackRockFileAnalyzer.m      # reads trials CSV, fits/plots the psychometric curve
├── CageTrainingDataLoading.m    # concatenates cage-trainer .json trials into one CSV
├── CageTrainingDataAnalyzer.m   # reads that CSV, plots the psychometric curve
└── ToolsAndFunctions/
    ├── LoadingTools/
    │   └── BlackrockLoader.m         # class: schema-checked load + comment parsing
    ├── AnalyzeTools/
    │   └── VisPsychometricFunction.m # shared logistic-regression psychometric fit
    └── NPMK/                         # BlackRock NPMK toolkit (third-party, gitignored)
```

## Usage

1. Complete all steps in **Prerequisites**
2. Open MATLAB and navigate to the JLab folder
3. Run the loader, then the analyzer:
   - first the loader: `BlackRockFileLoader` to parse the raw data into CSV/txt
   - then the analyzer: `BlackRockFileAnalyzer` for the psychometric curve

`BlackRockFileLoader.m` is a thin **driver script**: it sets the run config,
constructs a `BlackrockLoader`, and loops over date folders calling
`loader.processFolder(...)`. All loading, parsing, preparation, and file writing
live in the class (`ToolsAndFunctions/LoadingTools/BlackrockLoader.m`).

## How the BlackRock loader works

Loading, parsing, and exporting are handled by the **`BlackrockLoader`** class.
It is a stateful (handle) config-property class: its config properties hold the
file schema, the load flags, the parsing schema (templates + event maps), and
the segmentation buffers (`Segment_PreBuffer` / `Segment_PostBuffer` /
`Segment_BinWidth`). Construct it once with name/value overrides, then drive it
in whichever of the three ways below fits the task:

```matlab
loader = BlackrockLoader('LoadEyeData', true, ...        % override any property
                         'LoadOnlineSpikeData', true, ...
                         'LoadOnlineSpikeWaveform', false);  % opt-in spike waveforms (default off)
```

### Three ways to use the loader

**1. Run everything (normal use).** One call does the whole pipeline for a date
folder and writes the output files:

```matlab
loader.processFolder(DataFolder, OutputPath, 'Blackrock_2026-06-24');
```

**2. Step by step (staged pipeline, for debugging).** `processFolder` just runs
these six methods in order; call them yourself to inspect the loader property
each one fills before moving on:

```matlab
loader.load(DataFolder);   % -> loader.Loaded  (resolves + loads files, resets prior state)
loader.parseEvents();      % -> loader.Trials, loader.Experiment  (comments -> records)
loader.parseEye();      % -> loader.Eye  (per-trial eye slices)
loader.parseSpikes();      % -> loader.Spike, loader.SpikeWaveformData  (per-trial rasters)
loader.prepareExport();    % -> loader.Export  (trials table + expmeta lines)
loader.export(OutputPath, 'Blackrock_2026-06-24');   % writes the .txt/.csv/.mat files
```

State is cleared at the start of every `load()`, so a single loader can be
reused across a batch of folders without leaking data between them. `load()`
delegates the actual file reading to the orchestrator `loadSession(DataFolder)`
(returns the `S` struct), which throws only when comments are missing and wraps
continuous-stream and spike loading in the load-flag gating and soft-failure handling.

**3. Load one data product on its own.** When you only want to look at the
comments, one continuous stream, or the spikes — not run the whole session — call
the matching **pure** loader. Each opens only the file(s) it needs, returns just
its own product, and touches no loader state:

```matlab
C = loader.loadComments(DataFolder);   % -> .Events, .EventTime, .comments_source (required)
A = loader.loadContinuous(DataFolder);     % -> .nsxdata (raw int16), .uv_per_digit, .nsx_samplingrate, .nsx_abs_time, .timeresolution, .status
R = loader.loadSpikes(DataFolder);     % -> .online_spike, .spike_status
```

These are independent: `loadSpikes` does not need `loadContinuous` to have run
(it reads its own time resolution from the NEV's clock), and either can be
called without touching comments. `parseEvents(Events, EventTime)` is likewise
available for ad-hoc parsing of a comment set you pass in directly.

#### Loading a different continuous file (`.ns6`, other prefixes)

`loadContinuous` takes two optional arguments —
`loadContinuous(DataFolder, postFix, preFix)` — that override which file is
picked **for that call only**, leaving `EyeIdentifier` / `EyePrefix`
untouched, so a loader being reused across a batch is unaffected:

```matlab
A = loader.loadContinuous(f);                  % '*.ns2' (EyeIdentifier), any prefix
A = loader.loadContinuous(f, '.ns6');          % the .ns6, whatever its prefix
A = loader.loadContinuous(f, '.ns6', 'NSP');   % the .ns6, NSP only
A = loader.loadContinuous(f, [], 'Hub1');      % the .ns2, Hub1 only
LFP = loader.loadContinuous(f, '*.ns2', 'Hub');   % LFP: the .ns2, Hub only
PD  = loader.loadContinuous(f, '*.ns4', 'NSP');   % dedicated photodiode file
```

This is exactly how `LoadLFPData`/`LoadPhotodiodeData` are implemented
internally — `parseLFP`/`parsePhotodiode` call `loadContinuous` with the
`LFPPrefix`/`LFPIdentifier` and `PhotodiodePrefix`/`PhotodiodeIdentifier`
properties, then run the result through the same `segmentContinuous` as the eye
data.

- `postFix` — file extension. Accepts `'.ns6'`, `'ns6'` or `'*.ns6'`. Omitted or
  `[]` falls back to `EyeIdentifier` (`'*.ns2'`).
- `preFix` — filename prefix. Omitted or `[]` means **no prefix filter**: any
  file with that extension. This is what lets you reach a stream stored under a
  non-`NSP` prefix (e.g. a `Hub1-*.ns6`), which the schema table below otherwise
  pins to `NSP`.

Handy for pulling the 30 kHz broadband `.ns6` alongside the 1 kHz `.ns2` when
checking a signal. Two things to keep in mind:

- `.ns6` is ~30× the samples of a `.ns2` and `openNSx` forces double precision
  for the µV conversion, so a full session is a large array (~560 MB for ~10 min
  on 4 channels). Sampling rate is read from the file's own metadata, so
  downstream timing stays correct.
- With no prefix, several files may match, and `loadContinuous` then raises the
  selection dialog rather than guessing.

This applies to standalone calls only. `loadSession` always passes
`obj.EyePrefix`, so the pipeline stays pinned to the schema below.

### Checking the comments to debug parsing

When the task's comment-string format changes, parsed events can land in
`trials.undefined` instead of the expected fields. `parseEvents` always prints a
report, so watch the `undefined / duplicates / malformed` counts and the three
lists printed under them. Each list gives the *distinct* strings, how many times
each occurred (`x3`), and the trials it occurred in as `[S<session>T<trial>, ...]`,
capped at 8 trials plus a `+N more`:

```
parseEvents: 109432 comments -> 5012 trials, 1 session(s); 604 distinct event bodies
  undefined 12, duplicates 4, malformed 5
  undefined events (add a key for these, or they stay dropped):
    x12   Target 1 color [-0.8, -0.8, -0.8]              [S1T1, S1T2, ..., +4 more]
  duplicated events (first write kept):
    x4    Choicetime                                     [S1T2, S1T3, S1T5]
  malformed comments (neither "Experiment" nor "Trial N:", skipped; shown against the trial that was open):
    x5    <the raw comment text>                         [S1T7, S1T8]
```

The three mean different things: **undefined** matched no key (add one, or it
stays dropped); **duplicates** were written more than once in a trial (the first
write is kept, the rest listed); **malformed** is neither an `Experiment` line
nor a `Trial N:` line, so it has no trial of its own and is dropped outright --
it is listed against the trial that was open when it arrived. To see the raw
strings, load just the comments
(way 3 above) and pair each raw, **unparsed** comment with its timestamp using
the static helper `BlackrockLoader.commentsWithTime`, so you can eyeball exactly
what the recording contains:

```matlab
C = loader.loadComments(DataFolder);                          % just the comments
T = BlackrockLoader.commentsWithTime(C.Events, C.EventTime);  % N-row table
disp(T)   % columns: TimeStampSec, Comment  (in recording order)
```

Use this to spot a new or renamed comment prefix, then add the matching key in
`BlackrockLoader.defaultEventMaps()` (and, if it is a new field, in
`defaultTrialTemplate()` / `defaultExpTemplate()`).

### Input file schema (role-aware resolution)

A single recording is split across files **by filename prefix**, and each data
product is verified present before use:

| File        | Role                                                        |
| ----------- | ----------------------------------------------------------- |
| `HUB-*.nev` | experiment comments + comment timing, and online spike timing (+ per-spike waveforms) |
| `NSP-*.nev` | comments fallback only (see below)                          |
| `NSP-*.ns2` | eye data (+ photodiode, by default channels 4-6)            |
| `Hub-*.ns2` | LFP                                                         |
| `NSP-*.ns4` | photodiode (fallback/forced dedicated file)                 |

- **Comments are required**, and normally come from `HUB-*.nev` — the same file
  as the spikes, which is why one parsed `.nev` is shared between them. If that
  file carries no comments (or is absent), they **fall back to `NSP-*.nev`**: a
  short window in mid-2026 wrote comments there instead. If neither has them,
  that folder errors and is reported as `failed`. Note the fallback tests the
  *content*, not just the filename — most sessions ship a small `NSP-*.nev` stub
  that has headers but no comment packets.
- **Eye, LFP, spikes, and photodiode are all soft.** A missing or unreadable
  file is recorded in a status string and that product is skipped — the folder
  still succeeds.
- **Alignment is checked after the export.** A continuous stream is segmented by
  matching each trial's absolute Start/End against the stream's own clock, so a
  recording whose `.ns2` clock disagrees with the comment clock still exports —
  just with **zero samples**. `processFolder` therefore prints an *Export
  alignment check* block naming, per product, how many trials were actually
  segmented, and warns
  (`BlackrockLoader:export:StreamMisaligned` / `:StreamPartial`) when any were
  not. It does not abort: the trials table and the spikes come from a different
  file and are still good. Watch for it — an unsynced PTP clock otherwise shows
  up much later as an out-of-bounds index inside `AlignContinuous`. The prefixes (`NSP`/`HUB`/`Hub`), the `.ns2`/`.ns4`
  identifiers, and the `LoadEyeData` / `LoadLFPData` / `LoadPhotodiodeData` /
  `LoadOnlineSpikeData` / `LoadOnlineSpikeWaveform` / `IncludeUnsorted` flags
  are all constructor-overridable properties. `loadContinuous` additionally takes
  per-call prefix/extension overrides — see
  [Loading a different continuous file](#loading-a-different-continuous-file-ns6-other-prefixes).
- **LFP** (`LoadLFPData`) reuses `loadContinuous`/`segmentContinuous` unchanged, just
  pointed at `LFPPrefix-*.ns2` (`Hub-*.ns2` by default) instead of
  `EyePrefix-*.ns2` — same logic, different file.
- **Eye and photodiode share one file and one pass.** The eye
  `EyePrefix-*.ns2` carries both: `EyeChannels` (`[1 2 3]`) is the eye signal
  and `PhotodiodeChannels` (`[4 5 6]`) the photodiode. The stream is read once and
  segmented once, then the per-trial array is split by row into `eye` and
  `photodiode` — no extra file read, and no second segmentation pass. So
  `eye.data` holds only `EyeChannels`, not every channel in the file.
- **Photodiode fallback.** If the eye stream has fewer channels than
  `PhotodiodeChannels` requests, the loader falls back to auto-loading a
  dedicated `PhotodiodePrefix-*.ns4` file (`NSP-*.ns4` by default) and uses all
  of that file's channels, segmenting it separately. Set
  `PhotodiodeUseSeparateFile` true to skip the shared-file path entirely.
- **Online spikes** come from `HUB-*.nev` when `LoadOnlineSpikeData` is on:
  `loadSpikes` reads each spike's time (s) — converting timestamps with the
  NEV's own clock (`MetaTags.TimeRes`, so the times are self-contained rather
  than borrowed from the eye file) — plus electrode and unit. By default
  unit `0` (unsorted) and unit `255` (noise) spikes are **dropped** after load
  (with their channel/unit/waveform columns), so downstream segmentation only
  sees sorted units; set `IncludeUnsorted` (default off) true to keep them. The
  flag is source-agnostic — the same drop applies to a future offline spike
  source feeding the same pipeline.
- **Spike waveforms** are an **opt-in extra** (`LoadOnlineSpikeWaveform`,
  default off). They live in the same `HUB-*.nev`, so they only load when
  `LoadOnlineSpikeData` is also on; if waveforms are requested without spikes,
  `loadSession` warns and skips them. Waveforms stay **raw `int16`** in memory
  with a per-spike µV scale factor alongside (`WaveformScale`, mirroring
  openNEV's `'uv'` conversion); the scale is applied per trial slice during
  segmentation, so the exported waveforms are in µV while the largest array in
  the session never gets a full `double` copy. The naming distinguishes these
  _online_ (Central-sorted, recorded live) waveforms from offline-sorted
  waveforms added later.

`loadSession` returns a struct `S` with:

- comments: `Events`, `EventTime`, `comments_source`;
- spikes (`LoadOnlineSpikeData`): `S.online_spike`, a generic **source-agnostic
  container** (from `BlackrockLoader.spikeContainer()`) with `TimeSec`,
  `Channel`, `Unit`, `Waveform` (`[nSamp × nSpikes]` raw `int16`, or `[]`;
  populated only when `LoadOnlineSpikeWaveform` is on), `WaveformScale`
  (per-spike µV per digit), `WaveformUnit`, and `source` (`'online'`). All
  per-spike arrays are aligned 1:1. Plus `spike_status`;
- eye (`LoadEyeData`): `nsxdata`, `uv_per_digit`, `nsx_samplingrate`,
  `nsx_abs_time`, `eye_status`.
- LFP (`LoadLFPData`): `lfp_nsxdata`, `lfp_uv_per_digit`, `lfp_samplingrate`,
  `lfp_abs_time`, `lfp_status`. Loaded the same way as the eye stream, from
  `LFPPrefix-*.ns2` (`Hub-*.ns2` by default) instead of `EyePrefix-*.ns2`.
- photodiode (`LoadPhotodiodeData`): `photodiode_samplingrate`,
  `photodiode_abs_time`, `photodiode_status`, and `photodiode_from_eye`. In the
  default layout the photodiode rides in the eye stream, so
  `photodiode_from_eye` is true and `photodiode_nsxdata` stays empty — nothing
  is copied, and the split happens after segmentation. When a dedicated
  `PhotodiodePrefix-*.ns4` file is used instead (fallback, or
  `PhotodiodeUseSeparateFile`), `photodiode_nsxdata` / `photodiode_uv_per_digit`
  hold **all** of that file's channels.

**`nsxdata` is raw `int16`, not µV.** openNSx's `'uv'` option forces the whole
array to `double` (4× the file size in RAM), so the loader reads the samples as
stored and returns the per-channel scale factor `uv_per_digit` beside them;
`segmentContinuous` applies it to the trial slices it keeps. To convert a raw stream
yourself: `uV = double(nsxdata) .* uv_per_digit`.

**Raw streams are released once segmented.** `FreeRawAfterParse` (default on)
clears each raw continuous stream from `loader.Loaded` as soon as its per-trial
product exists, so the loader does not hold raw and segmented copies of every
stream simultaneously. Set it false when you want `loader.Loaded` fully
inspectable after a run.

### Output file schema (what the loader exports)

Each date folder is written into its own `export_data/<date>/` subfolder, with
filenames prefixed `Blackrock_<date>_`. Up to **seven** files are produced; the
`.mat` files are written only when the matching load flag is on:

| File                                          | When                      | Contents                                         |
| --------------------------------------------- | ------------------------- | ------------------------------------------------ |
| `Blackrock_<date>_expmeta_matlab.txt`         | always                    | experiment-level metadata, one block per session |
| `Blackrock_<date>_trials_matlab.csv`          | always                    | one row per trial (the parsed `trials` records)  |
| `Blackrock_<date>_eye_matlab.mat`             | `LoadEyeData`             | eye channels cut into per-trial slices           |
| `Blackrock_<date>_lfp_matlab.mat`             | `LoadLFPData`             | LFP stream cut into per-trial slices             |
| `Blackrock_<date>_photodiode_matlab.mat`      | `LoadPhotodiodeData`      | photodiode stream cut into per-trial slices      |
| `Blackrock_<date>_spikes_matlab.mat`          | `LoadOnlineSpikeData`     | online spikes rasterized per trial               |
| `Blackrock_<date>_spikes_waveform_matlab.mat` | `LoadOnlineSpikeWaveform` | per-spike waveforms (µV) per trial               |

**`*_expmeta_matlab.txt`** — plain text. A single `.nev` may hold several
experiment sessions, so the file has one `Session N:` header per session
followed by its `field: value` lines and a blank line. Numeric values are
written with `mat2str`, everything else as a string.

`start` / `end` are the session's own timestamps in seconds, `end_by` the reason
it ended. `pause_times` / `resume_times` are the `Experiment paused` /
`Experiment resumed` markers, in seconds, in file order — lists, since a session
can pause any number of times, and `[]` when it never did. They are **not
necessarily the same length**: a session paused and then ended without resuming
has one more pause than resume. Trial numbers and `Session` do not restart at a
pause, so this is the only record of the gap.

**`*_trials_matlab.csv`** — the `trials` struct flattened with `struct2table`,
one row per trial. Key column conventions:

- `index` — a 0-based sequential row counter prepended for pandas
  (`read_csv(index_col='index')`). This is **not** the trial number.
- `Trial_number` — the real, task-reported trial number, which **resets** across
  sessions; use `Session` + `Trial_number` together to identify a trial.
- `Session` — which experiment session within the recording the trial belongs to.
- 2-element vector fields (e.g. target positions) are split into `<field>_x` /
  `<field>_y` columns; the original combined column is dropped.
- The `undefined` and `duplicates` bookkeeping fields are dropped before export.
- Derived features from parsing are included (polar target theta/rho,
  `Stimulus_direction`, `Choose_target`, `Choose_leftright`).
- `Target_*_theta` / `Target_*_rho` are taken from the task's
  `Target N position polar (theta ..., rho ...) deg` comment when it sends one,
  and back-computed from the cartesian position otherwise. Both paths store the
  **task's own convention**: `0` = +x (right), counter-clockwise, `[0, 360)`.
  The names match the comment's own words; they were `Target_*_angle` /
  `Target_*_eccentricity` before 2026-09-10, so an older export has the old
  headers and needs re-exporting.
  Preferring the sent values matters because the cartesian comments are printed
  to two decimals, so a back-computed rho is wrong in the fourth digit
  (`(4.95, 4.95)` gives 6.99985 where the task sent exactly 7.00).
  > ⚠️ This replaced an earlier compass frame (`0` = up, clockwise,
  > `(-180, 180]`). Angles are plain numbers, so an old export and a new one
  > cannot be told apart by inspection — **re-export every session** you intend
  > to compare, and re-run the analyzer with the `ReCompute*` flags on so cached
  > products are rebuilt. Use `BlackrockLoader.hemifield(theta)` for left/right;
  > the old `theta >= 0` test is true for every theta in this range.
- `Target_*_base_theta` / `Target_*_base_rho` are the **pre-jitter** position the
  task sends separately (`Requested target N base position polar`), in the same
  convention and units. Unlike `Target_*_theta` these are never back-computed, so
  a task that sends no base comment leaves them `NaN`.
- `Requested_jitter_theta` / `Requested_jitter_rho` are the full width of the
  jitter window applied to that base position, and `Requested_jitter_*_step` the
  grid it is quantised to (all in deg). So the actual position sits within
  ±`jitter/2` of the base, on a multiple of the step.

**`*_eye_matlab.mat`** — one variable `eye`, a struct that lines up 1:1
with the CSV rows (trial dimension is index-aligned with `trials`):

- `eye.data` — `nChan × nTrials × maxSamples` **`single`**, in µV, each
  trial's window `[Start − PreBuffer, End + PostBuffer]`, left-aligned and
  **NaN-padded** to the longest trial (missing-marker trials are all-NaN).
  `nChan` here is `EyeChannels` (`[1 2 3]`), not every channel in the file.
  `single` halves the size of these arrays and still carries far more precision
  than a 16-bit ADC resolves.
- `eye.timeseq` — `alignedrawtime` (abs time of each Start marker, s),
  `aligned_marker` (`'Start'`, where `relative_time = 0`), and `relative_time`
  (`1 × maxSamples`, seconds from the marker; negative through the pre-buffer).
- `eye.info` — `samplingrate`, plus `Session` and `Trial_number` per trial.

**`*_lfp_matlab.mat`** and **`*_photodiode_matlab.mat`** — same layout as
`*_eye_matlab.mat` (`.data`/`.timeseq`/`.info`), in variables `lfp` and
`photodiode` respectively. `lfp` is loaded from `LFPPrefix-*.ns2` (`Hub-*.ns2`
by default) via the exact same `loadContinuous`/`segmentContinuous` path as the eye
eye stream, just with a different file schema. `photodiode` is, by default,
rows `PhotodiodeChannels` (`[4 5 6]`) of the **same segmented array** `eye`
came from — the eye `EyePrefix-*.ns2` is read once and cut once, then split
by channel, so the photodiode costs neither an extra read nor an extra
segmentation pass. If the eye stream doesn't have that many channels, it falls
back to auto-loading a dedicated `PhotodiodePrefix-*.ns4` file (`NSP-*.ns4` by
default) and uses **all** of that file's channels; set
`PhotodiodeUseSeparateFile` to skip the eye-stream path and always load the
dedicated file.

**Precision: voltages are `single`, times are always `double`.** The segmented
sample arrays (`eye`/`lfp`/`photodiode` `.data`, spike waveforms, and the
`0/1` raster) are `single` — half the memory, and still ~300× finer than the ADC
quantum the values are stored on. Every timestamp stays `double`: comment/event
times, spike times, trial `Start`/`End`, `timeseq.alignedrawtime`,
`timeseq.relative_time`, and `waveform_time`. Recording clocks run to ~1.5e9 s
absolute and down to nanosecond PTP ticks, so `single` would discard real
resolution — never narrow a time field.

All `.mat` products are written as `-v7.3` (HDF5) — every one of them is a dense
per-trial array that can exceed the default MAT format's 2 GB per-variable cap.
They are gzip-compressed unless `CompressExport` is cleared: the arrays are
mostly NaN padding and compress ~6× (9.0 GB → 1.45 GB for one session), which is
usually worth the ~60 s of single-threaded gzip; clear the flag to trade the
disk for the time.

**`*_spikes_matlab.mat`** — one variable `online_spike`, same layout as `eye`
but a binary raster:

- `online_spike.data` — `NtotalUnit × nTrials × maxBins`, `0/1` (1 if any spike
  of that row falls in the bin), NaN-padded. Each row is one `(electrode, unit)`
  pair, so `NtotalUnit` sums isolated units across channels.
- `online_spike.timeseq` — same fields as the eye `timeseq` (`relative_time`
  is `1 × maxBins`).
- `online_spike.info` — `samplingrate` (bin rate, e.g. 1000 Hz for 1 ms bins),
  `Session`, `Trial_number`, `Channel_Number` and `Unit_No` per raster row, plus
  `source` (`'online'`; `'offline'` for a future offline-sorted source).

**`*_spikes_waveform_matlab.mat`** — written only when `LoadOnlineSpikeWaveform` is on
(opt-in; off by default, and requires `LoadOnlineSpikeData`). One variable
`online_spike_waveform` holding the raw waveform of every in-window spike, with
the **same row order** as the raster (`info.Channel_Number` / `info.Unit_No`).
Saved as `-v7.3` (HDF5) because the dense array can exceed the default MAT
format's 2 GB per-variable cap.

- `online_spike_waveform.waveform` — `NtotalUnit × nTrials × maxSpk × nSamp`, in
  **µV**, NaN-padded. The spike dimension `maxSpk` is the largest per-`(unit,
trial)` in-window spike count, shared across all rows/trials (so the busiest
  unit drives the array size — `segmentSpikeWaveforms` warns when it would exceed
  ~2 GB).
- `online_spike_waveform.waveform_time` — `NtotalUnit × nTrials × maxSpk`, each
  spike's time in seconds **relative to the Start marker**, NaN-padded.
- `online_spike_waveform.waveform_nsamp` — samples per waveform;
  `.waveform_unit` is `'microVolts'`; `.timeseq` has `alignedrawtime` /
  `aligned_marker`; `.info` has `Session`, `Trial_number`, `Channel_Number`,
  `Unit_No`, `maxSpikes`, and `source`.

The per-trial window buffers and the spike bin width are set by
`Segment_PreBuffer` / `Segment_PostBuffer` / `Segment_BinWidth` (ms) near the top
of `BlackRockFileLoader.m`.

### Comment parsing schema

`parseEvents` turns BlackRock's free-text comment strings into structured
`trials` and `experiment` records using the field maps from
`BlackrockLoader.defaultEventMaps()`. A single `.nev` may contain several
experiment **sessions** (the task started/stopped repeatedly). Trials are keyed
by position, so a reset trial counter starts a new trial rather than merging,
and **each reset of the trial counter begins a new session** — session labels
are therefore always 1-based and cover every trial. The
`Experiment start: git commit ...` markers are still parsed (they carry the
per-session metadata) and are used as a cross-check: if their session
boundaries disagree with the trial-counter resets, `parseEvents` warns
(`BlackrockLoader:parseEvents:SessionMismatch`). Sessions are labelled from the
resets rather than from the markers because a file that was not saved cleanly
can be missing its leading metadata block, which used to stamp `Session = 0` on
every trial of that block — and `Session` is a join key downstream
(`SpikeTrialAlignmentCheck` pairs comments to spikes on `(Session,
Trial_number)`). A session with no metadata block gets a blank `experiment`
entry so `experiment(Session)` is always addressable. Derived features (polar
target theta/rho, `Stimulus_direction`, `Choose_target`,
`Choose_leftright`) are added at the end; the polar pair prefers the task's own
`position polar` comment over the cartesian back-computation, and is stored in
the task's `[0, 360)` convention (see the CSV notes above).

Four `Experiment` markers are recognised: `Experiment start:` and
`Experiment end:`, which require the colon and carry a metadata token after it,
and `Experiment paused` / `Experiment resumed`, which carry no token and are
written without a colon (their timestamps go to `pause_times` / `resume_times`
on that session's `experiment` entry). Anything else beginning with
`Experiment ` — `Experiment ended by ...`, say — matches neither those nor the
`Trial N:` form, so it has no trial to attach to and is dropped and reported as
malformed.

Parsing is set-oriented rather than per-comment: the whole comment matrix is
tokenised at once, trial and session indices come from `cumsum`, and each
_distinct_ event body is classified once and its value scattered to the trials
that used it. A 109k-comment session carries only ~600 distinct bodies, so this
runs 12-16x faster than walking the comments one at a time. A comment matching
neither the `Experiment` nor the `Trial N:` form no longer aborts the parse; it
is skipped with a warning, and an unrecognised event body lands in
`trials.undefined` as before.

#### Event timestamp semantics (read before comparing timings)

Not every timestamp in the output CSV means the same thing. jives emits each
comment via one of two logging paths, and which one determines whether the
timestamp reflects "when the event was detected" or "when the screen actually
drew the change":

- **Immediate** (`logging_thread.log_event`) — timestamp is the frame when the
  handler line executed. Used for anything driven by gaze / detection (i.e. anything involving the eyetracker responding to subject's behavior & trial/reward start/end):
  `Fixation acquired`, `Fixation exited`, `Target 1/2 acquired` (→ `Choicetime`),
  `Broke fixation`, `Reward start/end`, `End - *`.
- **On-flip** (`log_event_on_flip`, via `window.callOnFlip`) — timestamp is
  posted at the _next_ vsync after queuing, so it lands ~1 frame later
  (≈16.7 ms at 60 Hz). Used for anything driven by the screen: `Fixation point
on/off`, `Target 1 presented`, `Target 2 presented`, `Targets off`,
  `Target 1 off`, `Feedback flash on/off`.

Consequences that are easy to mis-read as bugs:

1. **`Fixation_acquired` can be earlier than `Fixation_point_on`.** If the
   monkey's gaze is already inside the acceptance window on the first frame of
   `_fixation_shown`, the immediate `Fixation acquired` log lands _before_ the
   on_flip `Fixation point on` posts. Diff is typically −20 ms; not a
   parser bug.
2. **`Fixation_exited` can be ≈0 or slightly negative vs. `Fixation_point_off`
   in `time_delay`.** Both events fall on the same frame (state handler
   transitions and gaze leaves the window as the dot vanishes). The immediate
   `Fixation exited` beats the on*flip `Fixation point off` by roughly one
   frame minus render time — this is a \_healthy* trial, not a broken one.
3. **`Requested_fixation_hold_time` doesn't match measured
   `Target_1_presented − Fixation_acquired`.** The measured interval carries
   `hold_time` + 1–3 frames of state-machine overhead + 1 frame of on_flip lag.
   Expect a floor of ~30–60 ms extra at 60 Hz. If you need the true hold
   duration you must either subtract on_flip lag (`1000/FPS` ms), or ask jives
   to emit an on_flip `Fixation held` marker at the moment the hold gate opens.

**Rule of thumb when validating diffs against `Requested_*` durations:**
on-flip → on-flip diffs (`Target_1_presented → Target_2_presented`,
`Targets_off → Fixation_point_off`) match their requested durations to within
~1 frame because both endpoints share the same latency. Diffs that mix an
on-flip endpoint with an immediate one (`Fixation_point_off →
Fixation_exited`, `Fixation_acquired → Target_1_presented`) carry ±half a
frame of extra noise on top of whatever state-machine cost sits between them.

**What _is_ directly measurable to ~1 frame:** on-screen durations that use
two on-flip endpoints. The clearest is the fixation dot's total on-screen
lifetime, `Fixation_point_off − Fixation_point_on` — this is the actual number
of ms the red dot was drawn (spanning fixation-hold + target presentations +
delay, since the dot stays up through all of them in time_delay).

The event definitions live in `jives/experiment/{fixation,visual_saccades,
time_delay}_experiment.py`; search for `log_event(` (immediate) vs
`log_event_on_flip(` (on-flip). A full per-event breakdown for time_delay
lives in
`mendelevich/data-analysis/data_helpers/conversion/UNDERSTANDING.md` §10.

#### Adding a new comment key

For any event whose text matches a shape the parser already knows, there are
**two** places to edit and nothing else:

1. **`BlackrockLoader.defaultEventMaps()`** — add `'Comment key' → 'Field_name'`
   to the appropriate map.
2. **`BlackrockLoader.defaultTrialTemplate()`** — add `Field_name`, initialised
   `NaN` for a scalar or text field, `[NaN, NaN]` for a coordinate pair. The
   template's field _order_ is the CSV column order, so insert it where you want
   the column.

**Which map you choose is how you declare the shape** — that is the whole
mechanism, so pick by how the comment reads:

| map                 | comment text                      | what is stored                        |
| ------------------- | --------------------------------- | ------------------------------------- |
| `TimeEvents`        | `Widget engaged` (bare name)      | the comment's timestamp               |
| `SegmentEvents`     | `Widget color blue`               | the text after the **key**            |
| `InformationEvents` | `Widget position (1.5, -2.5) deg` | a `[x y]` pair                        |
| `InformationEvents` | `Reward start (250.0ms)`          | the timestamp **and** `Reward_amount` |
| `InformationEvents` | `Requested widget delay 250 ms`   | a scalar (`None`/`none` → `NaN`)      |
| `InformationEvents` | `Widget size 4.00 deg`            | a scalar                              |
| `PolarEvents`       | `Widget position polar (theta 1.0, rho 2.0) deg` | two scalars (see below) |

Everything downstream is derived from those two edits, so do not declare it
anywhere: whether the exported column is text or numeric, the `_x`/`_y` split of
a coordinate field, the CSV column order, first-write-wins, and duplicate
capture into `trials.duplicates`.

Two things to watch:

- **`SegmentEvents` keys may not be substrings of one another.** That map alone
  is matched in key order, first match wins, so an overlapping pair would bind by
  however the keys happen to sort. Adding `'Widget color'` next to
  `'Widget color scheme'` throws `BlackrockLoader:EventMaps:SubstringKey` when
  the loader is constructed. The other maps resolve by exact match and allow
  overlap — `'Requested jitter theta'` and `'Requested jitter theta step'` are
  both `InformationEvents` keys. There a name that matches no key exactly and is
  ambiguous between several lands in `trials.undefined`, where the parse report
  prints it; it never binds to the wrong field.
- **Every mapped field must exist in the template**, or construction throws
  `BlackrockLoader:EventMaps:UnknownField`. This is the one mistake the parse
  report cannot show you: a field nobody declared resolves to index 0, the write
  is dropped, and the comment lands in neither the trial nor `trials.undefined`.
  So forgetting edit 2 above is an error at construction, not silent data loss.
- **A `PolarEvents` value is a *pair* of field names, not one.** One such
  comment carries two numbers, so the value is
  `{'Target_1_theta', 'Target_1_rho'}` — theta to the first, rho to the second.
  It is a separate map from `InformationEvents` because no `InformationEvents`
  branch can write two fields from one body, not because of any key overlap.
  Both values are stored exactly as the task sends them (0 = +x,
  counter-clockwise, `[0, 360)`); `addDerivedTrialFeatures` only fills in the
  trials where no polar comment arrived.
- **`DashEvents` and `OutcomeEvents` are plain lists, not field maps.** Their
  target fields are hardcoded (`End`/`Trialoutcome` when the name contains
  `End`, `Choosen_choice` when it contains `choice`, `Choiceoutcome` for
  outcomes). A new value following those conventions needs only the list entry;
  one that does not needs the branch edited, as below.

If the comment matches **none** of the shapes in the table, there is a third
place: add a `kind` test and its extraction branch to
`BlackrockLoader.classifyEventBodies` (and a new `mode` if the value is not a
timestamp, scalar, pair, or text). That function is the only place event bodies
are pattern-matched. (`parseEventsLegacy` is now block-commented out in the class, and
stale — see the note above it. `Test_parseEvents_AB.m` cannot run until it is
restored, and would report differences for every shape added since 2026-08-06.)

Session-level rather than per-trial metadata follows the same pattern one level
up, via `ExpEvents` in `defaultEventMaps()` plus `defaultExpTemplate()`.

(See **Checking the comments to debug parsing** above for how to eyeball the raw,
unparsed comment strings when adding or fixing a comment key.)

### Setting up the data path

The driver finds your data by assembling a folder path from a few editable
variables at the top of `BlackRockFileLoader.m`. Set these to point at your own
data, then run the script — the loader resolves the `.nev`/`.ns2` files inside
each folder by the prefix schema above.

```matlab
Basic_Path   = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data'; % root of all data
Monkey       = 'Porthos';      % bare monkey name; folder on disk is "Monkey <name>"
Location     = 'in_lab';       % editable constant
DataType     = 'raw_data';     % editable constant
OutputFolder = 'export_data';  % where parsed data is written
```

The driver builds the input and export roots as:

```matlab
DataTypePath = fullfile(Basic_Path, ['Monkey ' Monkey], Location, DataType);
ExportPath   = fullfile(Basic_Path, ['Monkey ' Monkey], Location, OutputFolder);
```

so the expected folder layout on disk is:

```
<Basic_Path>/Monkey <Monkey>/<Location>/<DataType>/<YYYY-MM-DD>/    ← contains the .nev/.ns2 files
<Basic_Path>/Monkey <Monkey>/<Location>/export_data/<YYYY-MM-DD>/   ← parsed .txt/.csv output is written here
```

If your data already lives under a different layout, just overwrite `DataTypePath`
and `ExportPath` directly with your own absolute paths.

### Batch loading multiple sessions

The driver processes one or more `YYYY-MM-DD` session folders in a single run.
Set the `Folder` variable to choose which ones:

```matlab
Folder = '2026-06-17';                    % a single session folder
Folder = {'2026-06-17','2026-06-18'};     % several folders, loaded in order
Folder = {};                              % every YYYY-MM-DD folder under DataTypePath
```

For each folder the driver calls `loader.processFolder(...)`, which **loads →
parses → adds features → exports** in turn, writing the per-session output files
(`Blackrock_<date>_expmeta_matlab.txt` and `Blackrock_<date>_trials_matlab.csv`)
into the matching `export_data/<date>/` subfolder.

If one folder fails (e.g. a missing `.nev` file), it is caught and reported, and
the batch continues with the remaining folders. A **batch summary** listing the
`ok`/`failed` status of every folder is printed at the end.

> Note: a single `.nev` recording may contain several experiment sessions
> (the task started/stopped multiple times). These are tracked per session
> within each file via the `Session` column, independent of the batch-folder loop.

### Cage trainer data

`CageTrainingDataLoading.m` concatenates the per-trial `.json` files into one
`all_trials_<date>.csv`; `CageTrainingDataAnalyzer.m` reads that CSV and plots
the psychometric curve. Set the corresponding path variables at the top of those
scripts the same way as the BlackRock loader.

You are welcome to change these into your own paths.

## Feel free to push me request, report errors or bugs.
