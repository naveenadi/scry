# Config merge: deep merge except named maps

Global and project config are deep-merged, project overriding global, for `general`, `query_editor`, and `keybindings` — key-by-key recursively.

`connections` is a named map, not deep-merged. Rules:
- Keys present in only one layer (global-only or project-only) are included as-is.
- Keys present in both layers: the project entry replaces the global entry wholesale — no field-level merging. A project that overrides `connections.local_dev` must define all fields it needs; it does not inherit fields from the global version.

This prevents Frankenstein connections where the project overrides `host` but silently inherits `password` from global. Global config is the right place for shared credentials; project config for environment-specific overrides.
