"""Read the local receiver's advertised dimensions and codec capability (not an iPad test)."""
import argparse
import json
import plistlib
import socket
from pathlib import Path


def probe(port):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.settimeout(5)
        connection.sendall(b"GET /info RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n")
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = connection.recv(4096)
            if not chunk:
                raise RuntimeError("Receiver closed before sending RTSP headers")
            response.extend(chunk)
            if len(response) > 1024 * 1024:
                raise RuntimeError("RTSP headers exceed the size limit")
        headers, body = bytes(response).split(b"\r\n\r\n", 1)
        if headers.split(b"\r\n", 1)[0].split()[1] != b"200":
            raise RuntimeError("Receiver rejected GET /info")
        fields = dict(line.lower().split(b":", 1) for line in headers.split(b"\r\n")[1:] if b":" in line)
        length = int(fields[b"content-length"])
        if not 0 < length <= 1024 * 1024:
            raise RuntimeError("Invalid RTSP body size")
        while len(body) < length:
            chunk = connection.recv(min(65536, length - len(body)))
            if not chunk:
                raise RuntimeError("Truncated /info property list")
            body += chunk
    info = plistlib.loads(body[:length])
    display = info["displays"][0]
    return {"status": "success", "scope": "local receiver advertisement only", "ipadConnection": "unverified",
            "width": display["widthPixels"], "height": display["heightPixels"],
            "hevcEnabled": bool(info["features"] & (1 << 42))}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=7001)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = probe(args.port)
    text = json.dumps(result, indent=2)
    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
    print(text)
