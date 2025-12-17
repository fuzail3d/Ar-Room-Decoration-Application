import 'package:flutter/material.dart';

/// Model data class for UI representation
class ARModel {
  final String name;
  final String fileName;
  final IconData icon;
  final Color color;
  final String? thumbnailUrl;

  ARModel({
    required this.name,
    required this.fileName,
    this.icon = Icons.view_in_ar,
    this.color = Colors.blueAccent,
    this.thumbnailUrl,
  });
}

/// Predefined list of available 3D models
final List<ARModel> availableModels = [
  ARModel(
    name: 'Sofa',
    fileName: 'Sofa.glb',
    icon: Icons.chair,
    color: Colors.redAccent,
  ),
  ARModel(
    name: 'Chair',
    fileName: 'Chair.glb',
    icon: Icons.chair,
    color: Colors.orangeAccent,
  ),
  ARModel(
    name: 'Table',
    fileName: 'Table.glb',
    icon: Icons.table_restaurant,
    color: Colors.greenAccent,
  ),
  ARModel(
    name: 'Lamp',
    fileName: 'Lamp.glb',
    icon: Icons.lightbulb,
    color: Colors.yellowAccent,
  ),
  ARModel(
    name: 'Bed',
    fileName: 'Bed.glb',
    icon: Icons.bed,
    color: Colors.purpleAccent,
  ),
  ARModel(
    name: 'Cabinet',
    fileName: 'Cabinet.glb',
    icon: Icons.storage,
    color: Colors.cyanAccent,
  ),
];

/// Model Selection Card widget for horizontal list
class ModelSelectionCard extends StatelessWidget {
  final ARModel model;
  final bool isSelected;
  final bool isLoading;
  final VoidCallback onTap;

  const ModelSelectionCard({
    required this.model,
    required this.isSelected,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 100,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  model.color.withOpacity(0.7),
                  model.color.withOpacity(0.4),
                ],
              ),
              border: Border.all(
                color: isSelected
                    ? Colors.white
                    : Colors.white.withOpacity(0.3),
                width: isSelected ? 2.5 : 1.5,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: model.color.withOpacity(0.6),
                        blurRadius: 16,
                        spreadRadius: 3,
                      ),
                    ]
                  : [],
            ),
            child: Stack(
              children: [
                // Content
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      model.icon,
                      color: Colors.white,
                      size: 32,
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        model.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                // Loading indicator
                if (isLoading)
                  Container(
                    color: Colors.black.withOpacity(0.5),
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  ),
                // Selected checkmark
                if (isSelected && !isLoading)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: const Icon(
                        Icons.check,
                        size: 14,
                        color: Colors.green,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Model Selection UI widget - horizontal list at bottom
class ModelSelectionPanel extends StatelessWidget {
  final ARModel? selectedModel;
  final Set<String> loadingModels;
  final Function(ARModel) onModelSelected;

  const ModelSelectionPanel({
    required this.selectedModel,
    required this.loadingModels,
    required this.onModelSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.3),
            Colors.black.withOpacity(0.8),
          ],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(
            color: Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(
                  Icons.inventory_2,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Select Model',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                if (selectedModel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: selectedModel!.color.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selectedModel!.color.withOpacity(0.6),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      selectedModel!.name,
                      style: TextStyle(
                        color: selectedModel!.color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Model list
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: availableModels.length,
              itemBuilder: (context, index) {
                final model = availableModels[index];
                return ModelSelectionCard(
                  model: model,
                  isSelected: selectedModel?.fileName == model.fileName,
                  isLoading: loadingModels.contains(model.fileName),
                  onTap: () => onModelSelected(model),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
