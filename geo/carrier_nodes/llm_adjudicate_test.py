"""
llm_adjudicate_test.py

Tests llm_adjudicate.py against a local HTTP server that speaks each
vendor's wire format, so every path except the vendors' own judgement is
exercised with no API key and no network.

Boris 2026-11-03: "Test on Anthropic to avoid need for a key, or Google
Gemini, which is completely free to use". Measured against the live
endpoints the same day, neither is keyless:

    api.anthropic.com POST, no key             401 x-api-key header is required
    api.anthropic.com POST, invalid key        401 invalid x-api-key
    generativelanguage POST, no key            403 PERMISSION_DENIED
    generativelanguage POST, invalid key       400 API_KEY_INVALID

Gemini costs nothing on its free tier but still needs a key from AI Studio.
So the keyless test is this file: the server below asserts that the request
my code builds carries the header and body shape each vendor requires, and
replies with that vendor's real response envelope. The two invalid-key
probes above are the evidence that the header names asserted here are the
ones the services actually read.

His standing order is that a fixture which cannot produce the failure is not
a test, so the failure cases here are real failures, not mocks of success:
an HTTP 429 that never clears, a Gemini safety block, a thinking-only
response with no text, a dropped pair, and a verdict with an empty reason.
Each one must come out as 'flag'. The suite fails if any of them produces a
'y', because a wrong 'y' attaches one carrier's plant to another's address
space.

Run it with python3 and no arguments. It prints one line per case and exits
non-zero on the first failure.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "llm_adjudicate.py")

sys.path.insert(0, HERE)
import llm_adjudicate as mod

PAIRS = [
    ("Fusion Voice and Data Corp", "Fusion"),
    ("New Wave Industries", "Cox Communications"),
    ("Rural Telephone Service Co", "RURAL TELEPHONE COMPANY"),
]

FAILURES = []
CHECKS = [0]


def check(name, condition, detail=""):
    CHECKS[0] += 1
    if condition:
        sys.stdout.write("  ok    " + name + "\n")
    else:
        extra = "  " + str(detail) if detail else ""
        sys.stdout.write("  FAIL  " + name + extra + "\n")
        FAILURES.append(name)


class Handler(BaseHTTPRequestHandler):
    """Serves one scripted reply per request and records what it was sent."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8")
        self.server.seen.append({
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": json.loads(raw) if raw else {},
        })
        status, payload = self.server.replies.pop(0) if self.server.replies \
            else (500, {"error": "the test server ran out of scripted replies"})
        # a str payload is sent byte for byte, which is how the pretty-printed
        # multi-line error bodies the real vendors return get reproduced here
        encoded = payload.encode("utf-8") if isinstance(payload, str) \
            else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def serve(replies):
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.replies = list(replies)
    server.seen = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def anthropic_reply(text):
    return (200, {"id": "msg_test", "type": "message", "role": "assistant",
                  "model": "test", "content": [{"type": "text", "text": text}],
                  "stop_reason": "end_turn"})


def openai_reply(text):
    return (200, {"id": "chatcmpl-test", "object": "chat.completion",
                  "choices": [{"index": 0, "finish_reason": "stop",
                               "message": {"role": "assistant",
                                           "content": text}}]})


def gemini_reply(text):
    return (200, {"candidates": [{"content": {"role": "model",
                                              "parts": [{"text": text}]},
                                  "finishReason": "STOP"}],
                  "usageMetadata": {"totalTokenCount": 1}})


def write_todo(directory):
    path = os.path.join(directory, "todo.tsv")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("ipapi_side\tbdc_side\tverdict\treason\n")
        for left, right in PAIRS:
            handle.write(left + "\t" + right + "\t\t\n")
    return path


def read_out(path):
    rows = {}
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    for line in lines[1:]:
        cells = line.split("\t")
        if len(cells) >= 4:
            rows[(cells[0], cells[1])] = (cells[2], cells[3])
    return rows


def run(url, wire, todo, out, extra_env=None, retries=1, timeout=10):
    env = dict(os.environ)
    env["LLM_API_URL"] = url
    env["LLM_API_KEY"] = "test-key-not-a-real-credential"
    env["LLM_MODEL"] = "test-model"
    if wire:
        env["LLM_WIRE"] = wire
    else:
        env.pop("LLM_WIRE", None)
    env.pop("LLM_THINKING_BUDGET", None)
    if extra_env:
        env.update(extra_env)
    completed = subprocess.run(
        [sys.executable, SCRIPT, "--todo", todo, "--out", out,
         "--batch", "10", "--retries", str(retries),
         "--timeout", str(timeout)],
        env=env, capture_output=True, text=True, timeout=180)
    return completed


