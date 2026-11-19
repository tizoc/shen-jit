#!/usr/bin/env python3
"""A real Ctrl-C to the REPL on Windows, which tests/cli.sh cannot send: kill ends a native program
there, and it takes a console to interrupt one. The REPL gets a console of its own, and this attaches
to it to send the event. From the repository's root:

    python3 tests/ctrlc_windows.py build/shen-jit.exe
"""
import ctypes
import re
import subprocess
import sys
import threading
import time

kernel32 = ctypes.windll.kernel32
CREATE_NEW_CONSOLE = 0x10
ATTACH_PARENT_PROCESS = -1
PROMPT = re.compile(rb"\(\d+-\) ")

kernel32.SetConsoleCtrlHandler(None, False)  # a child inherits ignoring Ctrl-C from whatever started this
repl = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, creationflags=CREATE_NEW_CONSOLE)
output = bytearray()
passed = failed = 0


def read_output():
    while True:
        data = repl.stdout.read1(4096)
        if not data:
            return
        output.extend(data)


threading.Thread(target=read_output, daemon=True).start()


def send(line):
    repl.stdin.write(line.encode() + b"\n")
    repl.stdin.flush()


def next_prompt(start, seconds=20):
    """Waits for the REPL to finish what it was doing when the output stood at start."""
    end = time.time() + seconds
    while time.time() < end:
        if PROMPT.search(output, start):
            return True
        time.sleep(0.01)
    return False


def ctrl_c():
    kernel32.FreeConsole()
    if kernel32.AttachConsole(repl.pid):
        kernel32.SetConsoleCtrlHandler(None, True)  # not for this process
        kernel32.GenerateConsoleCtrlEvent(0, 0)
        time.sleep(0.05)
        kernel32.FreeConsole()
    kernel32.AttachConsole(ATTACH_PARENT_PROCESS)


def check(name, ok):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL %s, after:\n%s" % (name, bytes(output[-400:]).decode(errors="replace")))


def answer(line):
    """Sends a line that ends by itself, and gives what the REPL said."""
    start = len(output)
    send(line)
    next_prompt(start)
    return bytes(output[start:])


def interrupt(line, wait=0.5):
    """Sends a line that does not end by itself, stops it, and gives what the REPL said."""
    start = len(output)
    send(line)
    time.sleep(wait)
    ctrl_c()
    next_prompt(start)
    return bytes(output[start:])


next_prompt(0)
answer("(define spin N -> (spin (+ N 1)))")
check("a loop", b"interrupted" in interrupt("(spin 0)"))
said = interrupt("(trap-error (spin 0) (/. E caught))")
check("inside the program's own trap-error", b"interrupted" in said and b"caught" not in said)
check("a program reading input", b"interrupted" in interrupt("(read-byte (stinput))"))
interrupt("(+ 1", 0.3)
check("a half-typed expression is dropped", answer("(+ 3 4)").startswith(b"7"))

answer('(module.use [socket])')
answer('(set l (socket.listen "127.0.0.1" 0))')
check("a socket's accept", b"interrupted" in interrupt("(socket.accept (value l))"))
answer('(set c (socket.connect "127.0.0.1" (socket.port (value l))))')
check("a socket's recv", b"interrupted" in interrupt("(socket.recv (value c) 10)"))

check("the REPL goes on", answer("(+ 8 9)").startswith(b"17"))
repl.stdin.close()
try:
    check("end of input ends the REPL", repl.wait(10) == 0)
except subprocess.TimeoutExpired:
    repl.kill()
    check("end of input ends the REPL", False)

print("ctrl-c tests: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
