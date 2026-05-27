Before making any code, behavior, or architecture changes related to camera startup, restricted mode, live-slot assignment, battery-camera refresh, snapshot trust, or HomeKit connection handling:

1. Read `LOGIC.md` first.
2. Treat `LOGIC.md` as the source of truth for the intended behavior.
3. Keep the implementation consistent with `LOGIC.md`.
4. If the existing code disagrees with `LOGIC.md`, update the code to match `LOGIC.md` unless the user explicitly says otherwise.
5. If a requested change would alter the behavior described in `LOGIC.md`, update `LOGIC.md` in the same change so the documented logic stays accurate.
6. Do not introduce hidden behavior that contradicts `LOGIC.md`.
7. When finished, briefly summarize whether `LOGIC.md` was followed, changed, or left unchanged.

Always preserve this rule: `LOGIC.md` must remain accurate, current, and authoritative for this feature.