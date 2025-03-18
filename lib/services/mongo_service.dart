import 'package:mongo_dart/mongo_dart.dart';

class MongoService {
  static const String _mongoUrl =
      "mongodb+srv://irvinkierpresto26:Axf4WfjQpWEZCPt6@fda-cluster.kzch7.mongodb.net/";
  static const String _dbName = "FDA-CLUSTER";
  static const String _collectionName = "medication_database";

  late Db _db;
  late DbCollection _collection;

  /// Connect to MongoDB
  Future<void> connect() async {
    _db = await Db.create(_mongoUrl);
    await _db.open();
    _collection = _db.collection(_collectionName);
    print("Connected to MongoDB");
  }

  /// Insert extracted medication data into MongoDB
  Future<void> insertMedication(Map<String, dynamic> medication) async {
    try {
      await _collection.insertOne(medication);
      print("Medication inserted: $medication");
    } catch (e) {
      print("Error inserting medication: $e");
    }
  }

  /// Fetch medication list (brand -> molecule) from MongoDB
  Future<Map<String, String>> fetchMedicationMap() async {
    await connect();
    final medications = await _collection.find().toList();
    await close();

    // Convert MongoDB data into a map (Brand -> Molecule)
    final Map<String, String> brandToMolecule = {};
    for (var med in medications) {
      if (med.containsKey("brand") && med.containsKey("molecule")) {
        brandToMolecule[med["brand"].toString().toLowerCase()] =
            med["molecule"].toString().toLowerCase();
      }
    }

    return brandToMolecule;
  }

  /// Close the MongoDB connection
  Future<void> close() async {
    await _db.close();
    print("MongoDB connection closed");
  }
}
