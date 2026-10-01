import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'sketch_painter.dart';
import 'sketchify.dart';
import 'sketch_style.dart';

/// How the animation repeats.
enum SketchPlayMode {
  /// Play once and stop on the finished artwork.
  once,

  /// Start over from the beginning each time it finishes.
  loop,

  /// Draw in, then undraw back to nothing, and repeat.
  pingPong,
}

/// Draws a [Sketch] in: outlines first, then the artwork appears.
///
/// Control it through a `GlobalKey<SketchAnimationState>`:
/// [SketchAnimationState.replay], `pause`, `resume`, `seek` and
/// `progress`.
class SketchAnimation extends StatefulWidget {
  /// The traced image to draw, from [Sketchify.trace].
  final Sketch sketch;

  /// How the drawing looks: line colour, pen, order, fill and reveal.
  final SketchStyle style;

  /// Start drawing on first build. When false the finished artwork is shown
  /// until [SketchAnimationState.replay] is called.
  final bool autoPlay;

  /// Length of one run at [speed] 1.0.
  final Duration duration;

  /// Playback speed multiplier: 2.0 is twice as fast, 0.5 half speed.
  final double speed;

  /// Easing applied over a whole run.
  final Curve curve;

  /// Whether the animation plays once, loops or goes back and forth.
  final SketchPlayMode playMode;

  /// Wait before the first run, and before the run that starts when
  /// [sketch] is replaced or [autoPlay] is switched on.
  final Duration delay;

  /// Pause between runs when looping.
  final Duration repeatPause;

  /// Width of the widget. Height follows the image's aspect ratio.
  /// When null it fills the available space.
  final double? width;

  /// Called every time a run finishes drawing in. Not called by
  /// [SketchAnimationState.seek].
  final VoidCallback? onCompleted;

  /// Called on every frame with the current progress (0–1, before [curve]),
  /// and after every [SketchAnimationState.seek].
  final ValueChanged<double>? onProgress;

  const SketchAnimation({
    super.key,
    required this.sketch,
    this.style = const SketchStyle(),
    this.autoPlay = true,
    this.duration = const Duration(milliseconds: 4500),
    this.speed = 1.0,
    this.curve = Curves.easeInOut,
    this.playMode = SketchPlayMode.once,
    this.delay = Duration.zero,
    this.repeatPause = const Duration(milliseconds: 800),
    this.width,
    this.onCompleted,
    this.onProgress,
  }) : assert(speed > 0, 'speed must be greater than 0');

  @override
  State<SketchAnimation> createState() => SketchAnimationState();
}

