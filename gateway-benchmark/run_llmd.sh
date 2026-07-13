#!/usr/bin/env bash
# llm-d 网关快捷入口，等价于 ./run.sh --gateway llmd "$@"
exec "$(dirname "${BASH_SOURCE[0]}")/run.sh" --gateway llmd "$@"
