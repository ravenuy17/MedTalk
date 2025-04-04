import 'package:mongo_dart/mongo_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
// You can remove mongo_dart_query if you're not using its other features.

class MongoService {
  Db? _db;
  static const String _connectionString =
      'mongodb+srv://irvinkierpresto26:Axf4WfjQpWEZCPt6@fda-cluster.kzch7.mongodb.net/medicine_dictionary?retryWrites=true&w=majority';
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

      Map<String, String> brandToGenericName = {};
      for (var item in results) {
        brandToGenericName[item['brandName']] = item['genericName'];
      }

      await _cacheMedicationMap(brandToGenericName);
      return brandToGenericName;
    } catch (e) {
      print('Error fetching medication map: $e');
      return getCachedMedications();
    }
  }

  Future<void> _cacheMedicationMap(Map<String, String> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('medication_map', jsonEncode(data));
    } catch (e) {
      print('Error caching medication map: $e');
    }
  }

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
      return {};
    } catch (e) {
      print('Error getting cached medications: $e');
      return {};
    }
  }

  Future<void> insertMedication(Map<String, dynamic> data) async {
    try {
      final collection = _db!.collection(_userHistoryCollection);
      await collection.insert(data);
    } catch (e) {
      print('Error inserting medication data: $e');
      throw Exception('Failed to save data');
    }
  }

  Future<Map<String, dynamic>?> searchMedicationByName(String name) async {
    try {
      final collection = _db!.collection(_collectionName);
      final query = {
        r'$or': [
          {
            'brandName': {r'$regex': name, r'$options': 'i'}
          },
          {
            'genericName': {r'$regex': name, r'$options': 'i'}
          },
        ]
      };

      final result = await collection.findOne(query);
      return result;
    } catch (e) {
      print('Error searching medication: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> searchSimilarMedications(
      String text) async {
    try {
      final collection = _db!.collection(_collectionName);
      final List<Map<String, dynamic>> results = await collection
          .find()
          .map((doc) => {
                'brandName': doc['brandName'] as String,
                'genericName': doc['genericName'] as String,
                'similarity': _calculateSimilarity(text.toLowerCase(),
                    (doc['brandName'] as String).toLowerCase()),
              })
          .toList();

      final filteredResults = results
          .where((result) => result['similarity'] > 0.6)
          .toList()
        ..sort((a, b) =>
            (b['similarity'] as double).compareTo(a['similarity'] as double));

      return filteredResults.take(3).toList();
    } catch (e) {
      print('Error searching similar medications: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> fetchMedicationDetails(
      String genericName) async {
    try {
      final collection = _db!.collection('medication_details');
      final query = {
        'genericName': {
          r'$regex': '^${RegExp.escape(genericName)}\$',
          r'$options': 'i'
        }
      };
      final result = await collection.findOne(query);
      return result;
    } catch (e) {
      print('Error fetching medication details: $e');
      return null;
    }
  }

  double _calculateSimilarity(String s1, String s2) {
    if (s1.isEmpty || s2.isEmpty) return 0.0;

    final Set<String> set1 = s1.split('').toSet();
    final Set<String> set2 = s2.split('').toSet();

    final intersection = set1.intersection(set2).length;
    final union = set1.union(set2).length;

    return intersection / union;
  }
}
