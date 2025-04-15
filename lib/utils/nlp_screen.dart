import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:csv/csv.dart';
import 'package:flutter_tts/flutter_tts.dart';

class NlpScreen extends StatefulWidget {
  final String ocrText;
  const NlpScreen({Key? key, required this.ocrText}) : super(key: key);

  @override
  State<NlpScreen> createState() => _NlpScreenState();
}

class _NlpScreenState extends State<NlpScreen> {
  bool isLoading = true;
  String? recognizedMolecule; // Only storing one match
  final FlutterTts flutterTts = FlutterTts();

  @override
  void initState() {
    super.initState();
    _processText();
  }

  Future<void> _processText() async {
    try {
      // 1) Load CSV from assets
      final csvData = await rootBundle.loadString('assets/Medication_List.csv');
      final rows = const CsvToListConverter().convert(csvData);

      // 2) Build a brand->molecule map
      final brandToMolecule = <String, String>{};
      for (int i = 1; i < rows.length; i++) {
        // skip header row
        final row = rows[i];
        if (row.length >= 2) {
          final brand = row[0].toString().toLowerCase().trim();
          final molecule = row[1].toString().toLowerCase().trim();
          if (brand.isNotEmpty && molecule.isNotEmpty) {
            brandToMolecule[brand] = molecule;
          }
        }
      }

      // 3) Get the first word from OCR text
      final firstWord = _extractFirstWord(widget.ocrText);

      // 4) Match it to the CSV map
      if (firstWord != null && brandToMolecule.containsKey(firstWord)) {
        recognizedMolecule = brandToMolecule[firstWord];
        // Speak the recognized medication
        await flutterTts.speak("The molecule is $recognizedMolecule");
      } else {
        await flutterTts.speak("No medication found for the first word.");
      }
    } catch (e) {
      print("Error reading CSV or matching: $e");
    }

    setState(() {
      isLoading = false;
    });
  }

  /// Splits the text into words by whitespace, returns the first word in lowercase
  String? _extractFirstWord(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    // split by whitespace
    final words = trimmed.split(RegExp(r'\s+'));
    return words.isNotEmpty ? words.first.toLowerCase() : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Medication Details'),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : recognizedMolecule == null
              ? const Center(child: Text('No recognized medication.'))
              : Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ListTile(
                    leading: const Icon(Icons.medication),
                    title: Text(recognizedMolecule!),
                  ),
                ),
    );
  }
}
