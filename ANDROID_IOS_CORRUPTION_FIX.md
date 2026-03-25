# Android/iOS Database Corruption Fix

## 🐛 Problem

FastDB was experiencing database corruption on **Android and iOS** platforms. The corruption manifested as:

- Mixed JSON data with binary/random content
- Database files that could not be parsed correctly after reopening
- Data being written to wrong offsets within the file

### Example of Corrupted Data
```
!   "   #   $   %   &   '   (   )                   U!      9#      �%
{"fieldName":"campo2","isDeleted":false,"lastModifiedLocally":"2026-03-11T15:06:43.337"...}
�/��  {"isSynced":false,"amount":30.0,"fieldName":"campo1"...}
```

## 🔍 Root Cause

The issue was caused by using **`FileMode.append`** when opening database files in `IoStorageStrategy`:

```dart
// BROKEN CODE (before fix)
_file = await dbFile.open(mode: FileMode.append);
```

### Why FileMode.append Causes Corruption

On **mobile platforms** (Android/iOS), `FileMode.append` has stricter behavior than on desktop:

1. **`setPosition()` is IGNORED for writes** - The file pointer position set by `setPosition()` is only respected for reads
2. **All writes are forced to append at the end** - Regardless of where you set the position, writes always go to EOF
3. **B-tree corruption** - FastDB's B-tree structure requires updating nodes at specific offsets. When these updates are appended instead of overwriting, the database becomes corrupted

### Platform Differences

| Platform | FileMode.append behavior |
|----------|-------------------------|
| **Windows/macOS** | `setPosition()` works for both reads and writes (lenient) |
| **Android/iOS** | `setPosition()` ONLY works for reads, writes always append (strict) |
| **Linux** | Similar to mobile (strict, POSIX-compliant) |

## ✅ Solution

Changed to **`FileMode.write`** which correctly supports random-access I/O on all platforms:

```dart
// FIXED CODE
_file = await dbFile.open(mode: FileMode.write);
```

### Why FileMode.write is Correct

- ✅ **Random-access writes** - `setPosition()` is respected for both reads and writes
- ✅ **Cross-platform consistency** - Works identically on all platforms
- ✅ **Semantic correctness** - Database files require random-access updates, not append-only
- ✅ **B-tree integrity** - Nodes can be correctly updated at their specific offsets

## 📝 Files Changed

### Core Fix
- `lib/src/storage/io/io_storage_strategy.dart` - Changed from `FileMode.append` to `FileMode.write`

### Test Updates
- `test/fastdb_test.dart` - Updated tests that were corrupting the clean flag to use `FileMode.write`
- `test_file_mode.dart` - Enhanced to demonstrate the difference between append and write modes

### Documentation
- `CHANGELOG.md` - Added critical bug fix entry for v0.0.11

## 🧪 Verification

Run the verification test to see the difference:

```bash
dart test_file_mode.dart
```

On Windows/macOS, both modes may appear to work, but on Android/iOS, only `FileMode.write` will work correctly.

## 🚀 Migration

**No migration needed!** 

This is a transparent fix. Existing database files will work correctly after upgrading to the fixed version. However, **corrupted databases from previous versions cannot be automatically repaired** - they will need to be recreated or restored from backup.

## 📚 Technical Details

### File Modes Comparison

| FileMode | Read | Write | setPosition() | Use Case |
|----------|------|-------|---------------|----------|
| `read` | ✅ | ❌ | ✅ (reads only) | Log reading |
| `write` | ✅ | ✅ | ✅ (both) | **Database files** ⭐ |
| `append` | ✅ | ✅ | ⚠️ (platform-dependent) | Log appending only |
| `writeOnly` | ❌ | ✅ | ✅ (writes only) | File creation |
| `writeOnlyAppend` | ❌ | ✅ | ❌ | Strict append-only |

### FastDB Write Patterns

FastDB performs these operations that require `FileMode.write`:

1. **Header updates** - Updating root page pointer, nextId counter at file start
2. **B-tree node updates** - Modifying existing internal/leaf nodes
3. **Page recycling** - Overwriting deleted pages with new data
4. **WAL checkpointing** - Applying logged changes to specific offsets

All of these require **random-access writes**, which are not supported by append modes on mobile platforms.

## 🔒 Additional Context

The original code likely used `FileMode.append` with the intention of:
- Creating the file if it doesn't exist
- Being able to append new pages efficiently

However, this is a misuse of append mode for databases. The correct approach is:
1. Use `FileMode.write` for random-access I/O
2. Explicitly create the file if needed (which the code already does)
3. Use `setPosition()` + `writeFrom()` for all writes

## 🎯 Prevention

To prevent similar issues in the future:

1. **Always use `FileMode.write`** for database-like files that need random-access updates
2. **Test on actual mobile devices** - Desktop behavior may not match mobile
3. **Add platform-specific tests** - Verify critical file I/O operations on all target platforms
4. **Use the verification test** - `test_file_mode.dart` can detect this class of bugs
