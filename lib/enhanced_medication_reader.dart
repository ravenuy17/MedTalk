import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter_application_1/services/mongo_service.dart';
import 'package:lib/model/medication_model.dart';
import 'package:flutter_application_1/utils/string_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

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

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize ML Kit components
      _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
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
      // Load TFLite model for additional medication classification
      _tfliteInterpreter = await Interpreter.fromAsset(
          'assets/models/text_classification_model.tflite');
      debugPrint("TFLite model loaded successfully");
    } catch (e) {
      debugPrint("Failed to load TFLite model: $e");
      // Continue without TFLite model - we'll fall back to dictionary-based matching
    }
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

      // Extract structured text blocks for better context
      for (var textBlock in recognizedText.blocks) {
        for (var line in textBlock.lines) {
          // Process each line for entity extraction
          await _extractEntitiesFromText(line.text);
        }
      }
    } catch (e) {
      throw Exception("OCR processing failed: ${e.toString()}");
    }
  }

  Future<void> _extractEntitiesFromText(String text) async {
    final List<EntityAnnotation> annotations =
        await _entityExtractor.extractEntities(text);

    for (final entity in annotations) {
      if (entity.entities.isNotEmpty) {
        for (final entityType in entity.entities) {
          // Focus on medication-related entities
          if (entityType.type == EntityType.address ||
              entityType.type == EntityType.quantity ||
              entityType.type == EntityType.date) {
            // Store these for context
            _processedKeywords.add(entity.text);
          }
        }
      }
    }
  }

  // -------------------- ML Processing -------------------- //

  Future<Map<String, String>> _loadMedicationMap() async {
    if (!_isConnected) {
      // Fall back to cached data if available
      return MongoService.getCachedMedications();
    }

    try {
      await _mongoService.connect();
      final brandToGenericName = await _mongoService.fetchMedicationMap();
      await _mongoService.close();
      return brandToGenericName;
    } catch (e) {
      debugPrint("Failed to load medication map: $e");
      // Fall back to cached data
      return MongoService.getCachedMedications();
    }
  }

  Future<void> _processMedication() async {
    setState(() => isProcessing = true);

    try {
      // Perform OCR on the image
      await _performOCR();
      if (extractedText.isEmpty)
        throw Exception("No text extracted from image");

      // Load medication dictionary
      final medicationMap = await _loadMedicationMap();

      // Use multiple approaches to identify medications
      List<MedicationInfo> dictionaryMatches =
          _extractMedicationsFromDictionary(extractedText, medicationMap);
      List<MedicationInfo> nlpMatches =
          await _performNLPExtraction(extractedText);
      List<MedicationInfo> tfliteMatches =
          await _performTFLiteClassification(extractedText);

      // Combine and deduplicate results, prioritizing higher confidence matches
      setState(() {
        recognizedMedications = _combineAndDeduplicateResults(
            dictionaryMatches, nlpMatches, tfliteMatches);
      });

      // Fetch additional details for recognized medications
      if (recognizedMedications.isNotEmpty) {
        await _fetchMedicationDetails();
      }

      // Store extracted data in MongoDB if connected
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

      // Automatically read the text if enabled
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
            source: "database"));
      }
    });

    return foundMedications;
  }

  Future<List<MedicationInfo>> _performNLPExtraction(String text) async {
    final foundMedications = <MedicationInfo>[];

    try {
      // Use Entity Extraction to find medication mentions using ML Kit's NLP capabilities
      final entities = await _entityExtractor.extractEntities(text);

      for (final entity in entities) {
        // Attempt to match medication patterns
        if (_isMedicationPattern(entity.text)) {
          // Search our database for potential matches
          final matches =
              await _mongoService.searchSimilarMedications(entity.text);

          for (final match in matches) {
            foundMedications.add(MedicationInfo(
                brandName: match['brandName'],
                genericName: match['genericName'],
                confidence: match['similarity'] ?? 0.8,
                source: "nlp"));
          }
        }
      }
    } catch (e) {
      debugPrint("NLP extraction error: $e");
    }

    return foundMedications;
  }

  bool _isMedicationPattern(String text) {
    final pattern = RegExp(
        r'\b\d+\s*mg\b|\b\d+\s*mcg\b|\b\d+\s*ml\b|\btablet(s)?\b|\bcapsule(s)?\b',
        caseSensitive: false);
    return pattern.hasMatch(text);
  }

  Future<List<MedicationInfo>> _performTFLiteClassification(String text) async {
    final foundMedications = <MedicationInfo>[];

    try {
      if (_tfliteInterpreter == null) return [];

      // Prepare text chunks for classification
      final chunks = _prepareTextChunks(text);

      for (final chunk in chunks) {
        List<List<double>> inputVector = _textToInputVector(chunk);

        List<List<double>> outputVector =
            List.generate(1, (_) => List<double>.filled(100, 0));

        _tfliteInterpreter!.run(inputVector, outputVector);

        int bestClassIndex = 0;
        double bestConfidence = 0;

        for (int i = 0; i < outputVector[0].length; i++) {
          if (outputVector[0][i] > bestConfidence) {
            bestConfidence = outputVector[0][i];
            bestClassIndex = i;
          }
        }

        if (bestConfidence > _confidenceThreshold) {
          final Map<int, Map<String, String>> mockMedicationClasses = {
            0: {"brand": "Tylenol", "generic": "Acetaminophen"},
            1: {"brand": "Advil", "generic": "Ibuprofen"},
            2: {"brand": "Lipitor", "generic": "Atorvastatin"},
          };

          if (mockMedicationClasses.containsKey(bestClassIndex)) {
            final medInfo = mockMedicationClasses[bestClassIndex]!;
            foundMedications.add(MedicationInfo(
                brandName: medInfo["brand"] ?? "Unknown",
                genericName: medInfo["generic"] ?? "Unknown",
                confidence: bestConfidence,
                source: "tflite"));
          }
        }
      }
    } catch (e) {
      debugPrint("TFLite classification error: $e");
    }

    return foundMedications;
  }

  List<String> _prepareTextChunks(String text) {
    const maxLength = 50;
    final words = text.split(' ');
    final chunks = <String>[];

    for (int i = 0; i < words.length; i += maxLength) {
      final end = (i + maxLength < words.length) ? i + maxLength : words.length;
      chunks.add(words.sublist(i, end).join(' '));
    }

    return chunks;
  }

  List<List<double>> _textToInputVector(String text) {
    List<List<double>> inputVector =
        List.generate(1, (_) => List<double>.filled(128, 0.0));

    final words = text.toLowerCase().split(RegExp(r'\W+'));

    final Map<String, int> wordToIndex = {
      'tablet': 0,
      'capsule': 1,
      'mg': 2,
      'dose': 3,
      'oral': 4,
      'daily': 5,
    };

    for (final word in words) {
      if (wordToIndex.containsKey(word)) {
        inputVector[0][wordToIndex[word]] = 1.0;
      }
    }

    return inputVector;
  }

  List<MedicationInfo> _combineAndDeduplicateResults(
      List<MedicationInfo> dictionaryMatches,
      List<MedicationInfo> nlpMatches,
      List<MedicationInfo> tfliteMatches) {
    final allMatches = [...dictionaryMatches, ...nlpMatches, ...tfliteMatches];

    final Map<String, List<MedicationInfo>> grouped = {};

    for (final match in allMatches) {
      final key = match.genericName.toLowerCase();
      grouped[key] = grouped[key] ?? [];
      grouped[key]!.add(match);
    }

    final result = <MedicationInfo>[];

    grouped.forEach((key, matches) {
      matches.sort((a, b) => b.confidence.compareTo(a.confidence));
      result.add(matches.first);
    });

    return result;
  }

  Future<void> _fetchMedicationDetails() async {
    if (!_isConnected || recognizedMedications.isEmpty) return;

    try {
      await _mongoService.connect();

      for (final medication in recognizedMedications) {
        final details =
            await _mongoService.fetchMedicationDetails(medication.genericName);

        if (details != null) {
          medicationDetails[medication.genericName] = details;
        }
      }

      await _mongoService.close();
    } catch (e) {
      debugPrint("Failed to fetch medication details: $e");
    }
  }

  // -------------------- TTS HELPERS -------------------- //

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

  // -------------------- SPEECH RECOGNITION -------------------- //

  Future<void> _toggleListening() async {
    if (!_isListening) {
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

  // -------------------- NEW NLP FUNCTIONS -------------------- //

  // Process the voice command using basic NLP (regex parsing)
  Future<void> _processVoiceCommand(String command) async {
    final lowerCommand = command.toLowerCase().trim();
    // The regex looks for commands starting with keywords like "search", "read", "what is", or "side effects of"
    final RegExp commandRegex =
        RegExp(r'^(search|read|what is|side effects of)\s+(.+)$');
    final match = commandRegex.firstMatch(lowerCommand);
    if (match != null) {
      final action = match.group(1)!; // e.g., "search", "read"
      final medicationQuery = match.group(2)!;
      final medicationName = StringUtils.toTitleCase(medicationQuery);
      await _performMedicationQuery(action, medicationName);
    } else {
      await _speak(
          "Command not recognized. Please try again with a valid phrase such as 'Search Lipitor' or 'What is Advil'.");
    }
  }

  // Execute the medication query based on the parsed command
  Future<void> _performMedicationQuery(
      String action, String medicationName) async {
    bool found = false;

    // First, check in the already recognized medications
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

    // If not found locally, search in the database if connected
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
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.all(16.0),
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
                  Text(
                    'Voice Search',
                    style: Theme.of(context).textTheme.titleLarge,
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
                                ? 'Listening...'
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
                          icon: Icon(_isListening ? Icons.mic : Icons.mic_none,
                              color: _isListening ? Colors.red : Colors.blue),
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
                  children: [
                    Text(
                      'Voice Commands',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    const ListTile(
                      leading: Icon(Icons.search),
                      title: Text('Search [medication name]'),
                      subtitle:
                          Text('Search for information about a medication'),
                    ),
                    const ListTile(
                      leading: Icon(Icons.volume_up),
                      title: Text('Read [medication name]'),
                      subtitle:
                          Text('Read information about a specific medication'),
                    ),
                    const ListTile(
                      leading: Icon(Icons.help),
                      title: Text('What is [medication name]'),
                      subtitle:
                          Text('Get detailed information about a medication'),
                    ),
                    const ListTile(
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

  void _navigateToCameraScreen(BuildContext context) async {
    Navigator.of(context).pop(); // Return to camera screen
  }
}
