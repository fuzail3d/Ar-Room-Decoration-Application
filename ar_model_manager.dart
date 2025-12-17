import 'dart:io';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// ARModelManager handles downloading, caching, and creating ArCoreReferenceNode instances
/// for 3D models stored in Supabase Storage.
class ARModelManager {
  static final ARModelManager _instance = ARModelManager._internal();
  late CacheManager _cacheManager;
  late final SupabaseClient _supabase;

  factory ARModelManager() {
    return _instance;
  }

  ARModelManager._internal() {
    _supabase = Supabase.instance.client;
    _cacheManager = CacheManager(
      Config(
        'ar_model_cache',
        stalePeriod: const Duration(days: 30),
        maxNrOfCacheObjects: 50,
      ),
    );
  }

  /// Fetch the download URL for a model from Supabase Storage.
  /// Assumes the model is stored in a 'models' bucket in Supabase Storage.
  /// 
  /// Usage: getModelUrl('Sofa.glb') 
  /// Will fetch from: supabase_bucket/models/Sofa.glb
  Future<String> getModelUrl(String modelName) async {
    try {
      // Get public URL from Supabase Storage
      final url = _supabase.storage.from('models').getPublicUrl(modelName);
      debugPrint('✅ Model URL: $url');
      return url;
    } catch (e) {
      debugPrint('❌ Failed to fetch model URL for $modelName: $e');
      throw Exception('Failed to fetch model URL for $modelName: $e');
    }
  }

  /// Get the local file path for a cached model or download it if not cached.
  /// Returns the local file path if successful, throws exception on failure.
  Future<String> getOrDownloadModel(String modelName) async {
    try {
      debugPrint('📥 Getting or downloading model: $modelName');
      final url = await getModelUrl(modelName);
      debugPrint('📥 Attempting to cache from: $url');

      // Download via cache manager (may save with .gltf-binary extension)
      final file = await _cacheManager.getSingleFile(url);
      debugPrint('✅ Model cached at: ${file.path}');
      debugPrint('✅ File exists: ${await file.exists()}');
      debugPrint('✅ File size: ${file.lengthSync()} bytes');

      // Validate file is actually a GLB
      final bytes = await file.readAsBytes();
      if (bytes.length < 28) {
        throw Exception('File too small to be a valid GLB');
      }
      final magic = String.fromCharCodes(bytes.sublist(0, 4));
      if (magic != 'glTF') {
        debugPrint('❌ Downloaded file is not a valid GLB (magic: $magic)');
        throw Exception('Downloaded file is not a valid GLB');
      }
      debugPrint('✅ GLB magic header valid');

      // Sceneform detects GLB by file extension; cache_manager writes *.gltf-binary.
      // Copy to a .glb file so the loader treats it correctly.
      final glbPath = file.path.endsWith('.glb')
          ? file.path
          : file.path.replaceAll(RegExp(r'\.gltf-binary$'), '.glb');

      if (glbPath != file.path) {
        final glbFile = File(glbPath);
        if (!await glbFile.exists() || glbFile.lengthSync() != file.lengthSync()) {
          await glbFile.writeAsBytes(bytes, flush: true);
          debugPrint('🔄 Copied to GLB path for loader: $glbPath');
        }
      }

      // Sanity check: Inspect GLB JSON chunk for materials/meshes
      try {
        await _inspectGlb(glbPath);
      } catch (e) {
        debugPrint('⚠️ GLB inspection warning: $e');
        // Don't fail here, just warn
      }

      debugPrint('✅ Model ready at: $glbPath');
      return glbPath;
    } catch (e) {
      debugPrint('❌ Failed to cache model $modelName: $e');
      // Clear cache for this model to force re-download next time
      try {
        await _cacheManager.removeFile(modelName);
      } catch (_) {}
      throw Exception('Failed to cache model $modelName: $e');
    }
  }

  /// List GLB filenames from common paths in the `models` bucket.
  /// This attempts multiple known prefixes to accommodate uploads in subfolders.
  Future<List<String>> listModelFiles() async {
    final results = <String>{};
    try {
      // List all files at the root of the models bucket
      final files = await _supabase.storage.from('models').list();
      debugPrint('📂 Supabase list() at root: ${files.length} items');
      for (final f in files) {
        final name = f.name;
        debugPrint('   - File: $name');
        if (name.toLowerCase().endsWith('.glb')) {
          results.add(name);
        }
      }
      debugPrint('✅ Found ${results.length} GLB files: ${results.join(', ')}');
    } catch (e) {
      debugPrint('❌ Supabase list() failed: $e');
      rethrow;
    }
    
    return results.toList();
  }

