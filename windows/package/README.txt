KVM Bridge - shared monitor + shared keyboard/mouse
==================================================

WHAT IT DOES
  Adds an icon to the notification area (system tray). Right-click it to
  switch the shared monitor to one of four inputs:

      USB-C (Mac)               value 15
      DisplayPort (Windows)     value 16
      HDMI 1                    value 17
      HDMI 2                    value 18

  The check mark reflects what the monitor is actually showing, read from the
  display over DDC/CI (VCP 0x60), so it stays correct even if you switch with
  the monitor's own OSD buttons.

  "keep display awake" is on by default. It stops Windows from turning the
  panel off, which would otherwise leave you looking at a black screen when
  you switch over to this machine.

HOTKEYS (global, same meaning on both machines)
      Ctrl+Alt+1    switch the monitor to the Mac   (USB-C)
      Ctrl+Alt+2    switch the monitor to Windows   (DisplayPort)

  On this side the hotkeys are handled inside the low-level keyboard hook
  rather than RegisterHotKey, so keystrokes that arrive from the Mac are
  never mistaken for local presses. That is what prevents one key press from
  triggering two switches.

  A switch is only considered done after the other end confirms it can see
  its own signal. If the other end does not confirm within 12 seconds, this
  program checks whether the screen bounced back and reports the real state
  instead of pretending the switch worked.

KEYBOARD / MOUSE SHARING
  Both ends are equal: either one can change the mode, and the other
  follows immediately (the choice is sent over the same connection).

      independent   each machine uses its own keyboard and mouse
      shared        both keyboards/mice can drive whichever machine owns
                    the screen

  Under "shared" there are two independent switches, "键盘" and "鼠标".
  Turning one off leaves that device entirely local on both machines, which
  makes it possible to test key and pointer paths separately.

  Mouse movement is coalesced into one message every 4 ms (max 250 per
  second) instead of one message per raw event. Sending every 125–1000 Hz
  sample as its own TCP packet builds a queue that shows up as cursor lag.

  In shared mode:
    - When the screen is on the Mac, this program captures the local
      keyboard and mouse and forwards them (the cursor is pinned to the
      screen centre so relative movement never hits the screen edge).
    - When the screen is on Windows, events forwarded from the Mac are
      injected here.

  Safety rules, all deliberate:
    - Capture is refused unless the Mac reports it can inject input
      (its Accessibility permission). Without that, capturing here would
      swallow your keyboard and deliver it nowhere.
    - Capture is released immediately when the connection drops, so a Mac
      crash can never leave you unable to use this machine.
    - Every key still held down is released on both ends when capture or
      forwarding stops, so no modifier gets stuck.
    - If both machines are used at the same time, the machine that currently
      owns the screen wins: locally injected input suppresses remote events
      for 400 ms.

  A heartbeat runs every 2 seconds. If nothing arrives for 7 seconds the
  connection is treated as dead and rebuilt, so a half-open TCP connection
  cannot silently swallow your input.

HOW TO BUILD
  1. Copy this folder to the Windows machine.
  2. Double-click build.cmd
  3. It produces KVMBridge.exe in the same folder.

  No downloads and no SDK required: build.cmd uses csc.exe that ships with
  .NET Framework 4.x, present on every Windows 10 / 11 install.

HOW TO RUN
  Double-click KVMBridge.exe. It requests administrator rights through
  app.manifest, because Windows blocks a normal process from injecting input
  into elevated windows.

  Keep app.ico in the same folder: the tray icon is loaded from that file.
  It is also embedded into the exe by build.cmd, which is why Explorer shows
  the same icon for the program itself.

  The icon may be hidden in the "^" overflow area of the notification area.
  Drag it onto the taskbar if you want it always visible.

  To quit: right-click the icon, choose "退出".

AUTO START (optional)
  Press Win+R, type:  shell:startup
  Put a shortcut to KVMBridge.exe in the folder that opens.

NOTES
  - VCP 0x60 is the MCCS standard "Input Source" code. If a monitor does not
    respond to it, this tool cannot switch it.
  - Values 17 / 18 for HDMI are the MCCS defaults and have not been verified
    on this specific monitor. If HDMI does not work, tell me the real value.
  - The USB-C port reports as 15 and the DisplayPort as 16 on this monitor
    because USB-C runs DP Alt Mode and the firmware registers it as the first
    DP channel.
  - A cursor is only drawn by Windows when a pointing device is present.
    If no physical mouse is attached the cursor may be invisible; the fix is
    to plug in any USB mouse or receiver.
  - The connection is not encrypted or authenticated. Anyone who can reach
    TCP 24801 on the Mac can inject input, so keep both machines on a trusted
    network.
