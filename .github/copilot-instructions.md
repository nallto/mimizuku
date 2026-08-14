@../AGENTS.md

# GitHub Copilot用アダプター

GitHub Copilot CLIは上のimportから`AGENTS.md`を全文読み、その指示に従う。importを解釈しないXcode、IDE Chat、cloud agent、code reviewでは、作業開始前にリポジトリ直下の`AGENTS.md`を全文読む。

タスクに対応する`.agents/skills/*/SKILL.md`を全文読み、そこから参照される必要なファイルにも従う。規約や手順の正典は`AGENTS.md`と`.agents/skills/`であり、このファイルへ複製しない。