  /// Get a public thumbnail URL (expects a .png with same basename as the model).
  String getThumbnailUrl(String modelName) {
    final base = modelName.replaceAll(RegExp(r'\.glb$', caseSensitive: false), '');
    // If model is in a subfolder, keep same prefix when deriving PNG path
    final pngPath = '$base.png';
    final url = _supabase.storage.from('models').getPublicUrl(pngPath);
    debugPrint('🖼️ Thumb URL for $modelName -> $url');
    return url;
  }

  /// Inspect the GLB file's JSON chunk for common fields (materials, meshes, images).
  /// This is diagnostic only to help detect malformed exports.
  Future<void> _inspectGlb(String glbPath) async {
    final bytes = await File(glbPath).readAsBytes();
    if (bytes.length < 28) throw Exception('File too small to be GLB');
    // Magic 'glTF' and version 2
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    final version = bytes.sublist(4, 8);
    if (magic != 'glTF' || version[0] != 2) throw Exception('Not GLB v2');
    final jsonLen = bytes.buffer.asByteData().getUint32(12, Endian.little);
    final type = String.fromCharCodes(bytes.sublist(16, 20));
    if (type != 'JSON') throw Exception('First chunk not JSON');
    final jsonStr = String.fromCharCodes(bytes.sublist(20, 20 + jsonLen));
    // Basic keys presence
    final hasMaterials = jsonStr.contains('"materials"');
    final hasMeshes = jsonStr.contains('"meshes"');
    final hasImages = jsonStr.contains('"images"');
    final hasTextures = jsonStr.contains('"textures"');
    debugPrint('🔎 GLB inspect: materials=$hasMaterials meshes=$hasMeshes images=$hasImages textures=$hasTextures');
  }

  /// Create a simplified GLB by stripping complex material graph and textures.
  /// Returns a path to a sanitized copy or null if no change is necessary.
  Future<String?> _sanitizeGlb(String glbPath) async {
    try {
      final file = File(glbPath);
      final bytes = await file.readAsBytes();
      if (bytes.length < 28) return null;

      // Validate header
      final magic = String.fromCharCodes(bytes.sublist(0, 4));
      if (magic != 'glTF') return null;
      final versionLE = bytes.sublist(4, 8);
      if (versionLE[0] != 2) return null;

      // Read JSON chunk
      final jsonLen = bytes.buffer.asByteData().getUint32(12, Endian.little);
      final jsonType = String.fromCharCodes(bytes.sublist(16, 20));
      if (jsonType != 'JSON') return null;
      final jsonStart = 20;
      final jsonEnd = jsonStart + jsonLen;
      var jsonStr = utf8.decode(bytes.sublist(jsonStart, jsonEnd));

      // Parse JSON
      Map<String, dynamic> gltf;
      try {
        gltf = json.decode(jsonStr) as Map<String, dynamic>;
      } catch (_) {
        return null; // cannot parse, skip
      }

      bool changed = false;
      // Remove textures/images to avoid converter issues; keep geometry only
      if (gltf.containsKey('textures')) { gltf.remove('textures'); changed = true; }
      if (gltf.containsKey('images')) { gltf.remove('images'); changed = true; }
      if (gltf.containsKey('samplers')) { gltf.remove('samplers'); changed = true; }

      // Simplify materials
      if (gltf.containsKey('materials') && gltf['materials'] is List) {
        final mats = gltf['materials'] as List;
        for (var i = 0; i < mats.length; i++) {
          final m = mats[i] as Map<String, dynamic>;
          // Remove texture slots and extensions
          m.remove('emissiveTexture');
          m.remove('normalTexture');
          m.remove('occlusionTexture');
          m.remove('extensions');
          // Ensure simple PBR
          final pbr = (m['pbrMetallicRoughness'] as Map<String, dynamic>? ) ?? <String, dynamic>{};
          pbr.remove('baseColorTexture');
          pbr.remove('metallicRoughnessTexture');
          pbr['baseColorFactor'] ??= [1.0, 1.0, 1.0, 1.0];
          pbr['metallicFactor'] = 0.0;
          pbr['roughnessFactor'] = 1.0;
          m['pbrMetallicRoughness'] = pbr;
          mats[i] = m;
        }
        gltf['materials'] = mats;
        changed = true;
      }

      if (!changed) return null;

      // Rebuild JSON string and recompose GLB
      var newJson = json.encode(gltf);
      // Pad JSON to 4-byte alignment with spaces per spec
      final padding = (4 - (newJson.length % 4)) % 4;
      newJson = newJson + (' ' * padding);
      final newJsonBytes = utf8.encode(newJson);

      // Compute positions for BIN chunk (copy original)
      final binLen = bytes.buffer.asByteData().getUint32(jsonEnd, Endian.little);
      final binType = bytes.sublist(jsonEnd + 4, jsonEnd + 8); // likely 'BIN\0'
      final binDataStart = jsonEnd + 8;
      final binDataEnd = binDataStart + binLen;
      final binData = bytes.sublist(binDataStart, binDataEnd);

      // Build new GLB
      final totalLen = 12 + 8 + newJsonBytes.length + 8 + binData.length;
      final out = BytesBuilder();
      out.add(utf8.encode('glTF')); // magic
      out.add([2, 0, 0, 0]); // version 2 (little endian encoded later below)
      // Write header little-endian integers
      final header = ByteData(8);
      header.setUint32(0, 2, Endian.little);
      header.setUint32(4, totalLen, Endian.little);
      final hdr = BytesBuilder();
      hdr.add(utf8.encode('glTF'));
      // But we already added 'glTF'. We'll construct properly below instead.
      
      final out2 = BytesBuilder();
      // Header
      final h = ByteData(12);
      h.setUint32(0, 0x46546C67, Endian.little); // 'glTF'
      h.setUint32(4, 2, Endian.little); // version
      h.setUint32(8, totalLen, Endian.little); // total length
      out2.add(h.buffer.asUint8List());
      // JSON chunk header
      final cj = ByteData(8);
      cj.setUint32(0, newJsonBytes.length, Endian.little);
      cj.setUint32(4, 0x4E4F534A, Endian.little); // 'JSON'
      out2.add(cj.buffer.asUint8List());
      out2.add(newJsonBytes);
      // BIN chunk header
      final cb = ByteData(8);
      cb.setUint32(0, binData.length, Endian.little);
      cb.setUint32(4, 0x004E4942, Endian.little); // 'BIN\0'
      out2.add(cb.buffer.asUint8List());
      out2.add(binData);

      final outPath = glbPath.replaceAll(RegExp(r'\.glb$'), '.san.glb');
      final outFile = File(outPath);
      await outFile.writeAsBytes(out2.toBytes(), flush: true);
      return outPath;
    } catch (e) {
      debugPrint('⚠️ sanitizeGlb error: $e');
      return null;
    }
  }

