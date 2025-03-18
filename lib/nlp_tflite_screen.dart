import 'dart:io';
import 'package:flutter/material.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class NlpTfliteScreen extends StatefulWidget {
  final String ocrText;
  const NlpTfliteScreen({Key? key, required this.ocrText}) : super(key: key);

  @override
  _NlpTfliteScreenState createState() => _NlpTfliteScreenState();
}

class _NlpTfliteScreenState extends State<NlpTfliteScreen> {
  Interpreter? _interpreter;
  List<String> _medications = [];
  bool _isProcessing = true;

  @override
  void initState() {
    super.initState();
    _loadModelAndRunInference();
  }

  Future<void> _loadModelAndRunInference() async {
    try {
      // 1) Load the TFLite model from assets
      _interpreter = await Interpreter.fromAsset(
        'assets/models/text_classification_model.tflite',
      );

      // 2) Preprocess the text: tokenize, convert to input indices, etc.
      var inputTensor = _preprocessText(widget.ocrText);

      // 3) Prepare output buffer.
      //    Example: if your model outputs shape [1, 3] for 3 classes,
      //    you'd need something like:
      var outputTensor = List.filled(1 * 3, 0).reshape([1, 3]);

      // 4) Run inference
      _interpreter!.run(inputTensor, outputTensor);

      // 5) Postprocess the output
      _medications = _postprocessOutput(outputTensor);

      setState(() {
        _isProcessing = false;
      });
    } catch (e) {
      print('Error running TFLite model: $e');
      setState(() {
        _isProcessing = false;
      });
    }
  }

  // Example tokenization / input prep.
  // Adjust to your model's sequence length & vocabulary mapping.
  List<List<int>> _preprocessText(String text) {
    // Suppose your model expects a sequence length of 50.
    // We'll dummy fill with '1' for tokens. In reality, you'd convert each
    // token to an integer index from a vocabulary.
    const seqLength = 50;
    final tokenIds = List<int>.filled(seqLength, 1);
    return [tokenIds]; // shape [1, seqLength]
  }

  // Example postprocessing
  List<String> _postprocessOutput(List<List<int>> outputTensor) {
    // If your model is a classification with 3 classes, you might parse it like:
    // (But you should adapt to your actual output structure.)
    // e.g., outputTensor = [[ <score0>, <score1>, <score2> ]]
    final outputList =
        outputTensor[0]; // e.g. [0, 5, 2], or actual numeric scores
    // For demonstration, just pretend we have 3 medication classes
    final labels = ['MedicationA', 'MedicationB', 'MedicationC'];

    // If these are raw scores, you'd pick the highest:
    // int bestIdx = 0;
    // double bestVal = -9999.0;
    // for (int i = 0; i < outputList.length; i++) {
    //   double val = outputList[i] * 1.0; // if it's int or double
    //   if (val > bestVal) {
    //     bestVal = val;
    //     bestIdx = i;
    //   }
    // }
    // return [labels[bestIdx]];

    // Or if each integer in outputList is an index for a recognized medication:
    // return outputList.map((int idx) => labels[idx]).toList();

    // For now, return a dummy result:
    return ['Medication A (dummy)', 'Medication B (dummy)'];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Medication Details (TFLite)')),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _medications.length,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: const Icon(Icons.medication),
                  title: Text(_medications[index]),
                );
              },
            ),
    );
  }
}
