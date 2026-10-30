# iPad Controls v1.0.0

A small native Mac app for mouse and keyboard control of an iPad **after Omarchy is up at its desktop**. Useful during Linux bring-up when native touch or directly attached input is unavailable.

Includes pointer capture, clicks, dragging, scrolling, keyboard forwarding, Escape-to-release, reconnect attempts and an optional Omarchy System info action. The iPad remains the display.

The release contains a credential-free Apple silicon macOS app and buildable source. Configure your own authenticated SSH connection and verified host key locally before use. macOS 13+, Python 3 on 64-bit Linux, a running compositor and user access to `/dev/uinput` are required. The app is ad-hoc signed, not notarized.

The original connection was tested on an iPad Air 2/J81 Omarchy desktop with Labwc: real mouse X/Y, key down/up, release-all, heartbeat and disconnect device cleanup passed. Public configuration and build paths were checked separately. Other hardware and layouts remain unqualified.

No private keys, device host keys, personal paths, owner identifiers, Wi-Fi credentials, private screenshots, firmware or device dumps are distributed. Linux boot/install remains part of the separate device setup.
