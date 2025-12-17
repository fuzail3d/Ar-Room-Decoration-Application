import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:url_launcher/url_launcher.dart';
import 'package:camera/camera.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:proj/services/ar_model_manager.dart';
import 'package:proj/widgets/model_selection_ui.dart';

// Helper types for node manipulation
enum _ManipulationMode { place, move, rotate, scale }

class _PlacedNodeState {
  final vector.Vector3? position;
  final double size;
  final int colorIndex;
  final dynamic rotation;

  _PlacedNodeState({this.position, required this.size, required this.colorIndex, this.rotation});

  _PlacedNodeState copyWith({vector.Vector3? position, double? size, int? colorIndex, dynamic rotation}) {
    return _PlacedNodeState(
      position: position ?? this.position,
      size: size ?? this.size,
      colorIndex: colorIndex ?? this.colorIndex,
      rotation: rotation ?? this.rotation,
    );
  }
}

class _RemoteModel {
  final String name;
  final String fileName;
  final String? thumbnailUrl;

  _RemoteModel({required this.name, required this.fileName, this.thumbnailUrl});
}

class ARCameraPage extends StatefulWidget {
  const ARCameraPage({super.key});

  @override
  State<ARCameraPage> createState() => _ARCameraPageState();
}

class _ARCameraPageState extends State<ARCameraPage> {
  static const double _defaultModelScale = 0.2;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  ArCoreController? arCoreController;
  int objectCount = 0;
  final List<ArCoreNode> placedNodes = [];
  String? _selectedNodeName;
  Map<String, _PlacedNodeState> _nodeStates = {};
  _ManipulationMode _mode = _ManipulationMode.place;
  bool _userChoseAr = false;
  bool _choiceShown = false;
  bool _arInitialized = false;
  Timer? _arWatchdog;

  // Fallback camera state
  List<CameraDescription>? _cameras;
  CameraController? _camController;
  bool _fallbackInitialized = false;

  // Gesture tracking
  double _rotationAngle = 0.0;
  double? _scaleBaseSize;
  bool _hasDetectedPlane = false;
  double? _pendingScaledSize;

  // Model management
  final ARModelManager _modelManager = ARModelManager();
  ARModel? _selectedModel;
  Set<String> _loadingModels = {};
  bool _isModelLoading = false;
  bool _isModelListLoading = false;
  List<_RemoteModel> _remoteModels = [];
  
  // Undo history - track state snapshots
  final List<Map<String, dynamic>> _undoHistory = [];

  @override
  void initState() {
    super.initState();
    _loadRemoteModels();
  }

