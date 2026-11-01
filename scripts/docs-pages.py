"""Patch the HTML pages docs-builder wrote, for scripts/docs-finish.sh.

    python3 -I scripts/docs-pages.py <output dir> <docs dir> <path prefix> <logo path, relative to docs>

- Links to the site root load it whole (hx-boost="false"). The root is the landing page, which has none of the docs
  shell, so htmx's boosted swap of #main-container would find nothing to swap and leave the reader on the docs.
- The header shows the docset's branding.icon. The design-system header has a slot for it (site-header__logo) that
  docs-builder never fills.
- Screenshots get width and height at half their pixel size. Every image under images/shots is rendered at 2x
  (mise run shots), and CSS cannot read an image's pixel size, so without this they show at twice their size.
"""

import re
import struct
import sys
from pathlib import Path

out, docs, prefix, logo = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3].strip("/"), sys.argv[4].strip("/")
root = f"/{prefix}/" if prefix else "/"
if not (docs / logo).is_file():
    print(f"docs: the logo {docs / logo} does not exist", file=sys.stderr)
    sys.exit(1)
logo_img = f'<img class="site-header__logo" src="{root}{logo}" alt="" width="28" height="28">'
brand = re.compile(r'(<a\b[^>]*\bclass="site-header__brand"[^>]*>)(?!\s*<img\b)')

root_link = re.compile(r'<a\b(?![^>]*\bhx-boost=)([^>]*\bhref="' + re.escape(root) + r'")')
shot = re.compile(r'<img\b(?![^>]*\bwidth=)([^>]*\bsrc="[^"]*/images/shots/([^"?#]+\.png)")')


def png_size(path: Path):
    with path.open("rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])


sizes: dict[str, tuple[int, int] | None] = {}


def sized(match: re.Match) -> str:
    rel = match.group(2)
    if rel not in sizes:
        file = docs / "images" / "shots" / rel
        sizes[rel] = png_size(file) if file.is_file() else None
    size = sizes[rel]
    if size is None:
        return match.group(0)
    w, h = size
    return f'<img width="{w // 2}" height="{h // 2}"{match.group(1)}'


any_root = re.compile(r'<a\b[^>]*\bhref="' + re.escape(root) + r'"')
pages = links = shots = logos = 0
seen_root = seen_brand = False
for page in out.rglob("*.html"):
    html = page.read_text(encoding="utf-8")
    seen_root = seen_root or bool(any_root.search(html))
    seen_brand = seen_brand or 'class="site-header__brand"' in html
    new, n_links = root_link.subn(r'<a hx-boost="false"\1', html)
    new, n_logos = brand.subn(lambda m: m.group(1) + logo_img, new)
    new, n_shots = shot.subn(sized, new)
    if new != html:
        page.write_text(new, encoding="utf-8")
        pages += 1
        links += n_links
        shots += n_shots
        logos += n_logos

missing = sorted(k for k, v in sizes.items() if v is None)
if missing:
    print("docs: screenshots referenced but not found: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
if not seen_root:
    print(f'docs: no links to "{root}" found; the docs-builder markup changed', file=sys.stderr)
    sys.exit(1)
if not seen_brand:
    print("docs: no site-header__brand found for the logo; the docs-builder markup changed", file=sys.stderr)
    sys.exit(1)
print(f"docs: {pages} pages patched ({links} root links unboosted, {logos} logos, {shots} screenshots sized)")
