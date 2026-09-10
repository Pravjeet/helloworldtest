import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// One recorded change, at `colleges/{collegeId}/auditLog/{id}`.
///
/// The design decision that makes undo possible: an entry stores the **full
/// document path** it touched plus a **snapshot of the document before the
/// change**. Undo is then one generic operation — write [before] back, or
/// delete the document if there was no before — rather than a switch
/// statement that grows a case every time a module is added.
///
/// What that buys and what it costs: undo works for anything living in a
/// Firestore document, and nothing else. A deleted Firebase Auth account
/// cannot be recreated, so a user deletion restores the profile but not the
/// login. [undoCaveat] says so on the entry itself rather than letting
/// somebody discover it afterwards.
class AuditEntry {
  final String id;

  /// Dotted verb: `user.delete`, `fine.impose`, `fee.markPaid`. Grouped by
  /// the part before the dot so the log can be filtered by module.
  final String action;

  /// One human sentence: "Deleted Aryan Kumar (2431008)".
  final String summary;

  /// Who did it.
  final String actorUid;
  final String actorName;

  /// What it was done to, for display: "Aryan Kumar", "BH-01 room 204".
  final String targetLabel;

  /// Full Firestore path of the document that changed. The whole undo
  /// mechanism hangs off this being accurate.
  final String? path;

  /// The document as it was *before*. Null means it did not exist — so undo
  /// deletes rather than restores.
  final Map<String, dynamic>? before;

  /// Whether an undo is even offered. False for anything not reversible by
  /// rewriting one document — bulk operations, Auth deletions, imports.
  final bool reversible;

  /// Shown next to the undo button when the restore is partial.
  final String? undoCaveat;

  final bool undone;
  final DateTime? undoneAt;
  final String? undoneByName;

  final DateTime? createdAt;

  const AuditEntry({
    required this.id,
    required this.action,
    required this.summary,
    required this.actorUid,
    required this.actorName,
    required this.targetLabel,
    this.path,
    this.before,
    this.reversible = false,
    this.undoCaveat,
    this.undone = false,
    this.undoneAt,
    this.undoneByName,
    this.createdAt,
  });

  factory AuditEntry.fromMap(String id, Map<String, dynamic> m) => AuditEntry(
    id: id,
    action: m['action'] as String? ?? 'unknown',
    summary: m['summary'] as String? ?? '',
    actorUid: m['actorUid'] as String? ?? '',
    actorName: m['actorName'] as String? ?? 'Unknown',
    targetLabel: m['targetLabel'] as String? ?? '',
    path: m['path'] as String?,
    before: (m['before'] as Map?)?.cast<String, dynamic>(),
    reversible: m['reversible'] as bool? ?? false,
    undoCaveat: m['undoCaveat'] as String?,
    undone: m['undone'] as bool? ?? false,
    undoneAt: (m['undoneAt'] as Timestamp?)?.toDate(),
    undoneByName: m['undoneByName'] as String?,
    createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
  );

  Map<String, dynamic> toMap() => {
    'action': action,
    'summary': summary,
    'actorUid': actorUid,
    'actorName': actorName,
    'targetLabel': targetLabel,
    'path': path,
    'before': before,
    'reversible': reversible,
    'undoCaveat': undoCaveat,
    'undone': undone,
  };

  /// The module this belongs to — the part before the dot.
  String get module => action.split('.').first;

  /// Undo is offered only while the entry is fresh. An hour-old delete can be
  /// reversed safely; reversing last week's would silently overwrite whatever
  /// happened since, which is a worse outcome than not offering it.
  static const undoWindow = Duration(hours: 24);

  bool get withinUndoWindow =>
      createdAt != null && DateTime.now().difference(createdAt!) < undoWindow;

  bool get canUndo => reversible && !undone && path != null && withinUndoWindow;

  /// Why the undo button is disabled, when it is.
  String? get undoBlockedReason {
    if (undone) return 'Already undone';
    if (!reversible) return 'This action cannot be undone';
    if (path == null) return 'Nothing recorded to restore';
    if (!withinUndoWindow) return 'Older than 24 hours';
    return null;
  }

  /// Restoring a deleted document versus reverting an edit — worth saying,
  /// because the two feel different to the person clicking.
  bool get isRestore => before != null && action.endsWith('.delete');

  IconData get icon => switch (module) {
    'user' => Icons.person_rounded,
    'fine' => Icons.gavel_rounded,
    'fee' => Icons.receipt_long_rounded,
    'notice' => Icons.campaign_rounded,
    'officeOrder' => Icons.description_rounded,
    'allotment' => Icons.bed_rounded,
    'hostel' => Icons.apartment_rounded,
    'role' => Icons.shield_rounded,
    'settings' => Icons.settings_rounded,
    _ => Icons.history_rounded,
  };

  /// Destructive actions read red, creations green, edits neutral — so the
  /// log scans by colour before it is read.
  AuditTone get tone {
    final verb = action.split('.').last.toLowerCase();
    if (verb.contains('delete') || verb.contains('remove')) {
      return AuditTone.destructive;
    }
    if (verb.contains('create') ||
        verb.contains('impose') ||
        verb.contains('add') ||
        verb.contains('publish')) {
      return AuditTone.additive;
    }
    return AuditTone.neutral;
  }
}

enum AuditTone { additive, neutral, destructive }

/// Human labels for the module filter.
const Map<String, String> kAuditModules = {
  'user': 'Users',
  'fine': 'Fines',
  'fee': 'Mess fees',
  'notice': 'Notices',
  'officeOrder': 'Office orders',
  'allotment': 'Allotment',
  'hostel': 'Hostels',
  'role': 'Roles',
  'settings': 'Settings',
};