def case_wire(name, wire, reply_builder):
    sys.stdout.write(name + "\n")
    body = "1|y|Fusion is the trading name of Fusion Voice and Data Corp\n" \
           "2|n|New Wave and Cox are separate operators, no relationship\n" \
           "3|y|both are the same rural telephone company, Co and Company\n"
    server = serve([reply_builder(body)])
    port = server.server_address[1]
    base = "http://127.0.0.1:" + str(port)
    url = {"anthropic": base + "/v1/messages",
           "openai": base + "/v1/chat/completions",
           "gemini": base + "/v1beta/models/test-model:generateContent"}[wire]
    with tempfile.TemporaryDirectory() as directory:
        todo = write_todo(directory)
        out = os.path.join(directory, "verdicts.tsv")
        completed = run(url, wire, todo, out)
        check(name + ": exit 0", completed.returncode == 0,
              completed.stderr[-300:])
        check(name + ": the wire it used is stated on stderr",
              completed.stderr.startswith("wire " + wire),
              completed.stderr.splitlines()[:1])
        rows = read_out(out) if os.path.exists(out) else {}
        check(name + ": three verdicts written", len(rows) == 3, str(rows))
        check(name + ": y, n, y in order",
              [rows.get(pair, ("", ""))[0] for pair in PAIRS] == ["y", "n", "y"],
              str([rows.get(pair, ("", ""))[0] for pair in PAIRS]))
        check(name + ": reason carries model and date",
              all("test-model" in rows[pair][1] for pair in rows), "")
    seen = server.seen
    server.shutdown()
    check(name + ": exactly one request", len(seen) == 1, str(len(seen)))
    if not seen:
        return
    request = seen[0]
    if wire == "anthropic":
        check(name + ": x-api-key sent",
              request["headers"].get("x-api-key") == "test-key-not-a-real-credential")
        check(name + ": anthropic-version sent",
              request["headers"].get("anthropic-version") == "2023-06-01")
        check(name + ": messages body",
              request["body"].get("messages", [{}])[0].get("role") == "user")
        check(name + ": temperature zero", request["body"].get("temperature") == 0)
        check(name + ": prompt reached the wire",
              "Fusion Voice and Data Corp" in
              request["body"]["messages"][0]["content"])
    elif wire == "openai":
        check(name + ": bearer sent",
              request["headers"].get("authorization")
              == "Bearer test-key-not-a-real-credential")
        check(name + ": prompt reached the wire",
              "Fusion Voice and Data Corp" in
              request["body"]["messages"][0]["content"])
    else:
        check(name + ": x-goog-api-key sent",
              request["headers"].get("x-goog-api-key")
              == "test-key-not-a-real-credential")
        check(name + ": no key in the URL", "key=" not in request["path"],
              request["path"])
        check(name + ": model in the path",
              request["path"].endswith("/models/test-model:generateContent"),
              request["path"])
        check(name + ": contents body",
              "Fusion Voice and Data Corp" in
              request["body"]["contents"][0]["parts"][0]["text"])
        check(name + ": temperature zero in generationConfig",
              request["body"]["generationConfig"].get("temperature") == 0)
        check(name + ": no thinkingConfig unless asked",
              "thinkingConfig" not in request["body"]["generationConfig"])


def case_failure(name, wire, replies, url_suffix, expect_in_reason,
                 retries=1, extra_env=None):
    """Every one of these must produce flag, never y."""
    sys.stdout.write(name + "\n")
    server = serve(replies)
    base = "http://127.0.0.1:" + str(server.server_address[1])
    with tempfile.TemporaryDirectory() as directory:
        todo = write_todo(directory)
        out = os.path.join(directory, "verdicts.tsv")
        completed = run(base + url_suffix, wire, todo, out,
                        extra_env=extra_env, retries=retries)
        check(name + ": exit 0", completed.returncode == 0,
              completed.stderr[-300:])
        rows = read_out(out) if os.path.exists(out) else {}
        verdicts = [rows.get(pair, ("missing", ""))[0] for pair in PAIRS]
        check(name + ": no y anywhere", "y" not in verdicts, str(verdicts))
        check(name + ": all flagged", verdicts == ["flag"] * 3, str(verdicts))
        reasons = " ".join(rows.get(pair, ("", ""))[1] for pair in PAIRS)
        check(name + ": reason names the cause",
              expect_in_reason.lower() in reasons.lower(), reasons[:200])
        check(name + ": no empty reason",
              all(rows[pair][1].strip() for pair in rows))
        # a vendor error body arrives pretty-printed over many lines. One
        # verdict must still occupy one line of the file.
        with open(out, encoding="utf-8") as handle:
            physical = handle.read().splitlines()
        check(name + ": one verdict per physical line",
              len(physical) == 1 + len(PAIRS), str(len(physical)))
    server.shutdown()


