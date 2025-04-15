import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_application_1/services/mongo_service.dart';

class MedicationReaderScreen extends StatefulWidget {
  final String imagePath;

  const MedicationReaderScreen({Key? key, required this.imagePath})
      : super(key: key);

  @override
  State<MedicationReaderScreen> createState() => _MedicationReaderScreenState();
}

String toTitleCase(String input) {
  final cleaned = input.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
  if (cleaned.isEmpty) return cleaned;
  return cleaned
      .split(' ')
      .map((word) =>
          word.isNotEmpty ? word[0].toUpperCase() + word.substring(1) : '')
      .join(' ');
}

class _MedicationReaderScreenState extends State<MedicationReaderScreen> {
  bool isLoading = true;
  String extractedText = '';
  List<String> recognizedMedications = [];
  final FlutterTts flutterTts = FlutterTts();
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _voiceSearchQuery = '';
  List<String> _lines = [];
  int _currentLineIndex = -1;
  bool _isReadingAll = false;

  // Holds the medication dictionary from the database.
  // Expected to map: Brand Name -> Generic Name
  Map<String, String> _medicationMap = {};

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _initTts();
    _processMedication();
  }

  Future<void> _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);

    // Handler to move to the next line when TTS finishes speaking
    flutterTts.setCompletionHandler(() {
      if (_isReadingAll) {
        _currentLineIndex++;
        if (_currentLineIndex < _lines.length) {
          _speakLine(_currentLineIndex);
        } else {
          _isReadingAll = false;
        }
      }
    });
  }

  @override
  void dispose() {
    flutterTts.stop();
    super.dispose();
  }

  // -------------------- OCR -------------------- //

  Future<void> _performOCR() async {
    try {
      final inputImage = InputImage.fromFilePath(widget.imagePath);
      final textRecognizer =
          TextRecognizer(script: TextRecognitionScript.latin);

      try {
        final recognizedText = await textRecognizer.processImage(inputImage);
        extractedText = recognizedText.text.trim();
        debugPrint("OCR text: $extractedText");
      } finally {
        textRecognizer.close();
      }
    } catch (e) {
      throw Exception("OCR failed: ${e.toString()}");
    }
  }

  Future<Map<String, String>> _loadMedicationMap() async {
    try {
      // Connect to MongoDB
      final mongoService = MongoService();
      await mongoService.connect();

      // Fetch medication map (Brand Name -> Generic Name)
      final brandToGenericName = await mongoService.fetchMedicationMap();

      // Close the connection
      await mongoService.close();

      return brandToGenericName;
    } catch (e) {
      throw Exception("Failed to load medication map: $e");
    }
  }

  // -------------------- MAIN PROCESSING -------------------- //

  Future<void> _processMedication() async {
    try {
      await _performOCR();
      if (extractedText.isEmpty) throw Exception("No text extracted");

      // Load the medication dictionary from the database
      final brandToGenericName = await _loadMedicationMap();
      _medicationMap = brandToGenericName;

      // Extract generic names from the recognized text using the medication dictionary.
      // If the OCR text contains a known Brand Name, its Generic Name is added.
      recognizedMedications =
          _extractMedicationsFromText(extractedText, _medicationMap);

      _lines = extractedText
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();

      // Store extracted data in MongoDB
      final mongoService = MongoService();
      await mongoService.connect();
      await mongoService.insertMedication({
        "text": extractedText,
        "medications": recognizedMedications,
        "timestamp": DateTime.now().toIso8601String(),
      });
      await mongoService.close();

      // Provide spoken feedback for OCR results and extracted medication names.
      if (_lines.isNotEmpty) await _speak("Text found on the medication box.");
      if (recognizedMedications.isNotEmpty) {
        await _speak("Found medications: ${recognizedMedications.join(", ")}");
      } else {
        await _speak("No matching medications found.");
      }

      // Automatically read the entire text line by line.
      await _readAllText();
    } catch (e) {
      debugPrint("Error: $e");
      setState(() {
        extractedText = "Error: ${e.toString()}";
        _lines = [extractedText];
        isLoading = false;
      });
      await _speak("An error occurred: ${e.toString()}");
    }

    if (mounted) setState(() => isLoading = false);
  }

  // -------------------- MEDICATION EXTRACTION -------------------- //

  /// Compare the recognized text against the (Brand Name -> Generic Name) map.
  /// If the OCR text contains a known Brand Name, add its Generic Name to the result.
  List<String> _extractMedicationsFromText(
    String text,
    Map<String, String> brandToGenericName,
  ) {
    final foundMedications = <String>[];
    final lowerText = text.toLowerCase();

    brandToGenericName.forEach((brand, genericName) {
      if (lowerText.contains(brand.toLowerCase())) {
        foundMedications.add(genericName);
      }
    });

    // Remove duplicates by converting to a set, then back to list.
    return foundMedications.toSet().toList();
  }

  // -------------------- TTS HELPERS -------------------- //

  Future<void> _speak(String message) async {
    try {
      await flutterTts.speak(message);
    } catch (e) {
      debugPrint("TTS Error: $e");
    }
  }

  /// Speaks a single line by index.
  Future<void> _speakLine(int index) async {
    if (index < 0 || index >= _lines.length) return;
    setState(() => _currentLineIndex = index);
    await flutterTts.speak(_lines[index]);
  }

  // -------------------- READ ALL TEXT -------------------- //

  /// Reads all lines one by one.
  Future<void> _readAllText() async {
    if (_lines.isEmpty) {
      await _speak("No text to read.");
      return;
    }
    _isReadingAll = true;
    _currentLineIndex = 0;
    await _speakLine(_currentLineIndex);
  }

  // -------------------- SPEECH RECOGNITION -------------------- //

  /// Starts or stops listening for voice input.
  Future<void> _toggleListening() async {
    if (!_isListening) {
      // Initialize speech recognition
      bool available = await _speech.initialize(
        onStatus: (status) => debugPrint('onStatus: $status'),
        onError: (error) => debugPrint('onError: $error'),
      );

      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) {
            setState(() {
              _voiceSearchQuery = val.recognizedWords;
            });
          },
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  /// Searches the medication dictionary using the voice query.
  /// It checks if the query matches any Brand Name or Generic Name in the database.
  Future<void> _searchByVoiceQuery() async {
    if (_voiceSearchQuery.isEmpty) {
      await _speak("Please say a medication name first.");
      return;
    }
    final query = toTitleCase(_voiceSearchQuery);
    bool found = false;

    // Loop through the medication dictionary and check for matches.
    for (var entry in _medicationMap.entries) {
      final brand = toTitleCase(entry.key);
      final genericName = toTitleCase(entry.value);
      if (brand.contains(query) || genericName.contains(query)) {
        found = true;
        await _speak(
            "Medication ${entry.key} found. Its generic name is ${entry.value}.");
      }
    }
    if (!found) {
      await _speak("No medication matching $query was found in the database.");
    }
  }

  // -------------------- UI -------------------- //

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: const Color(0xFF1f4f89),
      elevation: 0,
      title: null,
      leading: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0xFF1f4f89)),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    ),
    body: isLoading
        ? const Center(child: CircularProgressIndicator())
        : Container(
            color: const Color(0xFF1f4f89),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black12,
                            blurRadius: 8,
                            offset: Offset(0, 4),
                          )
                        ],
                      ),
                      child: ListView(
                        padding: const EdgeInsets.all(16.0),
                        children: [
                          Text(
                            extractedText.isNotEmpty
                                ? "Extracted Text (line by line):"
                                : "No text recognized.",
                            style: const TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          for (int i = 0; i < _lines.length; i++)
                            Container(
                              color: i == _currentLineIndex
                                  ? Colors.yellow.withOpacity(0.5)
                                  : Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(_lines[i]),
                            ),
                          const SizedBox(height: 16),
                          recognizedMedications.isNotEmpty
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "Matched Medication(s):",
                                      style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 8),
                                    for (final med in recognizedMedications)
                                      ListTile(
                                        leading: const Icon(Icons.medication),
                                        title: Text(med),
                                      ),
                                  ],
                                )
                              : const Text(
                                  "No matching medication found in the list.",
                                  style: TextStyle(fontSize: 16),
                                ),
                          const Divider(),
                          Text(
                            "Voice Query: $_voiceSearchQuery",
                            style: const TextStyle(fontSize: 16),
                          ),
                          SizedBox(height: 10),
                          Text(
                            "Tap once to Start Listening"
                          ),
                          Text(
                            "Double Tap once to Listen Again"
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      GestureDetector(
                        onTap: _toggleListening,
                        child: Container(
                          height: 150,
                          width: 100,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20)
                          ),
                          child: Icon(
                            Icons.hearing,
                            size: 48,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _searchByVoiceQuery,
                        child: Container(
                          height: 150,
                          width: 100,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            Icons.search,
                            size: 48,
                            color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
