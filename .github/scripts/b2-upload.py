#!/usr/bin/env python3
# Resumable Backblaze B2 upload via the native large-file API.
#
# Files larger than 100 MB are uploaded as a B2 large file: the parts are
# streamed one at a time (each ~recommendedPartSize, typically 100 MB) and a
# mid-transfer TLS/network drop only re-sends the affected part, never the
# whole multi-GB file. Small files use the single-shot b2_upload_file call.
#
# New content is uploaded and finished BEFORE any old versions are deleted,
# so a failed upload can never leave the bucket empty (the failure mode hit
# in CI run 31819490064, where the old ISO/bundle were deleted first).
#
# Usage:
#   b2-upload.py --key-id ID --key KEY --bucket BUCKET \
#       --file LOCAL --name B2_NAME \
#       [--content-type CT] \
#       [--prune-prefix PREFIX --prune-glob GLOB --keep-newest N] \
#       [--cancel-unfinished] [--retries N] [--backoff S]
#
# --prune-prefix/--prune-glob/--keep-newest: after the new file is safely
#   uploaded, delete the oldest versions under the prefix that match the glob
#   so the bucket stays under the free-tier storage cap.

import argparse
import fnmatch
import hashlib
import http.client
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.parse

SMALL_FILE_MAX = 100 * 1024 * 1024  # 100 MB
AUTH_URL = os.environ.get(
    "B2_API_URL",
    "https://api.backblazeb2.com/b2api/v3/b2_authorize_account",
)
TLS_INSECURE = os.environ.get("B2_TLS_INSECURE") == "1"


class CurlError(RuntimeError):
    pass


def curl_json(args, data=None, body=None):
    cmd = ["curl", "-sS", "--connect-timeout", "30", "--max-time", "300",
           "-w", "\n%{http_code}"]
    if TLS_INSECURE:
        cmd += ["-k"]
    cmd += args
    if data is not None:
        cmd += ["--data-binary", data]
    if body is not None:
        cmd += ["--data-binary", "@-"]
    r = subprocess.run(cmd, input=body, capture_output=True)
    out = r.stdout.decode(errors="replace")
    code = out.rsplit("\n", 1)[-1].strip() if out else ""
    if r.returncode != 0 or not code.startswith("2"):
        raise CurlError(
            f"curl {args[0] if args else ''} failed rc={r.returncode} http={code} "
            f"stderr={r.stderr.decode(errors='replace')[:300]} body={out[:400]}"
        )
    return json.loads(out.rsplit("\n", 1)[0])


def retry(fn, n=5, delay=5):
    last = None
    for i in range(n):
        try:
            return fn()
        except Exception as e:
            last = e
            if i == n - 1:
                raise
            print(f"attempt {i + 1}/{n} failed: {e}; retrying in {delay}s", file=sys.stderr)
            time.sleep(delay)
    raise last


def sha1_file(path):
    return sha1_range(path, 0, os.path.getsize(path))


def sha1_range(path, start, end):
    h = hashlib.sha1()
    remaining = end - start
    with open(path, "rb") as src:
        src.seek(start)
        while remaining > 0:
            chunk = src.read(min(1 << 20, remaining))
            if not chunk:
                break
            h.update(chunk)
            remaining -= len(chunk)
    return h.hexdigest()


def _ssl_ctx():
    ctx = ssl.create_default_context()
    if TLS_INSECURE:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def stream_upload(url, token, headers, path, start, end):
    # POST the byte range [start, end) from path to url with http.client,
    # which streams the body instead of buffering it in memory.
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPSConnection(u.hostname, u.port, timeout=3600,
                                       context=_ssl_ctx())
    size = end - start
    try:
        with open(path, "rb") as src:
            src.seek(start)
            remaining = size
            body = _slice_reader(src, remaining)
            conn.request("POST", u.path, body=body, headers={
                "Authorization": token,
                "Content-Length": str(size),
                **headers,
            })
            resp = conn.getresponse()
            resp_body = resp.read()
            if resp.status != 200:
                raise CurlError(
                    f"upload failed http={resp.status} body={resp_body.decode(errors='replace')[:400]}"
                )
            return json.loads(resp_body)
    finally:
        conn.close()


