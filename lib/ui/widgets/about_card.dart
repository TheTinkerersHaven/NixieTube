// About card for artist bios: clipped text with a "Show more" dialog
// that only appears when the text is actually clipped.

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../theme.dart';

/// About card used beside (or under) the top songs. Takes its natural
/// height; "Show more" only appears when the text is actually clipped.
class AboutCard extends StatelessWidget {
  const AboutCard({required this.text, this.fillHeight = false, super.key});

  final String text;
  final bool fillHeight;

  static const _maxLines = 8;

  void _showMore(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 480,
          child: Padding(
            padding: const EdgeInsets.all(spaceLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('About', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: spaceMd),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      text,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(height: spaceMd),
                Align(
                  alignment: Alignment.centerRight,
                  child: M3ETextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(spaceMd),
        child: LayoutBuilder(
          builder: (context, c) {
            // Full text metrics.
            final fullTp = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: c.maxWidth);
            final fullLines = fullTp.computeLineMetrics().length;
            final lineHeight = fullLines > 0
                ? fullTp.height / fullLines
                : ((style?.fontSize ?? 14) * (style?.height ?? 1.4));
            fullTp.dispose();

            final availH = c.maxHeight.isFinite ? c.maxHeight : 200.0;
            final titleH =
                (theme.textTheme.titleLarge?.fontSize ?? 22) + spaceSm;
            final linesThatFit = ((availH - titleH - spaceSm) / lineHeight)
                .floor()
                .clamp(1, 1000);
            final overflows = fullLines > linesThatFit;

            final maxLines = fillHeight ? linesThatFit : _maxLines;
            final textWidget = Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: style,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('About', style: theme.textTheme.titleLarge),
                const SizedBox(height: spaceSm),
                if (fillHeight) Expanded(child: textWidget) else textWidget,
                if (overflows) ...[
                  const SizedBox(height: spaceSm),
                  M3ETextButton(
                    onPressed: () => _showMore(context),
                    child: const Text('Show more'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
