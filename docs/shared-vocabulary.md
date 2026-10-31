# Shared ForIT vocabulary

Dictate's Dictionary → Vocabulary section provides **Add Shared Term**, catalog
import/export, and **Reload Vocabulary**. Shared terms feed supported Whisper
prompt hints and AI cleanup. This does not enable vocabulary biasing in other
engines or change cloud-provider policy. Personal vocabulary, spelling overrides,
and suppressed shared terms remain separate from the reusable catalog.

## Files and schema

The user-local shared catalog is:

`~/Library/Application Support/ForIT/SharedVocabulary/vocabulary-v1.json`

```json
{
  "format": "io.forit.shared-vocabulary",
  "schemaVersion": 1,
  "revision": 2,
  "terms": ["ForIT", "Tinycast", "A shared technical term"]
}
```

`revision` is a positive integer, independent of the schema and app version.
Dictate seeds 20 useful terms when creating the catalog. Adding a shared term
validates and normalizes it, rejects case-insensitive duplicates, preserves all
previous terms, and advances the revision by one. Revision overflow is rejected.
Import updates must advance the revision; an identical catalog at the same
revision is an accepted no-op. Shared-term deletion is outside this slice.

Personal shared-term preferences are stored separately at:

`~/Library/Application Support/io.forit.dictate/vocabulary-preferences-v1.json`

```json
{
  "schemaVersion": 1,
  "suppressed": ["a shared term"],
  "overrides": {"tinycast": "Tiny Cast"}
}
```

Preference keys use trimmed, Unicode NFC, POSIX-lowercased terms. Personal
SwiftData vocabulary always takes precedence, including when a shared term is
suppressed. Existing dictionary archives and the SwiftData schema are unchanged.
Shared catalog exports exclude personal words and preferences.

## Cooperating-writer protocol

Every managed writer, including catalog seeding, must open the persistent sibling
`vocabulary-v1.json.lock` and acquire an exclusive nonblocking `flock` before
reading the on-disk catalog, comparing revisions, and atomically replacing it.
New lock files are created with mode `0600`; existing permissions are unchanged.
Keep the lock file in place so writers continue to lock the same inode. Release
the lock after the entire compare-and-replace operation. A busy lock fails the
operation promptly; there is no retry loop or background writer.

Adding a term also requires the on-disk catalog to match the currently displayed
catalog while the lock is held. A concurrent change rejects the addition until
the user reloads, preventing accidental loss of other apps' terms. Other apps
should use the same baseline check for read-modify-write operations.

Advisory locking cannot protect against editors that ignore this protocol.
External editors must coordinate updates, advance the revision, and replace the
complete file atomically; users then reload it in Dictate. This is a local file
contract, not cloud synchronization or a background daemon.

## Bounds, recovery, and validation

Files are limited to 256 KiB, shared catalogs to 1,024 terms, and terms to 160
UTF-8 bytes without control characters. Resolution reads at most 4,096 personal
words, prioritizing personal entries in a 256-term/6,000-byte snapshot. Whisper
uses a whole-term subset of at most 64 terms/768 hint bytes while preserving the
existing language/custom prompt. Decoder requests copy the cached snapshot and
perform no catalog file I/O or network request.

Unreadable files are preserved. Reloading retries both catalog and personal
preferences independently; a repaired preferences file restores editing without
restarting. A failed reload retains the last valid values and reports the error.
Restore an unreadable catalog before importing or adding shared terms.

Foundation model/file fixtures live in `Tests/VoiceInkTests/SharedVocabulary*`.
The Mac test harness must include `SharedVocabulary.swift` and the
Darwin/Foundation helper `SharedVocabularyCatalogLock.swift`; SwiftData and UI
adapters require separate app SDK/runtime validation. No native behavior or
latency result is implied by source inspection.
