import 'package:flutter/material.dart';

import '../api.dart';
import '../customers.dart';
import '../guests_report.dart';
import '../phone.dart';
import 'guest_edit_dialog.dart';
import 'menu_editor.dart' show ManagerPinDialog;

/// Whether the guest at [phone] can be tagged from where they stand: the tags are kept by a phone number,
/// so a reservation or a party without one (or with too few digits to be one) has nothing to hang them on.
bool canTagGuest(String phone) => phoneDigits(phone).length >= customerDigits;

/// What the bar at the bottom says once a guest's tags were saved from their reservation or their party.
String tagsSavedWords(String name, List<String> tags) {
  final who = name.trim().isEmpty ? 'This guest' : name.trim();
  return tags.isEmpty ? '$who carries no tags now' : '$who is tagged ${tags.join(', ')}';
}

/// Tags a guest from their reservation or their line of the waitlist (docs/guest-list.md, "From a
/// reservation or the waitlist"). The guest need not have ordered: the tags are kept by the number.
///
/// It asks for the PIN of whoever may read the guest list (a manager, an owner, and anybody the location
/// handed "See the guest list"), each time: the host stand is nobody's back office. Then the same box of
/// tag buttons the guest list has, with the tags alone. Hands back the tags as the hub keeps them now, or
/// null when nothing was saved (no PIN, Cancel, no hub, a hub older than this: the last two say so).
Future<List<String>?> tagGuestHere(
  BuildContext context, {
  required PosApi api,
  required String device,
  required String name,
  required String phone,
}) async {
  final token = await showDialog<String>(
    context: context,
    builder: (_) =>
        ManagerPinDialog(api: api, device: device, action: 'Tag the guest', what: 'tag a guest', power: 'guests'),
  );
  if (token == null || !context.mounted) return null;
  void say(String words) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(key: const ValueKey('tag-guest-problem'), content: Text(words)));
  final TagBox? box;
  try {
    box = await api.tagBox(token, phone);
  } on ApiException catch (err) {
    if (!context.mounted) return null;
    say(switch (err.status) {
      null => 'The hub is not answering, so the tags cannot be read. Try again in a moment.',
      _ => err.detail?['message'] as String? ?? err.message,
    });
    return null;
  }
  if (!context.mounted) return null;
  if (box == null) {
    say('This hub is older than tagging a guest from here. Update the hub, then tap Tags again.');
    return null;
  }
  final offer = box;
  final kept = await showDialog<GuestKept>(
    context: context,
    builder: (_) => GuestEditDialog.tags(
      api: api,
      token: token,
      called: name.trim().isEmpty ? formatPhoneNumber(phone) : name.trim(),
      // the hub keeps the name with the tags: the guest list calls a guest who never ordered by it
      name: name,
      phone: phone,
      tags: offer.carried,
      offered: [for (final tag in offer.tags) tag.tag],
      tagMax: offer.tagMax,
      tagsMost: offer.tagsMost,
    ),
  );
  return kept?.tags;
}
