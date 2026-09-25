`debate-cli-console.txt` preserves the hook/exec framing of the recorded critic
round from 2026-09-18 (issue #67). Commands, paths, tool results, and answer
content have been replaced with fixture sentinels. No original memory content
is included. The trailing usage footer is synthetic coverage.

`model-definition-cases.json` holds named model definitions for
`runtime/tests/test_registry_differential.py` (#130). `expect` is the field
both `registry.sh` and `registry.py` must reject the definition on, or `null`
for a valid one. `argv`, where given, is the argv both must run with a final
file (`final`) and without one (`no_final`); `<prompt>` and `<final>` stand for
the test's prompt and final path. `no_final` is left out when `final_args` is
non-empty: the runtime always captures, so it has no such run to compare.
