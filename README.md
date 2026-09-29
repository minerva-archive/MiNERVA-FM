# MiNERVA-FM — Radio

A self-hosted chiptune radio. It indexes your retro game-music collection, broadcasts one shared
HLS stream, and serves a CRT-styled web player with a live spectrum visualizer. SID, SPC, VGM/VGZ,
NSF, tracker modules (MOD/XM/IT/S3M and friends) and MP3/FLAC/WAV all decode in-container
(ffmpeg + libgme + libopenmpt, sidplayfp) — no PulseAudio, players, or desktop required.

> [!CAUTION]
> Ships with a placeholder credential (`BRIDGE_TOKEN=changeme`). Before exposing to any network:
> set a strong, unique value. Put the container behind a reverse proxy (Nginx Proxy Manager, Caddy,
> etc.) for TLS — do not expose port 8080 directly.

## Quickstart

Needs Docker and your own music (none ships — copyright). No collection yet? See
[Getting music](#getting-music) — `examples/fetch-modarchive.sh` fills `./music` with
public-domain tracker modules in one command.

```bash
git clone <repo>
cd minerva-fm
docker compose up --build
```

Put your music in the directory mapped to `/music` as `<System>/<Game>/<files>`
(e.g. `SNES/Chrono Trigger/01 Title.spc`) — flat files won't index. Then open
http://localhost:8080/ and click TUNE IN. The first run builds the image (a few minutes).

## Getting music

Any tree shaped `<TLD>/<Game>/<files>` (or `<TLD>/<Group>/<Game>/<files>`) is indexed; flat
folders are not. `examples/fetch-modarchive.sh` builds one for you, in native tracker formats
only — a module is tens of KB where the rendered audio would be megabytes, and the station
decodes it in-container:

```bash
./examples/fetch-modarchive.sh --dry-run          # see what it would fetch
./examples/fetch-modarchive.sh                    # ~1000 modules, into ./music
./examples/fetch-modarchive.sh --pages 2 ./music  # just the first 80 per licence
```

It defaults to both unencumbered licence sets — Public Domain (~880 modules) and CC0 (~120) —
sorts downloads by format (`music/ModArchive/Impulse Tracker/…`), skips files already present,
skips anything that isn't a module the station can decode, and records every download in
`music/ModArchive/MANIFEST.csv` with its module id and licence, so provenance survives. It
waits between requests: the archive runs on donations, so leave `--delay` alone.

`--licence by,by-sa,by-nc,by-nc-sa,by-nc-nd,by-nd` reaches the ~2200 further modules under
Creative Commons terms — attribution and non-commercial conditions are then yours to honour.

After adding music, drop the stale catalogue so the station reindexes on restart:

```bash
docker compose exec station rm -f /data/vgm_catalogue.csv
docker compose restart station
```

### Native-format sources, and why there is only one script

Public domain plus *native chip/tracker formats* plus *a machine-readable licence per file* is
a narrow intersection. It was checked:

| source | native formats? | per-item licence? | verdict |
|---|---|---|---|
| [The Mod Archive](https://modarchive.org/index.php?request=view_by_license&query=publicdomain) | yes — MOD/XM/IT/S3M/… | yes, 8 licence sets | **scripted** — ~1000 PD + CC0 modules |
| [OpenGameArt](https://opengameart.org/art-search-advanced?field_art_type_tid%5B%5D=12&field_art_licenses_tid%5B%5D=4) | no — 4116 CC0 music entries, sampled module-tagged ones were all OGG/MP3/WAV | yes | excluded: rendered audio, not modules |
| [Battle of the Bits](https://battleofthebits.com/) | yes — SID, AHX, 2A03, AY, GB, modules | no licence field in its API | excluded: entries stay the artist's |
| [Internet Archive](https://archive.org/) | some, inside ZIPs | yes, but zero items index both a PD licence and a chip/tracker format | excluded: nothing to fetch |
| [Aminet](https://aminet.net/tree?path=mods) | yes — thousands of Amiga modules | no — `.lha` archives, free-text readmes | excluded: licence not determinable |
| HVSC, VGMRips, Zophar, Modland, AMP, SNDH, UnExoticA | yes | no | excluded: see below |

> [!WARNING]
> The big rip archives — HVSC (SID), VGMRips (VGM), Zophar's Domain, Modland, AMP, SNDH — are
> free to *download*, not to *broadcast*: the music in them is still the composer's and the
> publisher's, however old the chip. The station decodes those formats happily; the rights are
> your problem, not the decoder's. If you want a legally clean 24/7 stream, The Mod Archive's
> Public Domain and CC0 sets are the supply.

## Ways to run

| | how | needs |
|---|---|---|
| Build it yourself | `docker compose up --build` | this repo |
| Prebuilt image | copy `deploy/`, `cp .env.example .env`, add music, `docker compose up -d` | registry access |
| By hand | `docker build -f Dockerfile.station -t minerva-fm-station .` then `docker run -p 8080:8080 -v /your/music:/music:ro -e BRIDGE_TOKEN=… minerva-fm-station` | this repo |

## Configuration

Set via environment variables (or `deploy/.env`):

| variable | default | purpose |
|---|---|---|
| `BRIDGE_TOKEN` | `changeme` | auth for metadata updates and skip endpoint — change it |
| `STREAM_BITRATE` | `128k` | AAC HLS stream bitrate |
| `SID_DURATION` | `180` | seconds per SID track |
| `MAX_TRACK` | `300` | hard cap per track, in seconds |

## How it works

One container (Node/Debian + supervisord) runs four processes: `station` indexes `/music`, picks
tracks and decodes them to PCM; a FIFO feeds the `encoder` (ffmpeg → AAC HLS with AES-128
segment encryption); `bridge` tracks now-playing over SSE and exposes `/api/now-playing` and
`/admin/skip`; `nginx` serves the player (`radio.html`), HLS segments, and proxies the bridge
endpoints. Decoders are ffmpeg + libgme (VGM/VGZ/SPC/NSF/…), ffmpeg + libopenmpt
(MOD/XM/IT/S3M/MPTM/…), sidplayfp (SID), and native (MP3/FLAC/WAV). The catalogue is built
by `minerva-indexer.sh` into a `/data` volume, so `/music` can stay read-only. Listeners are within a few seconds of each other (standard HLS behaviour).

## Credits

Decoding by ffmpeg, libgme (Blargg's game-music-emu, LGPL), libopenmpt and sidplayfp.
CRT look inspired by cool-retro-term. Bundled components keep their upstream licenses — review them before redistributing.
You are responsible for the rights to any music you broadcast.