  @override
  Widget build(BuildContext context) {
    // Show choice dialog once
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_choiceShown) {
        _choiceShown = true;
        _showPreArChoice();
      }
    });

    if (_userChoseAr) {
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        endDrawer: _buildObjectDrawer(),
        endDrawerEnableOpenDragGesture: false,
        drawerEdgeDragWidth: 0,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withOpacity(0.8),
              border: Border.all(color: Colors.red.withOpacity(0.5), width: 1),
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
        body: Stack(
          children: [
            GestureDetector(
              onScaleStart: (details) {
                if (_selectedNodeName == null) return;
                if (_mode == _ManipulationMode.rotate) {
                  // Reset rotation accumulator for this gesture
                  _rotationAngle = 0.0;
                } else if (_mode == _ManipulationMode.scale) {
                  // Capture base size to avoid compounding
                  final state = _nodeStates[_selectedNodeName!];
                  _scaleBaseSize = state?.size;
                }
              },
              onScaleUpdate: (ScaleUpdateDetails details) {
                if (_selectedNodeName == null) return;
                
                if (_mode == _ManipulationMode.rotate) {
                  // Only accumulate, don't update AR node yet
                  final deltaDx = details.focalPointDelta.dx;
                  _rotationAngle += deltaDx * 0.5;
                } else if (_mode == _ManipulationMode.scale) {
                  // Defer expensive AR updates: accumulate and apply once on end
                  final state = _nodeStates[_selectedNodeName!];
                  final base = _scaleBaseSize ?? state?.size;
                  if (state != null && base != null) {
                    final computed = (base * details.scale).clamp(0.05, 1.0);
                    _pendingScaledSize = computed.toDouble();
                  }
                }
              },
              onScaleEnd: (ScaleEndDetails details) {
                if (_selectedNodeName == null) return;
                if (_mode == _ManipulationMode.rotate) {
                  // Apply rotation only at end of gesture
                  _updateSelectedNodeRotation(_rotationAngle);
                } else if (_mode == _ManipulationMode.scale) {
                  // Apply a single size change to avoid duplicate anchors
                  final target = _pendingScaledSize;
                  _pendingScaledSize = null;
                  if (target != null) {
                    _updateSelectedNodeSize(target);
                  }
                }
              },
              child: ArCoreView(
                onArCoreViewCreated: _onArCoreViewCreated,
                enableTapRecognizer: true,
              ),
            ),

            // Top status bar
            Positioned(
              top: 50,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withOpacity(0.9),
                        Colors.grey.shade900.withOpacity(0.8),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.red.withOpacity(0.5), width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withOpacity(0.3),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.view_in_ar,
                        color: Colors.red.shade400,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'AR Mode Active',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.red.shade400,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withOpacity(0.6),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Control buttons bar (Place, Move, Rotate, Scale)
            Positioned(
              top: 115,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Colors.grey.withOpacity(0.3), width: 1),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _TopControlButton(
                            icon: Icons.add_box,
                            label: 'Place',
                            isActive: _mode == _ManipulationMode.place,
                            onPressed: () => setState(() {
                              _mode = _ManipulationMode.place;
                            }),
                          ),
                          const SizedBox(width: 6),
                          _TopControlButton(
                            icon: Icons.pan_tool,
                            label: 'Move',
                            isActive: _mode == _ManipulationMode.move,
                            onPressed: () => setState(() {
                              _mode = _ManipulationMode.move;
                            }),
                          ),
                          const SizedBox(width: 6),
                          _TopControlButton(
                            icon: Icons.rotate_90_degrees_ccw,
                            label: 'Rotate',
                            isActive: _mode == _ManipulationMode.rotate,
                            onPressed: () {
                              if (_selectedNodeName == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Place a cube first'),
                                    duration: Duration(seconds: 1),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              setState(() {
                                _mode = _ManipulationMode.rotate;
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          _TopControlButton(
                            icon: Icons.open_in_full,
                            label: 'Scale',
                            isActive: _mode == _ManipulationMode.scale,
                            onPressed: () {
                              if (_selectedNodeName == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Place a cube first'),
                                    duration: Duration(seconds: 1),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              setState(() {
                                _mode = _ManipulationMode.scale;
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.center,
                        child: _TopControlButton(
                          icon: Icons.refresh,
                          label: 'Refresh',
                          isActive: false,
                          onPressed: _refreshAllNodes,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Bottom instruction overlay
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withOpacity(0.6),
                        Colors.black.withOpacity(0.4),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.red.withOpacity(0.3), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.touch_app, color: Colors.red.shade400, size: 16),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _getInstructionText(),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Selection indicator
            if (_selectedNodeName != null)
              Positioned(
                bottom: 170,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.red.shade900.withOpacity(0.8),
                          Colors.red.shade700.withOpacity(0.8),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withOpacity(0.4),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.select_all, color: Colors.white, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          'Cube Selected',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Right-side bubble menu
            Positioned(
              bottom: 24,
              right: 12,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 500),
                child: _buildBubbleMenu(),
              ),
            ),

            // Object count badge (opens drawer when enabled)
            Positioned(
              top: 60,
              right: 20,
              child: GestureDetector(
                onTap: placedNodes.isNotEmpty ? _openObjectDrawer : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: placedNodes.isNotEmpty
                        ? LinearGradient(
                            colors: [
                              Colors.red.shade800.withOpacity(0.95),
                              Colors.red.shade600.withOpacity(0.95),
                            ],
                          )
                        : LinearGradient(
                            colors: [
                              Colors.grey.shade800.withOpacity(0.8),
                              Colors.grey.shade900.withOpacity(0.8),
                            ],
                          ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: placedNodes.isNotEmpty ? Colors.red.withOpacity(0.6) : Colors.grey.withOpacity(0.5),
                      width: 1,
                    ),
                    boxShadow: placedNodes.isNotEmpty
                        ? [
                            BoxShadow(
                              color: Colors.red.withOpacity(0.35),
                              blurRadius: 14,
                              spreadRadius: 2,
                            ),
                          ]
                        : [],
                  ),
                  child: Text(
                    '${placedNodes.length}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(placedNodes.isNotEmpty ? 1 : 0.4),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),

            // Model selector trigger (bottom-left)
            Positioned(
              bottom: 24,
              left: 16,
              child: FloatingActionButton.small(
                heroTag: 'modelPicker',
                backgroundColor: Colors.redAccent.withOpacity(0.9),
                onPressed: _showModelPickerSheet,
                child: const Icon(Icons.add, color: Colors.white),
              ),
            ),

            // Model loading indicator overlay
            if (_isModelLoading)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.4),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.red.withOpacity(0.5),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.withOpacity(0.3),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.red,
                            ),
                            strokeWidth: 3,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Loading Model...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Downloading and caching 3D model',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // Fallback camera UI
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withOpacity(0.6),
            border: Border.all(color: Colors.red.withOpacity(0.5), width: 1),
          ),
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.2),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.red.withOpacity(0.5), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber, color: Colors.red.shade300, size: 16),
              const SizedBox(width: 8),
              const Text(
                'Fallback Mode',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        centerTitle: true,
      ),
      body: _fallbackInitialized && _camController != null && _camController!.value.isInitialized
          ? CameraPreview(_camController!)
          : Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black, Colors.grey.shade900],
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Colors.red.shade300,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'AR Not Available',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        'AR Core not initialized or Play Services flow blocked',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.blue.shade600, Colors.purple.shade600],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withOpacity(0.4),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: ElevatedButton.icon(
                        onPressed: _showPreArChoice,
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        label: const Text(
                          'Try AR Again',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
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

  Future<void> _showPreArChoice() async {
    final choice = await showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('AR Mode'),
        content: const Text(
            'The AR experience requires Google Play Services for AR (ARCore).\n\n'
                'If you proceed, a Play Store page may appear to install/update AR Core.\n\n'
                'If that dialog gets stuck, choose "Fallback" to use a simple camera preview.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'fallback'), child: const Text('Fallback')),
          TextButton(onPressed: () => Navigator.pop(context, 'open_store'), child: const Text('Open Play Store')),
          ElevatedButton(onPressed: () => Navigator.pop(context, 'proceed'), child: const Text('Proceed to AR')),
        ],
      ),
    );

    if (choice == 'proceed') {
      // Check platform for ARCore presence before enabling AR view
      final bool installed = await _isArCoreInstalled();
      if (installed) {
        setState(() => _userChoseAr = true);
        _startArInitWatchdog();
      } else {
        // If not installed, prompt to open Play Store instead of trying to initialize AR
        final open = await showDialog<bool?>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('AR Core Not Installed'),
            content: const Text('Google Play Services for AR is not installed. Open Play Store to install it or use the fallback.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Fallback')),
              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open Play Store')),
            ],
          ),
        );

        if (open == true) {
          final Uri marketUri = Uri.parse('market://details?id=com.google.ar.core');
          final Uri webUri = Uri.parse('https://play.google.com/store/apps/details?id=com.google.ar.core');
          if (await canLaunchUrl(marketUri)) {
            await launchUrl(marketUri);
          } else {
            await launchUrl(webUri);
          }
          _choiceShown = false;
        } else {
          await _initFallbackCamera();
          setState(() => _userChoseAr = false);
        }
      }
    } else if (choice == 'open_store') {
      // Open Play Store page for AR
      final Uri marketUri = Uri.parse('market://details?id=com.google.ar.core');
      final Uri webUri = Uri.parse('https://play.google.com/store/apps/details?id=com.google.ar.core');
      if (await canLaunchUrl(marketUri)) {
        await launchUrl(marketUri);
      } else {
        await launchUrl(webUri);
      }
      // After user returns, show choice again
      _choiceShown = false;
    } else {
      // Fallback: initialize camera preview
      await _initFallbackCamera();
      setState(() => _userChoseAr = false);
    }
  }

  Future<bool> _isArCoreInstalled() async {
    try {
      final platform = MethodChannel('com.example.proj/arcore');
      final String availability = await platform.invokeMethod<String>('checkArCoreAvailability') ?? 'UNKNOWN';
      // availability will be an ArCoreApk.Availability.name, e.g. SUPPORTED_INSTALLED, SUPPORTED_NOT_INSTALLED
      if (availability.contains('SUPPORTED') && availability.contains('INSTALLED')) return true;
      return false;
    } catch (_) {
      // Fallback: try simple package presence check
      try {
        final platform = MethodChannel('com.example.proj/arcore');
        final installed = await platform.invokeMethod<bool>('isArCoreInstalled');
        return installed == true;
      } catch (_) {
        return false;
      }
    }
  }

  Future<void> _onArCoreViewCreated(ArCoreController controller) async {
    try {
      arCoreController = controller;
      arCoreController!.onPlaneTap = _handleOnPlaneTap;
      _arInitialized = true;
      _arWatchdog?.cancel();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AR Ready')));
    } catch (e) {
      // If the AR controller initialization fails, fall back to camera preview
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('AR init failed: $e')));
      await _initFallbackCamera();
      setState(() {
        _userChoseAr = false;
        _arInitialized = false;
      });
    }
  }

  String _getInstructionText() {
    switch (_mode) {
      case _ManipulationMode.place:
        return _hasDetectedPlane
            ? 'Tap on a detected surface to place a cube'
            : 'Move your phone to detect surfaces';
      case _ManipulationMode.move:
        return _selectedNodeName != null 
            ? 'Tap a new surface to move the cube'
            : 'Select a cube first, then tap to move';
      case _ManipulationMode.rotate:
        return 'Select a cube and tap Rotate to adjust';
      case _ManipulationMode.scale:
        return 'Select a cube and tap Scale to resize';
    }
  }

  void _openObjectDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  Widget _buildObjectDrawer() {
    return Drawer(
      backgroundColor: Colors.black.withOpacity(0.92),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Objects (${placedNodes.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            if (placedNodes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No objects yet. Tap Place to add a cube.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: placedNodes.length,
                  itemBuilder: (context, index) {
                    final node = placedNodes[index];
                    final name = node.name ?? 'Object ${index + 1}';
                    final state = _nodeStates[name];
                    final color = state != null ? _colorForIndex(state.colorIndex) : Colors.grey.shade700;
                    final isSelected = _selectedNodeName == name;
                    final sizeLabel = state != null ? state.size.toStringAsFixed(2) : '--';

                    return ListTile(
                      leading: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                      ),
                      title: Text(
                        name,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        'Size: $sizeLabel m',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Colors.redAccent, size: 18)
                          : const SizedBox.shrink(),
                      onTap: () {
                        setState(() {
                          _selectedNodeName = name;
                        });
                        Navigator.of(context).maybePop();
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _startArInitWatchdog() {
    _arInitialized = false;
    _arWatchdog?.cancel();
    _arWatchdog = Timer(const Duration(seconds: 6), () async {
      if (!_arInitialized) {
        if (!mounted) return;
        final choice = await showDialog<String?>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('AR Initialization Problem'),
            content: const Text('AR did not initialize. The Play Store popup may have blocked the flow. Choose Fallback to use the camera preview or Open Play Store to try installing AR services.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, 'fallback'), child: const Text('Fallback')),
              TextButton(onPressed: () => Navigator.pop(context, 'open_store'), child: const Text('Open Play Store')),
              ElevatedButton(onPressed: () => Navigator.pop(context, 'retry'), child: const Text('Retry')),
            ],
          ),
        );

        if (choice == 'fallback') {
          await _initFallbackCamera();
          setState(() {
            _userChoseAr = false;
            _arInitialized = false;
          });
        } else if (choice == 'open_store') {
          final Uri marketUri = Uri.parse('market://details?id=com.google.ar.core');
          final Uri webUri = Uri.parse('https://play.google.com/store/apps/details?id=com.google.ar.core');
          if (await canLaunchUrl(marketUri)) {
            await launchUrl(marketUri);
          } else {
            await launchUrl(webUri);
          }
          _choiceShown = false;
        } else {
          // retry: reset to show choice again
          setState(() {
            _userChoseAr = false;
          });
          _choiceShown = false;
        }
      }
    });
  }

  Future<void> _initFallbackCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        _camController = CameraController(_cameras!.first, ResolutionPreset.medium, enableAudio: false);
        await _camController!.initialize();
        _fallbackInitialized = true;
      }
    } catch (e) {
      _fallbackInitialized = false;
    }
  }

  void _handleOnPlaneTap(List<ArCoreHitTestResult> hits) async {
    // Enforce plane-only interactions for accurate placement/move
    if (hits.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No surface detected here. Scan a flat area.')),
        );
      }
      return;
    }

    _hasDetectedPlane = true;
    final hit = hits.first;
    final position = vector.Vector3(
      hit.pose.translation.x,
      hit.pose.translation.y,
      hit.pose.translation.z,
    );

    try {
      if (_mode == _ManipulationMode.place || _selectedNodeName == null) {
        // Place new node - save snapshot first
        _saveSnapshot();

        // Check if a model is selected; if not, refuse placement
        if (_selectedModel != null) {
          debugPrint('📍 TRACE: [PLACE] Placing model ${_selectedModel!.name}');
          await _placeModelNode(_selectedModel!, position);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Select a model before placing.')),
            );
          }
          return;
        }
      } else if (_mode == _ManipulationMode.move) {
        // Move selected node to tapped position - save snapshot first
        _saveSnapshot();
        if (_selectedNodeName != null) {
          final name = _selectedNodeName!;
          final state = _nodeStates[name];
          if (state != null) {
            // Remove existing node and re-add at new position (models only)
            debugPrint('🔀 TRACE: [MOVE] Moving "$name". placedNodes before: ${placedNodes.length}');
            await _removeNodeIfExists(name);
            if (name.startsWith('model_')) {
              final fileName = name.substring(6, name.lastIndexOf('_'));
              final node = await _modelManager.createModelNode(
                modelName: fileName,
                position: position,
                nodeName: name,
                rotation: state.rotation,
                scale: vector.Vector3(state.size, state.size, state.size),
              );
              debugPrint('🔀 TRACE: [MOVE] Node recreated. Adding to arCoreController...');
              await arCoreController?.addArCoreNodeWithAnchor(node);
              _nodeStates[name] = state.copyWith(position: node.position?.value);
              _replaceNodeInList(name, node);
              debugPrint('🔀 TRACE: [MOVE] Complete. placedNodes after: ${placedNodes.length}');
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Only model nodes can be moved.')),
                );
              }
            }
            setState(() {});
          }
        }
      }
      // Don't do anything on tap when in rotate or scale mode - use gizmo controls instead
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Node operation failed: $e')));
    }
  }

  /// Handle model selection and preload
  Future<void> _handleModelSelected(ARModel model) async {
    if (_loadingModels.contains(model.fileName)) return;

    setState(() {
      _loadingModels.add(model.fileName);
      _isModelLoading = true;
    });

    try {
      // Preload the model from Firebase
      await _modelManager.preloadModel(model.fileName);

      if (mounted) {
        setState(() {
          _selectedModel = model;
          _loadingModels.remove(model.fileName);
          _isModelLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${model.name} ready to place'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingModels.remove(model.fileName);
          _isModelLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load ${model.name}: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  /// Place a 3D model node at the given position
  Future<void> _placeModelNode(ARModel model, vector.Vector3 position) async {
    try {
      final name = 'model_${model.fileName}_$objectCount';
      debugPrint('📍 TRACE: [PLACE] Creating node with name "$name". objectCount: $objectCount, placedNodes: ${placedNodes.length}');
      final node = await _modelManager.createModelNode(
        modelName: model.fileName,
        position: position,
        nodeName: name,
        scale: vector.Vector3.all(_defaultModelScale),
      );

      if (node is ArCoreReferenceNode) {
        debugPrint('📍 TRACE: [PLACE] Node created successfully. Adding to arCoreController...');
        await arCoreController?.addArCoreNodeWithAnchor(node);
        placedNodes.add(node);
        _nodeStates[name] = _PlacedNodeState(
          position: node.position?.value,
          size: _defaultModelScale,
          colorIndex: objectCount,
        );

        debugPrint('📍 TRACE: [PLACE] Complete. placedNodes: ${placedNodes.length}, objectCount will increment to ${objectCount + 1}');
        setState(() {
          objectCount++;
          _selectedNodeName = name;
        });
      }
    } catch (e) {
      debugPrint('❌ TRACE: [PLACE] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to place model: $e')),
        );
      }
    }
  }

  Color _colorForIndex(int index) {
    const list = [Colors.red, Colors.green, Colors.blue, Colors.yellow, Colors.purple, Colors.cyan];
    return list[index % list.length];
  }

  Future<void> _loadRemoteModels() async {
    setState(() => _isModelListLoading = true);
    try {
      final files = await _modelManager.listModelFiles();
      final models = files.map((file) {
        final base = file.replaceAll(RegExp(r'\.glb$', caseSensitive: false), '');
        final thumb = _modelManager.getThumbnailUrl(file);
        return _RemoteModel(name: base, fileName: file, thumbnailUrl: thumb);
      }).toList();
      if (mounted) {
        setState(() {
          _remoteModels = models;
        });
      }
    } catch (e) {
      debugPrint('❌ TRACE: [MODELS] Failed to load: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load models: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isModelListLoading = false);
      }
    }
  }

  void _showModelPickerSheet() {
    // Refresh list if empty and not currently loading
    if (_remoteModels.isEmpty && !_isModelListLoading) {
      _loadRemoteModels();
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        if (_isModelListLoading) {
          return const SizedBox(
            height: 220,
            child: Center(
              child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.red)),
            ),
          );
        }

        if (_remoteModels.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No models found in Supabase storage.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          );
        }

        return SizedBox(
          height: 320,
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.9,
            ),
            itemCount: _remoteModels.length,
            itemBuilder: (context, index) {
              final model = _remoteModels[index];
              final isLoading = _loadingModels.contains(model.fileName);
              final isSelected = _selectedModel?.fileName == model.fileName;

              return GestureDetector(
                onTap: isLoading
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _handleModelSelected(
                          ARModel(
                            name: model.name,
                            fileName: model.fileName,
                            thumbnailUrl: model.thumbnailUrl,
                          ),
                        );
                      },
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected ? Colors.redAccent : Colors.white24,
                      width: isSelected ? 2 : 1,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: Colors.red.withOpacity(0.35),
                              blurRadius: 12,
                              spreadRadius: 2,
                            ),
                          ]
                        : [],
                  ),
                  child: Stack(
                    children: [
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (model.thumbnailUrl != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(
                                model.thumbnailUrl!,
                                height: 80,
                                width: 80,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.view_in_ar, color: Colors.white70, size: 48),
                              ),
                            )
                          else
                            const Icon(Icons.view_in_ar, color: Colors.white70, size: 48),
                          const SizedBox(height: 10),
                          Text(
                            model.name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                      if (isLoading)
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                          ),
                        ),
                      if (isSelected && !isLoading)
                        const Positioned(
                          top: 8,
                          right: 8,
                          child: Icon(Icons.check_circle, color: Colors.redAccent, size: 18),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  // Save current state snapshot for undo
  void _saveSnapshot() {
    _undoHistory.add({
      'nodeStates': Map<String, _PlacedNodeState>.from(_nodeStates),
      'placedNodes': List<ArCoreNode>.from(placedNodes),
      'objectCount': objectCount,
      'selectedNode': _selectedNodeName,
    });
    // Keep only last 10 snapshots
    if (_undoHistory.length > 10) {
      _undoHistory.removeAt(0);
    }
  }

  // Keep placedNodes list in sync when we recreate nodes (move/scale/rotate).
  void _replaceNodeInList(String name, ArCoreNode node) {
    final index = placedNodes.indexWhere((n) => n.name == name);
    debugPrint('🔄 TRACE: _replaceNodeInList "$name" - found at index $index. placedNodes before: ${placedNodes.length}');
       
       // Remove the old node from list if it exists
       if (index >= 0) {
         placedNodes.removeAt(index);
         debugPrint('🔄 TRACE: Removed old node at index $index. placedNodes after removal: ${placedNodes.length}');
       }
       
       // Add the new node
       placedNodes.add(node);
       debugPrint('🔄 TRACE: Added new node. placedNodes after: ${placedNodes.length}');
       debugPrint('🔄 TRACE: Final placedNodes list: ${placedNodes.map((n) => n.name).toList()}');
     }

  // Best-effort removal with a short pause to avoid duplicate anchors before re-adding.
  Future<void> _removeNodeIfExists(String name) async {
    try {
      debugPrint('🗑️ TRACE: Removing node "$name". Current placedNodes count: ${placedNodes.length}');
      await arCoreController?.removeNode(nodeName: name);
      debugPrint('🗑️ TRACE: Node "$name" removed from arCoreController.');
      // Give the native side a bit more time to tear down the anchor before re-adding.
      await Future.delayed(const Duration(milliseconds: 160));
      debugPrint('🗑️ TRACE: Post-removal delay completed for "$name". placedNodes: ${placedNodes.length}');
    } catch (e) {
      debugPrint('❌ TRACE: Failed to remove "$name": $e');
    }
  }

  Future<void> _undoLast() async {
    if (_undoHistory.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to undo')));
      return;
    }
    
    // Get previous state
    final previousState = _undoHistory.removeLast();
    
    // Clear all current nodes
    for (final node in placedNodes) {
      try {
        await arCoreController?.removeNode(nodeName: node.name);
      } catch (e) {
        // ignore errors
      }
    }
    
    // Restore previous state
    placedNodes.clear();
    placedNodes.addAll(previousState['placedNodes'] as List<ArCoreNode>);
    _nodeStates = previousState['nodeStates'] as Map<String, _PlacedNodeState>;
    objectCount = previousState['objectCount'] as int;
    _selectedNodeName = previousState['selectedNode'] as String?;
    
    // Re-add all nodes
    for (final node in placedNodes) {
      try {
        await arCoreController?.addArCoreNodeWithAnchor(node);
      } catch (e) {
        // ignore errors
      }
    }
    
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Undo applied')));
    }
  }

  Future<void> _clearAll() async {
    for (final node in List<ArCoreNode>.from(placedNodes)) {
      await arCoreController?.removeNode(nodeName: node.name);
    }
    placedNodes.clear();
    _nodeStates.clear();
    setState(() {
      objectCount = 0;
      _selectedNodeName = null;
    });
  }

  Future<void> _updateSelectedNodeRotation(double angleInDegrees) async {
    if (_selectedNodeName == null || arCoreController == null) return;
    
    final name = _selectedNodeName!;
    final state = _nodeStates[name];
    if (state == null) return;

    try {
      debugPrint('🔄 TRACE: [ROTATE] Starting rotation for "$name". placedNodes: ${placedNodes.length}, _nodeStates: ${_nodeStates.length}');
      
      // Use proper quaternion for Y-axis (vertical) rotation
      // Quaternion: (x, y, z, w) where w is scalar part
      final radians = angleInDegrees * (3.14159 / 180.0);
      final halfAngle = radians / 2.0;
      final qw = math.cos(halfAngle);
      final qy = math.sin(halfAngle);
      
      // Remove and re-add with new rotation
      debugPrint('🔄 TRACE: [ROTATE] Removing node before recreation...');
      await _removeNodeIfExists(name);
      if (name.startsWith('model_')) {
        final fileName = name.substring(6, name.lastIndexOf('_'));
        final newRotation = vector.Vector4(0.0, qy, 0.0, qw);
        debugPrint('🔄 TRACE: [ROTATE] Creating new node with rotation. File: $fileName');
        final node = await _modelManager.createModelNode(
          modelName: fileName,
          position: state.position!,
          nodeName: name,
          rotation: newRotation,
          scale: vector.Vector3(state.size, state.size, state.size),
        );
        debugPrint('🔄 TRACE: [ROTATE] Node created: ${node.name}. Adding to arCoreController...');
        await arCoreController?.addArCoreNodeWithAnchor(node);
        _nodeStates[name] = state.copyWith(rotation: newRotation);
        _replaceNodeInList(name, node);
        debugPrint('🔄 TRACE: [ROTATE] Complete. placedNodes: ${placedNodes.length}, _nodeStates: ${_nodeStates.length}');
        setState(() {});
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Only model nodes can be rotated.')),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ TRACE: [ROTATE] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rotate failed: $e')));
      }
    }
  }

  Future<void> _updateSelectedNodeSize(double newSize) async {
    if (_selectedNodeName == null || arCoreController == null) return;
    
    final name = _selectedNodeName!;
    final state = _nodeStates[name];
    if (state == null) return;

    try {
      debugPrint('📏 TRACE: [SCALE] Starting scale for "$name" to size $newSize. placedNodes: ${placedNodes.length}, _nodeStates: ${_nodeStates.length}');
      await _removeNodeIfExists(name);
      if (name.startsWith('model_')) {
        final fileName = name.substring(6, name.lastIndexOf('_'));
        final newScale = vector.Vector3(newSize, newSize, newSize);
        debugPrint('📏 TRACE: [SCALE] Creating new node with scale $newSize. File: $fileName');
        final node = await _modelManager.createModelNode(
          modelName: fileName,
          position: state.position!,
          nodeName: name,
          rotation: state.rotation,
          scale: newScale,
        );
        debugPrint('📏 TRACE: [SCALE] Node created: ${node.name}, scale param: $newScale. Adding to arCoreController...');
        await arCoreController?.addArCoreNodeWithAnchor(node);
        _nodeStates[name] = state.copyWith(size: newSize);
        _replaceNodeInList(name, node);
        debugPrint('📏 TRACE: [SCALE] Complete. placedNodes: ${placedNodes.length}, _nodeStates: ${_nodeStates.length}');
        setState(() {});
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Only model nodes can be scaled.')),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ TRACE: [SCALE] Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scale failed: $e')));
      }
    }
  }

  /// Refresh all nodes in the scene without deleting state
  Future<void> _refreshAllNodes() async {
    if (placedNodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No nodes to refresh')),
      );
      return;
    }

    debugPrint('🔄 TRACE: [REFRESH] Starting refresh of ${placedNodes.length} nodes');
    
    try {
      // Remove all nodes from the scene
      final nodeNames = placedNodes.map((n) => n.name).toList();
      for (final name in nodeNames) {
         if (name != null) {
           await _removeNodeIfExists(name);
         }
      }
      
      // Clear the placed nodes list
      placedNodes.clear();
      
      debugPrint('🔄 TRACE: [REFRESH] All nodes removed. Recreating from state...');
      
      // Recreate all nodes from _nodeStates
      for (final MapEntry(key: name, value: state) in _nodeStates.entries) {
        if (name.startsWith('model_')) {
          final fileName = name.substring(6, name.lastIndexOf('_'));
          final node = await _modelManager.createModelNode(
            modelName: fileName,
            position: state.position,
            nodeName: name,
            rotation: state.rotation,
            scale: vector.Vector3(state.size, state.size, state.size),
          );
          await arCoreController?.addArCoreNodeWithAnchor(node);
          placedNodes.add(node);
          debugPrint('🔄 TRACE: [REFRESH] Recreated node "$name"');
        }
      }
      
      setState(() {});
      
      debugPrint('🔄 TRACE: [REFRESH] Complete. placedNodes: ${placedNodes.length}, _nodeStates: ${_nodeStates.length}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Refreshed ${placedNodes.length} nodes')),
      );
    } catch (e) {
      debugPrint('❌ TRACE: [REFRESH] Error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Refresh failed: $e')),
      );
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedNodeName == null) return;
    
    final nameToDelete = _selectedNodeName!;
    try {
      await arCoreController?.removeNode(nodeName: nameToDelete);
      placedNodes.removeWhere((node) => node.name == nameToDelete);
      _nodeStates.remove(nameToDelete);
      
      setState(() {
        _selectedNodeName = null;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cube deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  // Build bubble menu with action buttons
  Widget _buildBubbleMenu() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BubbleButton(
            icon: Icons.undo,
            label: 'Undo',
            onPressed: _undoLast,
            color: Colors.grey.shade700,
          ),
          const SizedBox(height: 8),
          _BubbleButton(
            icon: Icons.delete_outline,
            label: 'Delete',
            onPressed: _deleteSelected,
            color: Colors.grey.shade700,
          ),
          const SizedBox(height: 8),
          _BubbleButton(
            icon: Icons.delete,
            label: 'Clear',
            onPressed: _clearAll,
            color: Colors.grey.shade700,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    arCoreController?.dispose();
    _camController?.dispose();
    _arWatchdog?.cancel();
    super.dispose();
  }
}

// Custom bubble button widget
class _BubbleButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color color;

  const _BubbleButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.color,
  });

  @override
  State<_BubbleButton> createState() => _BubbleButtonState();
}

