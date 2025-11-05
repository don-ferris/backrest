Concrete implementations and commands

1) Automatic console autologin (systemd getty)
- Create directory:
  sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
- Create override file /etc/systemd/system/getty@tty1.service.d/autologin.conf with contents:
  [Service]
  ExecStart=
  ExecStart=-/sbin/agetty --autologin backrest --noclear %I $TERM
- Then reload systemd:
  sudo systemctl daemon-reload
  sudo systemctl restart getty@tty1.service

Notes and variants:
- For serial consoles (ttyS0): repeat for getty@ttyS0.service.d.
- If you prefer a custom systemd unit autologin@tty1.service can be used but the getty override is standard.

2) Launching the main script automatically after login
- Option A (preferred): systemd user or system service launched on boot:
  - Add a systemd service /etc/systemd/system/backrest.service with ExecStart=/usr/local/bin/backrest.py
  - WantedBy=multi-user.target
  Benefits: runs even without a login, easier lifecycle and logging.
- Option B: Place a single-line call in /home/backrest/.bash_profile or .bashrc to exec the menu only once:
  if [ -t 1 ]; then exec /usr/local/bin/backrest.py; fi
  (Be careful: this will replace the shell; use only if you want interactive console exclusively.)
