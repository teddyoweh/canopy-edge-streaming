"""
Canopy Streamer — macOS Status Window

A lightweight tkinter GUI that shows streaming status, the public URL,
and lets the user copy/stop with one click. Polls the local Flask
server's /status endpoint for live updates.

Phases:
  1. Setup — spinner while backend installs deps, starts server, creates tunnel
  2. Register — screen name + campaign picker (only on first run, skipped if .config exists)
  3. Streaming — live stats, URL, copy button, stop button

IMPORTANT: This file uses ONLY Python stdlib (tkinter, urllib, json, etc.)
so it can be launched with the system/brew Python BEFORE the venv exists.
This lets us show the window immediately while deps install in the background.

Usage (called by the launcher, not directly):
    python gui.py --port 8554 --progress-file /path/to/.setup_progress [--url-file ...] [--pid-file ...]
"""

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import font as tkfont
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError


# ── Colors ────────────────────────────────────────────────────────────────

BG           = "#111111"
BG_CARD      = "#1a1a1a"
BG_INPUT     = "#222222"
BORDER       = "#333333"
BORDER_FOCUS = "#555555"
TEXT          = "#ffffff"
TEXT_DIM      = "#888888"
TEXT_PLACEHOLDER = "#666666"
ACCENT        = "#FF5F0F"
ACCENT_HOVER  = "#e0540d"
GREEN         = "#22c55e"
RED           = "#dc2626"
YELLOW        = "#eab308"


# ── Setup progress steps (written by launcher to .setup_progress file) ──

SETUP_MESSAGES = {
    "checking_python":       "Checking for Python...",
    "installing_python":     "Installing Python (first run only)...",
    "installing_homebrew":   "Installing Homebrew (first run only)...",
    "installing_cloudflared":"Installing Cloudflare Tunnel...",
    "creating_venv":         "Creating Python environment...",
    "installing_deps":       "Installing streaming dependencies...",
    "checking_camera":       "Requesting camera access...",
    "starting_server":       "Starting camera server...",
    "creating_tunnel":       "Creating public tunnel...",
    "ready":                 "Stream is live!",
}


# ── API helper (stdlib only) ──────────────────────────────────────────────

