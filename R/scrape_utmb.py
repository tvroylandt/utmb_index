#!/usr/bin/env python3
"""Scrape de toutes les courses UTMB Index et de leurs résultats (rang, temps, index).

Étape 1 - liste des courses (https://utmb.world/fr/index-races), fenêtre mensuelle de
  2000-01 à aujourd'hui via api.utmb.world/search/races-qualifiers:
    python3 scrape_utmb.py races [--from 2000-01] [--to AAAA-MM] [--out data]
  -> data/races.csv

Étape 2 - résultats de chaque course (reprenable: les courses déjà faites sont ignorées):
    python3 scrape_utmb.py results [--out data] [--delay 0.15] [--limit N] [--since 2021] [--until 2025]
  -> data/results.csv (ajout au fil de l'eau) + data/results_done.txt

Connexion (nécessaire pour la colonne `index`, null pour les visiteurs anonymes):
    export UTMB_USER='email' UTMB_PASSWORD='motdepasse'   # compte MyUTMB (pas Google/Facebook)
  Le script se connecte à Keycloak (accounts.utmb.world), envoie le jeton en Bearer à api.utmb.world
  (`/races/{uri}/results`, 1 requête par course) et le renouvelle seul (il expire en quelques minutes). Sans ces variables,
  le scraping est anonyme et `index` reste vide. `--since/--until` bornent les années
  (défaut 2021-2025 pour `results`).

Séquentiel volontairement: le site renvoie des 503 dès qu'on parallélise.
Note: l'index *par course* est null pour les visiteurs non connectés ; conservé tel quel.
"""
import argparse, base64, csv, datetime as dt, hashlib, html as htmllib, http.cookiejar, json, os, re, secrets
import sys, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

BASE = "https://utmb.world"
API_BASE = "https://api.utmb.world"
API = API_BASE + "/search/races-qualifiers"
UA = {"User-Agent": "Mozilla/5.0 (utmb-index-scraper)"}
KC = "https://accounts.utmb.world/auth/realms/utmb-world/protocol/openid-connect"
CLIENT_ID, REDIRECT = "utmb-world", "https://utmb.world/fr/"
AUTH = None  # Auth() si identifiants fournis

RACE_FIELDS = ["uriResults", "id", "eventName", "name", "category", "year", "startDate", "startCountry",
               "startPlace", "distance", "elevationGain", "hasResults", "level", "nbStones", "url"]
RESULT_FIELDS = ["race_uri", "rank", "runnerUri", "fullname", "time", "gender", "ageGroup",
                 "nationalityCode", "nationality", "index"]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Auth:
    """Connexion Keycloak (code + PKCE) puis renouvellement par refresh_token."""

    def __init__(self, user, password):
        self.user, self.password = user, password
        self.token = self.refresh = None
        self.exp = 0

    def _post(self, opener, url, data):
        req = urllib.request.Request(url, urllib.parse.urlencode(data).encode(), UA)
        return opener.open(req, timeout=30)

    def login(self):
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), _NoRedirect)
        verifier = secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        q = urllib.parse.urlencode({"client_id": CLIENT_ID, "redirect_uri": REDIRECT, "response_type": "code",
                                    "response_mode": "query", "scope": "openid", "code_challenge": challenge,
                                    "code_challenge_method": "S256", "state": secrets.token_hex(8)})
        page = opener.open(urllib.request.Request(f"{KC}/auth?{q}", headers=UA), timeout=30).read().decode()
        m = re.search(r'<form[^>]+id="kc-form-login"[^>]+action="([^"]+)"', page) or re.search(r'action="([^"]+)"', page)
        if not m:
            raise RuntimeError("formulaire de connexion Keycloak introuvable")
        try:
            self._post(opener, htmllib.unescape(m.group(1)), {"username": self.user, "password": self.password,
                                                               "credentialId": ""})
            raise RuntimeError("connexion refusée (identifiants, 2FA ou captcha ?)")
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location", "")
            if e.code not in (301, 302, 303) or "code=" not in loc:
                raise RuntimeError(f"connexion refusée (HTTP {e.code})")
        code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)["code"][0]
        self._store(json.load(self._post(urllib.request.build_opener(), f"{KC}/token", {
            "grant_type": "authorization_code", "client_id": CLIENT_ID, "code": code,
            "redirect_uri": REDIRECT, "code_verifier": verifier})))

    def _store(self, t):
        self.token, self.refresh = t["access_token"], t.get("refresh_token")
        self.exp = time.time() + t.get("expires_in", 300) - 30

    def cookie(self):
        if time.time() >= self.exp:
            try:
                if not self.refresh:
                    raise ValueError
                self._store(json.load(self._post(urllib.request.build_opener(), f"{KC}/token", {
                    "grant_type": "refresh_token", "client_id": CLIENT_ID, "refresh_token": self.refresh})))
            except (urllib.error.HTTPError, ValueError):
                self.login()
        return f"access_token={self.token}"


def http_get(url, retries=6, delay=2.0):
    for i in range(retries):
        try:
            headers = dict(UA)
            if AUTH and url.startswith(BASE):
                headers["Cookie"] = AUTH.cookie()
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
                return r.read().decode()
        except urllib.error.HTTPError as e:
            if e.code == 404 or i == retries - 1:
                raise
        except (urllib.error.URLError, TimeoutError):
            if i == retries - 1:
                raise
        time.sleep(delay * 2 ** i)  # 503 / réseau: backoff


