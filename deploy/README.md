# MiNERVA-FM — deploy with Docker Compose

Run the whole station from the prebuilt image — no repo, no build needed.

```bash
cp .env.example .env          # 1. set BRIDGE_TOKEN
#   ...put music in ./music   # 2. layout: <System>/<Game>/<files>
docker compose up -d          # 3. -> http://localhost:8080/  (click TUNE IN)
```

- **Music** lives in `./music` (mounted read-only). Example: `music/SNES/Chrono Trigger/01 Title.spc`.
- The **catalogue** is built on first run into the `catalogue` volume and persists across restarts.
- All formats decode in-container (ffmpeg+libgme for VGM/VGZ/SPC/NSF, sidplayfp for SID).
- Audio is streamed via HLS (AES-128 encrypted segments); no Icecast required.

## Image access

The image is pulled from `gitea.lft.onl/admini/minerva-fm`. If the registry requires auth:

```bash
docker login gitea.lft.onl
```

## Update

```bash
docker compose pull && docker compose up -d
```

## Security

Set a strong `BRIDGE_TOKEN` in `.env` before exposing this to a network. It protects the
`/meta/update` and `/admin/skip` endpoints. Only port `8080` is published externally;
put it behind a reverse proxy (Nginx Proxy Manager, Caddy, etc.) for TLS.
