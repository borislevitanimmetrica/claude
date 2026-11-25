"""
llm_adjudicate.py

STEP 3 of the algorithm, as a program rather than a conversation.

Boris 2026-11-25: "Any LLM can be used." His step 3 is: remaining matches go
through an LLM to determine whether there is any relationship between the two
brands, and if there is, record it. Until now that adjudication happened in
chat, which does not scale: 100 pairs are queued and there would be thousands
if the pre-filter were removed.

Reads the pairs that need deciding, asks an LLM about each, and writes the
verdict file that load_llm_pairings.sql already consumes. Standard library
only, so there is nothing to install.

PROVIDER AGNOSTIC, because I do not know which API he has and will not guess.
Everything comes from the environment:

    LLM_API_URL   the endpoint. Required.
    LLM_API_KEY   the key. Required.
    LLM_MODEL     the model name. Required.
    LLM_WIRE      openai, anthropic or gemini. Optional; inferred from the
                  URL host, which covers the three endpoints below.
    LLM_THINKING_BUDGET   gemini only, optional. Send 0 to switch thinking
                  off on models that support the control, which stops a
                  thinking budget from consuming the output allowance.

Three wire formats, which cover what is actually deployed:

    openai      POST .../chat/completions, Authorization: Bearer
                spoken by OpenAI, Azure, Groq, Together, vLLM, Ollama,
                OpenRouter
    anthropic   POST https://api.anthropic.com/v1/messages, x-api-key
    gemini      POST https://generativelanguage.googleapis.com
                /v1beta/models/MODEL:generateContent, x-goog-api-key

Boris 2026-11-03 asked for a keyless test on Anthropic, or Gemini because it
is free. Measured against the live endpoints that day, neither is keyless:

    Anthropic, no key                 401 "x-api-key header is required"
    Anthropic, invalid x-api-key      401 "invalid x-api-key"
    Gemini, no key                    403 PERMISSION_DENIED
    Gemini, invalid x-goog-api-key    400 API_KEY_INVALID

Those two invalid-key probes are what fixed the header names used below.
Gemini is free of charge on its free tier, so it is the cheapest of the
three, but it still needs a key from Google AI Studio. Everything in this
file other than the vendors' own replies is tested by
llm_adjudicate_test.py, which serves each vendor's response envelope from a
local HTTP server, so the wires are verified without any key at all.

IT NEVER INVENTS A VERDICT. If a call fails, times out, returns something
unparseable, or omits a pair, that pair is written as 'flag' with the reason
stating exactly what happened. A failure must never read as "related",
because a wrong 'y' silently attaches one carrier's plant to another's
address space. The loader also rejects any row with an empty reason.

RESUMABLE. Pairs already carrying a verdict in the output file are skipped,
so an interrupted run continues where it stopped and costs nothing twice.

USAGE. Set LLM_API_URL, LLM_API_KEY and LLM_MODEL, then pass --todo with
the queue that load_llm_pairings.sql writes and --out with the verdict file
to produce. Each command below is one line, nothing to continue:

    python3 CARRIER_NODES/llm_adjudicate.py --todo QUEUE --out VERDICTS
    python3 CARRIER_NODES/llm_adjudicate.py --todo QUEUE --dry-run

--dry-run prints the first prompt, calls nothing and needs no key. The two
capitalised words are paths; the runnable form with the real paths is in the
chat message that shipped this file, not here, so that no line of this
docstring can be pasted and run by accident.
"""

import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request

PROMPT_HEADER = """You are deciding whether pairs of US broadband carrier names refer to related companies.

For each numbered pair, answer whether the two names refer to the same company or to companies with a real corporate relationship, such as a trading name, a legal entity of the same group, a brand of the same operator, or an acquired subsidiary.

Answer n when the names merely share a word, a region or an industry term, or when they are different companies that happen to sound alike. Sharing a place name or a generic word is NOT a relationship.

Answer unsure when you cannot establish it. Do not guess.

Reply with one line per pair, in this exact format and nothing else:

NUMBER|y|short reason
NUMBER|n|short reason
NUMBER|unsure|short reason

The reason must be one clause, under 160 characters, stating the basis.

Pairs:
"""


def read_pairs(path):
    """The todo file as written by load_llm_pairings.sql: ipapi_side,
    bdc_side, verdict, reason."""
    pairs = []
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle, delimiter="\t")
        header = next(reader, None)
        if header is None:
            raise SystemExit("the todo file is empty: " + path)
        for row in reader:
            if len(row) < 2 or not row[0].strip() or not row[1].strip():
                continue
            pairs.append((row[0], row[1]))
    return pairs


def read_done(path):
    """Verdicts already decided, so a rerun costs nothing twice."""
    done = {}
    if not os.path.exists(path):
        return done
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle, delimiter="\t")
        next(reader, None)
        for row in reader:
            if len(row) >= 4 and row[2].strip():
                done[(row[0], row[1])] = (row[2].strip(), row[3])
    return done