def month_windows(start, end):
    y, m = start
    while (y, m) <= end:
        last = (dt.date(y + (m == 12), m % 12 + 1, 1) - dt.timedelta(days=1)).day
        yield f"{y}-{m:02d}-01", f"{y}-{m:02d}-{last}"
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def cmd_races(a):
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    today = dt.date.today()
    start = tuple(map(int, a.from_.split("-")))
    end = tuple(map(int, a.to.split("-"))) if a.to else (today.year, today.month)
    seen, total = set(), 0
    with open(out / "races.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=RACE_FIELDS, extrasaction="ignore")
        w.writeheader()
        for dmin, dmax in month_windows(start, end):
            offset = 0
            while True:
                q = urllib.parse.urlencode({"dateMin": dmin, "dateMax": dmax, "limit": 500, "offset": offset})
                d = json.loads(http_get(f"{API}?{q}"))
                for r in d["races"]:
                    key = (r["id"], r["uriResults"])
                    if key not in seen:
                        seen.add(key); w.writerow(r); total += 1
                offset += d["limit"]
                if offset >= d["nbHits"] or not d["races"]:
                    break
            print(f"{dmin[:7]}: {total} courses", file=sys.stderr)
            time.sleep(a.delay)
    print(f"OK -> {out}/races.csv ({total} courses)", file=sys.stderr)


class Results:
    """Une requête par course sur api.utmb.world (Bearer), `limit` géant au lieu des pages de 25."""

    def __init__(self, delay, limit=5000):
        self.delay, self.limit = delay, limit

    def get(self, uri, offset):
        q = urllib.parse.urlencode({"lang": "fr", "gender": "", "offset": offset, "limit": self.limit})
        req = urllib.request.Request(f"{API_BASE}/races/{uri}/results?{q}", headers=self.headers())
        for i in range(6):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 404 or i == 5:
                    raise
            except (urllib.error.URLError, TimeoutError):
                if i == 5:
                    raise
            time.sleep(2 * 2 ** i)
            req = urllib.request.Request(req.full_url, headers=self.headers())  # jeton éventuellement renouvelé

    def headers(self):
        h = dict(UA)
        if AUTH:
            h["Authorization"] = "Bearer " + AUTH.cookie().split("=", 1)[1]
        return h

    def race(self, uri):
        d = self.get(uri, 0)
        rows = list(d["results"])
        while len(rows) < d["nbHits"] and d["results"]:  # course > limit: on pagine
            time.sleep(self.delay)
            d = self.get(uri, len(rows))
            rows.extend(d["results"])
        for r in rows:
            r["race_uri"] = uri
        return rows, d["nbHits"]


def cmd_results(a):
    global AUTH
    if os.environ.get("UTMB_USER") and os.environ.get("UTMB_PASSWORD"):
        AUTH = Auth(os.environ["UTMB_USER"], os.environ["UTMB_PASSWORD"])
        AUTH.login()
        print("connecté (index par course activé)", file=sys.stderr)
    else:
        print("ATTENTION: anonyme, la colonne index restera vide (UTMB_USER/UTMB_PASSWORD)", file=sys.stderr)
    out = Path(a.out)
    done_path, res_path = out / "results_done.txt", out / "results.csv"
    done = set(done_path.read_text().split()) if done_path.exists() else set()
    with open(out / "races.csv", encoding="utf-8") as f:
        todo = [r for r in csv.DictReader(f)
                if r["hasResults"] == "True" and r["uriResults"] not in done
                and a.since <= int(r["year"]) <= a.until]
    todo = todo[: a.limit] if a.limit else todo
    new = not res_path.exists()
    scraper = Results(a.delay)
    with open(res_path, "a", newline="", encoding="utf-8") as fr, open(done_path, "a") as fd:
        w = csv.DictWriter(fr, fieldnames=RESULT_FIELDS, extrasaction="ignore")
        if new:
            w.writeheader()
        for i, r in enumerate(todo, 1):
            uri = r["uriResults"]
            try:
                rows, n = scraper.race(uri)
            except Exception as e:
                print(f"[{i}/{len(todo)}] ECHEC {uri}: {e}", file=sys.stderr)
                continue
            w.writerows(rows); fr.flush()
            fd.write(uri + "\n"); fd.flush()
            print(f"[{i}/{len(todo)}] {uri}: {len(rows)}/{n}", file=sys.stderr)
            time.sleep(a.delay)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("races")
    r.add_argument("--from", dest="from_", default="2000-01")
    r.add_argument("--to", default=None)
    r.add_argument("--delay", type=float, default=0.3)
    s = sub.add_parser("results")
    s.add_argument("--delay", type=float, default=0.15)
    s.add_argument("--limit", type=int, default=0, help="nb max de courses à traiter")
    s.add_argument("--since", type=int, default=2021, help="année minimale")
    s.add_argument("--until", type=int, default=2025, help="année maximale")
    for p in (r, s):
        p.add_argument("--out", default="data")
    a = ap.parse_args()
    {"races": cmd_races, "results": cmd_results}[a.cmd](a)


if __name__ == "__main__":
    main()
