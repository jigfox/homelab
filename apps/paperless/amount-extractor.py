#!/usr/bin/env python3
"""Fill empty monetary custom fields of Paperless-ngx documents with Claude.

Stdlib only, so a stock python:slim image runs it. Environment:
  PAPERLESS_URL, PAPERLESS_TOKEN, ANTHROPIC_API_KEY, MODEL, MAX_DOCS,
  DRY_RUN=1 (log only, no writes), ONLY_IDS=1,2 (test: these ids, any field state).
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

PAPERLESS = os.environ.get("PAPERLESS_URL", "http://paperless.paperless.svc").rstrip("/")
TOKEN = os.environ["PAPERLESS_TOKEN"]
API_KEY = os.environ["ANTHROPIC_API_KEY"]
MODEL = os.environ.get("MODEL", "claude-haiku-5-5")
MAX_DOCS = int(os.environ.get("MAX_DOCS", "20"))
DRY_RUN = os.environ.get("DRY_RUN") == "1"
ONLY_IDS = [int(i) for i in os.environ.get("ONLY_IDS", "").split(",") if i.strip()]
MAX_CONTENT = 200_000

F_TOTAL = "Rechnungsbetrag"
F_35A = "§35a Arbeitskosten"
REVIEW_TAG = "Betrag prüfen"
INVOICE_TYPE = "Rechnung"
TAG_35A = "§35a"

PROMPT = """You extract amounts from German documents archived in Paperless-ngx.