def build_prompt(batch):
    lines = [PROMPT_HEADER]
    for index, (left, right) in enumerate(batch, start=1):
        lines.append(str(index) + ". " + left + "  ||  " + right)
    return "\n".join(lines)


def call_openai(url, key, model, prompt, timeout):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
    }).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + key)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"]


def call_anthropic(url, key, model, prompt, timeout):
    body = json.dumps({
        "model": model,
        "max_tokens": 4096,
        "temperature": 0,
        "messages": [{"role": "user", "content": prompt}],
    }).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("x-api-key", key)
    request.add_header("anthropic-version", "2023-06-01")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return "".join(block.get("text", "") for block in payload["content"])


def one_line(text):
    """Reasons go into carrier_alias_tbl and get read by eye, so collapse
    every whitespace run to one space. A vendor error body arrives as
    pretty-printed JSON spanning a dozen lines; left alone it becomes a
    quoted multi-line CSV field that is correct but unreadable."""
    return " ".join(str(text).split())


def gemini_url(url, model):
    """Gemini puts the model in the path, so accept either the full
    generateContent URL or the API base and build the rest."""
    url = url.rstrip("/")
    if ":generateContent" in url:
        return url
    if url.endswith("/models"):
        return url + "/" + model + ":generateContent"
    if "/v1beta" in url or "/v1/" in url or url.endswith("/v1"):
        return url + "/models/" + model + ":generateContent"
    return url + "/v1beta/models/" + model + ":generateContent"


def gemini_text(payload):
    """The reply text, or an exception naming why there is none.

    Gemini can answer with no text in several ways that all have to become a
    flag rather than a crash or a silent empty string: the prompt itself can
    be blocked, the candidate list can be absent, a candidate can stop on
    MAX_TOKENS before emitting anything, and on thinking models the parts
    can be thoughts carrying no text."""
    feedback = payload.get("promptFeedback") or {}
    if feedback.get("blockReason"):
        raise ValueError("Gemini blocked the prompt, blockReason "
                         + str(feedback.get("blockReason")))
    candidates = payload.get("candidates") or []
    if not candidates:
        raise ValueError("Gemini returned no candidates: "
                         + json.dumps(payload)[:200])
    candidate = candidates[0]
    parts = (candidate.get("content") or {}).get("parts") or []
    text = "".join(part.get("text", "") for part in parts
                   if not part.get("thought"))
    if not text.strip():
        raise ValueError("Gemini returned no text, finishReason "
                         + str(candidate.get("finishReason")))
    return text


def call_gemini(url, key, model, prompt, timeout):
    config = {"temperature": 0, "maxOutputTokens": 8192}
    budget = os.environ.get("LLM_THINKING_BUDGET", "").strip()
    if budget:
        try:
            config["thinkingConfig"] = {"thinkingBudget": int(budget)}
        except ValueError:
            raise SystemExit("LLM_THINKING_BUDGET must be an integer, not "
                             + repr(budget))
    body = json.dumps({
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": config,
    }).encode("utf-8")
    request = urllib.request.Request(gemini_url(url, model), data=body,
                                     method="POST")
    request.add_header("Content-Type", "application/json")
    # measured 2026-11-03: this header name is what the service actually
    # reads. With it and a bad key the reply is API_KEY_INVALID; without it
    # the reply is PERMISSION_DENIED.
    request.add_header("x-goog-api-key", key)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return gemini_text(payload)


def infer_wire(url):
    host = url.lower()
    if "anthropic" in host:
        return "anthropic"
    if "generativelanguage" in host or "googleapis" in host:
        return "gemini"
    return "openai"


WIRES = {
    "openai": call_openai,
    "anthropic": call_anthropic,
    "gemini": call_gemini,
}


def parse_reply(text, batch_size):
    """Verdicts by pair number. A pair the model did not answer, or answered
    unparseably, is simply absent, and the caller turns that into a flag.
    Nothing here infers a verdict from a malformed line."""
    out = {}
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or "|" not in line:
            continue
        parts = line.split("|", 2)
        if len(parts) < 3:
            continue
        number, verdict, reason = parts[0].strip(), parts[1].strip().lower(), parts[2].strip()
        number = number.rstrip(".").strip()
        if not number.isdigit():
            continue
        position = int(number)
        if position < 1 or position > batch_size:
            continue
        if verdict in ("y", "yes"):
            verdict = "y"
        elif verdict in ("n", "no"):
            verdict = "n"
        elif verdict in ("unsure", "flag", "unknown"):
            verdict = "flag"
        else:
            continue
        reason = one_line(reason)
        if not reason:
            continue
        out[position] = (verdict, reason[:300])
    return out


