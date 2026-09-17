"""Utilities for selecting which pages of a scan should be analyzed."""


def parse_page_spec(spec, total_pages):
    """Expand all/odd/even or a comma-separated page/range specification."""
    normalized = spec.strip().lower()
    if normalized == "all":
        return set(range(1, total_pages + 1))
    if normalized == "odd":
        return set(range(1, total_pages + 1, 2))
    if normalized == "even":
        return set(range(2, total_pages + 1, 2))
    if not normalized:
        return set()

    selected = set()
    for token in normalized.split(","):
        token = token.strip()
        if not token:
            raise ValueError("empty page entry")
        if "-" in token:
            parts = token.split("-")
            if len(parts) != 2 or not all(part.strip().isdigit() for part in parts):
                raise ValueError(f"invalid page range: {token!r}")
            start, end = (int(part.strip()) for part in parts)
            if start > end:
                raise ValueError(f"page range starts after it ends: {token!r}")
            selected.update(range(start, end + 1))
        elif token.isdigit():
            selected.add(int(token))
        else:
            raise ValueError(f"invalid page entry: {token!r}")

    outside = sorted(page for page in selected if page < 1 or page > total_pages)
    if outside:
        raise ValueError(
            f"page(s) outside this PDF's 1-{total_pages} range: {outside}"
        )
    return selected