class _slice_reader:
    def __init__(self, src, length):
        self.src = src
        self.length = length
        self.sent = 0

    def read(self, size=-1):
        if self.length <= self.sent:
            return b""
        want = self.length - self.sent
        if size is not None and size >= 0:
            want = min(want, size)
        chunk = self.src.read(want)
        self.sent += len(chunk)
        return chunk


def upload_small(api_url, token, bucket_id, name, content_type, local, retries, backoff):
    full_sha1 = sha1_file(local)
    size = os.path.getsize(local)
    print(f"uploading {name} ({size} bytes, small file)")

    def attempt():
        up = curl_json(
            ["-H", f"Authorization: {token}",
             f"{api_url}/b2api/v3/b2_get_upload_url",
             "--data-binary", json.dumps({"bucketId": bucket_id})],
        )
        up_token = up.get("uploadAuthorizationToken") or up.get("authorizationToken")
        if not up_token:
            raise CurlError("no token in get_upload_url response")
        headers = {
            "X-Bz-File-Name": urllib.parse.quote(name, safe=""),
            "X-Bz-Content-Sha1": full_sha1,
            "Content-Type": content_type,
        }
        return stream_upload(up["uploadUrl"], up_token, headers, local, 0, size)

    result = retry(attempt, retries, backoff)
    print(f"uploaded {name} ({result.get('contentLength')}) fileId {result['fileId']}")


def upload_large(api_url, token, bucket_id, name, content_type, local,
                 part_size, retries, backoff):
    size = os.path.getsize(local)
    full_sha1 = sha1_file(local)
    print(f"uploading {name} ({size} bytes) as large file, part size {part_size}")

    start = curl_json(
        ["-H", f"Authorization: {token}",
         f"{api_url}/b2api/v3/b2_start_large_file",
         "--data-binary", json.dumps({
             "bucketId": bucket_id,
             "fileName": name,
             "contentType": content_type,
             "fileInfo": {"large_file_sha1": full_sha1},
         })],
    )
    file_id = start["fileId"]
    print(f"started large file {name} ({file_id})")

    part_shas = []
    try:
        offset = 0
        part_no = 0
        while offset < size:
            part_no += 1
            end = min(offset + part_size, size)
            part_shas.append(sha1_range(local, offset, end))

            def attempt(pn=part_no, off=offset, e=end, sha=part_shas[-1]):
                pu = curl_json(
                    ["-H", f"Authorization: {token}",
                     f"{api_url}/b2api/v3/b2_get_upload_part_url",
                     "--data-binary", json.dumps({"fileId": file_id})],
                )
                pu_token = pu.get("uploadAuthorizationToken") or pu.get("authorizationToken")
                if not pu_token:
                    raise CurlError("no token in get_upload_part_url response")
                headers = {
                    "X-Bz-Part-Number": str(pn),
                    "X-Bz-Content-Sha1": sha,
                }
                return stream_upload(pu["uploadUrl"], pu_token, headers, local, off, e)

            retry(attempt, retries, backoff)
            print(f"part {part_no} uploaded ({end - offset} bytes)")
            offset = end

        def do_finish():
            return curl_json(
                ["-H", f"Authorization: {token}",
                 f"{api_url}/b2api/v3/b2_finish_large_file",
                 "--data-binary", json.dumps({"fileId": file_id,
                                              "partSha1Array": part_shas})],
            )

        finish = retry(do_finish, retries, backoff)
        print(f"finished {name} ({finish.get('contentLength')} bytes) fileId {finish.get('fileId')}")
    except Exception:
        try:
            curl_json(
                ["-H", f"Authorization: {token}",
                 f"{api_url}/b2api/v3/b2_cancel_large_file",
                 "--data-binary", json.dumps({"fileId": file_id})],
            )
            print("cancelled unfinished large file (no partial parts left behind)")
        except Exception:
            pass
        raise


