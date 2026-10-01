import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sketchify/sketchify.dart';

// Traced images are cached on disk (IndexedDB on the web) out of the box,
// so they open instantly on the next launch too. No setup needed.
void main() => runApp(const SketchifyShowcase());

/// A playground for the sketchify package: pick an image, pick a look, and
/// watch it draw itself in.
class SketchifyShowcase extends StatefulWidget {
  const SketchifyShowcase({super.key});

  @override
  State<SketchifyShowcase> createState() => _SketchifyShowcaseState();
}

class _SketchifyShowcaseState extends State<SketchifyShowcase> {
  ThemeMode _themeMode = ThemeMode.system;

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF5B5BD6), brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        margin: EdgeInsets.zero,
      ),
      chipTheme: const ChipThemeData(showCheckmark: false),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
          textStyle: WidgetStatePropertyAll(const TextStyle(fontSize: 13)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sketchify',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _themeMode,
      home: ShowcasePage(
        onToggleTheme: () => setState(() {
          final bool dark =
              _themeMode == ThemeMode.dark ||
              (_themeMode == ThemeMode.system && MediaQuery.platformBrightnessOf(context) == Brightness.dark);
          _themeMode = dark ? ThemeMode.light : ThemeMode.dark;
        }),
      ),
    );
  }
}

// ── Samples and looks ───────────────────────────────────────────────────────

class _Sample {
  final String name;
  final String asset;
  final IconData icon;

  const _Sample(this.name, this.asset, this.icon);
}

const List<_Sample> _samples = [
  _Sample('Cat', 'assets/cat.png', Icons.pets_rounded),
  _Sample('Rocket', 'assets/rocket.svg', Icons.rocket_launch_rounded),
  _Sample('Owl', 'assets/owl.svg', Icons.nightlight_round),
  _Sample('Sunset', 'assets/sunset.svg', Icons.landscape_rounded),
  _Sample('Coffee', 'assets/coffee.svg', Icons.coffee_rounded),
  _Sample('Lettering', 'assets/lettering.svg', Icons.text_fields_rounded),
];

class _Look {
  final String name;
  final IconData icon;

  /// Paper colour behind the drawing; null uses the theme's.
  final Color? paper;
  final SketchStyle Function(ColorScheme scheme) style;

  const _Look(this.name, this.icon, this.style, {this.paper});
}

final List<_Look> _looks = [
  _Look(
    'Pencil',
    Icons.edit_rounded,
    (s) => SketchStyle(lineColor: s.onSurface.withValues(alpha: 0.85), lineWidth: 1.3, showPen: true, penGlow: false),
  ),
  _Look(
    'Neon',
    Icons.auto_awesome_rounded,
    (s) => const SketchStyle(
      lineGradient: LinearGradient(colors: [Color(0xFFFF3D9A), Color(0xFF8B5CF6), Color(0xFF22D3EE)]),
      lineWidth: 2.6,
      showPen: true,
      order: SketchOrder.staggered,
      reveal: SketchReveal.circle,
    ),
  ),
  _Look(
    'Ink',
    Icons.palette_rounded,
    (s) => const SketchStyle(
      useShapeColors: true,
      lineWidth: 2,
      order: SketchOrder.sequential,
      reveal: SketchReveal.wipeDown,
    ),
  ),
  _Look(
    'Blueprint',
    Icons.architecture_rounded,
    (s) => const SketchStyle(
      lineColor: Color(0xFFE3F0FF),
      lineWidth: 1.6,
      showPen: true,
      penColor: Color(0xFFFFFFFF),
      fill: SketchFill.none,
      order: SketchOrder.staggered,
    ),
    paper: const Color(0xFF1C4E89),
  ),
  _Look(
    'Vector',
    Icons.format_shapes_rounded,
    (s) => SketchStyle(lineColor: s.primary, lineWidth: 2, fill: SketchFill.vector, reveal: SketchReveal.wipeRight),
  ),
];

// ── Page ────────────────────────────────────────────────────────────────────

class ShowcasePage extends StatefulWidget {
  const ShowcasePage({super.key, required this.onToggleTheme});

  final VoidCallback onToggleTheme;

  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

class _ShowcasePageState extends State<ShowcasePage> {
  final GlobalKey<SketchAnimationState> _animation = GlobalKey();
  final ValueNotifier<double> _progress = ValueNotifier(0);

  String _current = _samples.first.asset;
  String? _customName;
  Sketch? _sketch; // what's on stage; kept while the next image traces
  bool _loading = true;
  Timer? _showLoading; // cache hits are quick, so the spinner waits a moment
  String? _error;

