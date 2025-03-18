import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter_application_1/services/mongo_service.dart';
import 'package:flutter_application_1/models/medication_model.dart';
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
  State<EnhancedMedicationReaderScreen> createState() => _EnhancedMedicationReaderScreenState();
}

class _EnhancedMedicationReaderScreenState extends State<EnhancedMedicationReaderScreen> {
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
      _entityExtractor = EntityExtractor(language: EntityExtractorLanguage.english);
      
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
      _tfliteInterpreter = await Interpreter.fromAsset('assets/models/medication_classifier.tflite');
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
    final List<EntityAnnotation> annotations = await _entityExtractor.extractEntities(text);
    
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
      if (extractedText.isEmpty) throw Exception("No text extracted from image");

      // Load medication dictionary
      final medicationMap = await _loadMedicationMap();
      
      // Use multiple approaches to identify medications
      List<MedicationInfo> dictionaryMatches = _extractMedicationsFromDictionary(extractedText, medicationMap);
      List<MedicationInfo> nlpMatches = await _performNLPExtraction(extractedText);
      List<MedicationInfo> tfliteMatches = await _performTFLiteClassification(extractedText);
      
      // Combine and deduplicate results, prioritizing higher confidence matches
      setState(() {
        recognizedMedications = _combineAndDeduplicateResults(
          dictionaryMatches, 
          nlpMatches,
          tfliteMatches
        );
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
            "medications": recognizedMedications.map((m) => m.toJson()).toList(),
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
        final medNames = recognizedMedications.map((m) => m.genericName).join(", ");
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
    String text, 
    Map<String, String> brandToGenericName
  ) {
    final foundMedications = <MedicationInfo>[];
    final lowerText = text.toLowerCase();

    brandToGenericName.forEach((brand, genericName) {
      if (lowerText.contains(brand.toLowerCase())) {
        foundMedications.add(MedicationInfo(
          brandName: StringUtils.toTitleCase(brand),
          genericName: StringUtils.toTitleCase(genericName),
          confidence: 0.95,
          source: "database"
        ));
      }
    });

    return foundMedications;
  }

  Future<List<MedicationInfo>> _performNLPExtraction(String text) async {
    final foundMedications = <MedicationInfo>[];
    
    try {
      // Use Entity Extraction to find medication mentions
      // This uses ML Kit's NLP capabilities
      final entities = await _entityExtractor.extractEntities(text);
      
      for (final entity in entities) {
        // Attempt to match medication patterns
        if (_isMedicationPattern(entity.text)) {
          // Search our database for potential matches
          final matches = await _mongoService.searchSimilarMedications(entity.text);
          
          for (final match in matches) {
            foundMedications.add(MedicationInfo(
              brandName: match['brandName'],
              genericName: match['genericName'],
              confidence: match['similarity'] ?? 0.8,
              source: "nlp"
            ));
          }
        }
      }
    } catch (e) {
      debugPrint("NLP extraction error: $e");
    }
    
    return foundMedications;
  }

  bool _isMedicationPattern(String text) {
    // Check for common medication patterns using regex
    final pattern = RegExp(
      r'\b\d+\s*mg\b|\b\d+\s*mcg\b|\b\d+\s*ml\b|\btablet(s)?\b|\bcapsule(s)?\b',
      caseSensitive: false
    );
    
    return pattern.hasMatch(text);
  }

  Future<List<MedicationInfo>> _performTFLiteClassification(String text) async {
    final foundMedications = <MedicationInfo>[];
    
    try {
      if (_tfliteInterpreter == null) return [];
      
      // Prepare text chunks for classification
      final chunks = _prepareTextChunks(text);
      
      for (final chunk in chunks) {
        // Prepare input tensor for classification
        // This is simplified; in practice you'd need proper text encoding
        List<List<double>> inputVector = _textToInputVector(chunk);
        
        // Allocate output tensor
        List<List<double>> outputVector = List.generate(
          1, 
          (_) => List<double>.filled(100, 0) // Assuming 100 classes
        );
        
        // Run inference
        _tfliteInterpreter!.run(inputVector, outputVector);
        
        // Process results
        int bestClassIndex = 0;
        double bestConfidence = 0;
        
        for (int i = 0; i < outputVector[0].length; i++) {
          if (outputVector[0][i] > bestConfidence) {
            bestConfidence = outputVector[0][i];
            bestClassIndex = i;
          }
        }
        
        // Only consider high confidence matches
        if (bestConfidence > _confidenceThreshold) {
          // In a real app, you'd map class index to medication name
          // For demo, we'll use mock data
          final Map<int, Map<String, String>> mockMedicationClasses = {
            0: {"brand": "Tylenol", "generic": "Acetaminophen"},
            1: {"brand": "Advil", "generic": "Ibuprofen"},
            2: {"brand": "Lipitor", "generic": "Atorvastatin"},
            // More classes would be defined here
          };
          
          if (mockMedicationClasses.containsKey(bestClassIndex)) {
            final medInfo = mockMedicationClasses[bestClassIndex]!;
            foundMedications.add(MedicationInfo(
              brandName: medInfo["brand"] ?? "Unknown",
              genericName: medInfo["generic"] ?? "Unknown",
              confidence: bestConfidence,
              source: "tflite"
            ));
          }
        }
      }
    } catch (e) {
      debugPrint("TFLite classification error: $e");
    }
    
    return foundMedications;
  }

  List<String> _prepareTextChunks(String text) {
    // Split text into manageable chunks for classification
    const maxLength = 50;
    final words = text.split(' ');
    final chunks = <String>[];
    
    for (int i = 0; i < words.length; i += maxLength) {
      final end = (i + maxLength < words.length) ? i + maxLength : words.length;
      chunks.add(words.sublist(i, end).join(' '));
    }
    
    return chunks;
  }

  List<List<double>> _textToInputVectorList<List<double>> _textToInputVector(String text) {
    // This is a simplified version for demonstration
    // In a real app, you would use proper text tokenization and embedding
    
    // Convert text to a simple bag-of-words representation
    // For demo purposes, we'll just create a simplified vector
    // that's compatible with our TFLite model
    
    // Create a 1x128 vector (assuming our model accepts this shape)
    List<List<double>> inputVector = List.generate(
      1, 
      (_) => List<double>.filled(128, 0.0)
    );
    
    // Simple encoding - real implementations would use proper tokenization
    final words = text.toLowerCase().split(RegExp(r'\W+'));
    
    // Map common medication-related words to vector positions
    final Map<String, int> wordToIndex = {
      'tablet': 0,
      'capsule': 1,
      'mg': 2,
      'dose': 3,
      'oral': 4,
      'daily': 5,
      // ... more words would be defined here
    };
    
    // Fill the vector based on word occurrences
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
    List<MedicationInfo> tfliteMatches
  ) {
    // Combine all results
    final allMatches = [...dictionaryMatches, ...nlpMatches, ...tfliteMatches];
    
    // Group by generic name
    final Map<String, List<MedicationInfo>> grouped = {};
    
    for (final match in allMatches) {
      final key = match.genericName.toLowerCase();
      grouped[key] = grouped[key] ?? [];
      grouped[key]!.add(match);
    }
    
    // For each group, select the match with highest confidence
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
        final details = await _mongoService.fetchMedicationDetails(medication.genericName);
        
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

  Future<void> _searchByVoiceQuery() async {
    if (_voiceSearchQuery.isEmpty) {
      await _speak("Please say a medication name first.");
      return;
    }
    
    final query = StringUtils.toTitleCase(_voiceSearchQuery);
    bool found = false;

    // First search in recognized medications
    for (var med in recognizedMedications) {
      if (med.brandName.contains(query) || med.genericName.contains(query)) {
        found = true;
        await _speak("Medication ${med.brandName} found. Its generic name is ${med.genericName}.");
        
        // Show details if available
        if (medicationDetails.containsKey(med.genericName)) {
          final details = medicationDetails[med.genericName];
          final usageInfo = details['usage'] ?? 'No usage information available';
          await _speak("Usage information: $usageInfo");
        }
      }
    }

    // If not found in recognized medications, search the database
    if (!found && _isConnected) {
      try {
        await _mongoService.connect();
        final result = await _mongoService.searchMedicationByName(query);
        await _mongoService.close();
        
        if (result != null) {
          found = true;
          await _speak(
            "Medication ${result['brandName']} found in database. " +
            "Generic name: ${result['genericName']}."
          );
        }
      } catch (e) {
        debugPrint("Database search error: $e");
      }
    }

    if (!found) {
      await _speak("No medication matching $query was found.");
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
        // Image preview
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
        
        // Main content
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
            title: Text(med.brandName, style: const TextStyle(fontWeight: FontWeight.bold)),
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
                  subtitle: Text(medicationDetails[med.genericName]['usage'] ?? 'Not available'),
                ),
                ListTile(
                  title: const Text('Side Effects'),
                  subtitle: Text(medicationDetails[med.genericName]['sideEffects'] ?? 'Not available'),
                ),
                ListTile(
                  title: const Text('Warnings'),
                  subtitle: Text(medicationDetails[med.genericName]['warnings'] ?? 'Not available'),
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
                      _speak('Medication ${med.brandName}. Generic name: ${med.genericName}.');
                      if (hasDetails) {
                        _speak('Usage: ${medicationDetails[med.genericName]['usage'] ?? 'Not available'}');
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
                      onPressed: _isReadingAll ? () {
                        flutterTts.stop();
                        setState(() => _isReadingAll = false);
                      } : _readAllText,
                      tooltip: _isReadingAll ? 'Stop Reading' : 'Read All Text',
                    ),
                  ],
                ),
                const Divider(),
                if (_lines.isEmpty)
                  const Text('No text detected from image'),
                ...List.generate(_lines.length, (i) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
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
                            _voiceSearchQuery.isEmpty ? 'Listening...' : _voiceSearchQuery,
                            style: TextStyle(
                              fontSize: 18,
                              color: _voiceSearchQuery.isEmpty ? Colors.grey : Colors.black,
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
                      onPressed: _searchByVoiceQuery,
                      style: ElevatedButton.styleFrom(style: ElevatedButton.styleFrom(
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
                      subtitle: Text('Search for information about a medication'),
                    ),
                    const ListTile(
                      leading: Icon(Icons.volume_up),
                      title: Text('Read [medication name]'),
                      subtitle: Text('Read information about a specific medication'),
                    ),
                    const ListTile(
                      leading: Icon(Icons.help),
                      title: Text('What is [medication name]'),
                      subtitle: Text('Get detailed information about a medication'),
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
          onPressed: _isReadingAll ? () {
            flutterTts.stop();
            setState(() => _isReadingAll = false);
          } : _readAllText,
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

// Helper class to import in utils/string_utils.dart
class StringUtils {
  static String toTitleCase(String input) {
    final cleaned = input.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
    if (cleaned.isEmpty) return cleaned;
    return cleaned
        .split(' ')
        .map((word) =>
            word.isNotEmpty ? word[0].toUpperCase() + word.substring(1) : '')
        .join(' ');
  }
}

// Model class to be defined in models/medication_model.dart
class MedicationInfo {
  final String brandName;
  final String genericName;
  final double confidence;
  final String source; // Where this match came from: 'database', 'nlp', 'tflite'

  MedicationInfo({
    required this.brandName,
    required this.genericName,
    required this.confidence,
    required this.source,
  });

  Map<String, dynamic> toJson() {
    return {
      'brandName': brandName,
      'genericName': genericName,
      'confidence': confidence,
      'source': source,
    };
  }

  factory MedicationInfo.fromJson(Map<String, dynamic> json) {
    return MedicationInfo(
      brandName: json['brandName'] ?? '',
      genericName: json['genericName'] ?? '',
      confidence: json['confidence'] ?? 0.0,
      source: json['source'] ?? '',
    );
  }
}

// Additional file: services/mongo_service.dart that needs to be created
import 'package:mongo_dart/mongo_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class MongoService {
  Db? _db;
  static const String _connectionString = 'mongodb://username:password@host:port/medication_db';
  static const String _collectionName = 'medications';
  static const String _userHistoryCollection = 'user_history';

  // Connect to MongoDB
  Future<void> connect() async {
    try {
      _db = await Db.create(_connectionString);
      await _db!.open();
      print('Connected to MongoDB');
    } catch (e) {
      print('Failed to connect to MongoDB: $e');
      throw Exception('Database connection failed');
    }
  }

  // Close the connection
  Future<void> close() async {
    await _db?.close();
    print('MongoDB connection closed');
  }

  // Fetch medication map (Brand Name -> Generic Name)
  Future<Map<String, String>> fetchMedicationMap() async {
    try {
      final collection = _db!.collection(_collectionName);
      final List<Map<String, dynamic>> results = await collection
          .find()
          .map((doc) => {
                'brandName': doc['brandName'] as String,
                'genericName': doc['genericName'] as String,
              })
          .toList();

      // Create a map of brand name to generic name
      Map<String, String> brandToGenericName = {};
      for (var item in results) {
        brandToGenericName[item['brandName']] = item['genericName'];
      }

      // Cache the results for offline use
      await _cacheMedicationMap(brandToGenericName);

      return brandToGenericName;
    } catch (e) {
      print('Error fetching medication map: $e');
      return getCachedMedications();
    }
  }

  // Cache medication data for offline use
  Future<void> _cacheMedicationMap(Map<String, String> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('medication_map', jsonEncode(data));
    } catch (e) {
      print('Error caching medication map: $e');
    }
  }

  // Get cached medication data
  static Future<Map<String, String>> getCachedMedications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonData = prefs.getString('medication_map');
      
      if (jsonData != null) {
        Map<String, dynamic> data = jsonDecode(jsonData);
        Map<String, String> result = {};
        data.forEach((key, value) {
          result[key] = value.toString();
        });
        return result;
      }
      
      // Return empty map if no cached data
      return {};
    } catch (e) {
      print('Error getting cached medications: $e');
      return {};
    }
  }

  // Insert medication data
  Future<void> insertMedication(Map<String, dynamic> data) async {
    try {
      final collection = _db!.collection(_userHistoryCollection);
      await collection.insert(data);
    } catch (e) {
      print('Error inserting medication data: $e');
      throw Exception('Failed to save data');
    }
  }

  // Search for a medication by name
  Future<Map<String, dynamic>?> searchMedicationByName(String name) async {
    try {
      final collection = _db!.collection(_collectionName);
      final query = where
          .or([
            where('brandName', RegExp(name, caseSensitive: false)),
            where('genericName', RegExp(name, caseSensitive: false))
          ])
          .limit(1);

      final result = await collection.findOne(query);
      return result;
    } catch (e) {
      print('Error searching medication: $e');
      return null;
    }
  }

  // Search for similar medications using fuzzy matching
  Future<List<Map<String, dynamic>>> searchSimilarMedications(String text) async {
    try {
      // This is a simplified version - in a real app you would use 
      // more sophisticated text similarity algorithms
      final collection = _db!.collection(_collectionName);
      final List<Map<String, dynamic>> results = await collection
          .find()
          .map((doc) => {
                'brandName': doc['brandName'] as String,
                'genericName': doc['genericName'] as String,
                'similarity': _calculateSimilarity(
                    text.toLowerCase(),
                    (doc['brandName'] as String).toLowerCase()),
              })
          .toList();

      // Filter results with similarity above threshold
      final filteredResults = results
          .where((result) => result['similarity'] > 0.6)
          .toList()
        ..sort((a, b) => (b['similarity'] as double)
            .compareTo(a['similarity'] as double));

      // Return top 3 matches
      return filteredResults.take(3).toList();
    } catch (e) {
      print('Error searching similar medications: $e');
      return [];
    }
  }

  // Fetch additional details for a medication
  Future<Map<String, dynamic>?> fetchMedicationDetails(String genericName) async {
    try {
      final collection = _db!.collection('medication_details');
      final query = where('genericName',
          RegExp('^${RegExp.escape(genericName)}\$', caseSensitive: false));

      final result = await collection.findOne(query);
      return result;
    } catch (e) {
      print('Error fetching medication details: $e');
      return null;
    }
  }

  // Helper method to calculate text similarity
  double _calculateSimilarity(String s1, String s2) {
    // Simple Jaccard similarity for demonstration
    // In a real app, you would use a more sophisticated algorithm
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    
    final Set<String> set1 = s1.split('').toSet();
    final Set<String> set2 = s2.split('').toSet();
    
    final intersection = set1.intersection(set2).length;
    final union = set1.union(set2).length;
    
    return intersection / union;
  }
}