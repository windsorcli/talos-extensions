# Extensions layout

| Directory | Purpose |
| --- | --- |
| [`_template/`](_template/) | Copy to start a new extension (not built) |
| [`hyper-v-linux-guest/`](hyper-v-linux-guest/) | Hyper-V KVP/VSS integration services for Talos guests |
| [`../contrib/`](../contrib/) | Other community-tier extensions (e.g. smoke tests) |

Add new targets in [`.kres.yaml`](../.kres.yaml) and regenerate the Makefile with `make rekres`.
