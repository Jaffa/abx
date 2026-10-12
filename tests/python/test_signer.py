"""Tests for resources/abx-bedrock-signer.py: SigV4 correctness and the gateway's proxy behaviour,
against a local stand-in for Bedrock that re-verifies every signature it receives."""

import http.client
import importlib.util
import json
import os
import pathlib
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ.setdefault("AWS_REGION", "eu-west-1")
SIGNER_PATH = pathlib.Path(__file__).resolve().parents[2] / "resources" / "abx-bedrock-signer.py"
spec = importlib.util.spec_from_file_location("abx_signer", SIGNER_PATH)
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
signer.Handler.log_message = lambda self, *args: None

SECRETS = {"ASIAONE": "secret-one", "ASIATWO": "secret-two"}
MODEL = "eu.anthropic.claude-sonnet-4-5-20250929-v1%3A0"


class SigV4Vectors(unittest.TestCase):
    """Vectors from AWS's published SigV4 test suite."""
    AK, SK, DATE = "AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830T123600Z"
    HEADERS = {"host": "example.amazonaws.com", "x-amz-date": "20150830T123600Z"}

    def check(self, method, expected):
        auth = signer.sign(method, "/", "", self.HEADERS, b"", self.AK, self.SK, self.DATE,
                           region="us-east-1", service="service")
        self.assertEqual(auth.rsplit("Signature=", 1)[1], expected)
        self.assertIn("Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request", auth)

    def test_get_vanilla(self):
        self.check("GET", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")

    def test_post_vanilla(self):
        self.check("POST", "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")


class StandIn(BaseHTTPRequestHandler):
    """Plays Bedrock: verifies the signature, then answers according to the path."""
    protocol_version = "HTTP/1.1"
    received = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        auth = self.headers["Authorization"]
        key = auth.split("Credential=")[1].split("/")[0]
        names = auth.split("SignedHeaders=")[1].split(",")[0].split(";")
        path, _, query = self.path.partition("?")
        expected = signer.sign("POST", path, query, {n: self.headers[n] for n in names}, body,
                               key, SECRETS[key], self.headers["x-amz-date"])
        StandIn.received.append({"valid": expected == auth, "key": key, "path": self.path, "body": body,
                                 "headers": {k.lower(): v for k, v in self.headers.items()}})
        if "error-model" in self.path:
            payload = json.dumps({"message": "The provided model identifier is invalid."}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.amazon.eventstream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for i in range(3):
            chunk = ("event-%d" % i).encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()
            time.sleep(0.3)
        self.wfile.write(b"0\r\n\r\n")


class Gateway(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.creds_path = os.path.join(cls.tmp.name, "aws-credentials.json")
        cls.write_credentials("ASIAONE", "2099-01-01T00:00:00Z")
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), StandIn)
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        signer.UPSTREAM = "127.0.0.1:%d" % cls.upstream.server_address[1]
        signer.UPSTREAM_TLS = False
        signer.CREDENTIALS = signer.Credentials(cls.creds_path)
        cls.gateway = ThreadingHTTPServer(("127.0.0.1", 0), signer.Handler)
        threading.Thread(target=cls.gateway.serve_forever, daemon=True).start()
        cls.port = cls.gateway.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.gateway.shutdown()
        cls.gateway.server_close()
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.tmp.cleanup()

    @classmethod
    def write_credentials(cls, key, expires):
        tmp = cls.creds_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"Version": 1, "AccessKeyId": key, "SecretAccessKey": SECRETS[key],
                       "SessionToken": "token-" + key, "Expiration": expires}, f)
        os.replace(tmp, cls.creds_path)

    def setUp(self):
        StandIn.received.clear()
        self.write_credentials("ASIAONE", "2099-01-01T00:00:00Z")

    def post(self, path, body=b'{"x":1}', headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        self.addCleanup(conn.close)
        conn.request("POST", path, body=body, headers=headers or {"Content-Type": "application/json"})
        resp = conn.getresponse()
        return resp, resp.read()

    def test_requests_are_signed_and_forwarded_intact(self):
        body = b'{"messages":[{"role":"user","content":"hi"}]}'
        resp, _ = self.post("/model/%s/invoke" % MODEL, body=body,
                            headers={"Content-Type": "application/json", "Authorization": "Bearer agent",
                                     "x-api-key": "agent-key", "Host": "evil.example.com"})
        self.assertEqual(resp.status, 200)
        got = StandIn.received[0]
        self.assertTrue(got["valid"], "signature should verify")
        self.assertEqual(got["path"], "/model/%s/invoke" % MODEL)
        self.assertEqual(got["body"], body)
        self.assertEqual(got["headers"]["host"], signer.UPSTREAM, "a Host header from the agent is ignored")
        self.assertNotIn("x-api-key", got["headers"])
        self.assertTrue(got["headers"]["authorization"].startswith("AWS4-HMAC-SHA256"))
        self.assertEqual(got["headers"]["x-amz-security-token"], "token-ASIAONE")

    def test_streamed_responses_are_relayed_as_they_arrive(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        self.addCleanup(conn.close)
        start = time.time()
        conn.request("POST", "/model/%s/invoke-with-response-stream" % MODEL, body=b"{}",
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        arrivals = []
        while True:
            data = resp.read1(65536)
            if not data:
                break
            arrivals.append(time.time() - start)
        self.assertGreaterEqual(len(arrivals), 3)
        self.assertLess(arrivals[0], 0.25, "the first event shouldn't wait for the whole response")

    def test_replaced_credentials_are_used_without_restart(self):
        self.write_credentials("ASIATWO", "2099-01-01T00:00:00Z")
        self.post("/model/%s/converse" % MODEL)
        self.assertEqual(StandIn.received[-1]["key"], "ASIATWO")
        self.assertTrue(StandIn.received[-1]["valid"])

    def test_expired_credentials_give_a_clear_error(self):
        self.write_credentials("ASIAONE", "2020-01-01T00:00:00Z")
        resp, body = self.post("/model/%s/invoke" % MODEL)
        self.assertEqual(resp.status, 502)
        self.assertIn(b"expired", body)

    def test_upstream_errors_pass_through(self):
        resp, body = self.post("/model/error-model/invoke")
        self.assertEqual(resp.status, 400)
        self.assertIn(b"model identifier is invalid", body)

    def test_only_inference_paths_are_forwarded(self):
        for path in ["/guardrail/x/apply", "/model/../invoke", "/model/x/../../guardrail/invoke", "/model/x/delete"]:
            resp, _ = self.post(path)
            self.assertEqual(resp.status, 403, path)
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        self.addCleanup(conn.close)
        conn.request("GET", "/foundation-models")
        self.assertEqual(conn.getresponse().status, 405)
        self.assertEqual(StandIn.received, [], "nothing refused should reach Bedrock")

    def test_refusal_closes_connection_so_it_cannot_be_reused(self):
        resp, _ = self.post("/guardrail/x/apply")
        self.assertEqual(resp.getheader("Connection"), "close")


if __name__ == "__main__":
    unittest.main()
