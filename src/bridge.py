"""Session-scoped input devices, carried over the owner's authenticated USB SSH."""
import fcntl
import os
import select
import struct
import subprocess
import sys
import time

devices = []
pressed = set()

def device(name, mouse):
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    devices.append(fd)
    fcntl.ioctl(fd, 0x40045564, 1)  # UI_SET_EVBIT EV_KEY
    if mouse:
        fcntl.ioctl(fd, 0x40045564, 2)
        for code in (0, 1, 8):
            fcntl.ioctl(fd, 0x40045566, code)
        keys = (272, 273, 274)
    else:
        keys = range(1, 128)
    for code in keys:
        fcntl.ioctl(fd, 0x40045565, code)
    setup = struct.pack('80sHHHHi', name.encode(), 3, 0, 1 if mouse else 2, 1, 0)
    os.write(fd, setup + bytes(64 * 4 * 4))
    fcntl.ioctl(fd, 0x5501)  # UI_DEV_CREATE
    return fd

def emit(fd, kind, code, value):
    os.write(fd, struct.pack('llHHi', 0, 0, kind, code, value))

def sync(fd):
    emit(fd, 0, 0, 0)

def release():
    for fd, code in list(pressed):
        emit(fd, 1, code, 0)
        sync(fd)
    pressed.clear()

def command(line):
    words = line.split()
    if words == ['PING']:
        print('PONG', flush=True)
    elif words == ['RELEASE']:
        release()
    elif words == ['INFO']:
        env = dict(os.environ, XDG_RUNTIME_DIR='/run/user/1000', WAYLAND_DISPLAY='wayland-0',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus')
        subprocess.Popen(['/usr/local/bin/omarchy-launch-about'], env=env,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    elif len(words) == 3 and words[0] == 'MOVE':
        x, y = map(int, words[1:])
        if max(abs(x), abs(y)) > 2048:
            raise ValueError('Movement outside bounds')
        emit(mouse, 2, 0, x)
        emit(mouse, 2, 1, y)
        sync(mouse)
    elif len(words) == 2 and words[0] == 'WHEEL':
        value = int(words[1])
        if not -20 <= value <= 20:
            raise ValueError('Wheel outside bounds')
        emit(mouse, 2, 8, value)
        sync(mouse)
    elif len(words) == 3 and words[0] in ('KEY', 'BUTTON'):
        code, value = map(int, words[1:])
        is_key = words[0] == 'KEY'
        if value not in (0, 1, 2) or not (1 <= code <= 127 if is_key else 0 <= code <= 2):
            raise ValueError('Invalid key')
        fd = keyboard if is_key else mouse
        code = code if is_key else (272, 273, 274)[code]
        if value == 2 and (fd, code) not in pressed:
            return
        if value:
            pressed.add((fd, code))
        else:
            pressed.discard((fd, code))
        emit(fd, 1, code, value)
        sync(fd)
    else:
        raise ValueError('Unknown input command')

try:
    mouse = device('iPad Controls Mouse', True)
    keyboard = device('iPad Controls Keyboard', False)
    time.sleep(0.5)
    print('READY', flush=True)
    pending = b''
    last = time.monotonic()
    while True:
        ready, _, _ = select.select([0], [], [], 1)
        if not ready:
            if time.monotonic() - last > 8:
                release()
            if time.monotonic() - last > 30:
                break
            continue
        chunk = os.read(0, 8192)
        if not chunk:
            break
        last = time.monotonic()
        pending += chunk
        if len(pending) > 65536:
            raise ValueError('Input buffer exceeded')
        while b'\n' in pending:
            line, pending = pending.split(b'\n', 1)
            command(line.decode('ascii'))
finally:
    release()
    for fd in devices:
        try:
            fcntl.ioctl(fd, 0x5502)
        finally:
            os.close(fd)
