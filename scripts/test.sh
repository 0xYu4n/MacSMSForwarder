#!/usr/bin/env bash
# 运行单元测试
# 仅安装「命令行工具」（无 Xcode）时，Swift Testing 框架不在默认搜索路径，需要手动指定
set -euo pipefail
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$FW/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
else
  swift test "$@"
fi