def main():
    parser = argparse.ArgumentParser(
        description="Adjudicate carrier name pairs with an LLM, step 3 of the matching algorithm.")
    parser.add_argument("--todo", required=True,
                        help="TSV of pairs to decide, as written by load_llm_pairings.sql")
    parser.add_argument("--out", help="TSV of verdicts to write. Required unless --dry-run.")
    parser.add_argument("--batch", type=int, default=20,
                        help="pairs per request. Default 20.")
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after this many pairs. 0 means all.")
    parser.add_argument("--timeout", type=int, default=120, help="seconds per request")
    parser.add_argument("--retries", type=int, default=3, help="attempts per batch")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the first prompt and exit without calling anything")
    args = parser.parse_args()

    if not os.path.exists(args.todo):
        raise SystemExit("no such todo file: " + args.todo
                         + "\nIt is written by load_llm_pairings.sql.")

    pairs = read_pairs(args.todo)
    if not pairs:
        raise SystemExit("the todo file holds no pairs: " + args.todo)

    if args.dry_run:
        first = pairs[:args.batch]
        sys.stdout.write("would send " + str(len(pairs)) + " pair(s) in batches of "
                         + str(args.batch) + ". The first prompt:\n\n")
        sys.stdout.write(build_prompt(first) + "\n")
        return

    if not args.out:
        raise SystemExit("--out is required unless --dry-run. Nothing was written.")

    url = os.environ.get("LLM_API_URL", "").strip()
    key = os.environ.get("LLM_API_KEY", "").strip()
    model = os.environ.get("LLM_MODEL", "").strip()
    missing = [name for name, value in
               (("LLM_API_URL", url), ("LLM_API_KEY", key), ("LLM_MODEL", model))
               if not value]
    if missing:
        raise SystemExit(
            "these environment variables are not set: " + ", ".join(missing)
            + "\nSet them for whichever LLM you want to use. Nothing was called"
              " and nothing was written. To see the prompt without an API, use"
              " --dry-run.")

    wire = os.environ.get("LLM_WIRE", "").strip().lower()
    if not wire:
        wire = infer_wire(url)
    if wire not in WIRES:
        raise SystemExit("LLM_WIRE must be one of "
                         + ", ".join(sorted(WIRES)) + ", not " + repr(wire))
    caller = WIRES[wire]

    done = read_done(args.out)
    todo = [pair for pair in pairs if pair not in done]
    if args.limit:
        todo = todo[:args.limit]
    sys.stderr.write("wire " + wire + ", model " + model + "\n")
    sys.stderr.write(str(len(done)) + " already decided, " + str(len(todo))
                     + " to decide\n")

    results = dict(done)
    stamp = time.strftime("%Y-%m-%d")

    for start in range(0, len(todo), args.batch):
        batch = todo[start:start + args.batch]
        prompt = build_prompt(batch)
        reply = None
        failure = ""
        for attempt in range(1, args.retries + 1):
            try:
                reply = caller(url, key, model, prompt, args.timeout)
                break
            except urllib.error.HTTPError as error:
                detail = ""
                try:
                    detail = one_line(error.read().decode("utf-8", "replace"))[:200]
                except Exception:
                    pass
                failure = "HTTP " + str(error.code) + " " + detail
            except Exception as error:
                failure = type(error).__name__ + ": " + one_line(error)[:200]
            if attempt < args.retries:
                time.sleep(min(2 ** attempt, 30))

        parsed = parse_reply(reply, len(batch)) if reply is not None else {}
        for position, (left, right) in enumerate(batch, start=1):
            if position in parsed:
                verdict, reason = parsed[position]
                results[(left, right)] = (
                    verdict, reason + " [" + model + ", " + stamp + "]")
            else:
                # NEVER a y. An unanswered or unparseable pair is a flag, and
                # the reason says which, so a silent failure cannot become a
                # recorded match.
                why = ("the model did not answer this pair"
                       if reply is not None else
                       "the request failed: " + failure)
                results[(left, right)] = (
                    "flag", why + " [" + model + ", " + stamp + "]")

        sys.stderr.write("decided " + str(min(start + len(batch), len(todo)))
                         + " of " + str(len(todo)) + "\n")

        # written after every batch, so an interrupted run loses nothing
        with open(args.out, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
            writer.writerow(["ipapi_side", "bdc_side", "verdict", "reason"])
            for (left, right) in pairs:
                if (left, right) in results:
                    verdict, reason = results[(left, right)]
                    writer.writerow([left, right, verdict, reason])

    tally = {}
    for verdict, _ in results.values():
        tally[verdict] = tally.get(verdict, 0) + 1
    sys.stderr.write("verdicts: "
                     + ", ".join(k + " " + str(v) for k, v in sorted(tally.items()))
                     + "\n")
    sys.stderr.write("wrote " + args.out + "\n")
    sys.stderr.write("load it with: psql -f /home/boris/geo/src/claude/geo/"
                     "carrier_nodes/load_llm_pairings.sql after copying it over"
                     " llm_pairing_verdicts.tsv, or point that file's copy"
                     " command at this path\n")


if __name__ == "__main__":
    main()