class _BubbleButtonState extends State<_BubbleButton> with SingleTickerProviderStateMixin {
  late AnimationController _hoverController;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(duration: const Duration(milliseconds: 200), vsync: this);
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        onEnter: (_) => _hoverController.forward(),
        onExit: (_) => _hoverController.reverse(),
        child: ScaleTransition(
          scale: Tween<double>(begin: 1, end: 1.1).animate(
            CurvedAnimation(parent: _hoverController, curve: Curves.easeOut),
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withOpacity(0.4),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: FloatingActionButton.small(
              heroTag: widget.label,
              onPressed: widget.onPressed,
              backgroundColor: widget.color,
              elevation: 6,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              child: Icon(widget.icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

// Arrow button for gizmo controls (rotate/scale)
class _ArrowButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onPressed;

  const _ArrowButton({
    required this.icon,
    required this.color,
    required this.size,
    required this.onPressed,
  });

  @override
  State<_ArrowButton> createState() => _ArrowButtonState();
}

class _ArrowButtonState extends State<_ArrowButton> with SingleTickerProviderStateMixin {
  late AnimationController _pressController;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(duration: const Duration(milliseconds: 150), vsync: this);
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  void _handlePress() {
    _pressController.forward().then((_) {
      _pressController.reverse();
    });
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween<double>(begin: 0.9, end: 1).animate(
        CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
      ),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withOpacity(0.8),
              blurRadius: 16,
              spreadRadius: 3,
            ),
          ],
        ),
        child: FloatingActionButton(
          heroTag: '${widget.icon}_${widget.color.value}',
          onPressed: _handlePress,
          backgroundColor: widget.color,
          elevation: 12,
          child: Icon(widget.icon, color: Colors.white, size: widget.size * 0.5),
        ),
      ),
    );
  }
}

// Top control button widget for Place/Move/Rotate/Scale
class _TopControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onPressed;

  const _TopControlButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? Colors.red.shade700 : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? Colors.red.shade400 : Colors.grey.shade600,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
