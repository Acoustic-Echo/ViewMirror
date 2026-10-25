#!/usr/bin/env python3
"""Probe real DNS-SD replies; stdlib only. Exit 0 requires PTR, SRV, TXT and A.

A local reply proves registration/query response on this host. It cannot prove
that another device can discover the service across a Wi-Fi router/firewall.
"""
import argparse
import json
import socket
import struct
import time
from pathlib import Path


def dns_name(data, offset):
    labels, end, visited = [], None, set()
    while True:
        if offset >= len(data) or offset in visited:
            raise ValueError("invalid DNS name")
        visited.add(offset)
        length = data[offset]
        offset += 1
        if length & 0xC0 == 0xC0:
            if offset >= len(data):
                raise ValueError("truncated DNS pointer")
            end = end or offset + 1
            offset = ((length & 0x3F) << 8) | data[offset]
            continue
        if length & 0xC0 or offset + length > len(data):
            raise ValueError("invalid DNS label")
        if not length:
            return ".".join(labels), end or offset
        labels.append(data[offset:offset + length].decode("utf-8", "replace"))
        offset += length


def records(data):
    if len(data) < 12:
        return []
    _, flags, qd, an, ns, ar = struct.unpack_from("!6H", data)
    if not flags & 0x8000:
        return []
    offset, result = 12, []
    for _ in range(qd):
        _, offset = dns_name(data, offset)
        offset += 4
    for _ in range(an + ns + ar):
        name, offset = dns_name(data, offset)
        kind, cls, ttl, size = struct.unpack_from("!HHIH", data, offset)
        offset += 10
        if offset + size > len(data):
            raise ValueError("truncated DNS record")
        raw = data[offset:offset + size]
        record = {"name": name, "type": kind, "ttl": ttl}
        if kind == 12:
            record["target"], _ = dns_name(data, offset)
        elif kind == 33:
            record["port"] = struct.unpack_from("!H", raw, 4)[0]
            record["target"], _ = dns_name(data, offset + 6)
        elif kind == 16:
            txt, p = [], 0
            while p < len(raw):
                n = raw[p]
                txt.append(raw[p + 1:p + 1 + n].decode("utf-8", "replace"))
                p += n + 1
            record["txt"] = txt
        elif kind == 1 and size == 4:
            record["address"] = socket.inet_ntoa(raw)
        else:
            offset += size
            continue
        result.append(record)
        offset += size
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", required=True, help="Local IPv4 address")
    parser.add_argument("--name", required=True)
    parser.add_argument("--port", type=int, default=7000)
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    question = b"".join(bytes([len(x)]) + x.encode() for x in "_airplay._tcp.local".split(".")) + b"\0"
    # QU requests a unicast reply to our ephemeral source port.
    packet = struct.pack("!6H", 0, 0, 1, 0, 0, 0) + question + struct.pack("!HH", 12, 0x8001)
    found, senders = {}, set()
    deadline, next_send = time.monotonic() + args.seconds, 0
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.bind((args.interface, 0))
        client.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.interface))
        client.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        client.settimeout(0.5)
        while time.monotonic() < deadline:
            if time.monotonic() >= next_send:
                client.sendto(packet, ("224.0.0.251", 5353))
                next_send = time.monotonic() + 1
            try:
                data, sender = client.recvfrom(65535)
            except socket.timeout:
                continue
            try:
                for record in records(data):
                    if record["ttl"]:
                        found[json.dumps(record, sort_keys=True)] = record
                senders.add(sender[0])
            except (ValueError, struct.error, IndexError):
                continue
    items = list(found.values())
    instance = args.name + "._airplay._tcp.local"
    ptr = any(r["type"] == 12 and r["name"].lower() == "_airplay._tcp.local" and r.get("target") == instance for r in items)
    srv = [r for r in items if r["type"] == 33 and r["name"] == instance and r.get("port") == args.port]
    txt = any(r["type"] == 16 and r["name"] == instance and r.get("txt") for r in items)
    address = any(r["type"] == 1 and r.get("address") == args.interface and any(r["name"] == s.get("target") for s in srv) for r in items)
    result = {"status": "success" if ptr and srv and txt and address else "failed", "scope": "local-host-multicast-query-unicast-response", "interface": args.interface, "receiver": args.name, "checks": {"PTR": ptr, "SRV": bool(srv), "TXT": txt, "A": address}, "senders": sorted(senders), "records": items}
    Path(args.output).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "records"}, ensure_ascii=False))
    return 0 if result["status"] == "success" else 1


if __name__ == "__main__":
    raise SystemExit(main())
