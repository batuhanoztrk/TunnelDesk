#!/usr/bin/python3
"""Local-only integration double. Never contacts Kubernetes or an SSH server."""
import json
import os
import signal
import socket
import sys
import time

args = sys.argv[1:]
trace = os.environ.get("TUNNELDESK_TEST_TRACE")
if trace:
    with open(trace, "a") as f:
        f.write(json.dumps(args) + "\n")
namespace = args[args.index("--namespace") + 1] if "--namespace" in args else "default"
if "create" in args:
    manifest = json.load(sys.stdin)
    if namespace == "denied":
        print("Error from server (Forbidden): pod creation denied", flush=True)
        sys.exit(1)
    print("pod/" + manifest["metadata"]["name"] + " created", flush=True)
elif "wait" in args:
    if namespace == "slow":
        time.sleep(20)
    print("pod condition met", flush=True)
elif "delete" in args:
    if namespace == "cleanup-denied":
        print("Error from server (Forbidden): pod cleanup denied", flush=True)
        sys.exit(1)
    print("pod deleted", flush=True)
elif "get-contexts" in args:
    print("test-context\nsecond-context")
elif "namespaces" in args:
    print("Forbidden", flush=True)
    sys.exit(1)
elif "can-i" in args:
    print("Resources  Non-Resource URLs  Resource Names  Verbs")
    print("namespaces  []  [team-alpha team-beta]  [*]")
elif "port-forward" in args or "-L" in args:
    if namespace == "broken":
        print("error: target pod not found", flush=True)
        sys.exit(1)
    ssh = "-L" in args
    port = int(args[args.index("-L") + 1].split(":")[1]) if ssh else int(args[-1].split(":")[0])
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen()
    message = (f"debug1: Local forwarding listening on 127.0.0.1 port {port}.\n" if ssh else f"Forwarding from 127.0.0.1:{port} -> 1433\n")
    # Deliberately split the readiness message across output chunks.
    sys.stdout.write(message[:12]); sys.stdout.flush(); time.sleep(0.04)
    sys.stdout.write(message[12:]); sys.stdout.flush()
    while True:
        connection, _ = listener.accept()
        connection.close()
else:
    print("ok", flush=True)
