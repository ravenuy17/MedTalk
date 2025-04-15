// lib/main.dart
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_application_1/pages/login_or_register_screen.dart';
import 'package:flutter_application_1/pages/login_screen.dart';
import 'pages/camera_screen.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medication Scanner',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: CameraScreen(cameras: cameras),
      //home: LoginOrRegisterScreen(),
    );
  }
}
