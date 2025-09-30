import 'package:flutter/material.dart';
import '../../../../theme/app_theme.dart';
import '../../../../data/za_cities.dart';
import './_step_shared.dart';

class StepCity extends StatelessWidget {
  const StepCity({
    super.key,
    required this.cityController,
    required this.dropdownOpen,
    required this.citySearchController,
    required this.results,
    required this.locationModeIsGps,
    required this.locationModeIsManual,
    required this.onPickGps,
    required this.onToggleManualDropdown,
    required this.onFilterChanged,
    required this.onPickCity,
  });

  final TextEditingController cityController;
  final bool dropdownOpen;
  final TextEditingController citySearchController;
  final List<ZaCity> results;
  final bool locationModeIsGps;
  final bool locationModeIsManual;
  final VoidCallback onPickGps;
  final VoidCallback onToggleManualDropdown;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<ZaCity> onPickCity;

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'Where should we match you?',
      children: [
        const Text(
          'You can only use one method: Find your current location, or choose a city from a list.',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 12),

        // GPS option
        ElevatedButton.icon(
          onPressed: onPickGps,
          icon: const Icon(Icons.my_location, size: 18, color: Colors.white),
          label: const Text(
            'Find my current location',
            style: TextStyle(color: Colors.white),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.ffPrimary,
            shape: const StadiumBorder(),
            minimumSize: const Size.fromHeight(44),
          ),
        ),

        const SizedBox(height: 10),

        // Manual option
        OutlinedButton.icon(
          onPressed: onToggleManualDropdown,
          icon: const Icon(Icons.place_outlined, color: Colors.white70),
          label: const Text('Choose my location', style: TextStyle(color: Colors.white)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
            shape: const StadiumBorder(),
            minimumSize: const Size.fromHeight(44),
            foregroundColor: Colors.white,
          ),
        ),

        const SizedBox(height: 8),

        // Status chips
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (locationModeIsGps) _okChip('Using your current location'),
            if (locationModeIsManual && cityController.text.trim().isNotEmpty)
              _okChip('Chosen: ${cityController.text.trim()}'),
          ],
        ),

        const SizedBox(height: 8),

        // Selected label preview (read-only)
        InputText(
          label: 'Selected location',
          controller: cityController,
          hint: 'Auto-filled after you choose',
          readOnly: true,
        ),

        // Dropdown with search + results
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: dropdownOpen
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF141414),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.ffAlt.withValues(alpha: .60),
                      ),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: TextField(
                            controller: citySearchController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              prefixIcon:
                                  const Icon(Icons.search, color: Colors.white70),
                              hintText: 'Search South African cities…',
                              hintStyle: const TextStyle(color: Colors.white54),
                              isDense: true,
                              filled: true,
                              fillColor: const Color(0xFF0F0F0F),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: AppTheme.ffAlt.withValues(alpha: .60),
                                ),
                              ),
                            ),
                            onChanged: onFilterChanged,
                            textInputAction: TextInputAction.search,
                          ),
                        ),
                        const Divider(height: 1, color: Colors.white12),
                        SizedBox(
                          height: 260,
                          child: ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (ctx, i) {
                              final c = results[i];
                              return ListTile(
                                dense: true,
                                title: Text(
                                  c.name,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                subtitle: Text(
                                  c.province,
                                  style: const TextStyle(color: Colors.white54),
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right,
                                  color: Colors.white38,
                                ),
                                onTap: () => onPickCity(c),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _okChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.ffPrimary.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppTheme.ffPrimary.withValues(alpha: .35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
      );
}