def case_dropped_pair():
    name = "a pair the model skipped"
    sys.stdout.write(name + "\n")
    body = "1|y|Fusion is the trading name of Fusion Voice and Data Corp\n" \
           "3|n|unrelated despite the shared word\n"
    server = serve([anthropic_reply(body)])
    base = "http://127.0.0.1:" + str(server.server_address[1])
    with tempfile.TemporaryDirectory() as directory:
        todo = write_todo(directory)
        out = os.path.join(directory, "verdicts.tsv")
        run(base + "/v1/messages", "anthropic", todo, out)
        rows = read_out(out)
        verdicts = [rows.get(pair, ("missing", ""))[0] for pair in PAIRS]
        check(name + ": answered pairs kept, skipped pair flagged",
              verdicts == ["y", "flag", "n"], str(verdicts))
        check(name + ": the flag says the model did not answer",
              "did not answer" in rows[PAIRS[1]][1], rows[PAIRS[1]][1])
    server.shutdown()


def case_empty_reason():
    name = "a verdict with no reason"
    sys.stdout.write(name + "\n")
    body = "1|y|\n2|y\n3|y|   \n"
    server = serve([anthropic_reply(body)])
    base = "http://127.0.0.1:" + str(server.server_address[1])
    with tempfile.TemporaryDirectory() as directory:
        todo = write_todo(directory)
        out = os.path.join(directory, "verdicts.tsv")
        run(base + "/v1/messages", "anthropic", todo, out)
        rows = read_out(out)
        verdicts = [rows.get(pair, ("missing", ""))[0] for pair in PAIRS]
        check(name + ": a bare y is refused, not recorded",
              verdicts == ["flag"] * 3, str(verdicts))
    server.shutdown()


def case_resume():
    name = "resume skips what is already decided"
    sys.stdout.write(name + "\n")
    body = "1|n|different companies, nothing in common but the word\n" \
           "2|y|same rural telephone company\n"
    server = serve([anthropic_reply(body)])
    base = "http://127.0.0.1:" + str(server.server_address[1])
    with tempfile.TemporaryDirectory() as directory:
        todo = write_todo(directory)
        out = os.path.join(directory, "verdicts.tsv")
        with open(out, "w", encoding="utf-8") as handle:
            handle.write("ipapi_side\tbdc_side\tverdict\treason\n")
            handle.write(PAIRS[0][0] + "\t" + PAIRS[0][1]
                         + "\ty\tdecided on an earlier run\n")
        run(base + "/v1/messages", "anthropic", todo, out)
        rows = read_out(out)
        check(name + ": the earlier verdict survives untouched",
              rows.get(PAIRS[0]) == ("y", "decided on an earlier run"),
              str(rows.get(PAIRS[0])))
        check(name + ": the other two were decided",
              [rows.get(pair, ("missing", ""))[0] for pair in PAIRS[1:]]
              == ["n", "y"],
              str([rows.get(pair, ("missing", ""))[0] for pair in PAIRS[1:]]))
    sent = server.seen
    server.shutdown()
    check(name + ": the decided pair was not sent again",
          sent and PAIRS[0][0] not in json.dumps(sent[0]["body"]),
          "the done pair appeared in the request")
    check(name + ": the undecided pairs were sent",
          sent and PAIRS[2][0] in json.dumps(sent[0]["body"]))


