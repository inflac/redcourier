import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class CustomKeyboard extends StatefulWidget {
  final void Function(String) onKeyPress;
  final VoidCallback? onBackspace;
  final VoidCallback? onClear;

  const CustomKeyboard({
    super.key,
    required this.onKeyPress,
    this.onBackspace,
    this.onClear,
  });

  @override
  State<CustomKeyboard> createState() => _CustomKeyboardState();
}

class _CustomKeyboardState extends State<CustomKeyboard> {
  bool isShiftEnabled = false;
  bool showSymbols = false;

  final List<String> numbers = ['1','2','3','4','5','6','7','8','9','0'];
  final List<List<String>> letters = [
    ['q','w','e','r','t','z','u','i','o','p','ü'],
    ['a','s','d','f','g','h','j','k','l','ö','ä'],
    ['y','x','c','v','b','n','m',',','.','-'],
  ];
  final List<List<String>> symbols = [
    ['!', '"', '§', '\$', '%', '&', '/', '(', ')', '='],
    ['?', '[', ']', '{', '}', '@', '#', '<', '>', '+'],
    ['*', '~', '^', '|', '\\', '_', ':', ';', ',', '.'],
  ];

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final keyHeight = isLandscape ? 32.0 : 40.0;
    final rowPadding = isLandscape ? 1.0 : 2.0;

    // Tastatur-Layout
    List<List<String>> activeRows = showSymbols ? symbols : letters;
    List<Widget> keyRows = activeRows.map((row) {
      return _buildFlexibleRow(
          row.map((l) => isShiftEnabled && !showSymbols ? l.toUpperCase() : l).toList(),
          keyHeight,
          rowPadding);
    }).toList();

    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxKeyboardHeight = isLandscape
              ? constraints.maxHeight * 0.5
              : null; // Portrait: automatisch

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxKeyboardHeight ?? double.infinity,
            ),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppPalette.of(context).bgPanel,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ----------------- PASTE BUTTON -----------------
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _buildSpecialKey('Paste', () async {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text ?? '';
                        if (text.isNotEmpty) {
                          widget.onKeyPress(text);
                        }
                      }, height: keyHeight),
                    ),
                    // ----------------- NUMBER ROW -----------------
                    _buildFlexibleRow(numbers, keyHeight, rowPadding),
                    const SizedBox(height: 4),
                    ...keyRows,
                    const SizedBox(height: 4),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        double specialKeyWidth = 50;
                        double spacing = 4;
                        double spaceWidth = constraints.maxWidth - 4 * specialKeyWidth - 4 * spacing;
                        spaceWidth = spaceWidth.clamp(60, double.infinity);

                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildSpecialKey('Shift', () {
                              setState(() {
                                isShiftEnabled = !isShiftEnabled;
                              });
                            }, isActive: isShiftEnabled, height: keyHeight),
                            _buildSpecialKey('Sym', () {
                              setState(() {
                                showSymbols = !showSymbols;
                                isShiftEnabled = false;
                              });
                            }, height: keyHeight),
                            _buildKey(' ', width: spaceWidth, height: keyHeight),
                            _buildSpecialKeyIcon(Icons.backspace, widget.onBackspace, height: keyHeight),
                            _buildSpecialKey('C', widget.onClear, height: keyHeight),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFlexibleRow(List<String> keys, double keyHeight, double rowPadding) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: rowPadding),
      child: Row(
        children: keys.map((k) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: _buildKey(k, height: keyHeight),
          ),
        )).toList(),
      ),
    );
  }

  Widget _buildKey(String key, {double width = 40, double height = 40}) {
    return SizedBox(
      width: width,
      height: height,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: AppPalette.of(context).bgAlt,
          foregroundColor: AppPalette.of(context).fg,
          minimumSize: Size(width, height),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        onPressed: () => widget.onKeyPress(key),
        child: Text(
          key,
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildSpecialKey(String label, VoidCallback? onTap, {bool isActive = false, double height = 40}) {
    return SizedBox(
      width: 50,
      height: height,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: isActive ? AppPalette.of(context).accent : AppPalette.of(context).border,
          foregroundColor: isActive ? Colors.white : AppPalette.of(context).fg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildSpecialKeyIcon(IconData icon, VoidCallback? onTap, {double height = 40}) {
    return SizedBox(
      width: 50,
      height: height,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: AppPalette.of(context).border,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        onPressed: onTap,
        child: Icon(
          icon,
          size: 20,
          color: AppPalette.of(context).fg,
        ),
      ),
    );
  }
}
