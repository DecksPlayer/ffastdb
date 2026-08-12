# Flutter Database Benchmark 🚀

A benchmark suite comparing **`ffastdb`** (pure Dart NoSQL database with WAL) against **`isar_community`** (C++ native engine via FFI) and **`sembast`** (pure Dart JSON log store) in Flutter and server-side Dart.

---

## Benchmark Results

Environment: Windows x64, Dart SDK 3.12, disk storage with per-call / per-batch WAL durability.

### Benchmark Results (n = 10,000 documents)

| Operation | `ffastdb` | `isar_community` | `sembast` | Winner / Highlights |
|---|---|---|---|---|
| **`insertAll`** (bulk insert) | **39.7k ops/s** (252 ms) | **153.8k ops/s** (65 ms) | 15.3k ops/s (653 ms) | `isar` is fastest native FFI; `ffastdb` is **2.6× faster** than `sembast`. |
| **`singleInsert`** (per-call durability) | **382 ops/s** (5,234 ms) | **498 ops/s** (4,016 ms) | 97 ops/s (20,635 ms) | `ffastdb` nearly matches `isar` native fsync speed (**4× faster** than `sembast`). |
| **`queryIndexed`** (2k equality queries) | 151 ops/s (13,283 ms) | **583 ops/s** (3,427 ms) | 245 ops/s (8,149 ms) | `isar` leads in query execution; `ffastdb` queries on disk with LRU page cache. |
| **`findById`** (5k random primary key lookups) | **13.9k ops/s** (359 ms) | 9.2k ops/s (542 ms) | **333.3k ops/s** (15 ms) | `ffastdb` B-Tree lookups are **1.5× faster** than `isar`. (*`sembast` keeps raw maps in RAM*) |

---

### Benchmark Results (n = 1,000 documents)

| Operation | `ffastdb` | `isar_community` | `sembast` |
|---|---|---|---|
| **`insertAll`** (bulk insert) | **17.2k ops/s** (58 ms) | **47.6k ops/s** (21 ms) | 11.0k ops/s (91 ms) |
| **`singleInsert`** (per-call durability) | **378 ops/s** (2,646 ms) | **486 ops/s** (2,058 ms) | 92 ops/s (10,864 ms) |
| **`queryIndexed`** (2k equality queries) | 591 ops/s (3,386 ms) | **2.18k ops/s** (917 ms) | 1.53k ops/s (1,309 ms) |
| **`findById`** (1k random primary key lookups) | **13.9k ops/s** (72 ms) | 9.2k ops/s (109 ms) | 250.0k ops/s (4 ms) |

---

## Operations Overview

1. **`insertAll`**: Measures bulk insert throughput (`insertAll()` / `putAll()` / single transaction batch).
2. **`singleInsert`**: Measures single-document inserts where each call enforces individual WAL durability on disk.
3. **`queryIndexed`**: Performs repeated equality filters on an indexed string field (`city`) and fetches full matching documents.
4. **`findById`**: Measures random lookup speed by primary key ID.

---

## How to Run

### Command Line (CLI)

Run via Dart CLI (no Flutter device needed):

```bash
# Run with n=10000 (default)
dart run bin/run_benchmark.dart 10000

# Run with n=1000
dart run bin/run_benchmark.dart 1000
```

### Flutter GUI App

Run the interactive Flutter app on Windows, macOS, Linux, Android, or iOS:

```bash
flutter run -d windows
```

In the app UI, select `n` from the dropdown and click **Run All Benchmarks**.