  /// Create an ArCoreReferenceNode for a model at a given position.
  /// The model is automatically cached if not already present.
  /// Optional rotation (quaternion as Vector4) and scale can be applied.
  /// Create an ArCoreReferenceNode for a model at a given position.
  /// The model is automatically cached if not already present.
  /// Optional rotation (quaternion as Vector4) and scale can be applied.
  Future<ArCoreReferenceNode> createModelNode({
    required String modelName,
    required dynamic position,
    String? nodeName,
    dynamic rotation,
    dynamic scale,
  }) async {
    try {
      // Get or download the model
      final localPath = await getOrDownloadModel(modelName);

      debugPrint('🎯 Creating node with path: $localPath');

      // Create and return the ArCoreReferenceNode with all parameters set at construction
      final node = ArCoreReferenceNode(
        name: nodeName ?? 'model_${DateTime.now().millisecondsSinceEpoch}',
        objectUrl: localPath, // Use plain file path (with .glb extension)
        position: position,
        rotation: rotation,
        scale: scale,
      );
      debugPrint('✅ Node created successfully: ${node.name}');
      return node;
    } catch (e) {
      debugPrint('❌ Failed to create model node for $modelName: $e');
      throw Exception('Failed to create model node for $modelName: $e');
    }
  }

  /// Check if a model is already cached locally.
  Future<bool> isModelCached(String modelName) async {
    try {
      final url = await getModelUrl(modelName);
      final cachedFile = await _cacheManager.getFileFromCache(url);
      return cachedFile != null;
    } catch (e) {
      return false;
    }
  }

  /// Pre-cache a model without placing it in AR.
  Future<void> preloadModel(String modelName) async {
    try {
      await getOrDownloadModel(modelName);
    } catch (e) {
      throw Exception('Failed to preload model $modelName: $e');
    }
  }

  /// Clear the entire model cache.
  Future<void> clearCache() async {
    try {
      await _cacheManager.emptyCache();
    } catch (e) {
      throw Exception('Failed to clear model cache: $e');
    }
  }

  /// Get the size of the cache directory in bytes.
  Future<int> getCacheSize() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      return _getDirSize(Directory('${cacheDir.path}/ar_model_cache'));
    } catch (e) {
      return 0;
    }
  }

  int _getDirSize(Directory dir) {
    try {
      int size = 0;
      if (dir.existsSync()) {
        dir.listSync(recursive: true, followLinks: false).forEach((entity) {
          if (entity is File) {
            size += entity.lengthSync();
          }
        });
      }
      return size;
    } catch (_) {
      return 0;
    }
  }
}