  int _look = 0;
  SketchStyle? _style; // the look plus the user's tweaks
  double _speed = 1;
  SketchPlayMode _playMode = SketchPlayMode.once;
  bool _paused = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _load(_current, () => Sketchify.traceAsset(_current));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme-dependent looks follow light/dark mode.
    _style ??= _looks[_look].style(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    _showLoading?.cancel();
    _sketch?.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// Shows the image [id]. Tracing goes through [Sketchify.cache], so an
  /// image seen before (even in an earlier session) is back almost at once.
  Future<void> _open(String id, Future<Sketch> Function() trace) async {
    setState(() {
      _current = id;
      _error = null;
      _paused = false;
      _finished = false;
    });
    await _load(id, trace);
  }

  Future<void> _load(String id, Future<Sketch> Function() trace) async {
    _showLoading?.cancel();
    _showLoading = Timer(const Duration(milliseconds: 120), () {
      if (mounted && _current == id) setState(() => _loading = true);
    });
    try {
      final sketch = await trace();
      if (!mounted || _current != id) return sketch.dispose(); // superseded
      final Sketch? old = _sketch;
      setState(() {
        _sketch = sketch;
        _loading = false;
      });
      // Free the previous image once the new one is on screen.
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    } catch (e) {
      if (mounted && _current == id) {
        setState(() {
          _error = e is UnsupportedImageException ? e.message : 'Could not trace this image: $e';
          _loading = false;
        });
      }
    } finally {
      if (_current == id) _showLoading?.cancel();
    }
  }

  Future<void> _clearCache() async {
    await Sketchify.cache?.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Trace cache cleared. Images are traced afresh next time.')));
  }

  Future<void> _pickImage() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Images',
          extensions: SketchImageFormat.allExtensions,
          mimeTypes: SketchImageFormat.allMimeTypes,
          uniformTypeIdentifiers: const ['public.image', 'public.svg-image'],
        ),
      ],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    // A fresh id each time, so picking a new image never shows a stale one.
    // (Picking the same file again is still a cache hit: the cache goes by
    // the file's contents.)
    final id = 'custom:${DateTime.now().microsecondsSinceEpoch}';
    setState(() => _customName = file.name);
    await _open(id, () => Sketchify.trace(bytes));
  }

  void _chooseLook(int index) {
    setState(() {
      _look = index;
      _style = _looks[index].style(Theme.of(context).colorScheme);
    });
    _replay();
  }

  void _tweak(SketchStyle Function(SketchStyle s) change) => setState(() => _style = change(_style!));

  void _replay() {
    setState(() {
      _paused = false;
      _finished = false;
    });
    _animation.currentState?.replay();
  }

  void _togglePlay() {
    final state = _animation.currentState;
    if (state == null) return;
    if (_finished && !_paused && _playMode == SketchPlayMode.once) return _replay();
    setState(() => _paused = !_paused);
    if (_paused) {
      state.pause();
    } else {
      if (state.progress >= 1 && _playMode == SketchPlayMode.once) return _replay();
      _finished = false;
      state.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFFFF3D9A), Color(0xFF5B5BD6)]),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.draw_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sketchify',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'Any image, drawn by hand',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Clear trace cache',
            onPressed: _clearCache,
            icon: const Icon(Icons.cleaning_services_rounded),
          ),
          IconButton(
            tooltip: 'Light / dark',
            onPressed: () {
              widget.onToggleTheme();
              // Re-derive theme-dependent looks after the theme flips.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _style = _looks[_look].style(Theme.of(context).colorScheme));
              });
            },
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bool wide = constraints.maxWidth >= 960;
            final stage = _Stage(
              sketch: _sketch,
              error: _error,
              loading: _loading,
              paper: _looks[_look].paper,
              child: _sketch == null
                  ? null
                  : SketchAnimation(
                      key: _animation,
                      sketch: _sketch!,
                      style: _style!,
                      speed: _speed,
                      playMode: _playMode,
                      delay: const Duration(milliseconds: 250),
                      onProgress: (v) => _progress.value = v,
                      onCompleted: () {
                        if (_playMode == SketchPlayMode.once) setState(() => _finished = true);
                      },
                    ),
            );
            final transport = _Transport(
              progress: _progress,
              playing: !_paused && !(_finished && _playMode == SketchPlayMode.once),
              enabled: _sketch != null && _error == null,
              onReplay: _replay,
              onTogglePlay: _togglePlay,
              onSeekStart: () => setState(() => _paused = true),
              onSeek: (v) => _animation.currentState?.seek(v),
            );
            final controls = _Controls(
              sampleId: _current,
              customName: _customName,
              onSample: (s) => _open(s.asset, () => Sketchify.traceAsset(s.asset)),
              onPick: _pickImage,
              look: _look,
              onLook: _chooseLook,
              style: _style!,
              onTweak: _tweak,
              speed: _speed,
              onSpeed: (v) => setState(() => _speed = v),
              playMode: _playMode,
              onPlayMode: (m) => setState(() {
                _playMode = m;
                _finished = false;
              }),
              sketch: _sketch,
            );

            if (wide) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: stage),
                          const SizedBox(height: 12),
                          transport,
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    SizedBox(width: 380, child: SingleChildScrollView(child: controls)),
                  ],
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                AspectRatio(aspectRatio: 1.15, child: stage),
                const SizedBox(height: 12),
                transport,
                const SizedBox(height: 20),
                controls,
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── Stage: the drawing on dotted paper ──────────────────────────────────────