def prune_old(token, api_url, bucket_id, prefix, glob, keep_newest):
    listing = curl_json(
        ["-H", f"Authorization: {token}",
         f"{api_url}/b2api/v3/b2_list_file_versions",
         "--data-binary", json.dumps({"bucketId": bucket_id, "prefix": prefix,
                                      "maxFileCount": 10000})],
    )
    files = [f for f in listing.get("files", []) if fnmatch.fnmatch(f["fileName"], glob)]
    files.sort(key=lambda f: f.get("uploadTimestamp", 0), reverse=True)
    for f in files[keep_newest:]:
        print(f"removing old {f['fileName']} ({f['fileId']})")
        curl_json(
            ["-H", f"Authorization: {token}",
             f"{api_url}/b2api/v3/b2_delete_file_version",
             "--data-binary", json.dumps({"fileName": f["fileName"],
                                          "fileId": f["fileId"]})],
        )


def cancel_unfinished(token, api_url, bucket_id):
    listing = curl_json(
        ["-H", f"Authorization: {token}",
         f"{api_url}/b2api/v3/b2_list_unfinished_large_files",
         "--data-binary", json.dumps({"bucketId": bucket_id, "maxFileCount": 100})],
    )
    for f in listing.get("files", []):
        print(f"cancelling unfinished large file {f['fileName']} ({f['fileId']})")
        curl_json(
            ["-H", f"Authorization: {token}",
             f"{api_url}/b2api/v3/b2_cancel_large_file",
             "--data-binary", json.dumps({"fileId": f["fileId"]})],
        )


def main():
    ap = argparse.ArgumentParser(description="Resumable Backblaze B2 upload")
    ap.add_argument("--key-id", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--content-type", default="application/octet-stream")
    ap.add_argument("--prune-prefix")
    ap.add_argument("--prune-glob", default="*")
    ap.add_argument("--keep-newest", type=int, default=1)
    ap.add_argument("--cancel-unfinished", action="store_true")
    ap.add_argument("--retries", type=int, default=5)
    ap.add_argument("--backoff", type=float, default=5)
    args = ap.parse_args()

    if not os.path.isfile(args.file):
        raise SystemExit(f"local file not found: {args.file}")

    auth = retry(lambda: curl_json(["-u", f"{args.key_id}:{args.key}", AUTH_URL]),
                 args.retries, args.backoff)
    token = auth["authorizationToken"]
    api_info = auth.get("apiInfo") or {}
    storage = api_info.get("storageApi") or {}
    api_url = auth.get("apiUrl") or storage.get("apiUrl") or api_info.get("apiUrl")
    if not api_url:
        raise SystemExit("cannot find apiUrl in authorize response: "
                         + json.dumps(auth)[:400])
    print(f"authorized: api={api_url}")

    buckets = retry(lambda: curl_json(
        ["-H", f"Authorization: {token}",
         f"{api_url}/b2api/v3/b2_list_buckets",
         "--data-binary", json.dumps({"accountId": auth.get("accountId", ""),
                                      "bucketName": args.bucket})],
    ), args.retries, args.backoff)
    bucket_id = next(b["bucketId"] for b in buckets["buckets"]
                     if b["bucketName"] == args.bucket)
    print(f"bucket {args.bucket} id {bucket_id}")

    if args.cancel_unfinished:
        cancel_unfinished(token, api_url, bucket_id)

    size = os.path.getsize(args.file)
    if size <= SMALL_FILE_MAX:
        upload_small(api_url, token, bucket_id, args.name, args.content_type,
                     args.file, args.retries, args.backoff)
    else:
        recommended = storage.get("recommendedPartSize") or (100 * 1024 * 1024)
        part_size = max(recommended, 5 * 1024 * 1024)
        # B2 large files must consist of at least two parts.
        if size < 2 * part_size:
            part_size = max(size // 2, 5 * 1024 * 1024)
        upload_large(api_url, token, bucket_id, args.name, args.content_type,
                     args.file, part_size, args.retries, args.backoff)

    # Only now that the new file is safely in the bucket, prune old versions.
    if args.prune_prefix:
        prune_old(token, api_url, bucket_id, args.prune_prefix,
                  args.prune_glob, args.keep_newest)
    print(f"::notice::uploaded {args.name} to B2 bucket {args.bucket}")


if __name__ == "__main__":
    main()
