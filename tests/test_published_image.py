"""Exercise the deployed YARP config against the real, digest-pinned BFF image.

Requires Docker on Linux. The Products stand-in only records forwarded HTTP;
this does not claim to test SQL, Azure networking, SWA auth, or the Angular UI.
"""

import http.server
import json
from pathlib import Path
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
NAME = "bff-terraform-smoke"
PHOTO = "https://example.blob.core.windows.net/photos/Apple%20iPhone%2016%20128GB%20Bia%C5%82y/Main.webp"


class Products(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = json.dumps({"requestTarget": self.path, "mainPhoto": PHOTO}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def main():
    match = re.search(r'^bff_image\s*=\s*"([^"]+)"', (ROOT / "terraform.tfvars.example").read_text(), re.M)
    if not match:
        raise AssertionError("The example must identify a published BFF image")
    image = match.group(1)
    environment = json.loads((ROOT / "config/bff-environment.json").read_text())
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Products)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    environment["ReverseProxy__Clusters__products-cluster__Destinations__destination1__Address"] = (
        f"http://host.docker.internal:{server.server_port}"
    )
    command = ["run", "--detach", "--name", NAME, "--add-host", "host.docker.internal:host-gateway",
               "--publish", "127.0.0.1::8080"]
    for key, value in environment.items():
        command.extend(["--env", f"{key}={value}"])
    command.append(image)

    try:
        docker(*command)
        address = docker("port", NAME, "8080/tcp").splitlines()[0]
        base = f"http://{address}"
        for attempt in range(60):
            try:
                with urllib.request.urlopen(f"{base}/health", timeout=3) as response:
                    assert response.status == 200
                    assert response.read().decode() == "Healthy"
                break
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                if attempt == 59:
                    raise
                time.sleep(1)

        cases = {
            "/api/mobile-phones?amount=15": "/mobile-phones?amount=15",
            "/api/mobile-phones/00000000-0000-0000-0000-000000000001": "/mobile-phones/00000000-0000-0000-0000-000000000001",
            "/api/mobile-phones/filter?brand=Xiaomi": "/mobile-phones/filter?brand=Xiaomi",
            "/api/categories": "/categories",
            "/api/currencies": "/currencies",
            "/mobile-phones?amount=15": "/mobile-phones?amount=15",
            "/api/products/swagger/v1/swagger.json": "/swagger/v1/swagger.json",
        }
        for path, forwarded in cases.items():
            with urllib.request.urlopen(base + path, timeout=10) as response:
                body = json.load(response)
                assert response.status == 200
                assert body["requestTarget"] == forwarded, (path, body)
                assert body["mainPhoto"] == PHOTO, "YARP must preserve the encoded Blob URL"
            print(f"PASS {path} -> {forwarded}")
        print("Published image: /health and all 7 proxy requests passed; photo URLs preserved.")
    finally:
        subprocess.run(["docker", "logs", NAME], check=False)
        subprocess.run(["docker", "rm", "--force", NAME], check=False)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