class _Stage extends StatelessWidget {
  const _Stage({
    required this.sketch,
    required this.error,
    required this.loading,
    required this.paper,
    required this.child,
  });

  final Sketch? sketch;
  final String? error;
  final bool loading;
  final Color? paper;

  /// The animation. Always the same single widget (it holds a GlobalKey), so
  /// it is dimmed while loading rather than swapped out.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color background = paper ?? scheme.surfaceContainer;
    final Color dots = paper != null
        ? Colors.white.withValues(alpha: 0.16)
        : scheme.outlineVariant.withValues(alpha: 0.6);
    final double inset = MediaQuery.sizeOf(context).width < 600 ? 20 : 36;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _DotGridPainter(dots)),
          if (error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_rounded, size: 48, color: scheme.error),
                    const SizedBox(height: 12),
                    Text(error!, textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          else if (child != null)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: loading ? 0.2 : 1,
              child: Padding(padding: EdgeInsets.all(inset), child: child),
            ),
          if (loading)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [CircularProgressIndicator(), SizedBox(height: 16), Text('Tracing…')],
              ),
            ),
          if (sketch != null && error == null && !loading)
            Positioned(
              left: 16,
              top: 16,
              child: _Pill(
                icon: sketch!.fromCache ? Icons.bolt_rounded : null,
                text:
                    '${sketch!.format.name.toUpperCase()} · '
                    '${sketch!.fromCache ? 'from cache' : 'traced'} in ${sketch!.elapsed.inMilliseconds} ms',
              ),
            ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  _DotGridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const double gap = 20;
    for (double y = gap / 2; y < size.height; y += gap) {
      for (double x = gap / 2; x < size.width; x += gap) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: scheme.primary), const SizedBox(width: 4)],
          Text(
            text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ── Transport: replay, play/pause and the timeline ─────────────────────────

class _Transport extends StatelessWidget {
  const _Transport({
    required this.progress,
    required this.playing,
    required this.enabled,
    required this.onReplay,
    required this.onTogglePlay,
    required this.onSeekStart,
    required this.onSeek,
  });

  final ValueListenable<double> progress;
  final bool playing;
  final bool enabled;
  final VoidCallback onReplay;
  final VoidCallback onTogglePlay;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(tooltip: 'Replay', onPressed: enabled ? onReplay : null, icon: const Icon(Icons.replay_rounded)),
            IconButton.filled(
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: enabled ? onTogglePlay : null,
              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, value, _) => Slider(
                  value: value.clamp(0.0, 1.0),
                  onChangeStart: enabled ? (_) => onSeekStart() : null,
                  onChanged: enabled ? onSeek : null,
                ),
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, _) => SizedBox(
                width: 44,
                child: Text(
                  '${(value * 100).round()}%',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

// ── Controls ────────────────────────────────────────────────────────────────

class _Controls extends StatelessWidget {
  const _Controls({
    required this.sampleId,
    required this.customName,
    required this.onSample,
    required this.onPick,
    required this.look,
    required this.onLook,
    required this.style,
    required this.onTweak,
    required this.speed,
    required this.onSpeed,
    required this.playMode,
    required this.onPlayMode,
    required this.sketch,
  });

  final String sampleId;
  final String? customName;
  final ValueChanged<_Sample> onSample;
  final VoidCallback onPick;
  final int look;
  final ValueChanged<int> onLook;
  final SketchStyle style;
  final void Function(SketchStyle Function(SketchStyle s)) onTweak;
  final double speed;
  final ValueChanged<double> onSpeed;
  final SketchPlayMode playMode;
  final ValueChanged<SketchPlayMode> onPlayMode;
  final Sketch? sketch;

  @override
  Widget build(BuildContext context) {
    final bool custom = sampleId.startsWith('custom:');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Image',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _samples)
                ChoiceChip(
                  avatar: Icon(s.icon, size: 18),
                  label: Text(s.name),
                  selected: sampleId == s.asset,
                  onSelected: (_) => onSample(s),
                ),
              ChoiceChip(
                avatar: const Icon(Icons.upload_rounded, size: 18),
                label: Text(custom && customName != null ? _shorten(customName!) : 'Your image'),
                selected: custom,
                onSelected: (_) => onPick(),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Look',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 0; i < _looks.length; i++)
                ChoiceChip(
                  avatar: Icon(_looks[i].icon, size: 18),
                  label: Text(_looks[i].name),
                  selected: look == i,
                  onSelected: (_) => onLook(i),
                ),
            ],
          ),
        ),
        _Section(
          title: 'Playback',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<double>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0.5, label: Text('0.5×')),
                  ButtonSegment(value: 1, label: Text('1×')),
                  ButtonSegment(value: 2, label: Text('2×')),
                  ButtonSegment(value: 4, label: Text('4×')),
                ],
                selected: {speed},
                onSelectionChanged: (s) => onSpeed(s.first),
              ),
              const SizedBox(height: 10),
              SegmentedButton<SketchPlayMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: SketchPlayMode.once, label: Text('Once')),
                  ButtonSegment(value: SketchPlayMode.loop, label: Text('Loop')),
                  ButtonSegment(value: SketchPlayMode.pingPong, label: Text('Ping-pong')),
                ],
                selected: {playMode},
                onSelectionChanged: (s) => onPlayMode(s.first),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Fine-tune',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Labeled(
                label: 'Order',
                child: SegmentedButton<SketchOrder>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: SketchOrder.together, label: Text('All')),
                    ButtonSegment(value: SketchOrder.staggered, label: Text('Stagger')),
                    ButtonSegment(value: SketchOrder.sequential, label: Text('In turn')),
                  ],
                  selected: {style.order},
                  onSelectionChanged: (s) => onTweak((st) => st.copyWith(order: s.first)),
                ),
              ),
              _Labeled(
                label: 'Fill',
                child: SegmentedButton<SketchFill>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: SketchFill.image, label: Text('Image')),
                    ButtonSegment(value: SketchFill.vector, label: Text('Vector')),
                    ButtonSegment(value: SketchFill.none, label: Text('Lines')),
                  ],
                  selected: {style.fill},
                  onSelectionChanged: (s) => onTweak((st) => st.copyWith(fill: s.first)),
                ),
              ),
              _Labeled(
                label: 'Reveal',
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in SketchReveal.values)
                      ChoiceChip(
                        label: Text(_revealName(r)),
                        selected: style.reveal == r,
                        onSelected: style.fill == SketchFill.none
                            ? null
                            : (_) => onTweak((st) => st.copyWith(reveal: r)),
                      ),
                  ],
                ),
              ),
              _Labeled(
                label: 'Line width  ${style.lineWidth.toStringAsFixed(1)}',
                child: Slider(
                  min: 0.5,
                  max: 6,
                  value: style.lineWidth.clamp(0.5, 6),
                  onChanged: (v) => onTweak((st) => st.copyWith(lineWidth: v)),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pen dot'),
                value: style.showPen,
                onChanged: (v) => onTweak((st) => st.copyWith(showPen: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep lines on top'),
                value: style.keepLines,
                onChanged: (v) => onTweak((st) => st.copyWith(keepLines: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lines in shape colours'),
                value: style.useShapeColors,
                onChanged: (v) => onTweak((st) => st.copyWith(useShapeColors: v)),
              ),
            ],
          ),
        ),
        if (sketch != null)
          _Section(
            title: 'What was found',
            child: _Findings(sketch: sketch!),
          ),
      ],
    );
  }

  static String _shorten(String name) => name.length <= 18 ? name : '${name.substring(0, 15)}…';

  static String _revealName(SketchReveal r) => switch (r) {
    SketchReveal.fade => 'Fade',
    SketchReveal.wipeDown => 'Wipe ↓',
    SketchReveal.wipeUp => 'Wipe ↑',
    SketchReveal.wipeRight => 'Wipe →',
    SketchReveal.wipeLeft => 'Wipe ←',
    SketchReveal.circle => 'Circle',
  };
}

class _Findings extends StatelessWidget {
  const _Findings({required this.sketch});

  final Sketch sketch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget stat(String value, String label) => Expanded(
      child: Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            stat('${sketch.shapes.length}', 'shapes'),
            stat('${sketch.palette.length}', 'colours'),
            stat('${sketch.image.width}×${sketch.image.height}', 'final frame'),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in sketch.palette)
              Tooltip(
                message: '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                ),
              ),
          ],
        ),
        if (sketch.removedBackground != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.auto_fix_high_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              const Flexible(child: Text('Background removed: ', overflow: TextOverflow.ellipsis)),
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: sketch.removedBackground,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: scheme.outlineVariant),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
