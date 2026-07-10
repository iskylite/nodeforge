# NodeForge vendor notes

This directory vendors zli v5.1.2 at commit
`d6f38b85f7a69b537e90961f8780360208fa7786`.

NodeForge carries compatibility patches in `src/zli.zig` and
`src/lib/spinner.zig`:

- continue command discovery after a flag, so root flags may precede a
  subcommand;
- propagate values of persistent flags into the selected child command.
- treat the built-in help flag as persistent and let a conventional boolean
  version flag bypass leaf positional validation.
- avoid writing the ANSI “show cursor” sequence when a spinner was initialized
  but never started.

The patches preserve the documented form `nodeforge --config PATH config
validate` and keep non-spinner commands free of cursor-control bytes. Keep the
regression coverage in `tests/cli.sh` when upgrading zli.
