# iPod Manager

A native macOS app for managing music on an iPod Classic 5th generation (iPod Video) without iTunes or Finder sync.

## Features

- **Two panes:** a music folder on your Mac on the left and the iPod on the right. Drag songs, albums or whole folders from the left pane or from Finder onto the iPod.
- **Write queue:** additions, deletions and tag edits are collected first, then written in one go with **Write to iPod**. The previous database is kept as `iTunesDB.bak`.
- **Batch tag editing** for songs already on the iPod (shared fields across a multi-selection).
- **Batch volume leveling** with Sound Check: loudness is measured per EBU R128 straight from the files on the iPod, with track or album mode, target level and clipping protection. Files are not modified.
- **Export** from the iPod back to the Mac with real file names and an Artist / Album folder structure.
- **Tags from the internet** in batches: songs are matched album by album against MusicBrainz (few requests, consistent album tags), the rest one by one; untagged files can be recognized by sound via AcoustID (bundled Chromaprint `fpcalc`, needs a free AcoustID API key in Settings). When an album has several editions you pick one; nothing is written until you apply and write to the iPod.
- Settings (⌘,): interface language, default volume leveling options, AcoustID key.
- **Cover art on the iPod** (ArtworkDB + `.ithmb`, 100×100 and 200×200 RGB565 for the iPod Video): covers of new songs come from the files, you can set or remove covers in the tag editor, add the covers embedded in files already on the iPod, and download covers from the Cover Art Archive together with the tags. Existing artwork written by iTunes is preserved; the previous database is kept as `ArtworkDB.bak`.
- **MP3Gain-style volume change**: optionally the leveling is written into the MP3 files themselves (global gain shifted in 1.5 dB steps, no re-encoding), with mp3gain-compatible undo data in an APEv2 tag and a one-click restore. AAC and other formats keep using Sound Check.
- **Tags and covers inside the files** (optional, on by default): MP3 (ID3v2.2/2.3/2.4, unknown frames preserved) and M4A/ALAC (iTunes `ilst` atoms, chunk offsets fixed up when the header grows). Audio data is never touched; small edits are done in place using the padding, larger ones through a temporary file. A command copies the iPod database tags into all files.
- **Cover file compaction**: space taken by replaced or removed covers in the `.ithmb` files is reclaimed automatically once it is worth it, or on demand.
- Tag search batches several albums or songs into one MusicBrainz request and caches answers for two weeks.
- Cover thumbnails in both lists.
- Supported formats: MP3, AAC, Apple Lossless, WAV, AIFF. FLAC and other formats the iPod can't play are skipped.
- Localized in English, Ukrainian and Russian.

## Planned

- Lossless volume change for AAC.

## Install

Download the latest `.zip` from [Releases](../../releases), unpack it and move **iPod Manager** to Applications. The app is not notarized: open it the first time with right-click → Open.

Requires macOS 14 or later. The iPod must be mounted as a disk ("Enable disk use").

## Build

```sh
swift test
tools/bundle.sh   # produces dist/iPod Manager.app and a zip
```

UI strings live in `tools/strings.py` (run it to regenerate `Resources/*.lproj`). The icon is drawn by `tools/make_icon.py`.

## How it works

`Sources/IPodKit` reads and writes the iPod's `iTunesDB` (mhbd / mhsd / mhit / mhod / mhyp / mhip records, following libgpod's layout). Unknown records are preserved byte for byte. On every write the master playlists and their library index records (mhod 52/53) are rebuilt, play counts recorded on the iPod are merged, and new files are copied into `iPod_Control/Music/Fxx`.

5th generation iPods do not use a database hash, so no extra signing is needed. iPods with a compressed `iTunesCDB` (newer nanos) are not supported.
