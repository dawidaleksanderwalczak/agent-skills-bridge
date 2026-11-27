# agent-skills-bridge

A Claude Code plugin with one skill. The skill installs the
[agent-skills-bridge](https://github.com/dawidaleksanderwalczak/agent-skills-bridge) kit in a
project, so that Claude Code loads the Agent Skills kept in `.agents/skills`.

The plugin adds no hook, no server and no program to your sessions. Its skill runs only when you
type its name: Claude never starts it by itself, because it adds hooks to the project.

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

You need Python 3.11 or newer on PATH. Open the project in Claude Code and type:

```text
/agent-skills-bridge:installing-agent-skills-bridge
```

Claude runs the installer and reports what it did. The installer commits nothing: commit the files
that the report lists, and start a new session.

To update a project later, update the plugin and type the same command again.

## More

What the installer does in each case, how to check the result and how to remove the bridge: see the
[repository's README](https://github.com/dawidaleksanderwalczak/agent-skills-bridge#readme).
