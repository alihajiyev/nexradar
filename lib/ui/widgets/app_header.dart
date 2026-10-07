import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The header every tab shares: an optional leading widget (the brand mark on
/// the drive tab, a back button elsewhere), a title block and trailing actions.
///
/// Deliberately not a `SliverAppBar`: it scrolls away with the content, which
/// keeps the full viewport available for the gauge.
class NexHeader extends StatelessWidget {
  const NexHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexSpace.page,
        NexSpace.xs,
        NexSpace.page,
        NexSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: NexSpace.sm),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NexText.h2,
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NexText.caption,
                    ),
                  ),
              ],
            ),
          ),
          for (final Widget action in actions) ...<Widget>[
            const SizedBox(width: NexSpace.xs),
            action,
          ],
        ],
      ),
    );
  }
}
