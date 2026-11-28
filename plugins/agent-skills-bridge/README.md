# agent-skills-bridge

A Claude Code plugin with two skills. One installs the
[agent-skills-bridge](https://github.com/dawidaleksanderwalczak/agent-skills-bridge) kit in a
project, so that Claude Code loads the Agent Skills kept in `.agents/skills`. The other uninstalls
it again.

The plugin adds no hook, no server and no program to your sessions. Its skills run only when you
type their names: Claude never starts one by itself, because the first adds hooks to the project
and the second takes them out.

## Add the plugin, once per machine

In a Claude Code session, 2.1.275 or newer:

```text
/plugin install agent-skills-bridge --marketplace dawidaleksanderwalczak/agent-skills-bridge
```

On an older Claude Code, in two steps:

```text
/plugin marketplace add dawidaleksanderwalczak/agent-skills-bridge
/plugin install agent-skills-bridge@agent-skills-bridge
```

From a terminal, write `claude plugin` in place of `/plugin`.

## Install the bridge, once per project

You need Python 3.11 or newer on PATH, under any name: `python3`, `python`, `py` or a versioned one
such as `python3.12`. Open the project in Claude Code and type:

```text
/agent-skills-bridge:installing-agent-skills-bridge
```

Claude runs the installer and reports what it did. The installer commits nothing: commit the files
that the report lists, and start a new session.

To update a project later, update the plugin and type the same command again.

## Uninstall the bridge from a project

With the same Python, open the project in Claude Code and type:

```text
/agent-skills-bridge:uninstalling-agent-skills-bridge
```

Claude runs the uninstaller and reports what it did. The uninstaller takes the bridge's hooks out
of `.claude/settings.json`, and deletes the kit's files, the copies in `.claude/skills` and the
bridge's records. Your other settings and hooks, your own skills and `.agents/skills` stay. It
commits nothing: commit the removal that the report lists, and start a new session.

The copies are in no repository, so a pull removes none of them. Type the command in every
checkout where a Claude Code session ran: it deletes the copies also where the kit is already gone.

## More

What the installer and the uninstaller do in each case, how to check the result and how to remove
the plugin from your machine: see the
[repository's README](https://github.com/dawidaleksanderwalczak/agent-skills-bridge#readme).
