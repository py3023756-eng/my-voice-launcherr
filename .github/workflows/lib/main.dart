import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  runApp(const HyperVoiceLauncherApp());
}

class HyperVoiceLauncherApp extends StatelessWidget {
  const HyperVoiceLauncherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iOS Voice Launcher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF10B981),
        ),
      ),
      home: const LauncherHomeScreen(),
    );
  }
}

class ScheduleTask {
  String id;
  String title;
  String time; // "HH:mm"
  bool isCompleted;
  bool popupShown;
  DateTime? popupShownAt;
  bool alarmTriggered;

  ScheduleTask({
    required this.id,
    required this.title,
    required this.time,
    this.isCompleted = false,
    this.popupShown = false,
    this.popupShownAt,
    this.alarmTriggered = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'time': time,
        'isCompleted': isCompleted,
      };

  factory ScheduleTask.fromJson(Map<String, dynamic> json) => ScheduleTask(
        id: json['id'],
        title: json['title'],
        time: json['time'],
        isCompleted: json['isCompleted'] ?? false,
      );
}

class LauncherHomeScreen extends StatefulWidget {
  const LauncherHomeScreen({super.key});

  @override
  State<LauncherHomeScreen> createState() => _LauncherHomeScreenState();
}

class _LauncherHomeScreenState extends State<LauncherHomeScreen>
    with TickerProviderStateMixin {
  // 1. Gyroscope 3D Parallax State
  double _gyroX = 0.0;
  double _gyroY = 0.0;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  int _wallpaperIndex = 0;

  // 2. Dynamic Island State
  bool _islandExpanded = false;
  String _islandTitle = "Focus Ready";
  String _islandSubtitle = "Tap mic or swipe down";
  IconData _islandIcon = Icons.bolt_rounded;
  Color _islandAccent = const Color(0xFF38BDF8);
  bool _edgeGlowActive = false;

  // 3. Offline Voice Recognition
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  String _lastSpokenText = "";

  // 4. Custom Own-Voice Recorder & Player
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecordingVoice = false;
  String? _customVoicePath;

  // 5. Schedule & 5-Min Strict Alarm Engine
  List<ScheduleTask> _tasks = [];
  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  ScheduleTask? _activeCheckInTask;
  bool _isStrictAlarmRinging = false;

  // 6. Focus Lock & Ghost Vault
  bool _focusLockEnabled = false;
  bool _ghostVaultUnlocked = false;
  double _fakeBrightness = 0.8;
  double _fakeVolume = 0.9;

  final List<List<Color>> _wallpapers = [
    [const Color(0xFF0F172A), const Color(0xFF1E1B4B), const Color(0xFF020617)],
    [const Color(0xFF064E3B), const Color(0xFF0F172A), const Color(0xFF020617)],
    [const Color(0xFF4C0519), const Color(0xFF1E1B4B), const Color(0xFF090D16)],
    [const Color(0xFF311042), const Color(0xFF0B192C), const Color(0xFF000000)],
  ];

  @override
  void initState() {
    super.initState();
    _initPermissions();
    _loadSavedData();
    _startGyroscope();
    _startMasterClock();
  }

  Future<void> _initPermissions() async {
    await [
      Permission.microphone,
      Permission.notification,
    ].request();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    final voiceFile = File('${dir.path}/my_warning_voice.m4a');
    if (await voiceFile.exists()) {
      setState(() => _customVoicePath = voiceFile.path);
    }

    final savedTasks = prefs.getString('daily_tasks');
    if (savedTasks != null) {
      final List decoded = jsonDecode(savedTasks);
      setState(() {
        _tasks = decoded.map((e) => ScheduleTask.fromJson(e)).toList();
      });
    } else {
      // Default sample schedule
      final nextMin = DateTime.now().add(const Duration(minutes: 2));
      _tasks = [
        ScheduleTask(
          id: '1',
          title: 'Physics & Maths Revision',
          time: DateFormat('HH:mm').format(nextMin),
        ),
      ];
      _saveTasks();
    }
  }

  Future<void> _saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'daily_tasks', jsonEncode(_tasks.map((e) => e.toJson()).toList()));
  }

  // Gyroscope 3D Depth Effect
  void _startGyroscope() {
    _gyroSub = gyroscopeEventStream().listen((GyroscopeEvent event) {
      if (!mounted) return;
      setState(() {
        _gyroX = (_gyroX + event.y * 2.5).clamp(-22.0, 22.0);
        _gyroY = (_gyroY + event.x * 2.5).clamp(-22.0, 22.0);
      });
    });
  }

  // Master Second-by-Second Check for Schedule & 5-Min Escalation
  void _startMasterClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      final current = DateTime.now();
      setState(() => _now = current);

      final currentHHMM = DateFormat('HH:mm').format(current);

      for (var task in _tasks) {
        if (task.isCompleted) continue;

        // 1. Exact Scheduled Time Reached -> Show Check-in Popup
        if (task.time == currentHHMM && !task.popupShown) {
          task.popupShown = true;
          task.popupShownAt = current;
          _triggerDynamicIsland(
            title: "Time Up: ${task.title}",
            subtitle: "Tap Continue within 5 mins!",
            icon: Icons.notifications_active_rounded,
            accent: Colors.amberAccent,
            expand: true,
          );
          setState(() => _activeCheckInTask = task);
        }

        // 2. 5-Minute Unanswered Check -> BLAST USER'S OWN VOICE
        if (task.popupShown &&
            !task.isCompleted &&
            !task.alarmTriggered &&
            task.popupShownAt != null) {
          final elapsedSeconds =
              current.difference(task.popupShownAt!).inSeconds;
          if (elapsedSeconds >= 300) {
            // 300 seconds = 5 Minutes
            task.alarmTriggered = true;
            _triggerOwnVoiceWarning(task);
          }
        }
      }
    });
  }

  void _triggerDynamicIsland({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accent,
    bool expand = true,
  }) {
    HapticFeedback.heavyImpact();
    setState(() {
      _islandTitle = title;
      _islandSubtitle = subtitle;
      _islandIcon = icon;
      _islandAccent = accent;
      _islandExpanded = expand;
      _edgeGlowActive = true;
    });
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _edgeGlowActive = false);
    });
  }

  // Play User's Recorded Own Voice Warning
  Future<void> _triggerOwnVoiceWarning(ScheduleTask task) async {
    setState(() {
      _isStrictAlarmRinging = true;
      _activeCheckInTask = task;
    });
    _triggerDynamicIsland(
      title: "⚠️ 5 MIN OVERDUE!",
      subtitle: "Bhai, ${task.title} shuru nahi hua!",
      icon: Icons.record_voice_over_rounded,
      accent: Colors.roseAccent,
      expand: true,
    );

    if (_customVoicePath != null && File(_customVoicePath!).existsSync()) {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.play(DeviceFileSource(_customVoicePath!));
    } else {
      // Fallback system alert loop if user hasn't recorded voice yet
      Timer.periodic(const Duration(seconds: 2), (t) {
        if (!_isStrictAlarmRinging) {
          t.cancel();
        } else {
          SystemSound.play(SystemSoundType.alert);
          HapticFeedback.vibrate();
        }
      });
    }
  }

  Future<void> _stopWarningAlarm() async {
    await _audioPlayer.stop();
    setState(() {
      _isStrictAlarmRinging = false;
      if (_activeCheckInTask != null) {
        _activeCheckInTask!.isCompleted = true;
        _activeCheckInTask = null;
        _saveTasks();
      }
      _islandExpanded = false;
    });
  }

  // Offline Voice Command Listener
  Future<void> _toggleOfflineVoiceCommand() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      return;
    }

    bool available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
      onError: (err) {
        if (mounted) setState(() => _isListening = false);
      },
    );

    if (available) {
      setState(() {
        _isListening = true;
        _lastSpokenText = "Sun raha hoon (Offline)...";
      });
      _triggerDynamicIsland(
        title: "Offline Voice Active",
        subtitle: "Bolo: Add task / Focus on / Change wallpaper...",
        icon: Icons.mic_rounded,
        accent: const Color(0xFF10B981),
        expand: true,
      );

      _speech.listen(
        listenOptions: stt.SpeechListenOptions(
          onDevice: true, // Forces 100% Offline Recognition
          partialResults: true,
        ),
        onResult: (result) {
          setState(() => _lastSpokenText = result.recognizedWords);
          if (result.finalResult) {
            _executeVoiceIntent(result.recognizedWords.toLowerCase());
          }
        },
      );
    }
  }

  void _executeVoiceIntent(String cmd) {
    if (cmd.contains("wallpaper") || cmd.contains("background")) {
      setState(() {
        _wallpaperIndex = (_wallpaperIndex + 1) % _wallpapers.length;
      });
      _triggerDynamicIsland(
        title: "3D Wallpaper Changed",
        subtitle: "Gyroscope Depth Theme #${_wallpaperIndex + 1}",
        icon: Icons.wallpaper_rounded,
        accent: Colors.purpleAccent,
      );
    } else if (cmd.contains("focus on") || cmd.contains("lock")) {
      setState(() => _focusLockEnabled = true);
      _triggerDynamicIsland(
        title: "Strict Focus Lock ON",
        subtitle: "Distractions blocked!",
        icon: Icons.lock_rounded,
        accent: Colors.amberAccent,
      );
    } else if (cmd.contains("focus off") || cmd.contains("unlock")) {
      setState(() => _focusLockEnabled = false);
      _triggerDynamicIsland(
        title: "Focus Lock OFF",
        subtitle: "All apps accessible",
        icon: Icons.lock_open_rounded,
        accent: Colors.cyanAccent,
      );
    } else if (cmd.contains("vault") || cmd.contains("hidden")) {
      setState(() => _ghostVaultUnlocked = !_ghostVaultUnlocked);
      _triggerDynamicIsland(
        title: _ghostVaultUnlocked ? "Ghost Vault Open" : "Ghost Vault Hidden",
        subtitle: "Secret app drawer toggled",
        icon: Icons.visibility_off_rounded,
        accent: Colors.tealAccent,
      );
    } else if (cmd.contains("add") || cmd.contains("task")) {
      final cleanTitle =
          cmd.replaceAll("add task", "").replaceAll("add", "").trim();
      if (cleanTitle.isNotEmpty) {
        final inTenMins = DateTime.now().add(const Duration(minutes: 10));
        setState(() {
          _tasks.add(ScheduleTask(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            title: cleanTitle.toUpperCase(),
            time: DateFormat('HH:mm').format(inTenMins),
          ));
        });
        _saveTasks();
        _triggerDynamicIsland(
          title: "Task Scheduled!",
          subtitle: "${cleanTitle.toUpperCase()} at ${DateFormat('hh:mm a').format(inTenMins)}",
          icon: Icons.check_circle_rounded,
          accent: const Color(0xFF10B981),
        );
      }
    } else {
      _triggerDynamicIsland(
        title: "Command Executed",
        subtitle: "\"$cmd\"",
        icon: Icons.bolt_rounded,
        accent: Colors.cyanAccent,
      );
    }
  }

  // Record User's Own Voice Warning
  Future<void> _toggleRecordOwnVoice() async {
    if (_isRecordingVoice) {
      final path = await _audioRecorder.stop();
      setState(() {
        _isRecordingVoice = false;
        _customVoicePath = path;
      });
      _triggerDynamicIsland(
        title: "Apni Aawaz Save Ho Gayi!",
        subtitle: "5-min late hone par yahi bajegi",
        icon: Icons.graphic_eq_rounded,
        accent: const Color(0xFF10B981),
      );
    } else {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final filePath = '${dir.path}/my_warning_voice.m4a';
        await _audioRecorder.start(const RecordConfig(), path: filePath);
        setState(() => _isRecordingVoice = true);
      }
    }
  }

  int get _disciplineScore {
    if (_tasks.isEmpty) return 100;
    final done = _tasks.where((t) => t.isCompleted).length;
    return ((done / _tasks.length) * 100).round();
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    _clockTimer?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _wallpapers[_wallpaperIndex];

    return PopScope(
      canPop: false, // Prevents accidental exit since this is the Home Launcher
      child: GestureDetector(
        onScaleUpdate: (details) {
          // Pinch Out Gesture to unlock Ghost Vault
          if (details.scale > 1.4 && !_ghostVaultUnlocked) {
            HapticFeedback.mediumImpact();
            setState(() => _ghostVaultUnlocked = true);
            _triggerDynamicIsland(
              title: "Ghost Vault Unlocked",
              subtitle: "Pinch-out gesture detected",
              icon: Icons.fingerprint_rounded,
              accent: Colors.cyanAccent,
            );
          }
        },
        onVerticalDragEnd: (details) {
          // Swipe Down for iOS Control Center
          if (details.primaryVelocity != null && details.primaryVelocity! > 400) {
            _openIOSControlCenter();
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              // LAYER 1: 3D Parallax Gyroscope Wallpaper
              AnimatedPositioned(
                duration: const Duration(milliseconds: 120),
                left: -30 + _gyroX,
                right: -30 - _gyroX,
                top: -30 + _gyroY,
                bottom: -30 - _gyroY,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(_gyroX / 30, _gyroY / 30),
                      radius: 1.3,
                      colors: colors,
                    ),
                  ),
                  child: CustomPaint(
                    painter: _DepthGridPainter(offsetX: _gyroX, offsetY: _gyroY),
                  ),
                ),
              ),

              // LAYER 2: Edge Notification Neon Glow
              if (_edgeGlowActive)
                IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: _islandAccent, width: 3.5),
                    ),
                  ),
                ),

              // LAYER 3: Main Launcher Workspace
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  child: Column(
                    children: [
                      // iPHONE DYNAMIC ISLAND NOTCH PILL
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _islandExpanded = !_islandExpanded);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutBack,
                          width: _islandExpanded
                              ? MediaQuery.of(context).size.width * 0.9
                              : 195,
                          height: _islandExpanded ? 78 : 36,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(40),
                            border: Border.all(
                              color: _islandExpanded
                                  ? _islandAccent.withOpacity(0.6)
                                  : Colors.white12,
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _islandAccent.withOpacity(0.25),
                                blurRadius: 18,
                                spreadRadius: 1,
                              )
                            ],
                          ),
                          child: Row(
                            children: [
                              Icon(_islandIcon, color: _islandAccent, size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _islandTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                    if (_islandExpanded)
                                      Text(
                                        _islandSubtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.white.withOpacity(0.75),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (_focusLockEnabled)
                                const Icon(Icons.shield_rounded,
                                    color: Colors.amberAccent, size: 15),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 22),

                      // iOS Depth Clock & Discipline Score
                      Transform.translate(
                        offset: Offset(_gyroX * 0.4, _gyroY * 0.4),
                        child: Column(
                          children: [
                            Text(
                              DateFormat('hh:mm').format(_now),
                              style: const TextStyle(
                                fontSize: 68,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -2,
                                height: 1.0,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  DateFormat('EEE, d MMM').format(_now),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white70,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.emerald.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: Colors.emeraldAccent
                                            .withOpacity(0.4)),
                                  ),
                                  child: Text(
                                    "Discipline: $_disciplineScore%",
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.emeraldAccent,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 18),

                      // OWN-VOICE WARNING STUDIO CARD
                      _GlassCard(
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: _toggleRecordOwnVoice,
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _isRecordingVoice
                                      ? Colors.roseAccent
                                      : const Color(0xFF38BDF8),
                                ),
                                child: Icon(
                                  _isRecordingVoice
                                      ? Icons.stop_rounded
                                      : Icons.mic_rounded,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _isRecordingVoice
                                        ? "Recording Your Voice..."
                                        : (_customVoicePath != null
                                            ? "Apni Warning Voice Set Hai ✅"
                                            : "Record Your Own Warning Voice"),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _isRecordingVoice
                                        ? "Bolo: 'Bhai kaam nahi hua, jaldi kar!'"
                                        : "5 min late hone par yahi aawaz bajegi",
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white60,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_customVoicePath != null && !_isRecordingVoice)
                              IconButton(
                                icon: const Icon(Icons.play_circle_fill_rounded,
                                    color: Colors.emeraldAccent),
                                onPressed: () async {
                                  await _audioPlayer.setReleaseMode(ReleaseMode.release);
                                  await _audioPlayer
                                      .play(DeviceFileSource(_customVoicePath!));
                                },
                              )
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // DAILY SCHEDULE LIST + ADD BUTTON
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "TODAY'S STRICT SCHEDULE",
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                              color: Colors.white60,
                            ),
                          ),
                          GestureDetector(
                            onTap: _showAddScheduleDialog,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF38BDF8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                "+ Add Time",
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Expanded(
                        child: ListView.builder(
                          itemCount: _tasks.length,
                          itemBuilder: (ctx, i) {
                            final t = _tasks[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _GlassCard(
                                child: Row(
                                  children: [
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          t.isCompleted = !t.isCompleted;
                                        });
                                        _saveTasks();
                                      },
                                      child: Icon(
                                        t.isCompleted
                                            ? Icons.check_circle_rounded
                                            : Icons.radio_button_unchecked,
                                        color: t.isCompleted
                                            ? Colors.emeraldAccent
                                            : Colors.white54,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            t.title,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              decoration: t.isCompleted
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                              color: t.isCompleted
                                                  ? Colors.white38
                                                  : Colors.white,
                                            ),
                                          ),
                                          Text(
                                            "Time: ${t.time} • 5-min auto-voice check",
                                            style: const TextStyle(
                                                fontSize: 10.5,
                                                color: Colors.cyanAccent),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18, color: Colors.white38),
                                      onPressed: () {
                                        setState(() => _tasks.removeAt(i));
                                        _saveTasks();
                                      },
                                    )
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                      // GHOST VAULT HIDDEN APPS (Visible only when unlocked)
                      if (_ghostVaultUnlocked)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.roseAccent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: Colors.roseAccent.withOpacity(0.4)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _appDockIcon(Icons.play_circle_fill, "YouTube",
                                  Colors.redAccent, blockedInFocus: true),
                              _appDockIcon(Icons.camera_alt_rounded, "Insta",
                                  Colors.pinkAccent, blockedInFocus: true),
                              _appDockIcon(Icons.sports_esports_rounded, "Games",
                                  Colors.orangeAccent, blockedInFocus: true),
                              IconButton(
                                icon: const Icon(Icons.lock_rounded,
                                    color: Colors.white70, size: 18),
                                onPressed: () =>
                                    setState(() => _ghostVaultUnlocked = false),
                              )
                            ],
                          ),
                        ),

                      // iPHONE GLASS DOCK + OFFLINE VOICE COMMAND MIC
                      ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _appDockIcon(Icons.menu_book_rounded, "Study",
                                    Colors.cyanAccent),
                                _appDockIcon(Icons.calculate_rounded, "Calc",
                                    Colors.amberAccent),
                                // CENTER OFFLINE VOICE COMMAND BUTTON
                                GestureDetector(
                                  onTap: _toggleOfflineVoiceCommand,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    width: 54,
                                    height: 54,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        colors: _isListening
                                            ? [
                                                Colors.roseAccent,
                                                Colors.orangeAccent
                                              ]
                                            : [
                                                const Color(0xFF38BDF8),
                                                const Color(0xFF2563EB)
                                              ],
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF38BDF8)
                                              .withOpacity(0.5),
                                          blurRadius: 15,
                                        )
                                      ],
                                    ),
                                    child: Icon(
                                      _isListening
                                          ? Icons.graphic_eq_rounded
                                          : Icons.mic_none_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                ),
                                _appDockIcon(Icons.wallpaper_rounded, "3D Wall",
                                    Colors.purpleAccent, onTapOverride: () {
                                  setState(() => _wallpaperIndex =
                                      (_wallpaperIndex + 1) % _wallpapers.length);
                                }),
                                _appDockIcon(Icons.tune_rounded, "Control",
                                    Colors.emeraldAccent,
                                    onTapOverride: _openIOSControlCenter),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // LAYER 4: SCHEDULE CHECK-IN & 5-MIN STRICT VOICE ALARM OVERLAY
              if (_activeCheckInTask != null)
                Container(
                  color: Colors.black.withOpacity(0.88),
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: _isStrictAlarmRinging
                              ? Colors.roseAccent
                              : Colors.amberAccent,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isStrictAlarmRinging
                                ? Icons.volume_up_rounded
                                : Icons.alarm_on_rounded,
                            size: 54,
                            color: _isStrictAlarmRinging
                                ? Colors.roseAccent
                                : Colors.amberAccent,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _isStrictAlarmRinging
                                ? "5 MINUTE HO GAYE! KAAM SHURU KAR!"
                                : "SCHEDULE TIME STARTED",
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _activeCheckInTask!.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF38BDF8),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _isStrictAlarmRinging
                                ? "Tumhari khud ki warning voice baj rahi hai!"
                                : "Agar 5 min me Continue nahi kiya toh tumhari aawaz me alarm bajega.",
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70),
                          ),
                          const SizedBox(height: 22),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.black,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16)),
                              ),
                              onPressed: _stopWarningAlarm,
                              child: const Text(
                                "CONTINUE & START WORK ✅",
                                style: TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 13),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appDockIcon(IconData icon, String label, Color color,
      {bool blockedInFocus = false, VoidCallback? onTapOverride}) {
    return GestureDetector(
      onTap: () {
        if (onTapOverride != null) {
          onTapOverride();
          return;
        }
        if (blockedInFocus && _focusLockEnabled) {
          _triggerDynamicIsland(
            title: "Blocked by Focus Lock!",
            subtitle: "Pehle apna schedule task poora karo",
            icon: Icons.block_rounded,
            accent: Colors.roseAccent,
          );
          return;
        }
        _triggerDynamicIsland(
          title: "Launching $label",
          subtitle: "Offline instant trigger",
          icon: icon,
          accent: color,
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.18),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 3),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.white70)),
        ],
      ),
    );
  }

  void _showAddScheduleDialog() {
    final titleCtrl = TextEditingController();
    TimeOfDay pickedTime = TimeOfDay.now();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text("New Strict Task",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  hintText: "Kaam likho (e.g. Maths Practice)",
                  filled: true,
                  fillColor: Colors.black45,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                tileColor: Colors.black45,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                title: Text("Time: ${pickedTime.format(ctx)}"),
                trailing: const Icon(Icons.access_time_rounded,
                    color: Color(0xFF38BDF8)),
                onTap: () async {
                  final t = await showTimePicker(
                      context: ctx, initialTime: pickedTime);
                  if (t != null) setDialogState(() => pickedTime = t);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () {
                if (titleCtrl.text.trim().isNotEmpty) {
                  final formatted =
                      "${pickedTime.hour.toString().padLeft(2, '0')}:${pickedTime.minute.toString().padLeft(2, '0')}";
                  setState(() {
                    _tasks.add(ScheduleTask(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      title: titleCtrl.text.trim(),
                      time: formatted,
                    ));
                  });
                  _saveTasks();
                  Navigator.pop(ctx);
                }
              },
              child: const Text("Save"),
            ),
          ],
        ),
      ),
    );
  }

  // iOS Style Control Center Bottom Sheet
  void _openIOSControlCenter() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
            color: Color(0xFF0F172A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10)),
              ),
              const SizedBox(height: 16),
              const Text("iOS Control Hub",
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text("Strict Focus Lock (Block Distractions)",
                    style: TextStyle(fontSize: 13)),
                value: _focusLockEnabled,
                activeColor: Colors.amberAccent,
                onChanged: (v) {
                  setState(() => _focusLockEnabled = v);
                  setSheetState(() {});
                },
              ),
              SwitchListTile(
                title: const Text("Ghost App Vault (Show Hidden Apps)",
                    style: TextStyle(fontSize: 13)),
                value: _ghostVaultUnlocked,
                activeColor: Colors.cyanAccent,
                onChanged: (v) {
                  setState(() => _ghostVaultUnlocked = v);
                  setSheetState(() {});
                },
              ),
              Row(
                children: [
                  const Icon(Icons.brightness_6_rounded, size: 20),
                  Expanded(
                    child: Slider(
                      value: _fakeBrightness,
                      onChanged: (v) =>
                          setSheetState(() => _fakeBrightness = v),
                    ),
                  ),
                  const Icon(Icons.volume_up_rounded, size: 20),
                  Expanded(
                    child: Slider(
                      value: _fakeVolume,
                      onChanged: (v) => setSheetState(() => _fakeVolume = v),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white12),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _DepthGridPainter extends CustomPainter {
  final double offsetX;
  final double offsetY;
  _DepthGridPainter({required this.offsetX, required this.offsetY});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.04)
      ..strokeWidth = 1;
    const step = 45.0;
    for (double x = (offsetX % step); x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = (offsetY % step); y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DepthGridPainter oldDelegate) => true;
}
