// ocr_screen.dart
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'nlp_screen.dart';

class OcrScreen extends StatefulWidget {
  final String imagePath;
  const OcrScreen({Key? key, required this.imagePath}) : super(key: key);

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> {
  String extractedText = '';
  bool isProcessing = true;

  @override
  void initState() {
    super.initState();
    _performOCR();
  }

  Future<void> _performOCR() async {
    try {
      final inputImage = InputImage.fromFilePath(widget.imagePath);
      final textRecognizer =
          TextRecognizer(script: TextRecognitionScript.latin);
      final recognizedText = await textRecognizer.processImage(inputImage);

      setState(() {
        extractedText = recognizedText.text;
        isProcessing = false;
      });

      // Make sure to close the recognizer to free resources
      textRecognizer.close();
    } catch (e) {
      print('Error performing OCR: $e');
      setState(() {
        isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Extracted Text')),
      body: isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  // Show the extracted text
                  Expanded(
                    child: SingleChildScrollView(
                      child: Text(extractedText),
                    ),
                  ),
                  // Button to analyze the extracted text
                  ElevatedButton(
                    onPressed: () {
                      // Navigate to the NLP screen, passing the extracted text.
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              NlpScreen(ocrText: extractedText),
                        ),
                      );
                    },
                    child: const Text('Process Medications'),
                  ),
                ],
              ),
            ),
    );
  }
}
