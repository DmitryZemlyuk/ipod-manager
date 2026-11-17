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
- Cover thumbnails in both lists, read from the files' tags.
- Supported formats: MP3, AAC, Apple Lossless, WAV, AIFF. FLAC and other formats the iPod can't play are skipped.
- Localized in English, Ukrainian and Russian.

## Planned

- Cover art on the iPod itself (ArtworkDB).
- MP3Gain-style lossless volume change in the files.
- Writing found covers (Cover Art Archive) to the iPod together with ArtworkDB support.

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