def api_call(url, method="GET", data=None, token=None, timeout=10):
    """Make an HTTP request using only stdlib. Returns (status_code, parsed_json)."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode() if data else None
    req = Request(url, data=body, headers=headers, method=method)
    try:
        resp = urlopen(req, timeout=timeout)
        return resp.status, json.loads(resp.read().decode())
    except HTTPError as e:
        try:
            body = json.loads(e.read().decode())
        except Exception:
            body = {"detail": str(e)}
        return e.code, body
    except Exception as e:
        return 0, {"detail": str(e)}


def _generate_screen_name():
    """Generate a default screen name from hostname."""
    hostname = socket.gethostname().replace(".local", "").replace("-", " ").title()
    return f"{hostname} Screen"


class CanopyStatusWindow:
    def __init__(self, port: int, url_file: str, pid_file: str, progress_file: str,
                 config_file: str = "", api_url: str = ""):
        self.port = port
        self.url_file = url_file
        self.pid_file = pid_file
        self.progress_file = progress_file
        self.config_file = config_file
        self.api_url = api_url
        self.public_url = ""
        self.running = True
        self.is_ready = False       # Backend is fully up
        self.is_registered = False  # Screen registered in Canopy
        self.setup_error = None

        # Registration state
        self._api_token = ""
        self._campaigns = []
        self._screen_id = ""

        # Check if already registered
        self._load_config()

        self.root = tk.Tk()
        self.root.title("Canopy Streamer")
        self.root.configure(bg=BG)
        self.root.geometry("520x680")
        self.root.minsize(460, 520)
        self.root.resizable(True, True)

        # Attempt to set the app icon (won't crash if missing)
        try:
            icon_path = os.path.join(os.path.dirname(__file__), "AppIcon.icns")
            if os.path.exists(icon_path):
                self.root.iconphoto(False, tk.PhotoImage(file=icon_path))
        except Exception:
            pass

        self._build_ui()
        self._poll_progress()
        self._poll_status()
        self._poll_url()

        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _load_config(self):
        """Load saved config if it exists."""
        if not self.config_file or not os.path.exists(self.config_file):
            return
        try:
            with open(self.config_file) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("SAVED_SCREEN_ID="):
                        self._screen_id = line.split("=", 1)[1].strip('"')
                    elif line.startswith("SAVED_API_TOKEN="):
                        self._api_token = line.split("=", 1)[1].strip('"')
            if self._screen_id:
                self.is_registered = True
        except Exception:
            pass

    def _save_config(self, screen_id, screen_name, token):
        """Save registration config."""
        if not self.config_file:
            return
        try:
            # Preserve existing lines that aren't screen/token related
            existing = {}
            if os.path.exists(self.config_file):
                with open(self.config_file) as f:
                    for line in f:
                        line = line.strip()
                        if "=" in line and not line.startswith("#"):
                            key = line.split("=", 1)[0]
                            if key not in ("SAVED_SCREEN_ID", "SAVED_SCREEN_NAME", "SAVED_API_TOKEN"):
                                existing[key] = line
            with open(self.config_file, "w") as f:
                f.write(f'SAVED_SCREEN_ID="{screen_id}"\n')
                f.write(f'SAVED_SCREEN_NAME="{screen_name}"\n')
                f.write(f'SAVED_API_TOKEN="{token}"\n')
                for line in existing.values():
                    f.write(line + "\n")
        except Exception:
            pass

    # ── UI ────────────────────────────────────────────────────────────────

    def _build_ui(self):
        root = self.root

        # Fonts — use system fonts with fallbacks
        self.font_title = tkfont.Font(family="SF Pro Display", size=18, weight="bold")
        self.font_sub   = tkfont.Font(family="SF Pro Text", size=11)
        self.font_url   = tkfont.Font(family="SF Mono", size=13, weight="bold")
        self.font_label = tkfont.Font(family="SF Pro Text", size=10)
        self.font_value = tkfont.Font(family="SF Pro Display", size=22, weight="bold")
        self.font_btn   = tkfont.Font(family="SF Pro Text", size=12, weight="bold")
        self.font_small = tkfont.Font(family="SF Pro Text", size=10)
        self.font_setup = tkfont.Font(family="SF Pro Text", size=13)
        self.font_input = tkfont.Font(family="SF Pro Text", size=12)

        # Main container with padding
        self.main = tk.Frame(root, bg=BG, padx=24, pady=20)
        self.main.pack(fill="both", expand=True)

        # ── Header (always visible) ──
        tk.Label(self.main, text="Canopy Streamer", font=self.font_title,
                 bg=BG, fg=ACCENT).pack(anchor="w")

        self.lbl_subtitle = tk.Label(self.main, text="Starting up...",
                                     font=self.font_sub, bg=BG, fg=TEXT_DIM)
        self.lbl_subtitle.pack(anchor="w", pady=(2, 16))

        # ── Setup phase (shown while backend is setting up) ──
        self.setup_frame = tk.Frame(self.main, bg=BG)
        self.setup_frame.pack(fill="both", expand=True)

        # Spacer to center content vertically
        tk.Frame(self.setup_frame, bg=BG, height=40).pack()

        # Spinner / progress area
        self.setup_dot = tk.Canvas(self.setup_frame, width=48, height=48,
                                   bg=BG, highlightthickness=0)
        self.setup_dot.pack(pady=(0, 16))
        self._spinner_angle = 0
        self._draw_spinner()

        self.lbl_setup_msg = tk.Label(self.setup_frame, text="Starting up...",
                                      font=self.font_setup, bg=BG, fg=TEXT)
        self.lbl_setup_msg.pack()

        self.lbl_setup_detail = tk.Label(self.setup_frame,
                                         text="This takes about a minute on first run.",
                                         font=self.font_small, bg=BG, fg=TEXT_DIM)
        self.lbl_setup_detail.pack(pady=(6, 0))

        # Setup step indicators
        tk.Frame(self.setup_frame, bg=BG, height=30).pack()

        self.setup_steps_frame = tk.Frame(self.setup_frame, bg=BG)
        self.setup_steps_frame.pack()

        self.step_labels = {}
        steps_display = [
            ("installing_deps",    "Install dependencies"),
            ("checking_camera",    "Camera access"),
            ("starting_server",    "Start server"),
            ("creating_tunnel",    "Create public URL"),
        ]
        for step_key, step_text in steps_display:
            row = tk.Frame(self.setup_steps_frame, bg=BG)
            row.pack(fill="x", pady=2)
            dot = tk.Label(row, text="\u25cb", font=self.font_small, bg=BG, fg=TEXT_DIM)
            dot.pack(side="left", padx=(0, 8))
            lbl = tk.Label(row, text=step_text, font=self.font_small, bg=BG, fg=TEXT_DIM)
            lbl.pack(side="left")
            self.step_labels[step_key] = (dot, lbl)

        # ── Registration phase (shown after setup, before streaming) ──
        self._build_register_ui()

        # ── Streaming phase (shown when backend is ready) ──
        self._build_stream_ui()

    def _build_register_ui(self):
        """Build the screen registration form — dead simple, almost hands-free."""
        self.register_frame = tk.Frame(self.main, bg=BG)
        # NOT packed yet — shown after setup completes if not registered

        # Title
        tk.Label(self.register_frame, text="Almost ready!",
                 font=self.font_setup, bg=BG, fg=GREEN).pack(anchor="w", pady=(0, 4))
        tk.Label(self.register_frame,
                 text="Pick a campaign and hit the big button.",
                 font=self.font_small, bg=BG, fg=TEXT_DIM).pack(anchor="w", pady=(0, 20))

        # ── Campaign dropdown (the main thing) ──
        tk.Label(self.register_frame, text="CAMPAIGN", font=self.font_label,
                 bg=BG, fg=TEXT_DIM).pack(anchor="w", pady=(0, 4))

        self._campaign_var = tk.StringVar(value="Loading campaigns...")
        self._campaign_menu = tk.OptionMenu(self.register_frame, self._campaign_var, "Loading...")
        self._campaign_menu.config(
            font=self.font_input, bg=BG_INPUT, fg=TEXT, activebackground=BORDER,
            activeforeground=TEXT, highlightbackground=BORDER, highlightthickness=1,
            relief="flat", bd=6, width=40, anchor="w",
        )
        self._campaign_menu["menu"].config(
            font=self.font_input, bg=BG_INPUT, fg=TEXT, activebackground=ACCENT,
            activeforeground=TEXT, relief="flat", bd=0,
        )
        self._campaign_menu.pack(fill="x", pady=(0, 16))

        # ── Screen name (auto-filled, editable) ──
        tk.Label(self.register_frame, text="SCREEN NAME", font=self.font_label,
                 bg=BG, fg=TEXT_DIM).pack(anchor="w", pady=(0, 4))
        self.entry_name = tk.Entry(self.register_frame, font=self.font_input,
                                   bg=BG_INPUT, fg=TEXT, insertbackground=TEXT,
                                   highlightbackground=BORDER, highlightcolor=BORDER_FOCUS,
                                   highlightthickness=1, relief="flat", bd=8)
        self.entry_name.pack(fill="x", pady=(0, 12))
        self.entry_name.insert(0, _generate_screen_name())

        # ── City + Zone in one row (optional, small) ──
        loc_row = tk.Frame(self.register_frame, bg=BG)
        loc_row.pack(fill="x", pady=(0, 20))
        loc_row.columnconfigure(0, weight=1)
        loc_row.columnconfigure(1, weight=1)

        city_frame = tk.Frame(loc_row, bg=BG)
        city_frame.grid(row=0, column=0, sticky="ew", padx=(0, 6))
        tk.Label(city_frame, text="CITY (optional)", font=self.font_label,
                 bg=BG, fg=TEXT_DIM).pack(anchor="w", pady=(0, 4))
        self.entry_city = tk.Entry(city_frame, font=self.font_small,
                                   bg=BG_INPUT, fg=TEXT, insertbackground=TEXT,
                                   highlightbackground=BORDER, highlightcolor=BORDER_FOCUS,
                                   highlightthickness=1, relief="flat", bd=6)
        self.entry_city.pack(fill="x")

        zone_frame = tk.Frame(loc_row, bg=BG)
        zone_frame.grid(row=0, column=1, sticky="ew", padx=(6, 0))
        tk.Label(zone_frame, text="ZONE (optional)", font=self.font_label,
                 bg=BG, fg=TEXT_DIM).pack(anchor="w", pady=(0, 4))
        self.entry_zone = tk.Entry(zone_frame, font=self.font_small,
                                   bg=BG_INPUT, fg=TEXT, insertbackground=TEXT,
                                   highlightbackground=BORDER, highlightcolor=BORDER_FOCUS,
                                   highlightthickness=1, relief="flat", bd=6)
        self.entry_zone.pack(fill="x")

        # ── BIG register button ──
        self.btn_register = tk.Label(self.register_frame,
                                     text="Start Streaming",
                                     font=tkfont.Font(family="SF Pro Display", size=16, weight="bold"),
                                     bg=ACCENT, fg=TEXT,
                                     padx=20, pady=14, cursor="hand2")
        self.btn_register.pack(fill="x", pady=(0, 8))
        self.btn_register.bind("<Button-1>", lambda e: self._do_register())
        self.btn_register.bind("<Enter>", lambda e: self.btn_register.config(bg=ACCENT_HOVER))
        self.btn_register.bind("<Leave>", lambda e: self.btn_register.config(bg=ACCENT))

        # Status label (shows success/error)
        self.lbl_register_status = tk.Label(self.register_frame, text="",
                                            font=self.font_small, bg=BG, fg=TEXT_DIM)
        self.lbl_register_status.pack(anchor="w", pady=(0, 6))

        # Skip link (small, unobtrusive)
        self.btn_skip = tk.Label(self.register_frame,
                                 text="Skip registration \u2192",
                                 font=self.font_small, bg=BG, fg=TEXT_DIM, cursor="hand2")
        self.btn_skip.pack(anchor="center")
        self.btn_skip.bind("<Button-1>", lambda e: self._skip_register())
        self.btn_skip.bind("<Enter>", lambda e: self.btn_skip.config(fg=TEXT))
        self.btn_skip.bind("<Leave>", lambda e: self.btn_skip.config(fg=TEXT_DIM))

    def _build_stream_ui(self):
        """Build the streaming status view."""
        self.stream_frame = tk.Frame(self.main, bg=BG)
        # NOT packed yet — shown when ready

        # Status indicator
        status_frame = tk.Frame(self.stream_frame, bg=BG)
        status_frame.pack(fill="x", pady=(0, 12))

        self.status_dot = tk.Canvas(status_frame, width=12, height=12,
                                    bg=BG, highlightthickness=0)
        self.status_dot.pack(side="left", padx=(0, 8))
        self._draw_dot(YELLOW)

        self.lbl_status = tk.Label(status_frame, text="Connecting...",
                                   font=self.font_sub, bg=BG, fg=TEXT)
        self.lbl_status.pack(side="left")

        # URL Card
        url_card = tk.Frame(self.stream_frame, bg=BG_CARD, highlightbackground=BORDER,
                            highlightthickness=1, padx=16, pady=14)
        url_card.pack(fill="x", pady=(0, 16))

        tk.Label(url_card, text="STREAM URL", font=self.font_label,
                 bg=BG_CARD, fg=TEXT_DIM).pack(anchor="w")

        url_row = tk.Frame(url_card, bg=BG_CARD)
        url_row.pack(fill="x", pady=(6, 0))

        self.lbl_url = tk.Label(url_row, text="Waiting for tunnel...",
                                font=self.font_url, bg=BG_CARD, fg=ACCENT,
                                wraplength=380, justify="left")
        self.lbl_url.pack(side="left", fill="x", expand=True, anchor="w")

        self.btn_copy = tk.Label(url_row, text="  Copy  ", font=self.font_btn,
                                  bg=BG_CARD, fg=TEXT_DIM,
                                  cursor="arrow")
        self.btn_copy.pack(side="right", padx=(10, 0))
        self._copy_enabled = False

        self.lbl_copied = tk.Label(url_card, text="", font=self.font_small,
                                   bg=BG_CARD, fg=GREEN)
        self.lbl_copied.pack(anchor="w", pady=(4, 0))

        # Hint
        tk.Label(self.stream_frame,
                 text="Paste this URL as the Stream URL in Canopy admin.",
                 font=self.font_small, bg=BG, fg=TEXT_DIM).pack(anchor="w", pady=(0, 16))

        # Stats Grid
        stats_frame = tk.Frame(self.stream_frame, bg=BG)
        stats_frame.pack(fill="x", pady=(0, 16))

        stats_frame.columnconfigure(0, weight=1)
        stats_frame.columnconfigure(1, weight=1)
        stats_frame.columnconfigure(2, weight=1)
        stats_frame.columnconfigure(3, weight=1)

        self.stat_fps    = self._make_stat(stats_frame, "FPS",     "\u2014", 0)
        self.stat_frames = self._make_stat(stats_frame, "FRAMES",  "\u2014", 1)
        self.stat_uptime = self._make_stat(stats_frame, "UPTIME",  "\u2014", 2)
        self.stat_status = self._make_stat(stats_frame, "CAMERA",  "\u2014", 3)

        # Links
        links_card = tk.Frame(self.stream_frame, bg=BG_CARD, highlightbackground=BORDER,
                              highlightthickness=1, padx=16, pady=12)
        links_card.pack(fill="x", pady=(0, 16))

        tk.Label(links_card, text="OTHER ENDPOINTS", font=self.font_label,
                 bg=BG_CARD, fg=TEXT_DIM).pack(anchor="w", pady=(0, 6))

        self.lbl_dashboard = tk.Label(links_card, text="Dashboard: \u2014",
                                      font=self.font_small, bg=BG_CARD, fg=TEXT_DIM)
        self.lbl_dashboard.pack(anchor="w", pady=1)

        self.lbl_snapshot = tk.Label(links_card, text="Snapshot:  \u2014",
                                     font=self.font_small, bg=BG_CARD, fg=TEXT_DIM)
        self.lbl_snapshot.pack(anchor="w", pady=1)

        self.lbl_local = tk.Label(links_card, text=f"Local:     http://localhost:{self.port}",
                                   font=self.font_small, bg=BG_CARD, fg=TEXT_DIM)
        self.lbl_local.pack(anchor="w", pady=1)

        # Stop Button (Label-based to respect colors on macOS)
        self.btn_stop = tk.Label(self.stream_frame, text="Stop Streaming",
                                 font=self.font_btn,
                                 bg=RED, fg=TEXT,
                                 padx=20, pady=8,
                                 cursor="hand2")
        self.btn_stop.pack(fill="x", pady=(0, 4))
        self.btn_stop.bind("<Button-1>", lambda e: self._stop())
        self.btn_stop.bind("<Enter>", lambda e: self.btn_stop.config(bg="#b91c1c"))
        self.btn_stop.bind("<Leave>", lambda e: self.btn_stop.config(bg=RED))

        tk.Label(self.stream_frame,
                 text="Auto-restarts on failure. Close this window to stop.",
                 font=self.font_small, bg=BG, fg=TEXT_DIM).pack(anchor="center")

    def _make_stat(self, parent, label, value, col):
        frame = tk.Frame(parent, bg=BG_CARD, highlightbackground=BORDER,
                         highlightthickness=1, padx=12, pady=10)
        frame.grid(row=0, column=col, padx=(0 if col == 0 else 4, 0), sticky="nsew")

        tk.Label(frame, text=label, font=self.font_label,
                 bg=BG_CARD, fg=TEXT_DIM).pack(anchor="w")
        lbl_val = tk.Label(frame, text=value, font=self.font_value,
                           bg=BG_CARD, fg=TEXT)
        lbl_val.pack(anchor="w")
        return lbl_val

    def _draw_dot(self, color):
        self.status_dot.delete("all")
        self.status_dot.create_oval(2, 2, 10, 10, fill=color, outline=color)

    # ── Spinner animation ─────────────────────────────────────────────────

    def _draw_spinner(self):
        c = self.setup_dot
        c.delete("all")
        import math
        cx, cy, r = 24, 24, 18
        for i in range(12):
            angle = math.radians(self._spinner_angle + i * 30)
            x1 = cx + r * math.cos(angle)
            y1 = cy + r * math.sin(angle)
            x2 = cx + (r - 6) * math.cos(angle)
            y2 = cy + (r - 6) * math.sin(angle)
            brightness = max(0x33, int(0xFF * (1 - i / 12)))
            color = f"#{brightness:02x}{brightness:02x}{brightness:02x}"
            c.create_line(x1, y1, x2, y2, fill=color, width=2.5, capstyle="round")

        self._spinner_angle = (self._spinner_angle - 30) % 360

        if not self.is_ready and self.running:
            self.root.after(100, self._draw_spinner)

    # ── Phase transitions ─────────────────────────────────────────────────

    def _switch_to_register(self):
        """Show registration form after setup completes."""
        self.setup_frame.pack_forget()
        self.register_frame.pack(fill="both", expand=True)
        self.lbl_subtitle.config(text="Register this screen")
        # Start loading campaigns in background
        threading.Thread(target=self._fetch_campaigns, daemon=True).start()

    def _switch_to_streaming(self):
        """Hide current phase, show streaming phase."""
        if self.is_ready:
            return
        self.is_ready = True
        self.setup_frame.pack_forget()
        self.register_frame.pack_forget()
        self.stream_frame.pack(fill="both", expand=True)
        self.lbl_subtitle.config(text="Stream is live!")
        # Re-apply URL if it was loaded before this view was shown
        if self.public_url:
            self._update_url(self.public_url)

    # ── Registration: API calls ───────────────────────────────────────────

    def _auth_login(self):
        """Authenticate with admin credentials. Returns token or empty string."""
        if self._api_token:
            # Verify existing token
            status, _ = api_call(f"{self.api_url}/auth/me", token=self._api_token, timeout=5)
            if status == 200:
                return self._api_token

        # Login with default admin creds
        email = os.environ.get("CANOPY_ADMIN_EMAIL", "admin2@canopyads.io")
        password = os.environ.get("CANOPY_ADMIN_PASS", "Admin123!")
        status, data = api_call(
            f"{self.api_url}/auth/login", method="POST",
            data={"email": email, "password": password}
        )
        if status == 200 and "access_token" in data:
            self._api_token = data["access_token"]
            return self._api_token
        return ""

    def _fetch_campaigns(self):
        """Fetch campaigns list from API (runs in background thread)."""
        # Authenticate first
        token = self._auth_login()
        if not token:
            self.root.after(0, self._show_campaign_error, "Could not authenticate with Canopy API.")
            return

        status, data = api_call(
            f"{self.api_url}/engagement/campaigns-list",
            token=token
        )
        if status == 200 and isinstance(data, list):
            self._campaigns = data
            self.root.after(0, self._render_campaigns)
        else:
            self.root.after(0, self._show_campaign_error, "Could not load campaigns.")

    def _show_campaign_error(self, msg):
        self._campaign_var.set("No campaigns available")

    def _render_campaigns(self):
        """Populate the campaign dropdown. Auto-select first. Auto-register if only one."""
        menu = self._campaign_menu["menu"]
        menu.delete(0, "end")

        if not self._campaigns:
            self._campaign_var.set("No campaigns available")
            return

        # Build display names and populate dropdown
        self._campaign_display = {}  # display_name -> campaign dict
        for camp in self._campaigns:
            name = camp.get("name", "Unnamed")
            status = camp.get("status", "")
            display = f"{name}  ({status})" if status else name
            self._campaign_display[display] = camp
            menu.add_command(
                label=display,
                command=lambda d=display: self._campaign_var.set(d),
            )

        # Add "No campaign" option
        menu.add_separator()
        menu.add_command(
            label="No campaign (register only)",
            command=lambda: self._campaign_var.set("No campaign (register only)"),
        )
        self._campaign_display["No campaign (register only)"] = None

        # Pre-select the first campaign (user can change via dropdown)
        first_display = list(self._campaign_display.keys())[0]
        self._campaign_var.set(first_display)

    def _do_register(self):
        """Register the screen (runs API call in background)."""
        screen_name = self.entry_name.get().strip()
        if not screen_name:
            screen_name = _generate_screen_name()

        # Disable button
        self.btn_register.config(text="Registering...", bg=BORDER, cursor="arrow")
        self.btn_register.unbind("<Button-1>")
        self.lbl_register_status.config(text="Setting up your screen...", fg=ACCENT)

        city = self.entry_city.get().strip()
        zone = self.entry_zone.get().strip()

        # Get campaign from dropdown
        campaign_id = ""
        selected = self._campaign_var.get()
        camp = self._campaign_display.get(selected) if hasattr(self, "_campaign_display") else None
        if camp:
            campaign_id = camp.get("id", "")

        threading.Thread(
            target=self._register_thread,
            args=(screen_name, city, zone, campaign_id),
            daemon=True,
        ).start()

    def _register_thread(self, screen_name, city, zone, campaign_id):
        """Background thread for registration API call."""
        token = self._auth_login()
        if not token:
            self.root.after(0, self._register_failed, "Authentication failed.")
            return

        # Get stream URL
        stream_url = ""
        if self.public_url:
            stream_url = self.public_url + "/stream"
        else:
            stream_url = f"http://localhost:{self.port}/stream"

        payload = {
            "screen_name": screen_name,
            "stream_url": stream_url,
            "city": city,
            "zone": zone,
        }
        if campaign_id:
            payload["campaign_id"] = campaign_id

        status, data = api_call(
            f"{self.api_url}/engagement/provision",
            method="POST", data=payload, token=token
        )

        if status in (200, 201) and data.get("screen_id"):
            screen_id = data["screen_id"]
            self._screen_id = screen_id
            self._save_config(screen_id, screen_name, token)
            msg = data.get("message", "Screen registered!")
            self.root.after(0, self._register_success, msg)
        else:
            detail = data.get("detail", data.get("message", "Unknown error"))
            self.root.after(0, self._register_failed, str(detail))

    def _register_success(self, msg):
        self.is_registered = True
        self.lbl_register_status.config(text=msg, fg=GREEN)
        # Transition to streaming after a brief moment
        self.root.after(1200, self._switch_to_streaming)

    def _register_failed(self, msg):
        self.lbl_register_status.config(text=msg, fg=RED)
        # Re-enable button
        self.btn_register.config(text="Register & Start", bg=ACCENT, cursor="hand2")
        self.btn_register.bind("<Button-1>", lambda e: self._do_register())

    def _skip_register(self):
        """Skip registration and go straight to streaming."""
        self._switch_to_streaming()

    # ── Actions ───────────────────────────────────────────────────────────

    def _copy_url(self, event=None):
        if self._copy_enabled and self.public_url:
            self.root.clipboard_clear()
            self.root.clipboard_append(self.public_url + "/stream")
            self.lbl_copied.config(text="Copied to clipboard!")
            self.root.after(2000, lambda: self.lbl_copied.config(text=""))

    def _stop(self):
        self.running = False
        self.lbl_status.config(text="Stopping...")
        self._draw_dot(RED)

        def _kill():
            if os.path.exists(self.pid_file):
                try:
                    with open(self.pid_file) as f:
                        for line in f:
                            pid = line.strip()
                            if pid:
                                try:
                                    os.kill(int(pid), signal.SIGTERM)
                                except (ProcessLookupError, ValueError):
                                    pass
                except Exception:
                    pass

            ppid = os.getppid()
            try:
                os.kill(ppid, signal.SIGTERM)
            except Exception:
                pass

            self.root.after(500, self.root.destroy)

        threading.Thread(target=_kill, daemon=True).start()

    def _on_close(self):
        self._stop()

    # ── Polling: setup progress ───────────────────────────────────────────

    def _poll_progress(self):
        if not self.running or self.is_ready:
            return

        def check():
            try:
                if os.path.exists(self.progress_file):
                    with open(self.progress_file) as f:
                        lines = f.readlines()
                    current_step = None
                    error_msg = None
                    completed_steps = set()

                    for line in lines:
                        line = line.strip()
                        if line.startswith("STEP:"):
                            step = line[5:]
                            if current_step:
                                completed_steps.add(current_step)
                            current_step = step
                        elif line.startswith("ERROR:"):
                            error_msg = line[6:]

                    self.root.after(0, self._update_progress,
                                   current_step, completed_steps, error_msg)
            except Exception:
                pass

        threading.Thread(target=check, daemon=True).start()
        self.root.after(500, self._poll_progress)

    def _update_progress(self, current_step, completed_steps, error_msg):
        if error_msg:
            self.setup_error = error_msg
            self.lbl_setup_msg.config(text="Setup failed", fg=RED)
            self.lbl_setup_detail.config(text=error_msg)
            return

        if current_step:
            msg = SETUP_MESSAGES.get(current_step, f"Working ({current_step})...")
            self.lbl_setup_msg.config(text=msg)

            if current_step == "ready":
                self.lbl_setup_detail.config(text="")
                if self.is_registered:
                    # Already registered — go straight to streaming
                    self.root.after(800, self._switch_to_streaming)
                else:
                    # Show registration form
                    self.root.after(800, self._switch_to_register)
            else:
                self.lbl_setup_detail.config(text="This takes about a minute on first run.")

        # Update step indicators
        step_order = ["installing_deps", "checking_camera", "starting_server", "creating_tunnel"]
        for step_key in step_order:
            if step_key not in self.step_labels:
                continue
            dot_lbl, text_lbl = self.step_labels[step_key]
            if step_key in completed_steps:
                dot_lbl.config(text="\u25cf", fg=GREEN)
                text_lbl.config(fg=GREEN)
            elif step_key == current_step:
                dot_lbl.config(text="\u25c9", fg=ACCENT)
                text_lbl.config(fg=TEXT)
            else:
                dot_lbl.config(text="\u25cb", fg=TEXT_DIM)
                text_lbl.config(fg=TEXT_DIM)

    # ── Polling: server status ────────────────────────────────────────────

    def _poll_status(self):
        if not self.running:
            return

        def fetch():
            try:
                resp = urlopen(f"http://localhost:{self.port}/status", timeout=3)
                data = json.loads(resp.read().decode())
                self.root.after(0, self._update_stats, data)
            except (URLError, Exception):
                if self.is_ready:
                    self.root.after(0, self._show_connecting)

        threading.Thread(target=fetch, daemon=True).start()
        self.root.after(2000, self._poll_status)

    def _update_stats(self, data):
        if not self.is_ready:
            return  # Don't auto-switch — let the registration flow handle it

        fps = data.get("fps", 0)
        frames = data.get("frames", 0)
        uptime_s = data.get("uptime_seconds", 0)
        camera = data.get("camera", "Unknown")
        status = data.get("status", "unknown")

        m, s = divmod(uptime_s, 60)
        h, m = divmod(m, 60)
        uptime_str = f"{h}h{m}m" if h > 0 else f"{m}m{s}s"

        if frames > 1_000_000:
            frames_str = f"{frames/1_000_000:.1f}M"
        elif frames > 1000:
            frames_str = f"{frames/1000:.1f}K"
        else:
            frames_str = str(frames)

        self.stat_fps.config(text=str(fps))
        self.stat_frames.config(text=frames_str)
        self.stat_uptime.config(text=uptime_str)
        self.stat_status.config(text="OK" if status == "streaming" else "...")

        if status == "streaming":
            self._draw_dot(GREEN)
            self.lbl_status.config(text="Streaming")
            self.lbl_subtitle.config(text=camera)
        else:
            self._draw_dot(YELLOW)
            self.lbl_status.config(text="Starting camera...")

    def _show_connecting(self):
        self._draw_dot(YELLOW)
        self.lbl_status.config(text="Reconnecting...")

    # ── Polling: tunnel URL ───────────────────────────────────────────────

    def _poll_url(self):
        if not self.running:
            return

        def check():
            try:
                if os.path.exists(self.url_file):
                    with open(self.url_file) as f:
                        url = f.read().strip()
                    if url and url != self.public_url:
                        self.public_url = url
                        self.root.after(0, self._update_url, url)
            except Exception:
                pass

        threading.Thread(target=check, daemon=True).start()
        self.root.after(3000, self._poll_url)

    def _update_url(self, url):
        # Always store the URL; update labels if streaming view is visible
        self.lbl_url.config(text=url + "/stream")
        self._copy_enabled = True
        self.btn_copy.config(bg=ACCENT, fg=TEXT, cursor="hand2")
        self.btn_copy.bind("<Button-1>", self._copy_url)
        self.btn_copy.bind("<Enter>", lambda e: self.btn_copy.config(bg=ACCENT_HOVER))
        self.btn_copy.bind("<Leave>", lambda e: self.btn_copy.config(bg=ACCENT))
        self.lbl_dashboard.config(text=f"Dashboard: {url}/")
        self.lbl_snapshot.config(text=f"Snapshot:  {url}/frame")

    # ── Run ────────────────────────────────────────────────────────────────

    def run(self):
        self.root.mainloop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8554)
    parser.add_argument("--url-file", default=".public_url")
    parser.add_argument("--pid-file", default=".pids")
    parser.add_argument("--progress-file", default=".setup_progress")
    parser.add_argument("--config-file", default="")
    parser.add_argument("--api-url", default="https://canopy-api-154019513092.us-central1.run.app/api/v1")
    args = parser.parse_args()

    app = CanopyStatusWindow(
        port=args.port,
        url_file=args.url_file,
        pid_file=args.pid_file,
        progress_file=args.progress_file,
        config_file=args.config_file,
        api_url=args.api_url,
    )
    app.run()


if __name__ == "__main__":
    main()
