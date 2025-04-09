// lib/camera_screen.dart
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'dart:io';
import 'medication_reader_screen.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraScreen({Key? key, required this.cameras}) : super(key: key);

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    _controller = CameraController(
      widget.cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _initializeControllerFuture = _controller!.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
    }).catchError((e) {
      debugPrint('Error initializing camera: $e');
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capturePhoto() async {
    if (_isCapturing) return;
    if (_controller == null || !_controller!.value.isInitialized) return;

    setState(() {
      _isCapturing = true;
    });

    try {
      await _initializeControllerFuture;

      final XFile file = await _controller!.takePicture();
      final String filePath = file.path;

      if (!mounted) return;

      // Navigate directly to MedicationReaderScreen with the image path
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MedicationReaderScreen(
            imagePath: filePath,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error capturing photo: $e');
    } finally {
      setState(() {
        _isCapturing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final screenSize = MediaQuery.of(context).size;
    final cameraAspectRatio = _controller!.value.aspectRatio;
    final screenAspectRatio = screenSize.height / screenSize.width;

    return Scaffold(
      body: Stack(
          fit: StackFit.expand,
            children: [
              OverflowBox(
                maxHeight: screenAspectRatio > cameraAspectRatio
                    ? screenSize.height
                    : screenSize.width / cameraAspectRatio,
                maxWidth: screenAspectRatio > cameraAspectRatio
                    ? screenSize.height * cameraAspectRatio
                    : screenSize.width,
                  child: CameraPreview(_controller!),
                ),
      Positioned(
        bottom: 40,
        left: 0,
        right: 0,
        child: Center(
          child: FloatingActionButton(
            onPressed: _capturePhoto,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            child: Icon(
              _isCapturing ? Icons.hourglass_bottom : Icons.camera_alt,
              size: 30,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
