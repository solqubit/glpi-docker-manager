# Contributing

Use English for code, comments, technical documentation and pull requests. Keep
English and Spanish locale keys/printf placeholders aligned and update both
READMEs for user-visible behavior. The CLI language is independent from upstream
Docker/GLPI log language.

Read [architecture](docs/architecture.md) and [data operations](docs/data-operations.md)
before modifying lifecycle/data paths. Configuration is parsed as JSON; do not
introduce `source .env`, `eval`, unquoted user input, permanent latest tags,
unlabelled volume adoption or blanket Docker prune commands.

Run syntax/unit/negative tests and ShellCheck:

```bash
bash tests/run.sh
shellcheck -x start.sh lib/*.sh templates/*.sh tests/*.sh
```

For isolated Docker integration, use a development Linux machine with Docker:

```bash
GDM_INTEGRATION=1 bash tests/integration.sh
```

This is an explicit opt-in to create disposable test services/volumes. Tests keep
private evidence in ignored `tests/.runtime/` and remove only their own uniquely
labelled Docker projects. Never use production credentials or mount production
volumes in tests. A distribution fixture validates parsing, not actual package
installation, SELinux or boot behavior on that distribution; document evidence
honestly in the compatibility matrix.

The optional `tests/Dockerfile` builds a development runner, not a modified GLPI
image. Mount the repository at the same absolute path seen by the Docker daemon
for integration tests, since generated Compose files use absolute bind paths.
If using Docker Desktop, set `GDM_PROBE_HOST=host.docker.internal` in that runner
so published-port probes reach the host. Access to a mounted Docker socket is
privileged; use only trusted source code.
