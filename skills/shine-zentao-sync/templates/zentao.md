---
description: 禅道工时/统计 CLI（task / log / stats / query / sync / setup）
argument-hint: <子命令> [参数]
---

执行下面的 bash 命令，把 stdout/stderr **原样回显**给用户（仅当报错时才解释原因，正常输出不要加额外说明）。zentao 脚本不在 PATH，这里用全路径调用，**无需任何环境变量**：

```bash
Z=$(for d in "$HOME/.claude/skills/shine-zentao-sync" \
          ".claude/skills/shine-zentao-sync" \
          ".agents/skills/shine-zentao-sync" \
          "/workspace/shine-zentao-sync/skills/shine-zentao-sync"; do
  [ -x "$d/scripts/zentao" ] && { echo "$d/scripts/zentao"; break; }
done)
if [ -z "$Z" ]; then
  echo "未找到 zentao 脚本，请确认 shine-zentao-sync skill 已安装" >&2
  exit 1
fi
bash "$Z" $ARGUMENTS
```

用户传入的参数：$ARGUMENTS（为空时 zentao 会打印用法）。
