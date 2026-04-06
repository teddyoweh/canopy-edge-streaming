# Canopy Edge Streaming

Drop this folder on any computer with a camera. Run one command. Get a public URL.

## Quick Start

```bash
chmod +x run.sh
./run.sh
```

That's it. Works on a completely fresh Mac Mini — no Python, no accounts, nothing needed.

## How URL Persistence Works

The tunnel URL **stays the same as long as the script is running**. It does NOT change randomly.

- Script running → URL stays alive → 48 hours, 7 days, whatever
- Mac goes to sleep → `caffeinate` prevents this
- Internet blip → Cloudflare auto-reconnects (same URL)
- Streamer crashes → watchdog restarts it (same URL)
- Tunnel process dies → watchdog restarts tunnel → **new URL** (rare, only on crash)

If the tunnel does get a new URL, it:
1. Prints the new URL in the terminal
2. Saves it to `STREAM_URL.txt`
3. Copies it to clipboard
4. Auto-updates the screen in Canopy backend (if SCREEN_ID is set)

## Auto-Sync with Canopy (Optional)

To auto-update the screen's URL in Canopy when the tunnel restarts:

```bash
SCREEN_ID="your-screen-uuid" API_TOKEN="your-admin-jwt" ./run.sh
```

This way nobody needs to manually paste a URL — the script handles it.

## Options

```bash
CAMERA=1 ./run.sh              # Different camera index
SOURCE=video.mp4 ./run.sh      # Video file instead of camera
RESOLUTION=1280x720 ./run.sh   # Higher resolution
FPS=30 ./run.sh                # Higher frame rate
PORT=9000 ./run.sh             # Different port
```

## For the Dubai Demo

1. Copy this folder to the Mac Mini
2. Plug in camera + ethernet
3. Open Terminal, run: `./run.sh`
4. Send the URL it prints to your team
5. Team sets it as the screen's stream_url in Canopy admin
6. Leave it running — it handles everything

## What Gets Installed Automatically

- **Homebrew** (macOS package manager)
- **Python 3.13** (via Homebrew)
- **cloudflared** (Cloudflare Tunnel CLI)
- **Python packages** (opencv, flask, gunicorn, numpy)
- Everything goes into this folder — no system pollution

## Troubleshooting

- **Check status**: `cat STREAM_URL.txt`
- **Check logs**: `cat logs/main.log`
- **Streamer logs**: `cat logs/streamer.log`
- **Tunnel logs**: `cat logs/tunnel.log`
- **Restart**: Ctrl+C then `./run.sh` again
