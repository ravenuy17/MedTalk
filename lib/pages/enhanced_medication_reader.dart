import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:math' show log, min;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mongo_service.dart'; // Ensure your MongoService defines the methods used below

class EnhancedMedicationReaderScreen extends StatefulWidget {
  final String imagePath;
  final bool autoRead;

  const EnhancedMedicationReaderScreen({
    Key? key,
    required this.imagePath,
    this.autoRead = true,
  }) : super(key: key);

  @override
  State<EnhancedMedicationReaderScreen> createState() =>
      _EnhancedMedicationReaderScreenState();
}

class _EnhancedMedicationReaderScreenState
    extends State<EnhancedMedicationReaderScreen> {
  // State variables
  bool isLoading = true;
  bool isProcessing = false;
  bool hasError = false;
  String errorMessage = '';
  String extractedText = '';

  // Medication data
  List<MedicationInfo> recognizedMedications = [];
  Map<String, dynamic> medicationDetails = {};

  // Text processing
  List<String> _lines = [];
  int _currentLineIndex = -1;
  bool _isReadingAll = false;
  Set<String> _processedKeywords = {};

  // TTS and STT
  final FlutterTts flutterTts = FlutterTts();
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _voiceSearchQuery = '';

  // ML components
  late TextRecognizer _textRecognizer;
  late EntityExtractor _entityExtractor;
  Interpreter? _tfliteInterpreter;

  // Database service
  late MongoService _mongoService;
  bool _isConnected = true;

  // Classification confidence threshold
  final double _confidenceThreshold = 0.70;

  // Parameters for TFLite (set these according to your model specifications)
  final int _maxSequenceLength = 128;
  final int _strideLength = 64;
  final int _numMedicationClasses = 10;
  // This placeholder holds text spans from the original text
  final Map<int, String> _originalTextSpans = {};

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize ML Kit components
      _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      // NOTE: Using annotateText per updated API
      _entityExtractor =
          EntityExtractor(language: EntityExtractorLanguage.english);

      // Initialize speech services
      _speech = stt.SpeechToText();
      await _initTts();

      // Initialize database service
      _mongoService = MongoService();

      // Initialize TFLite model for medication classification
      await _loadTFLiteModel();

      // Check connectivity
      await _checkConnectivity();

      // Process the medication image
      await _processMedication();
    } catch (e) {
      setState(() {
        hasError = true;
        errorMessage = "Initialization error: ${e.toString()}";
        isLoading = false;
      });
      await _speak("An error occurred during setup. Please try again.");
    }
  }

  Future<void> _checkConnectivity() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    setState(() {
      _isConnected = connectivityResult != ConnectivityResult.none;
    });

    if (!_isConnected) {
      _speak("Warning: No internet connection. Some features may be limited.");
    }
  }

  Future<void> _loadTFLiteModel() async {
    try {
      _tfliteInterpreter = await Interpreter.fromAsset(
          'assets/models/medication_classifier.tflite');
      debugPrint("TFLite model loaded successfully");
    } catch (e) {
      debugPrint("Failed to load TFLite model: $e");
      // Continue without TFLite model (will fall back to dictionary-based matching)
    }
  }

  Future<void> _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);

    // When TTS finishes speaking a line, move to the next one if reading all text
    flutterTts.setCompletionHandler(() {
      if (_isReadingAll) {
        _currentLineIndex++;
        if (_currentLineIndex < _lines.length) {
          _speakLine(_currentLineIndex);
        } else {
          setState(() => _isReadingAll = false);
        }
      }
    });
  }

  @override
  void dispose() {
    flutterTts.stop();
    _textRecognizer.close();
    _entityExtractor.close();
    _tfliteInterpreter?.close();
    super.dispose();
  }

  // -------------------- OCR & Text Processing -------------------- //

  Future<void> _performOCR() async {
    try {
      final inputImage = InputImage.fromFilePath(widget.imagePath);
      final recognizedText = await _textRecognizer.processImage(inputImage);

      setState(() {
        extractedText = recognizedText.text.trim();
        _lines = extractedText
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .toList();
      });

      debugPrint("OCR extracted ${_lines.length} lines of text");

      // Process text blocks for entity extraction
      for (var textBlock in recognizedText.blocks) {
        for (var line in textBlock.lines) {
          await _extractEntitiesFromText(line.text);
        }
      }
    } catch (e) {
      throw Exception("OCR processing failed: ${e.toString()}");
    }
  }

  Future<void> _extractEntitiesFromText(String text) async {
    final List<EntityAnnotation> annotations =
        await _entityExtractor.annotateText(text);

    for (final entity in annotations) {
      if (entity.entities.isNotEmpty) {
        for (final entityType in entity.entities) {
          if (entityType.type == EntityType.address ||
              entityType.type == EntityType.money ||
              entityType.type == EntityType.dateTime) {
            _processedKeywords.add(entity.text);
          }
        }
      }
    }
  }

  // -------------------- ML Processing -------------------- //

  Future<Map<String, String>> _loadMedicationMap() async {
    if (!_isConnected) {
      return MongoService.getCachedMedications();
    }

    try {
      await _mongoService.connect();
      final brandToGenericName = await _mongoService.fetchMedicationMap();
      await _mongoService.close();
      return brandToGenericName;
    } catch (e) {
      debugPrint("Failed to load medication map: $e");
      return MongoService.getCachedMedications();
    }
  }

  Future<void> _processMedication() async {
    setState(() => isProcessing = true);

    try {
      // Perform OCR
      await _performOCR();
      if (extractedText.isEmpty)
        throw Exception("No text extracted from image");

      // Load medication dictionary
      final medicationMap = await _loadMedicationMap();

      // Identify medications via various approaches
      List<MedicationInfo> dictionaryMatches =
          _extractMedicationsFromDictionary(extractedText, medicationMap);
      List<MedicationInfo> nlpMatches =
          await _performNLPExtraction(extractedText);
      List<MedicationInfo> tfliteMatches =
          await _performTFLiteClassification(extractedText);

      // Combine and deduplicate results
      setState(() {
        recognizedMedications = _combineAndDeduplicateResults(
            dictionaryMatches, nlpMatches, tfliteMatches);
      });

      // Fetch additional details if any medications were found
      if (recognizedMedications.isNotEmpty) {
        await _fetchMedicationDetails();
      }

      // Store the extracted data if connected
      if (_isConnected) {
        try {
          await _mongoService.connect();
          await _mongoService.insertMedication({
            "text": extractedText,
            "medications":
                recognizedMedications.map((m) => m.toJson()).toList(),
            "timestamp": DateTime.now().toIso8601String(),
            "keywords": _processedKeywords.toList(),
          });
          await _mongoService.close();
        } catch (e) {
          debugPrint("Failed to store data: $e");
        }
      }

      // Provide spoken feedback
      if (_lines.isNotEmpty) {
        await _speak("Text found on the medication package.");
      }

      if (recognizedMedications.isNotEmpty) {
        final medNames =
            recognizedMedications.map((m) => m.genericName).join(", ");
        await _speak("Found medications: $medNames");
      } else {
        await _speak("No matching medications found.");
      }

      if (widget.autoRead && _lines.isNotEmpty) {
        await _readAllText();
      }
    } catch (e) {
      setState(() {
        hasError = true;
        errorMessage = e.toString();
      });
      await _speak("An error occurred: ${e.toString()}");
    } finally {
      setState(() {
        isLoading = false;
        isProcessing = false;
      });
    }
  }

  // -------------------- Medication Extraction Methods -------------------- //

  List<MedicationInfo> _extractMedicationsFromDictionary(
      String text, Map<String, String> brandToGenericName) {
    final foundMedications = <MedicationInfo>[];
    final lowerText = text.toLowerCase();

    brandToGenericName.forEach((brand, genericName) {
      if (lowerText.contains(brand.toLowerCase())) {
        foundMedications.add(MedicationInfo(
          brandName: StringUtils.toTitleCase(brand),
          genericName: StringUtils.toTitleCase(genericName),
          confidence: 0.95,
          source: "database",
        ));
      }
    });

    return foundMedications;
  }

  Future<List<MedicationInfo>> _performNLPExtraction(String text) async {
    // TODO: Insert your NLP extraction logic here.
    return [];
  }

  Future<List<MedicationInfo>> _performTFLiteClassification(String text) async {
    final foundMedications = <MedicationInfo>[];

    try {
      if (_tfliteInterpreter == null) return [];

      final encodedText = await _encodeTextForBert(text);

      List<MedicationInfo> allPredictions = [];
      for (int i = 0;
          i < encodedText.length - _maxSequenceLength + 1;
          i += _strideLength) {
        final inputSequence = encodedText.sublist(
            i, min(i + _maxSequenceLength, encodedText.length));
        final paddedSequence = _padSequence(inputSequence, _maxSequenceLength);

        // Create input tensor (shape: [1, _maxSequenceLength])
        final input = [paddedSequence];

        // Define output tensor (expected output shape: [1, _numMedicationClasses])
        final output = List.generate(
            1, (_) => List<double>.filled(_numMedicationClasses, 0));

        // Create a map for the outputs with index 0 pointing to your output tensor
        final outputsMap = {0: output};
        _tfliteInterpreter!.runForMultipleInputs([input], outputsMap);

        final predictions = await _processClassificationResults(output[0], i);
        allPredictions.addAll(predictions);
      }

      foundMedications.addAll(_consolidatePredictions(allPredictions));
    } catch (e) {
      debugPrint("TFLite classification error: $e");
    }

    return foundMedications;
  }

  Future<List<MedicationInfo>> _processClassificationResults(
      List<double> scores, int startPosition) async {
    final results = <MedicationInfo>[];

    // Get medication info from your database via LazyMedicationDatabase
    final medicationDatabase = await LazyMedicationDatabase().getMedications();

    for (int i = 0; i < scores.length; i++) {
      if (scores[i] > _confidenceThreshold) {
        // Assume your medicationDatabase keys are strings; adjust as needed
        if (medicationDatabase.containsKey(i.toString())) {
          final medInfo = medicationDatabase[i.toString()]!;
          results.add(MedicationInfo(
            brandName: medInfo.brandName,
            genericName: medInfo.genericName,
            confidence: scores[i],
            source: "tflite",
            metadata: {
              'startPosition': startPosition,
              'textSpan': _originalTextSpans[startPosition],
            },
          ));
        }
      }
    }

    return results;
  }

  List<MedicationInfo> _consolidatePredictions(
      List<MedicationInfo> predictions) {
    final Map<String, List<MedicationInfo>> grouped = {};

    for (final pred in predictions) {
      final key = pred.genericName.toLowerCase();
      grouped[key] = grouped[key] ?? [];
      grouped[key]!.add(pred);
    }

    final result = <MedicationInfo>[];
    grouped.forEach((key, meds) {
      meds.sort((a, b) => b.confidence.compareTo(a.confidence));
      final highestConfMed = meds.first;
      double adjustedConfidence = highestConfMed.confidence;

      if (meds.length > 1) {
        adjustedConfidence =
            min(0.99, highestConfMed.confidence + 0.1 * log(meds.length));
      }

      result.add(MedicationInfo(
        brandName: highestConfMed.brandName,
        genericName: highestConfMed.genericName,
        confidence: adjustedConfidence,
        source: "tflite+ensemble",
        metadata: {
          'occurrences': meds.length,
          'textSpans': meds.map((m) => m.metadata?['textSpan']).toList(),
        },
      ));
    });

    return result;
  }

  Future<List<int>> _encodeTextForBert(String text) async {
    // Dummy implementation: returns the code units.
    return text.codeUnits;
  }

  List<int> _padSequence(List<int> sequence, int maxLength) {
    final padded = List<int>.from(sequence);
    while (padded.length < maxLength) {
      padded.add(0);
    }
    return padded;
  }

  // -------------------- New Helper Methods -------------------- //

  List<MedicationInfo> _combineAndDeduplicateResults(
      List<MedicationInfo> dictionaryMatches,
      List<MedicationInfo> nlpMatches,
      List<MedicationInfo> tfliteMatches) {
    List<MedicationInfo> allMatches = [];
    allMatches.addAll(dictionaryMatches);
    allMatches.addAll(nlpMatches);
    allMatches.addAll(tfliteMatches);

    // Deduplicate by generic name, keeping the highest-confidence detection.
    Map<String, MedicationInfo> deduped = {};
    for (final med in allMatches) {
      final key = med.genericName.toLowerCase();
      if (deduped.containsKey(key)) {
        if (med.confidence > deduped[key]!.confidence) {
          deduped[key] = med;
        }
      } else {
        deduped[key] = med;
      }
    }
    return deduped.values.toList();
  }

  Future<void> _fetchMedicationDetails() async {
    // Dummy implementation: Replace with your actual API/database calls.
    for (final med in recognizedMedications) {
      medicationDetails[med.genericName] = {
        'usage': 'Usage details for ${med.genericName}.',
        'sideEffects': 'Side effects for ${med.genericName}.',
        'warnings': 'Warnings for ${med.genericName}.'
      };
    }
  }

  // -------------------- TTS Helpers -------------------- //

  Future<void> _speak(String message) async {
    try {
      await flutterTts.speak(message);
    } catch (e) {
      debugPrint("TTS Error: $e");
    }
  }

  Future<void> _speakLine(int index) async {
    if (index < 0 || index >= _lines.length) return;
    setState(() => _currentLineIndex = index);
    await flutterTts.speak(_lines[index]);
  }

  Future<void> _readAllText() async {
    if (_lines.isEmpty) {
      await _speak("No text to read.");
      return;
    }

    setState(() {
      _isReadingAll = true;
      _currentLineIndex = 0;
    });

    await _speakLine(_currentLineIndex);
  }

  // -------------------- Speech Recognition -------------------- //

  Future<void> _toggleListening() async {
    if (!_isListening) {
      bool available = await _speech.initialize(
        onStatus: (status) {
          debugPrint('onStatus: $status');
          if (status == 'notListening') {
            setState(() => _isListening = false);
          }
        },
        onError: (error) => debugPrint('onError: $error'),
      );

      if (available) {
        setState(() {
          _isListening = true;
          _voiceSearchQuery = "";
        });
        _speech.listen(
          onResult: (val) {
            setState(() {
              _voiceSearchQuery = val.recognizedWords;
            });
          },
          listenFor: Duration(seconds: 5),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  Future<void> _searchByVoiceQuery() async {
    if (_voiceSearchQuery.isEmpty) {
      await _speak("Please say a medication name first.");
      return;
    }

    final query = StringUtils.toTitleCase(_voiceSearchQuery);
    bool found = false;

    for (var med in recognizedMedications) {
      if (med.brandName.contains(query) || med.genericName.contains(query)) {
        found = true;
        await _speak(
            "Medication ${med.brandName} found. Its generic name is ${med.genericName}.");
        if (medicationDetails.containsKey(med.genericName)) {
          final details = medicationDetails[med.genericName];
          final usageInfo =
              details['usage'] ?? 'No usage information available';
          await _speak("Usage information: $usageInfo");
        }
      }
    }

    if (!found && _isConnected) {
      try {
        await _mongoService.connect();
        final result = await _mongoService.searchMedicationByName(query);
        await _mongoService.close();

        if (result != null) {
          found = true;
          await _speak(
              "Medication ${result['brandName']} found in database. Generic name: ${result['genericName']}.");
        }
      } catch (e) {
        debugPrint("Database search error: $e");
      }
    }

    if (!found) {
      await _speak("No medication matching $query was found.");
    }
  }

  void _processVoiceCommand(String command) async {
    final lowerCommand = command.toLowerCase().trim();
    final RegExp commandRegex =
        RegExp(r'^(search|read|what is|side effects of)\s+(.+)$');
    final match = commandRegex.firstMatch(lowerCommand);
    if (match != null) {
      final action = match.group(1)!;
      final medicationQuery = match.group(2)!;
      final medicationName = StringUtils.toTitleCase(medicationQuery);
      await _performMedicationQuery(action, medicationName);
    } else {
      await _speak(
          "Command not recognized. Please try again with a valid phrase such as 'Search Lipitor' or 'What is Advil'.");
    }
  }

  Future<void> _performMedicationQuery(
      String action, String medicationName) async {
    bool found = false;

    for (var med in recognizedMedications) {
      if (med.brandName.toLowerCase() == medicationName.toLowerCase() ||
          med.genericName.toLowerCase() == medicationName.toLowerCase()) {
        found = true;
        if (action.contains("read") ||
            action.contains("what is") ||
            action.contains("side effects")) {
          await _speak(
              "Medication ${med.brandName} found. Generic name is ${med.genericName}.");
          if (medicationDetails.containsKey(med.genericName)) {
            final details = medicationDetails[med.genericName];
            final usageInfo =
                details['usage'] ?? 'No usage information available';
            final sideEffects = details['sideEffects'] ??
                'No side effects information available';
            await _speak("Usage: $usageInfo. Side effects: $sideEffects.");
          } else {
            await _speak(
                "No additional details are available for ${med.brandName}.");
          }
        } else {
          await _speak(
              "Medication ${med.brandName} found. Generic name: ${med.genericName}.");
        }
        break;
      }
    }

    if (!found && _isConnected) {
      try {
        await _mongoService.connect();
        final result =
            await _mongoService.searchMedicationByName(medicationName);
        await _mongoService.close();
        if (result != null) {
          found = true;
          if (action.contains("read") ||
              action.contains("what is") ||
              action.contains("side effects")) {
            await _speak(
                "Medication ${result['brandName']} found in database. Generic name: ${result['genericName']}.");
            final details = await _mongoService
                .fetchMedicationDetails(result['genericName']);
            if (details != null) {
              final usage =
                  details['usage'] ?? 'No usage information available';
              final sideEffects = details['sideEffects'] ??
                  'No side effects information available';
              await _speak("Usage: $usage. Side effects: $sideEffects.");
            } else {
              await _speak("No additional details available.");
            }
          } else {
            await _speak(
                "Medication ${result['brandName']} found in database. Generic name: ${result['genericName']}.");
          }
        }
      } catch (e) {
        debugPrint("Error searching database: $e");
      }
    }

    if (!found) {
      await _speak("No medication matching $medicationName was found.");
    }
  }

  void _navigateToCameraScreen(BuildContext context) async {
    Navigator.of(context).pop();
  }

  // -------------------- UI -------------------- //

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enhanced Medication Reader'),
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt),
            onPressed: () => _navigateToCameraScreen(context),
            tooltip: 'Take New Photo',
          ),
          IconButton(
            icon: Icon(_isConnected ? Icons.wifi : Icons.wifi_off),
            onPressed: _checkConnectivity,
            tooltip: _isConnected ? 'Connected' : 'Offline Mode',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _buildFloatingActionButton(),
    );
  }

  Widget _buildBody() {
    if (isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Processing medication image...'),
          ],
        ),
      );
    }

    if (hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Error occurred',
              style: TextStyle(fontSize: 24),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(errorMessage),
            ),
            ElevatedButton(
              onPressed: () => _processMedication(),
              child: const Text('Try Again'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          height: 150,
          width: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(
              image: FileImage(File(widget.imagePath)),
              fit: BoxFit.cover,
            ),
          ),
        ),
        Expanded(
          child: DefaultTabController(
            length: 3,
            child: Column(
              children: [
                TabBar(
                  labelColor: Theme.of(context).colorScheme.primary,
                  tabs: const [
                    Tab(text: 'Medications'),
                    Tab(text: 'Text'),
                    Tab(text: 'Voice Search'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildMedicationsTab(),
                      _buildTextTab(),
                      _buildVoiceSearchTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMedicationsTab() {
    if (recognizedMedications.isEmpty) {
      return const Center(
        child: Text('No medications detected'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: recognizedMedications.length,
      itemBuilder: (context, index) {
        final med = recognizedMedications[index];
        final hasDetails = medicationDetails.containsKey(med.genericName);

        return Card(
          margin: const EdgeInsets.only(bottom: 16.0),
          child: ExpansionTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              child: const Icon(Icons.medication, color: Colors.white),
            ),
            title: Text(med.brandName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Generic: ${med.genericName}'),
                Text(
                  'Confidence: ${(med.confidence * 100).toStringAsFixed(1)}% (${med.source})',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            children: [
              if (hasDetails) ...[
                ListTile(
                  title: const Text('Usage'),
                  subtitle: Text(medicationDetails[med.genericName]['usage'] ??
                      'Not available'),
                ),
                ListTile(
                  title: const Text('Side Effects'),
                  subtitle: Text(medicationDetails[med.genericName]
                          ['sideEffects'] ??
                      'Not available'),
                ),
                ListTile(
                  title: const Text('Warnings'),
                  subtitle: Text(medicationDetails[med.genericName]
                          ['warnings'] ??
                      'Not available'),
                ),
              ] else ...[
                const ListTile(
                  title: Text('No detailed information available'),
                ),
              ],
              ButtonBar(
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.volume_up),
                    label: const Text('Read Aloud'),
                    onPressed: () {
                      _speak(
                          'Medication ${med.brandName}. Generic name: ${med.genericName}.');
                      if (hasDetails) {
                        _speak(
                            'Usage: ${medicationDetails[med.genericName]['usage'] ?? 'Not available'}');
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextTab() {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Extracted Text',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    IconButton(
                      icon: Icon(_isReadingAll ? Icons.stop : Icons.volume_up),
                      onPressed: _isReadingAll
                          ? () {
                              flutterTts.stop();
                              setState(() => _isReadingAll = false);
                            }
                          : _readAllText,
                      tooltip: _isReadingAll ? 'Stop Reading' : 'Read All Text',
                    ),
                  ],
                ),
                const Divider(),
                if (_lines.isEmpty) const Text('No text detected from image'),
                ...List.generate(_lines.length, (i) {
                  return Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    color: i == _currentLineIndex
                        ? Colors.yellow.withOpacity(0.3)
                        : Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(child: Text(_lines[i])),
                        IconButton(
                          icon: const Icon(Icons.volume_up, size: 18),
                          onPressed: () => _speakLine(i),
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                          tooltip: 'Read this line',
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceSearchTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Voice Search',
                          style: Theme.of(context).textTheme.titleLarge),
                      Row(
                        children: [
                          Icon(
                            _isListening ? Icons.mic : Icons.mic_off,
                            color: _isListening ? Colors.red : Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isListening ? "Listening..." : "Not Listening",
                            style: TextStyle(
                              color: _isListening ? Colors.red : Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Say a medication name to search',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _voiceSearchQuery.isEmpty
                                ? (_isListening
                                    ? "Listening..."
                                    : "Tap the mic to start")
                                : _voiceSearchQuery,
                            style: TextStyle(
                              fontSize: 18,
                              color: _voiceSearchQuery.isEmpty
                                  ? Colors.grey
                                  : Colors.black,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _isListening ? Icons.mic : Icons.mic_none,
                            color: _isListening ? Colors.red : Colors.blue,
                          ),
                          onPressed: _toggleListening,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.search),
                      label: const Text('Search Medication'),
                      onPressed: () {
                        _processVoiceCommand(_voiceSearchQuery);
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16.0),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Voice Commands',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 16),
                    ListTile(
                      leading: Icon(Icons.search),
                      title: Text('Search [medication name]'),
                      subtitle:
                          Text('Search for information about a medication'),
                    ),
                    ListTile(
                      leading: Icon(Icons.volume_up),
                      title: Text('Read [medication name]'),
                      subtitle:
                          Text('Read information about a specific medication'),
                    ),
                    ListTile(
                      leading: Icon(Icons.help),
                      title: Text('What is [medication name]'),
                      subtitle:
                          Text('Get detailed information about a medication'),
                    ),
                    ListTile(
                      leading: Icon(Icons.warning),
                      title: Text('Side effects of [medication name]'),
                      subtitle: Text('Learn about potential side effects'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingActionButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          onPressed: _isReadingAll
              ? () {
                  flutterTts.stop();
                  setState(() => _isReadingAll = false);
                }
              : _readAllText,
          tooltip: _isReadingAll ? 'Stop Reading' : 'Read All Text',
          child: Icon(_isReadingAll ? Icons.stop : Icons.volume_up),
        ),
        const SizedBox(height: 8),
        FloatingActionButton(
          onPressed: _toggleListening,
          tooltip: 'Voice Search',
          child: Icon(_isListening ? Icons.mic_off : Icons.mic),
        ),
      ],
    );
  }
}

// -------------------- Helper Classes -------------------- //

class StringUtils {
  static String toTitleCase(String input) {
    final cleaned =
        input.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
    if (cleaned.isEmpty) return cleaned;
    return cleaned
        .split(' ')
        .map((word) =>
            word.isNotEmpty ? word[0].toUpperCase() + word.substring(1) : '')
        .join(' ');
  }
}

// Consolidated MedicationInfo class
class MedicationInfo {
  final String brandName;
  final String genericName;
  final double confidence;
  final String source; // e.g., 'database', 'nlp', 'tflite'
  final Map<String, dynamic>? metadata;

  MedicationInfo({
    required this.brandName,
    required this.genericName,
    required this.confidence,
    required this.source,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    return {
      'brandName': brandName,
      'genericName': genericName,
      'confidence': confidence,
      'source': source,
      'metadata': metadata,
    };
  }

  factory MedicationInfo.fromJson(Map<String, dynamic> json) {
    return MedicationInfo(
      brandName: json['brandName'] ?? '',
      genericName: json['genericName'] ?? '',
      confidence: (json['confidence'] is int)
          ? (json['confidence'] as int).toDouble()
          : json['confidence'] ?? 0.0,
      source: json['source'] ?? '',
      metadata: json['metadata'] ?? {},
    );
  }
}

class MedicationCache {
  static const String _cacheKey = 'medication_cache';
  static const Duration _maxCacheAge = Duration(days: 30);

  static Future<void> cacheMedications(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final cacheData = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    };
    await prefs.setString(_cacheKey, jsonEncode(cacheData));
  }

  static Future<Map<String, dynamic>?> getCachedMedications() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedString = prefs.getString(_cacheKey);

    if (cachedString == null) return null;

    try {
      final cacheData = jsonDecode(cachedString);
      final timestamp = cacheData['timestamp'] as int;
      final cacheAge = DateTime.now().millisecondsSinceEpoch - timestamp;

      if (cacheAge < _maxCacheAge.inMilliseconds) {
        return cacheData['data'];
      }
    } catch (e) {
      debugPrint('Cache parsing error: $e');
    }

    return null;
  }

  static Future<void> invalidateCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  }
}

class LazyMedicationDatabase {
  static final LazyMedicationDatabase _instance =
      LazyMedicationDatabase._internal();
  factory LazyMedicationDatabase() => _instance;
  LazyMedicationDatabase._internal();

  Map<String, MedicationInfo>? _cachedMedications;
  DateTime? _lastFetchTime;
  bool _isLoading = false;
  final _loadingCompleter = Completer<void>();

  Future<Map<String, MedicationInfo>> getMedications() async {
    if (_cachedMedications != null &&
        _lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < Duration(hours: 12)) {
      return _cachedMedications!;
    }

    if (_isLoading) {
      await _loadingCompleter.future;
      return _cachedMedications!;
    }

    _isLoading = true;
    try {
      final mongoService = MongoService();
      await mongoService.connect();
      // Make sure MongoService includes a fetchAllMedications method.
      final medicationData = await mongoService.fetchAllMedications();
      await mongoService.close();

      _cachedMedications = {};
      for (final med in medicationData) {
        final info = MedicationInfo.fromJson(med);
        _cachedMedications![info.genericName.toLowerCase()] = info;
      }

      _lastFetchTime = DateTime.now();
      return _cachedMedications!;
    } catch (e) {
      debugPrint('Error loading medication database: $e');
      final cachedData = await MedicationCache.getCachedMedications();
      if (cachedData != null) {
        _cachedMedications = {};
        for (final med in cachedData['medications']) {
          final info = MedicationInfo.fromJson(med);
          _cachedMedications![info.genericName.toLowerCase()] = info;
        }
        return _cachedMedications!;
      }
      return {};
    } finally {
      _isLoading = false;
      _loadingCompleter.complete();
    }
  }
}
