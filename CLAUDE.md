# CLAUDE.md

このリポジトリのルールは `AGENTS.md` にあり、Codex などと共有している。Claude Code は次の行で読み込む。

@AGENTS.md

## Claude Code だけの注意

- プロジェクトのスキル: `.claude/skills` は `.agents/skills` へのシンボリックリンク。スキルはそちらに 1 回足せば両方が読む。
- このファイルには Claude Code だけに要る注意を書く。それ以外は `AGENTS.md` へ。
