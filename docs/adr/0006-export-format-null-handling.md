# Export format: RFC 4180 CSV, NULL handling per format

CSV export follows RFC 4180: values containing commas, newlines, or double quotes are wrapped in double quotes; embedded double quotes are escaped by doubling (`"` → `""`).

NULL handling differs by format:
- **CSV**: NULL renders as empty string. This matches how NULL almost universally round-trips in CSV consumers — there's no standard CSV null type, and an empty field is the conventional representation.
- **JSON**: NULL renders as `null`. This is the type-correct representation; JSON has a native null type and consumers parse it correctly.

Both exports are consistent: the CSV consumer sees an empty cell, the JSON consumer sees a typed null. Neither silently substitutes a string like `"NULL"` or `"null"`.
