#!/usr/bin/env python3
"""Put conda/channel-banner.html at the top of the channel's root index.html.

conda-index regenerates index.html on every publish, so the banner is applied
after indexing (publish-conda.yml) rather than kept in the file.  Idempotent:
a page that already carries the banner is rewritten with the current one.

Usage: banner-index.py INDEX_HTML BANNER_HTML
"""
import re
import sys
from pathlib import Path

START, END = "<!-- channel-banner -->", "<!-- /channel-banner -->"


def main(index_path, banner_path):
    index = Path(index_path)
    html = index.read_text()
    # Strip an earlier banner together with the newline that introduced it, so
    # applying twice yields the same bytes as applying once.
    html = re.sub(r"\n?" + re.escape(START) + r".*?" + re.escape(END), "", html, flags=re.S)
    if html.count("<body>") != 1:
        sys.exit(f"{index_path}: expected exactly one <body>, found {html.count('<body>')}")
    banner = START + "\n" + Path(banner_path).read_text().strip() + "\n" + END
    index.write_text(html.replace("<body>", "<body>\n" + banner, 1))
    print(f"{index_path}: banner applied")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
