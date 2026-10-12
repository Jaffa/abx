#!/usr/bin/env python3
"""abx Bedrock signer.

Accepts Claude Code's unsigned Bedrock requests (CLAUDE_CODE_SKIP_BEDROCK_AUTH=1), signs them with
AWS SigV4 and forwards them to one fixed Bedrock runtime endpoint. The AWS credentials live only in
this container, so the agent container never holds anything worth stealing.

Standard library only. Credentials are read from a process-format JSON file (as written by
`aws configure export-credentials --format process`), which the host rewrites as it refreshes them.
"""

import datetime
import hashlib
import hmac
import http.client
import json
import os
import re
import ssl
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGION = os.environ["AWS_REGION"]
SERVICE = "bedrock"
UPSTREAM = os.environ.get("ABX_SIGNER_UPSTREAM", "bedrock-runtime.%s.amazonaws.com" % REGION)
UPSTREAM_TLS = os.environ.get("ABX_SIGNER_UPSTREAM_TLS", "1") == "1"
CREDENTIALS_FILE = os.environ.get("ABX_SIGNER_CREDENTIALS", "/run/abx-credentials/aws-credentials.json")
PORT = int(os.environ.get("ABX_SIGNER_PORT", "8787"))
TIMEOUT_SECONDS = 900

# Only model inference is forwarded, whatever the role would otherwise allow.
ALLOWED_PATH = re.compile(
    r"^/model/(?!\.\.?/)[^/]+/(invoke|invoke-with-response-stream|converse|converse-stream|count-tokens)$")

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
              "trailer", "transfer-encoding", "upgrade"}
NOT_FORWARDED = HOP_BY_HOP | {"host", "authorization", "content-length", "x-amz-date",
                              "x-amz-security-token", "x-amz-content-sha256", "x-api-key"}


def _hmac(key, message):
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def sign(method, raw_path, raw_query, headers, body, access_key, secret_key, amz_date,
         region=REGION, service=SERVICE):
    """Returns the SigV4 Authorization value. `headers` maps lower-case names to values and must
    include host and x-amz-date; every header given is signed."""
    # Paths arrive already percent-encoded; SigV4 encodes them again for every service except S3.
    canonical_uri = urllib.parse.quote(raw_path or "/", safe="/~")
    params = sorted(urllib.parse.parse_qsl(raw_query, keep_blank_values=True))
    canonical_query = "&".join("%s=%s" % (urllib.parse.quote(k, safe="-_.~"),
                                          urllib.parse.quote(v, safe="-_.~")) for k, v in params)
    names = sorted(headers)
    canonical_headers = "".join("%s:%s\n" % (n, " ".join(str(headers[n]).split())) for n in names)
    signed_headers = ";".join(names)
    canonical_request = "\n".join([method, canonical_uri, canonical_query, canonical_headers,
                                   signed_headers, hashlib.sha256(body).hexdigest()])
    date = amz_date[:8]
    scope = "%s/%s/%s/aws4_request" % (date, region, service)
    string_to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()])
    key = _hmac(("AWS4" + secret_key).encode("utf-8"), date)
    for part in (region, service, "aws4_request"):
        key = _hmac(key, part)
    signature = hmac.new(key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    return "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (
        access_key, scope, signed_headers, signature)


class Credentials:
    """Re-reads the credentials file whenever the host replaces it."""

    def __init__(self, path):
        self.path = path
        self.stamp = None
        self.data = None
        self.lock = threading.Lock()

    def get(self):
        with self.lock:
            stat = os.stat(self.path)
            stamp = (stat.st_mtime_ns, stat.st_ino, stat.st_size)
            if stamp != self.stamp:
                with open(self.path) as f:
                    data = json.load(f)
                if not data.get("AccessKeyId") or not data.get("SecretAccessKey"):
                    raise ValueError("credentials file has no access key")
                self.data, self.stamp = data, stamp
            expires = self.data.get("Expiration")
            if expires:
                when = datetime.datetime.fromisoformat(expires.replace("Z", "+00:00"))
                if when <= datetime.datetime.now(datetime.timezone.utc):
                    raise ValueError("credentials expired at %s; the host refresh is failing" % expires)
            return self.data


CREDENTIALS = Credentials(CREDENTIALS_FILE)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "abx-bedrock-signer"

    def log_message(self, fmt, *args):
        sys.stderr.write("[signer] %s\n" % (fmt % args))

    def _fail(self, status, message):
        # A refused request's body may still be unread, so the connection can't be reused safely.
        self.close_connection = True
        body = json.dumps({"message": message}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._fail(405, "only model inference requests are forwarded")

    do_PUT = do_DELETE = do_PATCH = do_GET

    def do_POST(self):
        split = urllib.parse.urlsplit(self.path)
        if not ALLOWED_PATH.match(split.path):
            self._fail(403, "path not allowed by the abx Bedrock signer: %s" % split.path)
            return
        length = self.headers.get("Content-Length")
        if length is None:
            self._fail(411, "Content-Length required")
            return
        body = self.rfile.read(int(length))
        try:
            creds = CREDENTIALS.get()
        except (OSError, ValueError) as exc:
            self._fail(502, "abx Bedrock signer has no usable credentials: %s" % exc)
            return

        amz_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        signed = {"host": UPSTREAM, "x-amz-date": amz_date}
        if creds.get("SessionToken"):
            signed["x-amz-security-token"] = creds["SessionToken"]
        outgoing = {k.lower(): v for k, v in self.headers.items() if k.lower() not in NOT_FORWARDED}
        if "content-type" in outgoing:
            signed["content-type"] = outgoing["content-type"]
        outgoing.update(signed)
        outgoing["authorization"] = sign("POST", split.path, split.query, signed, body,
                                         creds["AccessKeyId"], creds["SecretAccessKey"], amz_date)
        outgoing["content-length"] = str(len(body))

        if UPSTREAM_TLS:
            conn = http.client.HTTPSConnection(UPSTREAM, timeout=TIMEOUT_SECONDS,
                                               context=ssl.create_default_context())
        else:
            conn = http.client.HTTPConnection(UPSTREAM, timeout=TIMEOUT_SECONDS)
        try:
            conn.request("POST", self.path, body=body, headers=outgoing)
            resp = conn.getresponse()
        except OSError as exc:
            conn.close()
            self._fail(502, "could not reach %s: %s" % (UPSTREAM, exc))
            return

        try:
            self.send_response(resp.status)
            for name, value in resp.getheaders():
                if name.lower() not in HOP_BY_HOP and name.lower() != "content-length":
                    self.send_header(name, value)
            # Responses are relayed as they arrive, so streamed model output isn't held back.
            chunked = resp.getheader("Content-Length") is None
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", resp.getheader("Content-Length"))
            self.end_headers()
            while True:
                data = resp.read1(65536)
                if not data:
                    break
                if chunked:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                else:
                    self.wfile.write(data)
                self.wfile.flush()
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except OSError:
            self.close_connection = True
        finally:
            conn.close()


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write("[signer] forwarding Bedrock inference to %s on port %d\n" % (UPSTREAM, PORT))
    server.serve_forever()


if __name__ == "__main__":
    main()
