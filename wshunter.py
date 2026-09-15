#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wshunter.py - Webshell & Backdoor Hunter untuk server Linux (NON-ROOT)
======================================================================
* Hanya Python 3 standard library (>= 3.6). Tanpa pip, tanpa sudo.
* Tidak pernah mengikuti symlink; tidak pernah menghapus permanen.

Mode:
  scan        Pindai & laporkan saja (default).
  dry-run     Pindai + tampilkan RENCANA karantina, tanpa mengubah berkas apa pun.
  quarantine  Pindai + pindahkan berkas mencurigakan ke
              <root>/.quarantine_YYYYMMDD/ (berkas & folder di-chmod 000).

Exit code:
  0 = tidak ada temuan, 1 = temuan LOW/MEDIUM, 2 = ada temuan HIGH, 3 = error fatal
"""

import argparse
import collections
import datetime
import errno
import fnmatch
import hashlib
import json
import math
import os
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys
import time

VERSION = "1.0.0"
DEFAULT_ROOT = "/home/yimand5"

# =============================================================================
# 1. KONFIGURASI
# =============================================================================
PHP_EXT = {".php", ".php3", ".php4", ".php5", ".php7", ".php8", ".phtml",
           ".pht", ".phar", ".phps", ".inc"}
PHP_ALT_EXT = PHP_EXT - {".php", ".inc"}
IMG_EXT = {".ico", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp",
           ".svg", ".tif", ".tiff"}
SCRIPT_EXT = {".sh", ".bash", ".pl", ".cgi", ".py", ".rb"}
TEXT_EXT = {".txt", ".html", ".htm", ".tpl", ".bak", ".old", ".orig",
            ".save", ".tmp"}
SHELL_RC = {".bashrc", ".bash_profile", ".bash_login", ".profile",
            ".bash_logout", ".zshrc", ".zprofile"}
CONFIG_NAMES = {".htaccess", ".user.ini", "php.ini"}
SSH_KEY_NAMES = {"authorized_keys", "authorized_keys2"}

# Pengecualian default (bisa dimatikan dengan --no-default-excludes).
# Pola tanpa "/" dicocokkan ke NAMA folder; pola dengan "/" ke PATH relatif.
DEFAULT_EXCLUDES = ["node_modules", "vendor", "storage/framework/cache",
                    ".git", ".svn", ".npm", ".cache/composer"]
# Selalu dikecualikan (agar tidak memindai hasil karantina / log sendiri).
HARD_EXCLUDE_DIRS = [".quarantine_*"]
HARD_EXCLUDE_FILES = ["webshell_scan_*.log", "webshell_scan_*.json"]

LEVEL_THRESHOLD = [("HIGH", 10), ("MEDIUM", 6), ("LOW", 3)]
LEVEL_RANK = {"INFO": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3}

ENTROPY_THRESHOLD = 5.3      # bit/karakter (base64 acak ~5.9, teks biasa ~4.2)
ENTROPY_MIN_LEN = 150
LONG_LINE_THRESHOLD = 5000

IMG_MAGIC = {
    ".png": [b"\x89PNG"], ".jpg": [b"\xff\xd8\xff"], ".jpeg": [b"\xff\xd8\xff"],
    ".gif": [b"GIF87a", b"GIF89a"], ".bmp": [b"BM"], ".webp": [b"RIFF"],
    ".ico": [b"\x00\x00\x01\x00", b"\x00\x00\x02\x00", b"\x89PNG"],
}

# =============================================================================
# 2. RULES / SIGNATURE
# =============================================================================
Rule = collections.namedtuple("Rule", "rid weight desc regex")
FLAGS = re.IGNORECASE | re.MULTILINE


def _r(rid, weight, desc, pattern):
    return Rule(rid, weight, desc, re.compile(pattern, FLAGS))


# Bukan method (->x / ::x), bukan variabel ($x), bukan deklarasi fungsi.
FN = r"(?<![\w>$:])(?<!function )"
UI = r"(?:\$_(?:GET|POST|REQUEST|COOKIE|FILES)\b|\$_SERVER\s*\[\s*['\"]HTTP_)"
UI_STRICT = r"\$_(?:GET|POST|REQUEST|COOKIE)\b"

PHP_RULES = [
    # --- fungsi berbahaya -------------------------------------------------
    _r("PHP-EXEC", 3, "Fungsi eksekusi perintah OS (system/shell_exec/passthru/proc_open/popen)",
       FN + r"(?:system|shell_exec|passthru|proc_open|popen|pcntl_exec)\s*\("),
    _r("PHP-EXEC2", 2, "Fungsi exec()", FN + r"exec\s*\("),
    _r("PHP-EVAL", 3, "eval()", FN + r"eval\s*\("),
    _r("PHP-ASSERT", 4, "assert() dengan argumen dinamis",
       FN + r"assert\s*\(\s*(?:\$|base64|str_rot13|gz)"),
    _r("PHP-DECODE", 1, "Fungsi decode/obfuscation (base64_decode/gzinflate/str_rot13/...)",
       r"\b(?:base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|convert_uudecode|hex2bin)\s*\("),
    _r("PHP-CREATEFUNC", 3, "create_function() (deprecated, favorit backdoor)",
       r"\bcreate_function\s*\("),
    _r("PHP-PREG-E", 6, "preg_replace dengan modifier /e (eksekusi kode)",
       r"preg_replace\s*\(\s*(['\"])(.)(?:(?!\1).)*?\2[imsxuADSUXJ]*e[imsxuADSUXJ]*\1"),
    _r("PHP-UPLOAD", 2, "Handler upload (move_uploaded_file) - cek validasinya",
       r"move_uploaded_file\s*\("),
    _r("PHP-SOCKET", 2, "Koneksi socket keluar (fsockopen/socket_create)",
       r"\b(?:fsockopen|pfsockopen|socket_create|stream_socket_client)\s*\("),
    # --- kombinasi (indikator kuat) ---------------------------------------
    _r("PHP-EVAL-DECODE", 8, "Rantai eksekusi + decode, mis. eval(base64_decode(...))",
       r"(?:eval|assert|system|create_function|shell_exec|passthru)\s*\(\s*@?\s*"
       r"(?:base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|rawurldecode|"
       r"urldecode|convert_uudecode|hex2bin|pack)\s*\("),
    _r("PHP-NESTED-DECODE", 5, "Decode berlapis, mis. gzinflate(base64_decode(...))",
       r"(?:gzinflate|gzuncompress|gzdecode|str_rot13|strrev|base64_decode)\s*\(\s*@?\s*"
       r"(?:base64_decode|str_rot13|gzinflate|gzuncompress|strrev|rawurldecode)\s*\("),
    _r("PHP-UI-EXEC", 9, "Eksekusi kode/perintah langsung dari input HTTP",
       FN + r"(?:eval|assert|system|shell_exec|passthru|exec|popen|proc_open|pcntl_exec|"
       r"create_function|call_user_func(?:_array)?)\s*\([^;]{0,80}?" + UI),
    _r("PHP-UI-INCLUDE", 7, "include/require dari input HTTP (LFI/RFI)",
       r"\b(?:include|require)(?:_once)?\b\s*\(?[^;]{0,60}?" + UI_STRICT),
    _r("PHP-BACKTICK", 8, "Backtick shell execution dengan input HTTP",
       r"(?:=|\(|\becho|\bprint|\breturn)\s*`[^`\n]{0,80}" + UI_STRICT),
    _r("PHP-VARFUNC-UI", 9, "Fungsi dinamis dari input HTTP, mis. $_GET['f']($_GET['c'])",
       UI_STRICT + r"\s*\[[^\]]{1,40}\]\s*\("),
    _r("PHP-EVAL-CLOSE", 6, "eval('?>' . ...) - eksekusi blok PHP tersisip",
       r"eval\s*\(\s*['\"]\?>"),
    _r("PHP-ENC-INCLUDE", 10, "include/require dengan path ter-encode (hex/octal)",
       r"\b(?:include|require)(?:_once)?\b\s*\(?\s*['\"][^'\"\n]*(?:\\x[0-9a-f]{2}|\\[0-7]{3})"),
    _r("PHP-INCLUDE-NONPHP", 7, "include/require berkas non-PHP (gambar/teks)",
       r"\b(?:include|require)(?:_once)?\b\s*\(?\s*['\"][^'\"\n]+\.(?:jpe?g|png|gif|ico|bmp|txt|webp|svg)['\"]"),
    _r("PHP-DROPPER", 4, "Menulis kode/berkas PHP ke disk (dropper)",
       r"(?:file_put_contents|fwrite|fputs)\s*\([^;]{0,150}?(?:<\?php|\.php[0-9]?['\"])"),
    _r("PHP-REMOTE-PAYLOAD", 3, "Mengunduh payload remote berekstensi non-kode",
       r"(?:file_get_contents|fopen|curl_init|copy|readfile)\s*\(\s*['\"](?:https?|ftp)://"
       r"[^'\"]+\.(?:txt|jpe?g|png|gif|ico)['\"]"),
    _r("PHP-PASTE-HOST", 4, "Mengambil kode dari layanan paste/raw hosting",
       r"(?:pastebin\.com/raw|paste\.ee/r|raw\.githubusercontent\.com|transfer\.sh|hastebin\.com/raw)"),
    _r("PHP-REVSHELL", 8, "Pola reverse shell",
       r"(?:/bin/(?:ba)?sh\s+-i|/dev/tcp/|\bnc\s+-e\b)"),
    _r("PHP-SUPPRESS-EXEC", 2, "Eksekusi dengan error-suppression (@)",
       r"@\s*(?:eval|assert|system|shell_exec|passthru|exec|popen)\s*\("),
    _r("PHP-INI-TAMPER", 3, "Mengubah pengaturan keamanan PHP saat runtime",
       r"ini_(?:set|restore)\s*\(\s*['\"](?:disable_functions|open_basedir|safe_mode|allow_url_include)"),
    _r("PHP-STEALTH", 2, "Kombinasi siluman error_reporting(0) + set_time_limit(0)",
       r"error_reporting\s*\(\s*0\s*\)[\s\S]{0,300}set_time_limit\s*\(\s*0\s*\)"),
    _r("PHP-BOT-CLOAK", 4, "Cloaking berdasarkan User-Agent/Referer mesin pencari (SEO spam)",
       r"(?:HTTP_USER_AGENT|HTTP_REFERER)[^;\n]{0,120}(?:googlebot|bingbot|yandex|google\.)"),
    # --- obfuscation --------------------------------------------------------
    _r("PHP-VARFUNC", 2, "Pemanggilan fungsi via variabel ($f($x))",
       r"(?<![\w>:])\$[a-z_]\w*\s*(?:\[[^\]\n]{1,40}\]\s*|\{[^}\n]{1,40}\}\s*){0,3}\(\s*\$"),
    _r("PHP-HEXVARNAME", 6, "Nama variabel hex/octal-encoded, mis. ${\"\\x47LOBALS\"}",
       r"\$\{\s*['\"](?:\\x[0-9a-f]{2}|\\[0-7]{3})"),
    _r("PHP-GLOBALS-CALL", 5, "Pemanggilan fungsi lewat $GLOBALS[...]",
       r"\$GLOBALS\s*\[[^\]]{1,60}\]\s*(?:\[[^\]]{1,40}\]\s*)*\("),
    _r("PHP-HEXSTR", 3, "String hex-escape panjang (\\xNN berantai)", r"(?:\\x[0-9a-f]{2}){10,}"),
    _r("PHP-OCTSTR", 3, "String octal-escape panjang (\\NNN berantai)", r"(?:\\[0-7]{3}){10,}"),
    _r("PHP-CHR", 4, "Konstruksi string via chr() berantai", r"(?:chr\s*\(\s*\d+\s*\)\s*\.\s*){5,}"),
    _r("PHP-REVFUNC", 6, "Nama fungsi berbahaya ditulis terbalik (untuk strrev)",
       r"['\"](?:edoced_46esab|etalfnizg|sserpmocnuzg|31tor_rts|lave|tressa|metsys|cexe_llehs|urhtssap)['\"]"),
    _r("PHP-B64BLOB", 4, "Blob base64 sangat panjang (>=300 char)", r"['\"][a-z0-9+/]{300,}={0,2}['\"]"),
    _r("PHP-HEXBLOB", 3, "Blob hex sangat panjang (>=300 char)", r"['\"][0-9a-f]{300,}['\"]"),
    _r("PHP-PACK-H", 3, "pack('H*') - decode hex menjadi kode", r"pack\s*\(\s*['\"]H\*"),
    # --- signature webshell dikenal ------------------------------------------
    _r("PHP-KNOWN", 10, "Signature webshell / file-manager ilegal yang dikenal",
       r"(?:FilesMan|WSOsetcookie|wso_version|b374k|c99shell|c99_buff|r57shell|IndoXploit|"
       r"AlfaTeam|ALFA_DATA|MARIJUANA|0byt3m1n1|bypass_disable_function|php-reverse-shell|"
       r"pentestmonkey|Gecko\s*Shell|Tiny\s*File\s*Manager)"),
]

SEO_RULES = [
    _r("SEO-GAMBLING", 5, "Kata kunci spam judi/SEO (indikasi situs diretas)",
       r"(?:slot\s*gacor|judi\s*online|situs\s*slot|slot\s*online|togel\s*online|maxwin|sbobet|scatter\s*hitam)"),
]

SCRIPT_RULES = [
    _r("SH-DEVTCP", 8, "Reverse shell via /dev/tcp atau /dev/udp", r"/dev/(?:tcp|udp)/"),
    _r("SH-NC-EXEC", 8, "netcat dengan eksekusi (-e/-c)",
       r"\b(?:nc|ncat|netcat)\b[^\n|;]{0,60}\s-[a-z]*[ec]\b"),
    _r("SH-INTERACTIVE", 7, "Shell interaktif diarahkan ke socket/redirect",
       r"\b(?:ba)?sh\s+-i\s*(?:[<>]|&|2>)"),
    _r("SH-MKFIFO", 6, "mkfifo + shell/netcat (reverse shell klasik)", r"mkfifo[^\n]{0,120}(?:sh|nc)\b"),
    _r("PY-PTY", 6, "pty.spawn / dup2 socket (reverse shell Python)",
       r"pty\.spawn\s*\(|os\.dup2\s*\(\s*\w+\.fileno"),
    _r("PY-EXEC-B64", 7, "exec() atas payload ter-decode (Python)",
       r"\bexec\s*\(\s*(?:base64\.b64decode|zlib\.decompress|codecs\.decode|marshal\.loads|bytes\.fromhex)"),
    _r("PL-SOCKET-EXEC", 7, "Perl socket + exec shell",
       r"use\s+Socket\b[\s\S]{0,400}exec\s*\(?\s*['\"]/bin/"),
    _r("SH-CURL-PIPE", 6, "Unduh lalu langsung eksekusi (curl/wget | sh)",
       r"\b(?:curl|wget)\b[^\n|]{0,200}\|\s*(?:ba|z|da)?sh\b"),
    _r("SH-B64-PIPE", 7, "Decode base64 lalu eksekusi",
       r"base64\s+(?:-d|--decode)[^\n]{0,80}\|\s*(?:ba|z|da)?sh\b"),
    _r("SH-MINER", 8, "Indikasi cryptominer",
       r"\b(?:xmrig|minerd|cpuminer|xmr-stak|nicehash)\b|stratum\+(?:tcp|ssl)://"),
    _r("SH-TMPEXEC", 4, "Referensi file tersembunyi di direktori temp",
       r"(?:/tmp|/var/tmp|/dev/shm)/\.[\w.-]+"),
    _r("SH-HISTORY-KILL", 4, "Mematikan/menghapus jejak history",
       r"(?:unset\s+HISTFILE|HISTFILE=/dev/null|history\s+-c\b|HISTSIZE=0\b)"),
    _r("SH-PERSIST-BG", 2, "Proses latar belakang persisten (nohup/setsid ... &)",
       r"\b(?:nohup|setsid)\b[^\n]{0,160}&\s*$"),
    _r("SH-CHATTR", 3, "chattr +i/-i untuk mengunci berkas", r"\bchattr\s+[+-]i\b"),
    _r("SH-SSHKEY-INJECT", 6, "Menyuntikkan SSH key ke authorized_keys", r">>\s*[~\w/.$]*authorized_keys"),
    _r("SH-LD-PRELOAD", 6, "LD_PRELOAD (indikasi userland rootkit)", r"\bLD_PRELOAD\s*="),
]

CRON_RULES = [
    _r("CRON-FETCH", 3, "Cron memanggil curl/wget, php -r, atau lokasi temp",
       r"(?:\bcurl\s|\bwget\s|/tmp/|/dev/shm/|\bphp\s+-r\b)"),
    _r("CRON-REBOOT", 2, "Cron @reboot (persistensi saat boot)", r"^\s*@reboot\b"),
]

HTACCESS_RULES = [
    _r("HT-ADDTYPE-IMG", 9, "Memaksa ekstensi non-PHP (gambar/teks) dieksekusi sebagai PHP",
       r"^\s*(?:AddType|AddHandler)\s+[^\n]*(?:php|x-httpd)[^\n]*\.(?:jpe?g|png|gif|ico|txt|bmp|webp|svg|html?)\b"),
    _r("HT-SETHANDLER", 5, "SetHandler/ForceType ke PHP", r"^\s*(?:SetHandler|ForceType)\s+application/x-httpd-php"),
    _r("HT-PREPEND", 6, "php_value auto_prepend/append_file", r"php_value\s+auto_(?:prepend|append)_file"),
    _r("HT-ENGINE", 2, "php_flag engine on", r"php_flag\s+engine\s+on"),
    _r("HT-BOT-REDIRECT", 4, "Rewrite kondisional berdasarkan bot/referer mesin pencari",
       r"RewriteCond\s+%\{HTTP_(?:USER_AGENT|REFERER)\}[^\n]*(?:google|bing|yahoo)"),
    _r("HT-LOCK", 6, "Pola 'lock' defacer: blokir semua PHP kecuali file tertentu",
       r"<FilesMatch\s+[\"'][^\"'\n]*php[^\"'\n]*[\"']>\s*Order\s+allow,\s*deny\s*Deny\s+from\s+all"),
]

USERINI_RULES = [
    _r("INI-PREPEND", 6, "auto_prepend/append_file (kode disisipkan ke SETIAP request PHP)",
       r"^\s*auto_(?:prepend|append)_file\s*=\s*(?!none\b|[\"']{2})\S+"),
    _r("INI-DISABLEFN-EMPTY", 3, "disable_functions dikosongkan", r"^\s*disable_functions\s*=\s*$"),
    _r("INI-URL-INCLUDE", 4, "allow_url_include diaktifkan", r"^\s*allow_url_include\s*=\s*(?:on|1|true)\b"),
]

PHP_TAG_RE = re.compile(r"<\?php\b|<\?=", re.IGNORECASE)
PHP_TAG_STRICT_RE = re.compile(r"<\?php", re.IGNORECASE)
DOUBLE_EXT_EXEC_RE = re.compile(
    r"\.(?:php\d?|phtml|phar|pht)\.(?:jpe?g|png|gif|ico|bmp|webp|svg|txt|pdf|zip|mp4|html?|css|js)$")
DOUBLE_EXT_BAK_RE = re.compile(r"\.(?:php\d?|phtml)\.(?:bak|old|orig|save|swp|tmp|\d+)$")
REVERSE_DOUBLE_RE = re.compile(r"\.(?:jpe?g|png|gif|ico|bmp|txt|pdf|docx?)\.(?:php\d?|phtml|phar)$")
SUSPICIOUS_NAME_RE = re.compile(
    r"^(?:c99|r57|wso|b374k|alfa|indoxploit|lock360|wp-l0gin|sh3ll|0byt3m1n1|marijuana|"
    r"gel4y|priv8|bypass|shell|cmd)[\w.-]*\.(?:php\d?|phtml|phar)$")
UPLOAD_DIR_RE = re.compile(r"/(?:uploads?|images?|img|media|files|tmp|temp|cache)/")
STR_LITERAL_RE = re.compile(r"""(['"])([^'"\s]{%d,})\1""" % ENTROPY_MIN_LEN)


# =============================================================================
# 3. UTILITAS
# =============================================================================
def shannon_entropy(s):
    if not s:
        return 0.0
    n = float(len(s))
    return -sum((c / n) * math.log2(c / n) for c in collections.Counter(s).values())


def max_string_entropy(text, limit=300):
    best = 0.0
    for i, m in enumerate(STR_LITERAL_RE.finditer(text)):
        if i >= limit:
            break
        s = m.group(2)
        if s.lower().startswith("data:"):
            continue
        best = max(best, shannon_entropy(s[:4096]))
    return best


def sanitize(s, limit=160):
    s = "".join(ch if 32 <= ord(ch) < 127 else "." for ch in s)
    return s[:limit]


def make_snippet(text, start, end):
    ls = text.rfind("\n", 0, start) + 1
    s = max(ls, start - 40)
    return sanitize(text[s:min(len(text), end + 80)].replace("\n", " "))


def hit(rid, weight, desc, count=1, lines=None, snippet=""):
    return {"id": rid, "weight": weight, "desc": desc, "count": count,
            "lines": lines or [], "snippet": snippet}


def apply_rules(text, rules, max_lines=3):
    hits = []
    for rule in rules:
        count, lines, snippet = 0, [], ""
        for m in rule.regex.finditer(text):
            count += 1
            if len(lines) < max_lines:
                lines.append(text.count("\n", 0, m.start()) + 1)
                if not snippet:
                    snippet = make_snippet(text, m.start(), m.end())
            if count >= 500:
                break
        if count:
            hits.append(hit(rule.rid, rule.weight, rule.desc, count, lines, snippet))
    return hits


def score_to_level(score):
    for name, thr in LEVEL_THRESHOLD:
        if score >= thr:
            return name
    return "INFO"


def sha256_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except (OSError, IOError):
        return ""


def owner_name(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def iso(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def parse_time_spec(value):
    m = re.match(r"^([+-]?)(\d+(?:\.\d+)?)$", value.strip())
    if not m:
        raise argparse.ArgumentTypeError("format --mtime harus seperti -7, +30, atau 3")
    return (m.group(1), float(m.group(2)))


def time_match(spec, ts, now):
    sign, n = spec
    age = (now - ts) / 86400.0
    if sign == "-":
        return age < n
    if sign == "+":
        return math.floor(age) > n
    return math.floor(age) == n


def write_private(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(path, 0o600)


def classify(lower, ext):
    if lower in CONFIG_NAMES:
        return "config"
    if lower in SHELL_RC:
        return "shellrc"
    if lower in SSH_KEY_NAMES:
        return "sshkeys"
    if ext in PHP_EXT or DOUBLE_EXT_EXEC_RE.search(lower) or DOUBLE_EXT_BAK_RE.search(lower):
        return "php"
    if ext in IMG_EXT:
        return "image"
    if ext in SCRIPT_EXT:
        return "script"
    if ext in TEXT_EXT:
        return "text"
    if lower.startswith("."):
        return "dotfile"
    if ext == "":
        return "noext"
    return None


# =============================================================================
# 4. SCANNER BERKAS
# =============================================================================
class Scanner(object):
    def __init__(self, root, excludes, wl_hashes, wl_globs, mtime_spec, time_field,
                 max_size, verbose, show_progress):
        self.root = root
        self.excludes = [p.strip("/") for p in excludes if p.strip("/")]
        self.wl_hashes = wl_hashes
        self.wl_globs = wl_globs
        self.mtime_spec = mtime_spec
        self.time_field = time_field
        self.max_size = max_size
        self.verbose = verbose
        self.show_progress = show_progress
        self.self_path = os.path.realpath(__file__)
        self.uid = os.getuid()
        self.now = time.time()
        self.stats = collections.Counter()
        self.errors = []

    # ---- traversal ----------------------------------------------------------
    def _err(self, path, exc):
        self.stats["errors"] += 1
        if len(self.errors) < 500:
            self.errors.append({"path": path, "error": str(exc)})

    def _walk_error(self, exc):
        self._err(getattr(exc, "filename", "?"), exc)

    def _dir_excluded(self, rel_dir, name):
        if any(fnmatch.fnmatch(name, p) for p in HARD_EXCLUDE_DIRS):
            return True
        for pat in self.excludes:
            if "/" in pat:
                if fnmatch.fnmatch(rel_dir, pat) or fnmatch.fnmatch(rel_dir, "*/" + pat):
                    return True
            elif fnmatch.fnmatch(name, pat):
                return True
        return False

    def run(self):
        findings = []
        for dirpath, dirnames, filenames in os.walk(self.root, topdown=True,
                                                    onerror=self._walk_error, followlinks=False):
            rel_dir = os.path.relpath(dirpath, self.root)
            keep = []
            for d in dirnames:
                rd = d if rel_dir == "." else rel_dir + "/" + d
                if self._dir_excluded(rd, d):
                    self.stats["dirs_excluded"] += 1
                else:
                    keep.append(d)
            dirnames[:] = keep
            self.stats["dirs_scanned"] += 1
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                rel = fn if rel_dir == "." else rel_dir + "/" + fn
                try:
                    f = self.scan_file(full, rel, fn)
                except Exception as exc:  # jangan biarkan 1 berkas menghentikan scan
                    self._err(full, "unexpected: %r" % exc)
                    f = None
                if f:
                    findings.append(f)
                if self.show_progress and self.stats["files_seen"] % 2000 == 0:
                    sys.stderr.write("\r  ... %d berkas diperiksa, %d temuan"
                                     % (self.stats["files_seen"], len(findings)))
                    sys.stderr.flush()
        if self.show_progress:
            sys.stderr.write("\r" + " " * 60 + "\r")
        return findings

    # ---- per berkas -----------------------------------------------------------
    def _time_ok(self, st):
        if not self.mtime_spec:
            return True
        if self.time_field == "mtime":
            return time_match(self.mtime_spec, st.st_mtime, self.now)
        if self.time_field == "ctime":
            return time_match(self.mtime_spec, st.st_ctime, self.now)
        return (time_match(self.mtime_spec, st.st_mtime, self.now)
                or time_match(self.mtime_spec, st.st_ctime, self.now))

    def _read(self, path):
        try:
            with open(path, "rb") as fh:
                return fh.read(self.max_size)
        except (OSError, IOError) as exc:
            self._err(path, exc)
            return None

    def scan_file(self, path, rel, name):
        self.stats["files_seen"] += 1
        if path == self.self_path or any(fnmatch.fnmatch(name, p) for p in HARD_EXCLUDE_FILES):
            return None
        try:
            st = os.lstat(path)
        except OSError as exc:
            self._err(path, exc)
            return None
        if stat.S_ISLNK(st.st_mode):
            self.stats["symlinks_skipped"] += 1
            return None
        if not stat.S_ISREG(st.st_mode) or st.st_size == 0:
            return None

        lower = name.lower()
        ext = os.path.splitext(lower)[1]
        category = classify(lower, ext)
        if category is None:
            return None
        if self.wl_globs and any(fnmatch.fnmatch(rel, g) or fnmatch.fnmatch(path, g)
                                 for g in self.wl_globs):
            self.stats["whitelisted"] += 1
            return None
        if not self._time_ok(st):
            self.stats["skipped_by_time"] += 1
            return None

        data = self._read(path)
        if data is None:
            return None
        truncated = st.st_size > self.max_size
        self.stats["files_scanned"] += 1
        text = data.decode("latin-1")
        hits = []

        # --- klasifikasi berbasis isi ---
        if category in ("noext", "dotfile"):
            if PHP_TAG_RE.search(text):
                if category == "dotfile":
                    hits.append(hit("FILE-HIDDEN-PHP", 5, "Dotfile (tersembunyi) berisi kode PHP"))
                else:
                    hits.append(hit("FILE-NOEXT-PHP", 4, "Berkas tanpa ekstensi berisi kode PHP"))
                category = "php"
            elif data.startswith(b"#!"):
                if category == "dotfile":
                    hits.append(hit("FILE-HIDDEN-SCRIPT", 3, "Dotfile (tersembunyi) berupa script eksekusi"))
                category = "script"
            else:
                return None
        elif category == "image":
            if not PHP_TAG_STRICT_RE.search(text):
                return None
            hits.append(hit("IMG-PHP-TAG", 10, "Tag <?php di dalam berkas gambar/ikon"))
            magics = IMG_MAGIC.get(ext)
            if magics and not any(data.startswith(mg) for mg in magics):
                hits.append(hit("IMG-MAGIC", 2, "Header biner tidak sesuai ekstensi %s" % ext))
            category = "php"   # FILE-HIDDEN ditambahkan oleh _php_checks bila dotfile
        elif category == "text":
            if PHP_TAG_RE.search(text):
                hits.append(hit("TXT-PHP-TAG", 4, "Kode PHP di berkas berekstensi non-PHP (%s)" % ext))
                category = "php"
            else:
                hits += apply_rules(text, SEO_RULES)

        # --- analisis per kategori ---
        if category == "php":
            hits += self._php_checks(text, rel, lower, ext)
        elif category in ("script", "shellrc"):
            hits += apply_rules(text, SCRIPT_RULES)
        elif category == "config":
            hits += apply_rules(text, HTACCESS_RULES if lower == ".htaccess" else USERINI_RULES + SEO_RULES)
        elif category == "sshkeys":
            hits += self._ssh_keys(text)

        base = sum(h["weight"] for h in hits)
        if base > 0 and category == "php":
            if st.st_uid != self.uid:
                hits.append(hit("META-OWNER", 2, "Pemilik berkas bukan user saat ini (%s)"
                                % owner_name(st.st_uid)))
            if st.st_mode & stat.S_IWOTH:
                hits.append(hit("META-WORLDWRITE", 1, "Berkas world-writable"))
            if st.st_ctime - st.st_mtime > 2 * 86400:
                hits.append(hit("META-TIMESTOMP", 1, "ctime jauh lebih baru dari mtime (indikasi timestomping)"))
        if base > 0 and truncated:
            hits.append(hit("META-TRUNCATED", 0, "Berkas > --max-size, hanya sebagian yang dipindai"))

        score = sum(h["weight"] for h in hits)
        level = score_to_level(score)
        if level == "INFO" and not (self.verbose and score > 0):
            return None

        digest = sha256_file(path)
        if digest and digest in self.wl_hashes:
            self.stats["whitelisted"] += 1
            return None

        hits.sort(key=lambda h: -h["weight"])
        self.stats["findings_" + level] += 1
        return {
            "path": path, "rel": rel, "category": category, "score": score, "level": level,
            "reasons": hits, "size": st.st_size, "sha256": digest,
            "mode": oct(stat.S_IMODE(st.st_mode)), "uid": st.st_uid, "owner": owner_name(st.st_uid),
            "mtime": iso(st.st_mtime), "ctime": iso(st.st_ctime),
            "quarantinable": category in ("php", "script"),
            "is_config": category == "config",
            "action": "", "_ino": st.st_ino, "_mtime_raw": st.st_mtime,
        }

    def _php_checks(self, text, rel, lower, ext):
        hits = apply_rules(text, PHP_RULES) + apply_rules(text, SEO_RULES)
        if DOUBLE_EXT_EXEC_RE.search(lower):
            hits.append(hit("NAME-DOUBLE-EXT", 6, "Ekstensi ganda/samaran (mis. .php.jpg)"))
        elif DOUBLE_EXT_BAK_RE.search(lower):
            hits.append(hit("NAME-PHP-BACKUP", 3, "Salinan/backup PHP (bisa membocorkan source/kredensial)"))
        if REVERSE_DOUBLE_RE.search(lower):
            hits.append(hit("NAME-REVERSE-DOUBLE", 5, "Ekstensi ganda terbalik (mis. .jpg.php)"))
        if ext in PHP_ALT_EXT:
            hits.append(hit("NAME-ALT-EXT", 2, "Ekstensi PHP alternatif (%s)" % ext))
        if lower.startswith("."):
            hits.append(hit("FILE-HIDDEN", 4, "Berkas PHP tersembunyi (dotfile)"))
        if SUSPICIOUS_NAME_RE.match(lower):
            hits.append(hit("NAME-KNOWN-SHELL", 3, "Nama berkas mirip webshell yang dikenal"))
        seg = "/" + rel.lower()
        if UPLOAD_DIR_RE.search(seg):
            hits.append(hit("LOC-UPLOAD-DIR", 4, "Berkas PHP di direktori upload/media/cache"))
        if "/.well-known/" in seg:
            hits.append(hit("LOC-WELL-KNOWN", 5, "Berkas PHP di .well-known (lokasi persembunyian umum)"))
        ent = max_string_entropy(text)
        if ent >= ENTROPY_THRESHOLD:
            hits.append(hit("OBF-ENTROPY", 4, "String dengan entropy tinggi (%.2f bit/char)" % ent))
        longest = max((len(x) for x in text.split("\n")), default=0)
        if longest >= LONG_LINE_THRESHOLD and not lower.endswith(".min.php"):
            hits.append(hit("OBF-LONG-LINE", 2, "Baris sangat panjang (%d karakter)" % longest))
        return hits

    @staticmethod
    def _ssh_keys(text):
        hits, keys = [], []
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            keys.append(parts[-1] if len(parts) >= 3 else "(tanpa komentar)")
            if re.match(r"^[^ ]*command=", line):
                hits.append(hit("SSH-FORCED-CMD", 5, "SSH key dengan opsi command= (cek apakah sah)",
                                snippet=sanitize(line[:120])))
        if keys:
            hits.append(hit("SSH-KEYS-REVIEW", 3, "%d SSH key terpasang - verifikasi pemilik: %s"
                            % (len(keys), ", ".join(sanitize(k, 40) for k in keys[:10]))))
        return hits


# =============================================================================
# 5. PERSISTENSI (crontab, proses, rc files di luar root) - REPORT ONLY
# =============================================================================
class PersistenceChecker(object):
    def __init__(self, root, scanner):
        self.root = root
        self.scanner = scanner
        self.uid = os.getuid()
        self.user = owner_name(self.uid)

    def run(self):
        out = []
        out += self._crontab()
        out += self._processes()
        out += self._home_files()
        return out

    def _mk(self, path, category, hits, evidence=""):
        score = sum(h["weight"] for h in hits)
        level = score_to_level(score)
        if level == "INFO":
            return []
        hits.sort(key=lambda h: -h["weight"])
        return [{"path": path, "rel": path, "category": category, "score": score, "level": level,
                 "reasons": hits, "size": 0, "sha256": "", "mode": "", "uid": self.uid,
                 "owner": self.user, "mtime": "", "ctime": "", "quarantinable": False,
                 "is_config": False, "action": "REVIEW MANUAL", "evidence": evidence}]

    def _crontab(self):
        try:
            p = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            return []
        if p.returncode != 0:
            return []
        hits = apply_rules(p.stdout, SCRIPT_RULES + CRON_RULES)
        return self._mk("crontab://" + self.user, "crontab", hits, p.stdout[:5000])

    def _processes(self):
        out = []
        skip = {os.getpid(), os.getppid()}
        try:
            pids = [int(x) for x in os.listdir("/proc") if x.isdigit()]
        except OSError:
            return out
        for pid in pids:
            if pid in skip:
                continue
            pdir = "/proc/%d" % pid
            try:
                if os.stat(pdir).st_uid != self.uid:
                    continue
                with open(pdir + "/cmdline", "rb") as fh:
                    cmd = fh.read().replace(b"\0", b" ").decode("latin-1").strip()
                try:
                    exe = os.readlink(pdir + "/exe")
                except OSError:
                    exe = ""
            except (OSError, IOError):
                continue
            hits = []
            if exe.endswith(" (deleted)"):
                hits.append(hit("PROC-DELETED-EXE", 6, "Binary proses sudah dihapus dari disk (fileless)"))
            if re.match(r"^(?:/tmp|/var/tmp|/dev/shm)/", exe):
                hits.append(hit("PROC-TMP-EXE", 6, "Proses berjalan dari direktori temp"))
            if re.match(r"^\[?(?:kworker|kthreadd|ksoftirqd|migration|rcu_|watchdog)", cmd):
                hits.append(hit("PROC-KTHREAD-SPOOF", 7, "Nama proses menyamar sebagai kernel thread"))
            hits += apply_rules(cmd, SCRIPT_RULES)
            out += self._mk("process://%d" % pid, "process", hits,
                            "exe=%s | cmd=%s" % (exe, sanitize(cmd, 300)))
        return out

    def _home_files(self):
        out = []
        home = os.path.expanduser("~")
        prefix = self.root.rstrip("/") + "/"
        candidates = [os.path.join(home, n) for n in SHELL_RC]
        candidates += [os.path.join(home, ".ssh", n) for n in SSH_KEY_NAMES]
        for path in candidates:
            if path.startswith(prefix) or not os.path.isfile(path):
                continue
            f = self.scanner.scan_file(path, path, os.path.basename(path))
            if f:
                f["quarantinable"] = False
                f["action"] = "REVIEW MANUAL"
                out.append(f)
        return out


# =============================================================================
# 6. KARANTINA
# =============================================================================
class QuarantineManager(object):
    def __init__(self, root, dry_run):
        self.root = root
        self.dry_run = dry_run
        self.qdir = os.path.join(root, ".quarantine_" + datetime.date.today().strftime("%Y%m%d"))
        self.manifest_path = os.path.join(self.qdir, "manifest.json")
        self.actions = []

    @staticmethod
    def _qname(f):
        base = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(f["path"]))[:80]
        return "%s_%s.quarantined" % ((f["sha256"] or "nohash")[:12], base)

    def _record(self, f, status, dest="", note=""):
        entry = {"timestamp": iso(time.time()), "status": status, "original_path": f["path"],
                 "quarantined_as": dest, "sha256": f["sha256"], "size": f["size"],
                 "mode": f["mode"], "owner": f["owner"], "mtime": f["mtime"], "ctime": f["ctime"],
                 "score": f["score"], "level": f["level"],
                 "rules": [h["id"] for h in f["reasons"]], "note": note}
        if dest:
            entry["restore_cmd"] = "chmod 700 '%s' && mv '%s' '%s' && chmod 644 '%s'" % (
                self.qdir, dest, f["path"], f["path"])
        self.actions.append(entry)
        f["action"] = status + (" -> " + dest if dest else "") + (" (" + note + ")" if note else "")

    def execute(self, candidates):
        if not candidates:
            return self.actions
        if self.dry_run:
            for f in candidates:
                self._record(f, "DRY-RUN", os.path.join(self.qdir, self._qname(f)),
                             "tidak ada perubahan dilakukan")
            return self.actions
        try:
            if os.path.isdir(self.qdir):
                os.chmod(self.qdir, 0o700)
            else:
                os.makedirs(self.qdir, 0o700)
            os.chmod(self.qdir, 0o700)
        except OSError as exc:
            for f in candidates:
                self._record(f, "FAILED", note="tidak bisa menyiapkan folder karantina: %s" % exc)
            return self.actions

        manifest = []
        if os.path.exists(self.manifest_path):
            try:
                os.chmod(self.manifest_path, 0o600)
                with open(self.manifest_path, "r", encoding="utf-8") as fh:
                    manifest = json.load(fh)
            except (OSError, IOError, ValueError):
                manifest = []

        for f in candidates:
            self._move_one(f)
        manifest.extend(self.actions)
        try:
            write_private(self.manifest_path, json.dumps(manifest, indent=2, ensure_ascii=False))
            os.chmod(self.manifest_path, 0o400)
        except OSError as exc:
            sys.stderr.write("[!] Gagal menulis manifest karantina: %s\n" % exc)
        try:
            os.chmod(self.qdir, 0o000)
        except OSError as exc:
            sys.stderr.write("[!] Gagal chmod 000 folder karantina: %s\n" % exc)
        return self.actions

    def _move_one(self, f):
        src = f["path"]
        try:
            st = os.lstat(src)
        except OSError as exc:
            return self._record(f, "FAILED", note="berkas hilang: %s" % exc)
        if not stat.S_ISREG(st.st_mode):
            return self._record(f, "FAILED", note="bukan lagi regular file (kemungkinan TOCTOU)")
        if st.st_ino != f["_ino"] or st.st_size != f["size"] or st.st_mtime != f["_mtime_raw"]:
            return self._record(f, "SKIPPED", note="berkas berubah sejak dipindai, jalankan ulang scan")

        dest = os.path.join(self.qdir, self._qname(f))
        n = 1
        while os.path.exists(dest):
            dest = os.path.join(self.qdir, "%s.%d" % (self._qname(f), n))
            n += 1
        try:
            os.rename(src, dest)
        except OSError as exc:
            if exc.errno == errno.EXDEV:
                try:
                    shutil.copy2(src, dest)
                    os.unlink(src)
                except (OSError, IOError) as exc2:
                    return self._record(f, "FAILED", note="copy lintas filesystem gagal: %s" % exc2)
            else:
                # Fallback: netralisasi di tempat (chmod 000) bila tidak bisa dipindah
                try:
                    os.chmod(src, 0)
                    return self._record(f, "NEUTRALIZED_IN_PLACE",
                                        note="gagal dipindah (%s), berkas di-chmod 000 di lokasi asal" % exc)
                except OSError as exc2:
                    return self._record(f, "FAILED",
                                        note="tidak bisa dipindah/chmod (%s); eskalasi ke admin/root" % exc2)
        note = ""
        try:
            os.chmod(dest, 0)
        except OSError as exc:
            note = "chmod 000 gagal (%s); tetap terisolasi karena folder karantina 000" % exc
        return self._record(f, "QUARANTINED", dest, note)


# =============================================================================
# 7. REPORTER (terminal + log teks + JSON)
# =============================================================================
class Reporter(object):
    COLORS = {"HIGH": "\033[1;31m", "MEDIUM": "\033[1;33m", "LOW": "\033[36m",
              "INFO": "\033[37m", "DIM": "\033[2m", "BOLD": "\033[1m", "OK": "\033[1;32m"}
    RESET = "\033[0m"

    def __init__(self, color, quiet, verbose):
        self.color = color
        self.quiet = quiet
        self.verbose = verbose

    def c(self, text, key):
        return "%s%s%s" % (self.COLORS[key], text, self.RESET) if self.color else text

    def out(self, msg=""):
        if not self.quiet:
            print(msg)

    def banner(self, meta):
        self.out(self.c("=" * 78, "DIM"))
        self.out(self.c(" wshunter %s  |  Webshell & Backdoor Hunter (non-root)" % VERSION, "BOLD"))
        self.out(self.c("=" * 78, "DIM"))
        for k in ("host", "user", "root", "mode", "time_filter", "excludes"):
            self.out("  %-12s: %s" % (k, meta[k]))
        self.out("")

    def findings(self, findings, min_rank):
        shown = [f for f in findings if LEVEL_RANK[f["level"]] >= min_rank]
        if not shown:
            self.out(self.c("  Tidak ada temuan pada level yang dipilih.", "OK"))
            return
        for f in shown:
            tag = self.c("[%-6s]" % f["level"], f["level"])
            self.out("%s skor %3d  %s" % (tag, f["score"], f["path"]))
            limit = None if self.verbose else 5
            for h in f["reasons"][:limit]:
                loc = (" (L%s)" % ",".join(str(x) for x in h["lines"])) if h["lines"] else ""
                self.out("           - %s%s %s" % (h["desc"], loc, self.c("[%s]" % h["id"], "DIM")))
                if self.verbose and h["snippet"]:
                    self.out(self.c("             > " + h["snippet"], "DIM"))
            if limit and len(f["reasons"]) > limit:
                self.out(self.c("           ... +%d alasan lain (lihat log)" % (len(f["reasons"]) - limit), "DIM"))
            if f.get("action"):
                self.out("           aksi: " + f["action"])

    def summary(self, stats, findings, log_path, json_path, elapsed):
        cnt = collections.Counter(f["level"] for f in findings)
        self.out("")
        self.out(self.c("-" * 78, "DIM"))
        self.out("  Berkas diperiksa : %d (dianalisis: %d) | direktori: %d | dikecualikan: %d dir"
                 % (stats["files_seen"], stats["files_scanned"], stats["dirs_scanned"], stats["dirs_excluded"]))
        self.out("  Temuan           : %s  %s  %s" % (
            self.c("HIGH=%d" % cnt["HIGH"], "HIGH"), self.c("MEDIUM=%d" % cnt["MEDIUM"], "MEDIUM"),
            self.c("LOW=%d" % cnt["LOW"], "LOW")))
        self.out("  Error akses      : %d | symlink dilewati: %d | whitelist: %d | durasi: %.1fs"
                 % (stats["errors"], stats["symlinks_skipped"], stats["whitelisted"], elapsed))
        self.out("  Log teks         : %s" % log_path)
        self.out("  Log JSON         : %s" % json_path)
        self.out(self.c("-" * 78, "DIM"))

    @staticmethod
    def write_logs(log_path, json_path, meta, stats, findings, actions, errors):
        clean = [{k: v for k, v in f.items() if not k.startswith("_")} for f in findings]
        payload = {"meta": meta, "stats": dict(stats), "findings": clean,
                   "actions": actions, "errors": errors}
        write_private(json_path, json.dumps(payload, indent=2, ensure_ascii=False))

        L = []
        L.append("=" * 78)
        L.append("WSHUNTER %s - LAPORAN PEMINDAIAN WEBSHELL/BACKDOOR" % VERSION)
        L.append("=" * 78)
        for k, v in meta.items():
            L.append("%-14s: %s" % (k, v))
        L.append("")
        L.append("STATISTIK: " + ", ".join("%s=%s" % kv for kv in sorted(stats.items())))
        L.append("")
        L.append("-" * 78)
        L.append("TEMUAN (%d)" % len(clean))
        L.append("-" * 78)
        for i, f in enumerate(clean, 1):
            L.append("")
            L.append("#%d [%s] skor=%d kategori=%s" % (i, f["level"], f["score"], f["category"]))
            L.append("  path   : %s" % f["path"])
            if f["sha256"]:
                L.append("  sha256 : %s" % f["sha256"])
                L.append("  meta   : size=%s mode=%s owner=%s mtime=%s ctime=%s"
                         % (f["size"], f["mode"], f["owner"], f["mtime"], f["ctime"]))
            for h in f["reasons"]:
                L.append("  - [%s] (+%d, %dx) %s%s" % (
                    h["id"], h["weight"], h["count"], h["desc"],
                    (" @L" + ",".join(str(x) for x in h["lines"])) if h["lines"] else ""))
                if h["snippet"]:
                    L.append("      > %s" % h["snippet"])
            if f.get("evidence"):
                L.append("  evidence:")
                for ln in f["evidence"].splitlines()[:50]:
                    L.append("      | " + sanitize(ln, 300))
            if f.get("action"):
                L.append("  aksi   : %s" % f["action"])
        L.append("")
        L.append("-" * 78)
        L.append("AKSI KARANTINA (%d)" % len(actions))
        L.append("-" * 78)
        for a in actions:
            L.append("[%s] %s -> %s %s" % (a["status"], a["original_path"],
                                           a["quarantined_as"] or "-", a["note"]))
            if a.get("restore_cmd") and a["status"] == "QUARANTINED":
                L.append("    restore: " + a["restore_cmd"])
        if errors:
            L.append("")
            L.append("-" * 78)
            L.append("ERROR AKSES (%d, maks 500 dicatat)" % len(errors))
            L.append("-" * 78)
            for e in errors:
                L.append("%s : %s" % (e["path"], e["error"]))
        write_private(log_path, "\n".join(L) + "\n")


# =============================================================================
# 8. MAIN
# =============================================================================
def load_whitelist(path):
    hashes, globs = set(), []
    if not path:
        return hashes, globs
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if line.lower().startswith("sha256:"):
                hashes.add(line[7:].strip().lower())
            elif re.fullmatch(r"[0-9a-fA-F]{64}", line):
                hashes.add(line.lower())
            else:
                globs.append(line)
    return hashes, globs


def build_parser():
    epilog = """contoh:
  %(prog)s                                  # scan biasa di /home/yimand5
  %(prog)s --dry-run --mtime -7             # rencana karantina, file berubah 7 hari terakhir
  %(prog)s --quarantine                     # karantina temuan HIGH (dengan konfirmasi)
  %(prog)s --quarantine --quarantine-level MEDIUM -y
  %(prog)s -e 'public_html/wp-content/cache' -w whitelist.txt --persistence -v
"""
    p = argparse.ArgumentParser(prog="wshunter.py", epilog=epilog,
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                description="Deteksi & karantina webshell/backdoor tanpa root.")
    p.add_argument("-r", "--root", default=DEFAULT_ROOT, help="direktori target (default: %(default)s)")
    p.add_argument("-m", "--mode", choices=["scan", "dry-run", "quarantine"], default="scan")
    p.add_argument("--dry-run", dest="mode", action="store_const", const="dry-run", help="alias --mode dry-run")
    p.add_argument("--quarantine", dest="mode", action="store_const", const="quarantine",
                   help="alias --mode quarantine")
    p.add_argument("--mtime", type=parse_time_spec, metavar="[+-]N",
                   help="filter waktu ala find: -7 (<7 hari), +30 (>30 hari), 3 (tepat 3 hari)")
    p.add_argument("--time-field", choices=["mtime", "ctime", "both"], default="mtime",
                   help="atribut waktu untuk --mtime; 'both' menangkap timestomping (default: mtime)")
    p.add_argument("-e", "--exclude", action="append", default=[], metavar="PATTERN",
                   help="tambahan pengecualian direktori (bisa diulang)")
    p.add_argument("--no-default-excludes", action="store_true",
                   help="jangan kecualikan vendor/, node_modules/, dll (scan menyeluruh)")
    p.add_argument("-w", "--whitelist", metavar="FILE",
                   help="berkas whitelist: baris 'sha256:<hash>' atau glob path")
    p.add_argument("--min-level", choices=["LOW", "MEDIUM", "HIGH"], default="LOW",
                   help="level minimum yang ditampilkan di terminal")
    p.add_argument("--quarantine-level", choices=["LOW", "MEDIUM", "HIGH"], default="HIGH",
                   help="level minimum yang dikarantina (default: HIGH)")
    p.add_argument("--quarantine-config", action="store_true",
                   help="ikut karantina .htaccess/.user.ini (default: hanya dilaporkan)")
    p.add_argument("--persistence", action="store_true",
                   help="cek juga crontab, proses milik user, dan rc files (report only)")
    p.add_argument("--max-size", type=int, default=8, metavar="MB", help="batas baca per berkas (default 8)")
    p.add_argument("--log-dir", default=None, help="lokasi log (default: sama dengan --root)")
    p.add_argument("-y", "--yes", action="store_true", help="lewati konfirmasi karantina")
    p.add_argument("-q", "--quiet", action="store_true", help="tanpa output terminal (cocok untuk cron)")
    p.add_argument("-v", "--verbose", action="store_true", help="tampilkan semua alasan + snippet")
    p.add_argument("--no-color", action="store_true")
    p.add_argument("--allow-root", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--version", action="version", version="%(prog)s " + VERSION)
    return p


def main():
    args = build_parser().parse_args()
    start = time.time()

    if os.geteuid() == 0 and not args.allow_root:
        sys.stderr.write("[!] Script ini dirancang untuk user non-root. Jalankan sebagai user pemilik "
                         "direktori (mis. yimand5), bukan root/sudo.\n")
        return 3

    root = os.path.realpath(args.root)
    if not os.path.isdir(root):
        sys.stderr.write("[!] Direktori root tidak ditemukan: %s\n" % root)
        return 3
    log_dir = os.path.realpath(args.log_dir) if args.log_dir else root
    if not os.access(log_dir, os.W_OK):
        sys.stderr.write("[!] Tidak bisa menulis log ke %s\n" % log_dir)
        return 3
    if args.mode == "quarantine" and not os.access(root, os.W_OK):
        sys.stderr.write("[!] Tidak punya izin tulis di %s untuk membuat folder karantina\n" % root)
        return 3

    try:
        wl_hashes, wl_globs = load_whitelist(args.whitelist)
    except (OSError, IOError) as exc:
        sys.stderr.write("[!] Gagal membaca whitelist: %s\n" % exc)
        return 3

    try:
        os.nice(10)  # ramah terhadap server produksi; diizinkan untuk non-root
    except (OSError, AttributeError):
        pass

    excludes = ([] if args.no_default_excludes else list(DEFAULT_EXCLUDES)) + args.exclude
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = os.path.join(log_dir, "webshell_scan_%s.log" % ts)
    json_path = os.path.join(log_dir, "webshell_scan_%s.json" % ts)
    color = sys.stdout.isatty() and not args.no_color

    meta = collections.OrderedDict([
        ("version", VERSION), ("host", socket.gethostname()),
        ("user", "%s (uid %d)" % (owner_name(os.getuid()), os.getuid())),
        ("root", root), ("mode", args.mode),
        ("time_filter", ("%s%s hari (%s)" % (args.mtime[0], args.mtime[1], args.time_field))
         if args.mtime else "tidak ada"),
        ("excludes", ", ".join(excludes) or "-"),
        ("quarantine_level", args.quarantine_level),
        ("started", iso(start)), ("argv", " ".join(sys.argv)),
    ])

    rep = Reporter(color, args.quiet, args.verbose)
    rep.banner(meta)

    scanner = Scanner(root, excludes, wl_hashes, wl_globs, args.mtime, args.time_field,
                      args.max_size * 1024 * 1024, args.verbose,
                      show_progress=sys.stderr.isatty() and not args.quiet)
    findings = scanner.run()
    if args.persistence:
        findings += PersistenceChecker(root, scanner).run()
    findings.sort(key=lambda f: (-LEVEL_RANK[f["level"]], -f["score"], f["path"]))

    actions = []
    if args.mode in ("dry-run", "quarantine"):
        q_rank = LEVEL_RANK[args.quarantine_level]
        candidates = [f for f in findings if LEVEL_RANK[f["level"]] >= q_rank
                      and (f["quarantinable"] or (args.quarantine_config and f["is_config"]))]
        for f in findings:
            if f not in candidates and not f.get("action"):
                f["action"] = "REVIEW MANUAL" if (f["is_config"] or not f["quarantinable"]) else ""
        proceed = True
        if args.mode == "quarantine" and candidates and not args.yes:
            if not sys.stdin.isatty():
                sys.stderr.write("[!] Mode non-interaktif: gunakan -y untuk konfirmasi karantina.\n")
                proceed = False
            else:
                rep.out(rep.c("Akan mengkarantina %d berkas (level >= %s):" % (len(candidates), args.quarantine_level), "BOLD"))
                for f in candidates:
                    rep.out("  - [%s] %s" % (f["level"], f["path"]))
                ans = input("Lanjutkan karantina? [y/N]: ").strip().lower()
                proceed = ans in ("y", "ya", "yes")
        if proceed:
            qm = QuarantineManager(root, dry_run=(args.mode == "dry-run"))
            actions = qm.execute(candidates)
            meta["quarantine_dir"] = qm.qdir
        else:
            for f in candidates:
                f["action"] = "DIBATALKAN oleh user"

    rep.findings(findings, LEVEL_RANK[args.min_level])
    elapsed = time.time() - start
    meta["finished"] = iso(time.time())
    meta["elapsed_sec"] = round(elapsed, 2)
    try:
        Reporter.write_logs(log_path, json_path, meta, scanner.stats, findings, actions, scanner.errors)
    except (OSError, IOError) as exc:
        sys.stderr.write("[!] Gagal menulis log: %s\n" % exc)
    rep.summary(scanner.stats, findings, log_path, json_path, elapsed)

    if args.mode == "quarantine" and actions:
        done = sum(1 for a in actions if a["status"] == "QUARANTINED")
        rep.out(rep.c("  Karantina: %d/%d berhasil -> %s (chmod 000)" % (done, len(actions), meta["quarantine_dir"]), "BOLD"))

    levels = {f["level"] for f in findings}
    if "HIGH" in levels:
        return 2
    return 1 if levels & {"MEDIUM", "LOW"} else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.stderr.write("\n[!] Dibatalkan oleh user.\n")
        sys.exit(130)