/// The state of a [SketchAnimation], for controlling playback.
class SketchAnimationState extends State<SketchAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _paused = false;
  bool _forward = true;
  int _run = 0; // invalidates pending delayed restarts
  Timer? _wait; // a pending delayed start, cancelled when superseded
  bool _seeking = false; // status changes from seek() aren't real run ends
  bool _progressPending = false; // an onProgress call waits for the frame to end

  /// Current position, 0 → 1.
  double get progress => _controller.value;

  /// Whether the drawing is moving right now. False while paused, finished
  /// or waiting between runs.
  bool get isPlaying => _controller.isAnimating;

  /// Whether [pause] or [seek] stopped the animation.
  bool get isPaused => _paused;

  // No upper clamp: large int literals like `1 << 52` are 0 on the web.
  Duration get _effectiveDuration =>
      Duration(microseconds: math.max(1, (widget.duration.inMicroseconds / widget.speed).round()));

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _effectiveDuration, value: widget.autoPlay ? 0.0 : 1.0)
      ..addStatusListener(_onStatus)
      ..addListener(_notifyProgress);
    if (widget.autoPlay) _startAfter(widget.delay, fromStart: true);
  }

  @override
  void didUpdateWidget(covariant SketchAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration || oldWidget.speed != widget.speed) {
      _controller.duration = _effectiveDuration;
      // Keep going at the new speed from where it is.
      if (_controller.isAnimating) _continue();
    }
    if (!identical(oldWidget.sketch, widget.sketch) && widget.autoPlay) {
      _restart();
    } else if (!oldWidget.autoPlay && widget.autoPlay) {
      _restart();
    } else if (oldWidget.playMode != widget.playMode &&
        _controller.isCompleted &&
        !_paused &&
        widget.playMode != SketchPlayMode.once) {
      if (widget.playMode == SketchPlayMode.pingPong) _forward = false;
      _startAfter(widget.repeatPause, fromStart: widget.playMode == SketchPlayMode.loop);
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Reports progress. Changes made while the tree is building (e.g. a new
  /// [SketchAnimation.sketch] restarting the drawing) are reported once the
  /// frame is done, so [SketchAnimation.onProgress] can safely call setState.
  void _notifyProgress() {
    if (widget.onProgress == null) return;
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      widget.onProgress!(_controller.value);
      return;
    }
    if (_progressPending) return;
    _progressPending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _progressPending = false;
      if (mounted) widget.onProgress?.call(_controller.value);
    });
  }

  void _onStatus(AnimationStatus status) {
    if (_seeking) return;
    if (status == AnimationStatus.completed) {
      widget.onCompleted?.call();
      switch (widget.playMode) {
        case SketchPlayMode.once:
          break;
        case SketchPlayMode.loop:
          _startAfter(widget.repeatPause, fromStart: true);
        case SketchPlayMode.pingPong:
          _forward = false;
          _startAfter(widget.repeatPause);
      }
    } else if (status == AnimationStatus.dismissed && widget.playMode == SketchPlayMode.pingPong && !_forward) {
      _forward = true;
      _startAfter(widget.repeatPause);
    }
  }

  void _startAfter(Duration wait, {bool fromStart = false}) {
    final int run = ++_run;
    _wait?.cancel();
    _wait = null;
    void start() {
      if (!mounted || run != _run || _paused) return;
      if (fromStart) {
        _forward = true;
        _controller.forward(from: 0.0);
      } else {
        _continue();
      }
    }

    if (wait > Duration.zero) {
      _wait = Timer(wait, start);
    } else {
      start();
    }
  }

  void _continue() {
    if (_forward) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  /// Clears to the start, then plays after [SketchAnimation.delay].
  void _restart() {
    _paused = false;
    _forward = true;
    _setSilently(0.0);
    _startAfter(widget.delay, fromStart: true);
  }

  void _setSilently(double value) {
    _seeking = true;
    try {
      _controller.value = value;
    } finally {
      _seeking = false;
    }
  }

  /// Plays from the beginning, straight away.
  void replay() {
    _paused = false;
    _run++;
    _wait?.cancel();
    _forward = true;
    _controller.forward(from: 0.0);
  }

  /// Freezes the animation where it is.
  void pause() {
    _paused = true;
    _run++;
    _wait?.cancel();
    _controller.stop();
  }

  /// Continues after [pause] or [seek].
  void resume() {
    _paused = false;
    if (_controller.isCompleted && _forward) {
      // Finished drawing: carry on with the next run, if there is one.
      switch (widget.playMode) {
        case SketchPlayMode.once:
          return;
        case SketchPlayMode.loop:
          _startAfter(Duration.zero, fromStart: true);
        case SketchPlayMode.pingPong:
          _forward = false;
          _continue();
      }
      return;
    }
    if (_controller.isDismissed && !_forward) _forward = true;
    _continue();
  }

  /// Jumps to [value] (0 → 1) and pauses there. Doesn't call
  /// [SketchAnimation.onCompleted] or start the next run; [resume] does.
  void seek(double value) {
    pause();
    _setSilently(value.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final Widget paint = AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: SketchPainter(
            sketch: widget.sketch,
            progress: widget.curve.transform(_controller.value),
            style: widget.style,
          ),
          size: Size.infinite,
        );
      },
    );

    final double ratio = widget.sketch.aspectRatio;
    final double? width = widget.width;
    if (width != null) {
      return SizedBox(width: width, height: width / ratio, child: paint);
    }
    return Center(
      child: AspectRatio(aspectRatio: ratio, child: paint),
    );
  }
}
