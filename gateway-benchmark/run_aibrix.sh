#!/usr/bin/env bash
# aibrix 网关快捷入口，等价于 ./run.sh --gateway aibrix "$@"
exec "$(dirname "${BASH_SOURCE[0]}")/run.sh" --gateway aibrix "$@"
