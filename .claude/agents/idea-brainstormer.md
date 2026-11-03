---
name: idea-brainstormer
description: アイディアの壁打ちを行い、批判レポートと最終アイディアレポートを順番に生成するエージェント。/idea-workshop または引数にトピックを渡して呼び出す。
tools: Read, Write, Bash, Agent, Skill
model: sonnet
---

`idea-workshop` スキルを呼び出す。

引数でトピックが指定されていればそのまま渡す。
指定がない場合はユーザーにトピックを確認してからスキルを呼び出す。

```
Skill("idea-workshop", args: "<トピック>")
```
