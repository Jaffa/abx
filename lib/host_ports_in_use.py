# Run as a file rather than from stdin, so the working directory (the project, which the agent can write to) isn't first on sys.path.
import socket, sys
addr = sys.argv[1]
for port in sys.argv[2:]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((addr, int(port)))
    except OSError:
        print(port)
    finally:
        sock.close()
