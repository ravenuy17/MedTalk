class MedicationInfo {
  final String brandName;
  final String genericName;
  final double confidence;
  final String source; // 'database', 'nlp', 'tflite', etc.

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
      confidence: (json['confidence'] ?? 0.0).toDouble(),
      source: json['source'] ?? '',
    );
  }
}
