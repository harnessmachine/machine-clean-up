# machine-clean-up

`machine-clean-up` освобождает оперативку, которую на маке съедают агенты.

каждая сессия Codex, Claude Code или OpenCode поднимает свои MCP-серверы: Playwright, Chrome DevTools, Context7 и другие. они живут в процессах `node`, `npm`, `uv` и `bun`. закрыли окно, а процессы остались. висят сиротами, плодятся дублями, и через десяток сессий мак уходит в swap.

`pkill node` здесь не помогает: вместе с мусором он убьёт живую работу. скилл закрывает только то, что точно мусор, и не трогает активные сессии.

## что закрывает сразу

- **сирот** — MCP-процессы, у которых родительский агент уже закрыт;
- **дубли** — одну и ту же команду MCP, запущенную несколько раз под одним агентом. самая новая копия остаётся.

процессы моложе 10 минут не трогаются. закрытие мягкое: сначала `SIGTERM`, через 5 секунд `SIGKILL` только тем, кто не закрылся. перед каждым сигналом скрипт заново проверяет родителя, группу, возраст и команду.

## что не трогает никогда

- сами приложения и сессии Codex, Claude Code, OpenCode, ChatGPT и Claude;
- агента, который запустил скилл, и всю его цепочку родителей;
- Cursor целиком;
- `node_repl` и Computer Use;
- MCP с относительными путями: одинаковый текст команды там может означать разные серверы;
- MCP других живых сессий, даже если там запущен тот же сервер.

если скилл видит что-то ещё тяжёлое за пределами этого контракта, он показывает это и спрашивает, закрывать ли.

## установка

Codex:

```bash
git clone --depth 1 \
  https://github.com/harnessmachine/machine-clean-up.git \
  "$HOME/.codex/skills/machine-clean-up"
```

Claude Code:

```bash
git clone --depth 1 \
  https://github.com/harnessmachine/machine-clean-up.git \
  "$HOME/.claude/skills/machine-clean-up"
```

после установки начните новый диалог, чтобы скилл появился в списке.

## как пользоваться

когда комп начал тупить, напишите агенту:

```text
$machine-clean-up
```

в Claude Code — `/machine-clean-up`.

агент закроет сирот и дубли и коротко отчитается: сколько процессов закрыто, сколько памяти освободилось, что осталось.

посмотреть план, ничего не закрывая:

```bash
~/.codex/skills/machine-clean-up/scripts/machine-clean-up.sh --auto --dry-run
```

## автозапуск

скрипт можно запускать без агента, например раз в час через launchd. сохраните файл как `~/Library/LaunchAgents/local.machine-clean-up.plist`, поправив путь к скрипту под свою установку:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.machine-clean-up</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/YOU/.codex/skills/machine-clean-up/scripts/machine-clean-up.sh</string>
    <string>--auto</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>/tmp/machine-clean-up.log</string>
  <key>StandardErrorPath</key><string>/tmp/machine-clean-up.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/local.machine-clean-up.plist
```

## требования

- macOS;
- `bash`, `ps`, `awk`, `vm_stat` — всё уже есть в системе.

## лицензия

MIT