def case_units():
    sys.stdout.write("unit checks on the pieces\n")
    check("wire inferred for anthropic",
          mod.infer_wire("https://api.anthropic.com/v1/messages") == "anthropic")
    check("wire inferred for gemini",
          mod.infer_wire("https://generativelanguage.googleapis.com/v1beta/"
                         "models/gemini-2.5-flash:generateContent") == "gemini")
    check("wire inferred for anything else",
          mod.infer_wire("https://api.groq.com/openai/v1/chat/completions")
          == "openai")
    check("gemini url left alone when complete",
          mod.gemini_url("https://x/v1beta/models/m:generateContent", "m")
          == "https://x/v1beta/models/m:generateContent")
    check("gemini url built from a bare base",
          mod.gemini_url("https://generativelanguage.googleapis.com", "gemini-2.5-flash")
          == "https://generativelanguage.googleapis.com/v1beta/models/"
             "gemini-2.5-flash:generateContent")
    check("gemini url built from a versioned base",
          mod.gemini_url("https://generativelanguage.googleapis.com/v1beta", "m")
          == "https://generativelanguage.googleapis.com/v1beta/models/m:generateContent")
    check("gemini url built from a models base",
          mod.gemini_url("https://generativelanguage.googleapis.com/v1beta/models/", "m")
          == "https://generativelanguage.googleapis.com/v1beta/models/m:generateContent")

    blocked = {"promptFeedback": {"blockReason": "SAFETY"}}
    try:
        mod.gemini_text(blocked)
        check("a blocked prompt raises", False, "it returned instead")
    except ValueError as error:
        check("a blocked prompt raises", "SAFETY" in str(error), str(error))

    thinking = {"candidates": [{"content": {"parts": [
        {"thought": True, "text": "weighing the two names"}]},
        "finishReason": "MAX_TOKENS"}]}
    try:
        mod.gemini_text(thinking)
        check("thoughts alone raise", False, "it returned instead")
    except ValueError as error:
        check("thoughts alone raise", "MAX_TOKENS" in str(error), str(error))

    check("gemini text joins the real parts",
          mod.gemini_text({"candidates": [{"content": {"parts": [
              {"thought": True, "text": "thinking"}, {"text": "1|y|because"}]},
              "finishReason": "STOP"}]}) == "1|y|because")

    check("an out of range pair number is dropped",
          mod.parse_reply("9|y|nonsense\n1|n|fine", 2) == {1: ("n", "fine")})
    check("None parses to nothing", mod.parse_reply(None, 2) == {})
    check("prose parses to nothing",
          mod.parse_reply("I think these are related.", 2) == {})
    check("yes and no spelled out are accepted",
          mod.parse_reply("1. yes|same operator", 1) == {}
          and mod.parse_reply("1|yes|same operator", 1) == {1: ("y", "same operator")})
    check("unsure becomes flag",
          mod.parse_reply("1|unsure|cannot establish it", 1)
          == {1: ("flag", "cannot establish it")})


def main():
    case_units()
    case_wire("anthropic wire", "anthropic", anthropic_reply)
    case_wire("gemini wire", "gemini", gemini_reply)
    case_wire("openai wire", "openai", openai_reply)

    case_failure("an HTTP 429 that never clears", "anthropic",
                 [(429, {"error": {"message": "rate limited"}})] * 3,
                 "/v1/messages", "HTTP 429", retries=3)
    case_failure("a Gemini safety block", "gemini",
                 [(200, {"promptFeedback": {"blockReason": "SAFETY"}})],
                 "/v1beta/models/test-model:generateContent", "SAFETY")
    case_failure("a Gemini reply with thoughts and no text", "gemini",
                 [(200, {"candidates": [{"content": {"parts": [
                     {"thought": True, "text": "thinking"}]},
                     "finishReason": "MAX_TOKENS"}]})],
                 "/v1beta/models/test-model:generateContent", "MAX_TOKENS")
    case_failure("a Gemini reply with no candidates", "gemini",
                 [(200, {"usageMetadata": {"totalTokenCount": 0}})],
                 "/v1beta/models/test-model:generateContent", "no candidates")
    case_failure("a reply that is prose instead of verdicts", "anthropic",
                 [anthropic_reply("All three look related to me.")],
                 "/v1/messages", "did not answer")
    case_failure("an HTTP 500", "openai",
                 [(500, {"error": "boom"})] * 2,
                 "/v1/chat/completions", "HTTP 500", retries=2)
    # the shape generativelanguage actually returns, measured 2026-11-03:
    # a nested, pretty-printed error that spans twenty lines
    multiline = json.dumps(
        {"error": {"code": 400,
                   "message": "API key not valid. Please pass a valid API key.",
                   "status": "INVALID_ARGUMENT",
                   "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo",
                                "reason": "API_KEY_INVALID",
                                "domain": "googleapis.com",
                                "metadata": {"service": "generativelanguage"
                                             ".googleapis.com"}}]}},
        indent=2)
    case_failure("a Gemini error body spanning many lines", "gemini",
                 [(400, multiline)],
                 "/v1beta/models/test-model:generateContent",
                 "API key not valid")

    case_dropped_pair()
    case_empty_reason()
    case_resume()

    sys.stdout.write("\n" + str(CHECKS[0]) + " checks, "
                     + str(len(FAILURES)) + " failed\n")
    if FAILURES:
        for name in FAILURES:
            sys.stdout.write("  failed: " + name + "\n")
        raise SystemExit(1)
    sys.stdout.write("all green\n")


if __name__ == "__main__":
    main()