Return `rechnungsbetrag`: the gross total (Brutto, including VAT) the invoice asks to pay, in EUR.
- If the document is not an invoice (payment reminder / Zahlungserinnerung, Mahnung, quote, delivery note, contract, letter), return null.
- For utility bills (Strom, Gas, Wasser) it is the gross total of the billing period, not the credit (Guthaben), the instalment or the balance after prepayments.
- Use the amount of the invoice itself, not a total with reminder fees.
- If several amounts are plausible and you cannot decide, return null.
{extra}
Never guess: null is always better than a wrong number. Use a plain number with a dot as decimal separator. `begruendung` is one or two short sentences (German) naming the amounts you used or why you returned null."""

EXTRA_35A = """
Also return `arbeitskosten_35a`: the part of the invoice deductible under § 35a EStG, gross (including VAT).
- Counts: labour, machine and travel costs (Arbeitslohn, Fahrtkosten, Maschinen- und Geraetekosten, Anfahrt), incl. VAT.
- Does not count: materials, plants, soil, goods, spare parts; disposal fees (Entsorgung) are excluded.
- A chimney sweep's (Schornsteinfeger) whole fee counts.
- If the invoice does not separate labour from material and you cannot derive it, return null.
- If the document is not an invoice, return null.
"""


def http(method, url, body=None, headers=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def pl(method, path, body=None):
    return http(
        method,
        f"{PAPERLESS}/api/{path}",
        body,
        {"Authorization": f"Token {TOKEN}", "Accept": "application/json; version=9"},
    )


def pl_list(path):
    out = []
    url = path
    while url:
        page = pl("GET", url)
        out += page["results"]
        nxt = page.get("next")
        url = nxt.split("/api/", 1)[1] if nxt else None
    return out


def ask_claude(doc, correspondent, tags, want_35a):
    props = {
        "rechnungsbetrag": {"type": ["number", "null"]},
        "begruendung": {"type": "string"},
    }
    if want_35a:
        props["arbeitskosten_35a"] = {"type": ["number", "null"]}
    schema = {
        "type": "object",
        "properties": props,
        "required": list(props),
        "additionalProperties": False,
    }
    content = doc.get("content") or ""
    if len(content) > MAX_CONTENT:
        raise RuntimeError(f"content too long ({len(content)} chars)")
    user = (
        f"Title: {doc.get('title')}\nCorrespondent: {correspondent}\n"
        f"Tags: {', '.join(tags)}\n\nContent:\n{content}"
    )
    resp = http(
        "POST",
        "https://api.anthropic.com/v1/messages",
        {
            "model": MODEL,
            "max_tokens": 2000,
            "system": PROMPT.format(extra=EXTRA_35A if want_35a else ""),
            "messages": [{"role": "user", "content": user}],
            "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": schema}},
        },
        {"x-api-key": API_KEY, "anthropic-version": "2023-06-01"},
        timeout=120,
    )
    if resp.get("stop_reason") in ("refusal", "max_tokens"):
        raise RuntimeError(f"stop_reason {resp.get('stop_reason')}")
    text = "".join(b.get("text", "") for b in resp["content"] if b.get("type") == "text")
    return json.loads(text)


def attach_missing(field_name, field_id, filters):
    """Attach the empty field to matching documents that lack it.

    The Paperless workflows that should do this run when a document is added,
    but the AI suggestions (document type, tags) arrive later from a task that
    saves without the document_updated signal, so they never match.
    """
    params = {
        **filters,
        "custom_field_query": json.dumps([field_name, "exists", False]),
        "page_size": 100,
        "fields": "id",
    }
    ids = [d["id"] for d in pl_list("documents/?" + urllib.parse.urlencode(params))]
    if not ids:
        return
    print(f"attaching {field_name!r} to {ids}")
    if DRY_RUN:
        return
    pl("POST", "documents/bulk_edit/", {
        "documents": ids,
        "method": "modify_custom_fields",
        "parameters": {"add_custom_fields": [field_id], "remove_custom_fields": []},
    })


def main():
    fields = {f["name"]: f["id"] for f in pl_list("custom_fields/?page_size=100")}
    for n in (F_TOTAL, F_35A):
        if n not in fields:
            print(f"custom field {n!r} missing", file=sys.stderr)
            return 1
    tags = {t["name"]: t["id"] for t in pl_list("tags/?page_size=1000")}
    tag_names = {v: k for k, v in tags.items()}

    if not ONLY_IDS:
        types = {t["name"]: t["id"] for t in pl_list("document_types/?page_size=1000")}
        if INVOICE_TYPE in types:
            attach_missing(F_TOTAL, fields[F_TOTAL], {"document_type__id": types[INVOICE_TYPE]})
        if TAG_35A in tags:
            attach_missing(F_35A, fields[F_35A], {"tags__id__all": tags[TAG_35A]})
    if REVIEW_TAG not in tags:
        if DRY_RUN:
            print(f"(dry run) would create tag {REVIEW_TAG!r}")
        else:
            t = pl("POST", "tags/", {"name": REVIEW_TAG, "is_inbox_tag": False})
            tags[REVIEW_TAG] = t["id"]
    review_id = tags.get(REVIEW_TAG)

    if ONLY_IDS:
        ids = ONLY_IDS
    else:
        q = ["OR", [[F_TOTAL, "isnull", True], [F_35A, "isnull", True]]]
        params = {
            "custom_field_query": json.dumps(q),
            "page_size": MAX_DOCS,
            "ordering": "id",
            "fields": "id",
        }
        if review_id:
            params["tags__id__none"] = review_id
        res = pl("GET", "documents/?" + urllib.parse.urlencode(params))
        ids = [d["id"] for d in res["results"]][:MAX_DOCS]
        print(f"{res['count']} candidate(s), processing {len(ids)}")

    corr_cache = {}
    for doc_id in ids:
        try:
            handle(doc_id, fields, tag_names, review_id, corr_cache)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403) and e.url.startswith(PAPERLESS):
                print(f"auth failure: {e}", file=sys.stderr)
                return 1
            if e.code in (401, 403):
                print(f"anthropic auth failure: {e}", file=sys.stderr)
                return 1
            print(f"doc {doc_id}: error {e} {e.read()[:300]!r}")
        except Exception as e:  # per-document problems never fail the job
            print(f"doc {doc_id}: error {type(e).__name__}: {e}")
    return 0


def handle(doc_id, fields, tag_names, review_id, corr_cache):
    doc = pl("GET", f"documents/{doc_id}/")
    cf = {c["field"]: c["value"] for c in doc.get("custom_fields", [])}
    has_total = fields[F_TOTAL] in cf
    has_35a = fields[F_35A] in cf
    if ONLY_IDS:  # test mode: pretend both fields are attached and empty
        need_total, need_35a = True, True
    else:
        need_total = has_total and cf[fields[F_TOTAL]] is None
        need_35a = has_35a and cf[fields[F_35A]] is None
    if not (need_total or need_35a):
        print(f"doc {doc_id}: nothing to do")
        return
    cid = doc.get("correspondent")
    if cid and cid not in corr_cache:
        corr_cache[cid] = pl("GET", f"correspondents/{cid}/")["name"]
    tags = [tag_names.get(t, str(t)) for t in doc.get("tags", [])]
    try:
        res = ask_claude(doc, corr_cache.get(cid, ""), tags, need_35a)
    except (RuntimeError, ValueError, KeyError) as e:
        # permanent per-document failures (too long, refusal, unparseable
        # answer): flag for review instead of retrying every run; transient
        # network/HTTP errors propagate and are retried next run
        res = {"begruendung": f"Fehler: {type(e).__name__}: {e}"}
    why = res.get("begruendung", "")

    values = {}
    problems = []
    if need_total:
        v = res.get("rechnungsbetrag")
        if v is None:
            problems.append(F_TOTAL)
        else:
            values[fields[F_TOTAL]] = f"EUR{v:.2f}"
    if need_35a:
        v = res.get("arbeitskosten_35a")
        if v is None:
            problems.append(F_35A)
        else:
            values[fields[F_35A]] = f"EUR{v:.2f}"
    print(f"doc {doc_id}: {values} missing={problems} reason={why!r}")
    if DRY_RUN or ONLY_IDS:
        return

    if values:
        pl("POST", "documents/bulk_edit/", {
            "documents": [doc_id],
            "method": "modify_custom_fields",
            "parameters": {"add_custom_fields": values, "remove_custom_fields": []},
        })
    if problems:
        pl("POST", "documents/bulk_edit/", {
            "documents": [doc_id],
            "method": "modify_tags",
            "parameters": {"add_tags": [review_id], "remove_tags": []},
        })
        pl("POST", f"documents/{doc_id}/notes/", {
            "note": f"Automatische Betragserkennung: {', '.join(problems)} nicht ermittelt. {why}",
        })


if __name__ == "__main__":
    sys.exit(main())
