#!/bin/sh
# Rebuild site/ (the folder to upload) from index.html and assets/.
cd "$(dirname "$0")/.." || exit 1
{ printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
  sed -n '1,/<\/style>/p' index.html
  printf '</head>\n<body>\n'
  sed -n '/<\/style>/,$p' index.html | tail -n +2
  printf '</body>\n</html>\n'; } > site/index.html
sed -i 's|^\* { box-sizing: border-box; }|* { box-sizing: border-box; }\nbody { margin: 0; }\nimg { max-width: 100%; }\n[hidden] { display: none !important; }|' site/index.html
mkdir -p site/assets/gallery && cp assets/*.webp site/assets/ && cp assets/gallery/*.webp site/assets/gallery/
# browser tab and home-screen icons; /favicon.ico is where browsers look by default
mkdir -p site/assets/icons && cp assets/icons/* site/assets/icons/ && cp assets/icons/favicon.ico site/favicon.ico
# Supabase client (login + registrations on your own host); not used in the claude.ai preview
mkdir -p site/assets/vendor && cp assets/vendor/* site/assets/vendor/
python3 - <<'PY'
p = "site/index.html"; s = open(p).read()
tag = '<script src="assets/vendor/supabase.js"></script>\n<script src="assets/vendor/qrcode.js"></script>\n'
if tag not in s:
    i = s.index("<script>\n(() => {")
    s = s[:i] + tag + s[i:]
open(p, "w").write(s)
PY
# yoursite.com/admin opens the team sign-in page
mkdir -p site/admin && cat > site/admin/index.html <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shift Nation Admin</title><meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url=../index.html#admin">
<style>body{margin:0;background:#07080c;color:#eef0f5;font:16px system-ui,sans-serif;display:grid;place-items:center;min-height:100vh}a{color:#f5b41f}</style>
</head><body><p><a href="../index.html#admin">Go to the team sign-in page</a></p></body></html>
HTML
